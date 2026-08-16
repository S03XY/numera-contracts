// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {LsLmsrMarket} from "../src/markets/LsLmsrMarket.sol";
import {NumeraForwarder} from "../src/relay/NumeraForwarder.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {MarketTypes} from "../src/libraries/MarketTypes.sol";

/// @title RedeployEngine
/// @notice Replace the engine and its forwarder, keeping the collateral, resolver and registry.
///
/// @dev The engine and the forwarder are a **pair**: the engine trusts one forwarder immutably, and
///      the forwarder targets one engine permanently. Neither can be replaced alone, so this always
///      deploys both — but there is no reason to reissue the collateral token (which would strand
///      every balance), the resolver, or the factory.
///
///      Existing markets stay on the old engine and remain tradeable and claimable there. Markets
///      for the new engine are created afresh with `npm run seed:testnet`. Nothing migrates itself,
///      deliberately: silently moving books between engines would move traders' positions with them.
///
///      Usage:
///        PRIVATE_KEY=0x... forge script script/RedeployEngine.s.sol:RedeployEngine \
///          --rpc-url monad_testnet --broadcast
contract RedeployEngine is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", admin);
        uint256 tradeFeeBps = vm.envOr("TRADE_FEE_BPS", uint256(100));
        uint256 minTradeCost = vm.envOr("MIN_TRADE_COST", uint256(5e6));

        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory book = vm.readFile(path);
        address usdc = vm.parseJsonAddress(book, ".usdc");
        address factory = vm.parseJsonAddress(book, ".marketFactory");
        // Carried over rather than redeployed: the bans already written to it are the point of it
        // existing separately from the engine at all.
        address blocklist = vm.parseJsonAddress(book, ".tradingBlocklist");

        vm.startBroadcast(pk);

        NumeraForwarder forwarder = new NumeraForwarder(usdc, deployer);
        LsLmsrMarket engine = new LsLmsrMarket(admin, feeRecipient, address(forwarder), blocklist);
        forwarder.initialize(address(engine));

        // Asserted rather than assumed: a half-wired relay fails every trade, and it should fail
        // here instead of one user at a time.
        require(forwarder.market() == address(engine), "forwarder not wired to engine");
        require(engine.isTrustedForwarder(address(forwarder)), "engine does not trust forwarder");

        uint256 engineId = type(uint256).max;
        if (admin == deployer) {
            engineId = MarketFactory(factory)
                .registerEngine(address(engine), MarketTypes.Kind.LsLmsr, "Damped LS-LMSR v1.1");
            engine.setTradeFee(uint16(tradeFeeBps));
            engine.setMinTradeCost(usdc, minTradeCost);
        }

        vm.stopBroadcast();

        _rewriteBook(path, book, address(engine), address(forwarder));

        console2.log("=== engine + forwarder replaced ===");
        console2.log("LsLmsrMarket:    ", address(engine));
        console2.log("NumeraForwarder: ", address(forwarder));
        console2.log("engineId:        ", engineId);
        console2.log("");
        console2.log("Next: update LS_LMSR_MARKET_ADDRESS + NUMERA_FORWARDER_ADDRESS (backend),");
        console2.log("      NEXT_PUBLIC_NUMERA_FORWARDER (frontend), restart, then re-seed markets.");
    }

    /// @dev Rewrite the book in place, carrying every untouched address across from the old one.
    ///
    ///      Its own function for stack room, and every field is re-serialized because
    ///      `vm.serializeAddress` builds a fresh object — carrying one over by hand is how an
    ///      address goes stale. Reads come straight from `book`, so a key this script forgets is a
    ///      parse failure here rather than a silently dropped address later.
    function _rewriteBook(string memory path, string memory book, address engine, address forwarder) private {
        string memory obj = "addressBook";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "admin", vm.parseJsonAddress(book, ".admin"));
        vm.serializeAddress(obj, "deployer", vm.parseJsonAddress(book, ".deployer"));
        vm.serializeAddress(obj, "usdc", vm.parseJsonAddress(book, ".usdc"));
        vm.serializeBool(obj, "usdcIsTestToken", vm.parseJsonBool(book, ".usdcIsTestToken"));
        vm.serializeAddress(obj, "tradingBlocklist", vm.parseJsonAddress(book, ".tradingBlocklist"));
        vm.serializeAddress(obj, "trustedResolver", vm.parseJsonAddress(book, ".trustedResolver"));
        vm.serializeAddress(obj, "optimisticResolver", vm.parseJsonAddress(book, ".optimisticResolver"));
        vm.serializeAddress(obj, "resolverMultisig", vm.parseJsonAddress(book, ".resolverMultisig"));
        vm.serializeAddress(obj, "resolutionForwarder", vm.parseJsonAddress(book, ".resolutionForwarder"));
        vm.serializeAddress(obj, "marketFactory", vm.parseJsonAddress(book, ".marketFactory"));
        vm.serializeAddress(obj, "lsLmsrMarket", engine);
        string memory json = vm.serializeAddress(obj, "numeraForwarder", forwarder);
        vm.writeJson(json, path);
    }
}
