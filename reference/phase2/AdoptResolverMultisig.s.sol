// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TrustedResolver} from "../src/resolvers/TrustedResolver.sol";
import {ResolverMultisig} from "../src/access/ResolverMultisig.sol";
import {Roles} from "../src/access/Roles.sol";

/// @title AdoptResolverMultisig
/// @notice Hand an already-deployed {TrustedResolver} over to a signer quorum.
///
/// @dev **Why this is a migration and not a redeploy.** A market's `resolver` address is fixed in
///      `CreateParams` at creation, so live markets are stuck with the resolver they were born
///      with. But the resolver is only a role gate: moving `DEFAULT_ADMIN_ROLE` and `RESOLVER_ROLE`
///      onto a multisig changes who may settle without touching a single market.
///
///      **Both roles move, or none.** `DEFAULT_ADMIN_ROLE` can grant `RESOLVER_ROLE` to anybody, so
///      a deployer that renounces only the resolver role has given up nothing.
///
///      **Any previous multisig is retired.** Two quorums that can both settle is the kind of
///      leftover that looks harmless while their signer sets match and becomes a hole the moment
///      they diverge. This revokes the old one in the same transaction batch.
///
///      Usage:
///        PRIVATE_KEY=0x... RESOLVER_SIGNERS=0xaaa...,0xbbb... RESOLVER_THRESHOLD=2 \
///        forge script script/AdoptResolverMultisig.s.sol:AdoptResolverMultisig \
///          --rpc-url monad_testnet --broadcast
///
///      Environment variables:
///        PRIVATE_KEY        (required)  must currently hold DEFAULT_ADMIN_ROLE on the resolver
///        RESOLVER_ADMIN     (optional)  operator who manages the signer set; defaults to deployer
///        RESOLVER_SIGNERS   (optional)  comma-separated signers; defaults to [deployer]
///        RESOLVER_THRESHOLD (optional)  confirmations required; defaults to 1
///        RESOLVER_ADDRESS   (optional)  resolver to adopt; defaults to the address book's
///        PREVIOUS_MULTISIG  (optional)  a quorum to strip of its roles in the same run
///        RENOUNCE           (optional)  when true, the deployer drops both roles afterwards
///
///      `RENOUNCE` is opt-in and irreversible: once the deployer renounces, the multisig is the
///      only way back in. Run without it first, settle something through the quorum, then renounce.
contract AdoptResolverMultisig is Script {
    struct Config {
        uint256 pk;
        address deployer;
        address admin;
        address[] signers;
        uint256 threshold;
        address resolver;
        address previousMultisig;
        bool renounce;
    }

    function run() external {
        Config memory c = _readConfig();

        TrustedResolver resolver = TrustedResolver(c.resolver);
        bytes32 adminRole = resolver.DEFAULT_ADMIN_ROLE();
        require(resolver.hasRole(adminRole, c.deployer), "deployer is not the resolver's admin");

        vm.startBroadcast(c.pk);

        ResolverMultisig multisig = new ResolverMultisig(c.admin, c.signers, c.threshold);
        // The quorum can only call what the operator has adopted. Settlement is the whole point, so
        // the resolver goes in immediately; the private resolver is added by its own deploy script.
        multisig.addTarget(c.resolver);

        resolver.grantRole(adminRole, address(multisig));
        resolver.grantRole(Roles.RESOLVER_ROLE, address(multisig));

        // Assert before revoking anything. Getting this order wrong bricks settlement permanently.
        require(
            resolver.hasRole(adminRole, address(multisig))
                && resolver.hasRole(Roles.RESOLVER_ROLE, address(multisig)),
            "multisig did not receive both roles"
        );

        if (c.previousMultisig != address(0) && c.previousMultisig != address(multisig)) {
            resolver.revokeRole(Roles.RESOLVER_ROLE, c.previousMultisig);
            resolver.revokeRole(adminRole, c.previousMultisig);
        }

        if (c.renounce) {
            resolver.renounceRole(Roles.RESOLVER_ROLE, c.deployer);
            resolver.renounceRole(adminRole, c.deployer);
        }

        vm.stopBroadcast();

        _rewriteBook(address(multisig));
        _report(c, address(multisig));
    }

    function _readConfig() private view returns (Config memory c) {
        c.pk = vm.envUint("PRIVATE_KEY");
        c.deployer = vm.addr(c.pk);
        c.admin = vm.envOr("RESOLVER_ADMIN", c.deployer);
        c.renounce = vm.envOr("RENOUNCE", false);

        address[] memory fallbackSigners = new address[](1);
        fallbackSigners[0] = c.deployer;
        c.signers = vm.envOr("RESOLVER_SIGNERS", ",", fallbackSigners);
        c.threshold = vm.envOr("RESOLVER_THRESHOLD", uint256(1));

        string memory book = vm.readFile(_bookPath());
        c.resolver = vm.envOr("RESOLVER_ADDRESS", vm.parseJsonAddress(book, ".trustedResolver"));
        // Named explicitly rather than read from the address book. A dry run rewrites that file
        // even though it sends nothing, so the book already names the about-to-be-deployed multisig
        // by the time the real broadcast reads it — and the old one silently keeps its roles.
        // Whoever is retiring a quorum knows its address; make them say it.
        c.previousMultisig = vm.envOr("PREVIOUS_MULTISIG", address(0));
    }

    function _bookPath() private view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
    }

    /// @dev Every field is re-serialized because `vm.serializeAddress` builds a fresh object;
    ///      carrying one over by hand is how an address goes stale.
    function _rewriteBook(address multisig) private {
        string memory path = _bookPath();
        string memory book = vm.readFile(path);

        string memory obj = "addressBook";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "admin", vm.parseJsonAddress(book, ".admin"));
        vm.serializeAddress(obj, "deployer", vm.parseJsonAddress(book, ".deployer"));
        vm.serializeAddress(obj, "usdc", vm.parseJsonAddress(book, ".usdc"));
        vm.serializeBool(obj, "usdcIsTestToken", vm.parseJsonBool(book, ".usdcIsTestToken"));
        vm.serializeAddress(obj, "trustedResolver", vm.parseJsonAddress(book, ".trustedResolver"));
        vm.serializeAddress(obj, "resolverMultisig", multisig);
        vm.serializeAddress(obj, "lsLmsrMarket", vm.parseJsonAddress(book, ".lsLmsrMarket"));
        vm.serializeAddress(obj, "numeraForwarder", vm.parseJsonAddress(book, ".numeraForwarder"));
        string memory json =
            vm.serializeAddress(obj, "marketFactory", vm.parseJsonAddress(book, ".marketFactory"));
        vm.writeJson(json, path);
    }

    function _report(Config memory c, address multisig) private pure {
        console2.log("=== resolver adopted by multisig ===");
        console2.log("TrustedResolver: ", c.resolver);
        console2.log("ResolverMultisig:", multisig);
        console2.log("admin (operator):", c.admin);
        console2.log("signers:         ", c.signers.length);
        console2.log("threshold:       ", c.threshold);
        if (c.previousMultisig != address(0)) {
            console2.log("retired multisig:", c.previousMultisig);
        }
        if (c.renounce) {
            console2.log("deployer roles:   RENOUNCED - the multisig is now the only way in.");
        } else {
            console2.log("deployer roles:   RETAINED - re-run with RENOUNCE=true to complete.");
        }
        console2.log("");
        console2.log("Next: set RESOLVER_MULTISIG_ADDRESS in backend/.env and restart the API.");
    }
}
