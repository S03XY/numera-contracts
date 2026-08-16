// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PrivateOptimisticResolver} from "../src/resolvers/PrivateOptimisticResolver.sol";
import {ResolutionForwarder} from "../src/relay/ResolutionForwarder.sol";
import {ResolverMultisig} from "../src/access/ResolverMultisig.sol";
import {TrustedResolver} from "../src/resolvers/TrustedResolver.sol";
import {Roles} from "../src/access/Roles.sol";

/// @title DeployPrivateResolution
/// @notice Add bonded, private, permissionless proposals on top of an existing deployment.
///
/// @dev **Nothing about live markets changes.** A market's `resolver` is fixed at creation, so this
///      does not try to replace it. Instead the new resolver is granted `RESOLVER_ROLE` on the
///      {TrustedResolver} those markets already point at, which lets it settle books created long
///      before it existed. The operator's own path through the multisig keeps working untouched.
///
///      Three things get deployed and wired:
///
///        1. {ResolutionForwarder} — a second relay, so a market account can propose without gas.
///        2. {PrivateOptimisticResolver} — bonds, dispute window, rewards, arbitration.
///        3. the grant, proposed through {ResolverMultisig}, since the multisig owns the resolver.
///
///      Usage:
///        PRIVATE_KEY=0x... forge script script/DeployPrivateResolution.s.sol:DeployPrivateResolution \
///          --rpc-url monad_testnet --broadcast
///
///      Environment variables:
///        PRIVATE_KEY          (required)  must be a signer on the resolver multisig
///        RESOLUTION_BOND      (optional)  bond per proposal/dispute, default 50e6 (50 USDC)
///        DISPUTE_WINDOW       (optional)  seconds a proposal can be challenged, default 6 hours
///        ARBITRATION_TIMEOUT  (optional)  seconds before a stuck dispute unwinds, default 7 days
///        RESOLUTION_REWARD_BPS(optional)  share of the pot paid for being right, default 100 (1%)
///        RESOLUTION_REWARD_CAP(optional)  ceiling on one reward, default 25e6 (25 USDC)
///        REWARD_POOL_FUNDING  (optional)  USDC to seed the reward pool with, default 0
///
///      The grant executes immediately when the multisig threshold is 1. Above that it is left as an
///      open proposal for the other signers, and the script says so rather than pretending it landed.
contract DeployPrivateResolution is Script {
    struct Config {
        uint256 pk;
        address deployer;
        address usdc;
        address trustedResolver;
        address multisig;
        uint256 bond;
        uint64 disputeWindow;
        uint64 arbitrationTimeout;
        uint16 rewardBps;
        uint256 rewardCap;
        uint256 funding;
    }

    function run() external {
        Config memory c = _readConfig();

        vm.startBroadcast(c.pk);

        ResolutionForwarder forwarder = new ResolutionForwarder(c.usdc, c.deployer);
        PrivateOptimisticResolver resolver = new PrivateOptimisticResolver(
            c.multisig,
            address(forwarder),
            c.usdc,
            c.trustedResolver,
            c.bond,
            c.disputeWindow,
            c.arbitrationTimeout,
            c.rewardBps,
            c.rewardCap
        );

        // Close the cycle, then assert it. A forwarder bound to nothing relays nothing, and a
        // resolver that does not trust the forwarder reads the relayer as the proposer — which would
        // silently attribute every proposal to us and destroy the privacy this exists for.
        forwarder.initialize(address(resolver));
        require(forwarder.resolver() == address(resolver), "forwarder not bound to resolver");
        require(resolver.isTrustedForwarder(address(forwarder)), "resolver does not trust forwarder");

        // Adopt the new resolver as a target, so the quorum can rule on challenges. The deployer
        // is the multisig's admin; the signers decide WHAT settles, the admin decides what they
        // may speak to.
        ResolverMultisig(c.multisig).addTarget(address(resolver));

        // The multisig owns TrustedResolver's roles, so the grant that lets the new resolver settle
        // goes through a proposal rather than a direct call.
        bytes memory grant = abi.encodeWithSignature(
            "grantRole(bytes32,address)", Roles.RESOLVER_ROLE, address(resolver)
        );
        ResolverMultisig(c.multisig).propose(c.trustedResolver, grant);

        if (c.funding > 0) {
            (bool ok,) = c.usdc.call(
                abi.encodeWithSignature("transfer(address,uint256)", address(resolver), c.funding)
            );
            require(ok, "reward pool funding failed");
        }

        vm.stopBroadcast();

        bool granted =
            TrustedResolver(c.trustedResolver).hasRole(Roles.RESOLVER_ROLE, address(resolver));
        _writeBook(address(forwarder), address(resolver));
        _report(c, address(forwarder), address(resolver), granted);
    }

    function _readConfig() private view returns (Config memory c) {
        c.pk = vm.envUint("PRIVATE_KEY");
        c.deployer = vm.addr(c.pk);

        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory book = vm.readFile(path);
        c.usdc = vm.parseJsonAddress(book, ".usdc");
        c.trustedResolver = vm.parseJsonAddress(book, ".trustedResolver");
        c.multisig = vm.parseJsonAddress(book, ".resolverMultisig");

        c.bond = vm.envOr("RESOLUTION_BOND", uint256(50e6));
        c.disputeWindow = uint64(vm.envOr("DISPUTE_WINDOW", uint256(6 hours)));
        c.arbitrationTimeout = uint64(vm.envOr("ARBITRATION_TIMEOUT", uint256(7 days)));
        c.rewardBps = uint16(vm.envOr("RESOLUTION_REWARD_BPS", uint256(100)));
        c.rewardCap = vm.envOr("RESOLUTION_REWARD_CAP", uint256(25e6));
        c.funding = vm.envOr("REWARD_POOL_FUNDING", uint256(0));
    }

    /// @dev Every field is re-serialized because `vm.serializeAddress` builds a fresh object;
    ///      carrying one over by hand is how an address goes stale.
    function _writeBook(address forwarder, address resolver) private {
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        string memory book = vm.readFile(path);

        string memory obj = "addressBook";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "admin", vm.parseJsonAddress(book, ".admin"));
        vm.serializeAddress(obj, "deployer", vm.parseJsonAddress(book, ".deployer"));
        vm.serializeAddress(obj, "usdc", vm.parseJsonAddress(book, ".usdc"));
        vm.serializeBool(obj, "usdcIsTestToken", vm.parseJsonBool(book, ".usdcIsTestToken"));
        vm.serializeAddress(obj, "trustedResolver", vm.parseJsonAddress(book, ".trustedResolver"));
        vm.serializeAddress(obj, "resolverMultisig", vm.parseJsonAddress(book, ".resolverMultisig"));
        vm.serializeAddress(obj, "privateResolver", resolver);
        vm.serializeAddress(obj, "resolutionForwarder", forwarder);
        vm.serializeAddress(obj, "lsLmsrMarket", vm.parseJsonAddress(book, ".lsLmsrMarket"));
        vm.serializeAddress(obj, "numeraForwarder", vm.parseJsonAddress(book, ".numeraForwarder"));
        string memory json =
            vm.serializeAddress(obj, "marketFactory", vm.parseJsonAddress(book, ".marketFactory"));
        vm.writeJson(json, path);
    }

    function _report(Config memory c, address forwarder, address resolver, bool granted)
        private
        pure
    {
        console2.log("=== private optimistic resolution deployed ===");
        console2.log("PrivateOptimisticResolver:", resolver);
        console2.log("ResolutionForwarder:      ", forwarder);
        console2.log("settles through:          ", c.trustedResolver);
        console2.log("bond:                     ", c.bond);
        console2.log("dispute window (s):       ", c.disputeWindow);
        console2.log("arbitration timeout (s):  ", c.arbitrationTimeout);
        console2.log("reward bps / cap:         ", c.rewardBps, c.rewardCap);
        console2.log("reward pool funded:       ", c.funding);
        if (granted) {
            console2.log("RESOLVER_ROLE:             GRANTED - proposals are live.");
        } else {
            console2.log("RESOLVER_ROLE:             PENDING - the multisig proposal needs more signers.");
            console2.log("Until it executes, proposals can be raised but finalize/arbitrate will revert.");
        }
        console2.log("");
        console2.log("Next: set PRIVATE_RESOLVER_ADDRESS + RESOLUTION_FORWARDER_ADDRESS in backend/.env,");
        console2.log("      NEXT_PUBLIC_RESOLUTION_FORWARDER in frontend/.env.local, then restart.");
    }
}
