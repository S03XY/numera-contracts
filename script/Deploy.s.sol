// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {LsLmsrMarket} from "../src/markets/LsLmsrMarket.sol";
import {TrustedResolver} from "../src/resolvers/TrustedResolver.sol";
import {OptimisticResolver} from "../src/resolvers/OptimisticResolver.sol";
import {ResolverMultisig} from "../src/resolvers/ResolverMultisig.sol";
import {TradingBlocklist} from "../src/access/TradingBlocklist.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";
import {NumeraForwarder} from "../src/relay/NumeraForwarder.sol";
import {ResolutionForwarder} from "../src/relay/ResolutionForwarder.sol";
import {MarketTypes} from "../src/libraries/MarketTypes.sol";
import {Roles} from "../src/access/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NumeraPoolEntrypoint} from "../src/pool/NumeraPoolEntrypoint.sol";
import {PrivacyPoolComplex} from "../src/pool/PrivacyPoolComplex.sol";
import {IPrivacyPool} from "../src/pool/interfaces/IPrivacyPool.sol";
import {WithdrawalVerifier} from "../src/pool/verifiers/WithdrawalVerifier.sol";
import {CommitmentVerifier} from "../src/pool/verifiers/CommitmentVerifier.sol";

/// @title Deploy
/// @notice Deploys the private prediction-market **infrastructure** and writes an address book.
///
/// @dev Usage (Monad testnet):
///        PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy \
///          --rpc-url monad_testnet --broadcast
///
///      Environment variables:
///        PRIVATE_KEY         (required)  deployer key; also the default admin
///        ADMIN               (optional)  protocol admin; defaults to the deployer
///        USDC_ADDRESS        (optional)  collateral; if unset, deploys TestUSDC with a faucet
///        USDC_IS_TEST_TOKEN  (optional)  set when reusing a faucet token, so seeding can still mint
///        RESOLVER_WALLETS    (optional)  wallets that may propose without a bond; default none
///        MULTISIG_SIGNERS    (optional)  arbitration signer set; defaults to [admin]
///        MULTISIG_THRESHOLD  (optional)  confirmations needed to arbitrate; defaults to 1
///        FEE_RECIPIENT       (optional)  receives resolution surplus and swept fees; default admin
///        TRADE_FEE_BPS       (optional)  the single all-in trading fee; defaults to 100 (1%)
///        MIN_TRADE_COST      (optional)  smallest accepted trade, collateral base units; default 5e6
///        BOND                (optional)  flat stake to propose or dispute; defaults to 25e6
///        PROPOSAL_FEE        (optional)  flat charge per proposal or dispute; defaults to 1e6
///        DISPUTE_WINDOW      (optional)  seconds a proposal stays challengeable; defaults to 6h
///        ARBITRATION_TIMEOUT (optional)  seconds before a stuck dispute unwinds; defaults to 3d
///        REWARD_BPS          (optional)  share of a market's fee revenue paid for being right; 200
///        REWARD_CAP          (optional)  ceiling on one reward; defaults to 50e6
///
///      Only the damped LS-LMSR engine is deployed. {ParimutuelMarket} and {LMSRMarket} remain in
///      the tree for reference but are no longer deployed or registered: a pooled book cannot let a
///      trader exit before settlement, and the fixed-`b` LMSR needs a protocol-funded `b*ln(n)`
///      subsidy that the damped curve removes the need for.
///
///      **Markets are deliberately not created here.** A market commits to a `metadataHash` that is
///      `keccak256` of a canonical JSON encoding of its title, description and outcome labels
///      (`backend/src/admin/metadata-hash.ts`). Rebuilding that exact JSON in Solidity would be
///      fragile and would duplicate the canonical encoder, so seeding runs through the real
///      operator path instead: `backend/scripts/seed-testnet-markets.ts`.
///
///      Output: `deployments/<chainid>.json`, consumed by the backend `.env` and the seeding script.
contract Deploy is Script {
    /// @dev Deployment inputs, gathered into structs rather than three dozen locals. `run()`
    ///      overflowed the stack once resolution was added, and this repo builds without `via_ir`
    ///      on purpose — a memory struct costs one slot instead of one per field.
    struct Config {
        uint256 pk;
        address deployer;
        address admin;
        address usdc;
        address[] resolverWallets;
        address[] signers;
        uint256 threshold;
        address feeRecipient;
        address relayer;
        uint256 tradeFeeBps;
        uint256 minTradeCost;
        bool deployedTestToken;
    }

    struct AddressBook {
        address admin;
        address deployer;
        address usdc;
        address blocklist;
        address trustedResolver;
        address optimisticResolver;
        address resolverMultisig;
        address lsLmsr;
        address forwarder;
        address resolutionForwarder;
        address factory;
        // ----- shielded pool -----
        address poolEntrypoint;
        address privacyPool;
        address withdrawalVerifier;
        address ragequitVerifier;
        bool deployedTestToken;
    }

    function run() external {
        Config memory c = _readConfig();
        AddressBook memory b;
        b.admin = c.admin;
        b.deployer = c.deployer;

        _deployCore(c, b);
        _deployResolution(c, b);
        _deployShieldedPool(c, b);
        uint256 engineId = _finishAsAdmin(c, b);

        _writeAddressBook(b);
        _report(c, b, engineId);
    }

    function _readConfig() private view returns (Config memory c) {
        c.pk = vm.envUint("PRIVATE_KEY");
        c.deployer = vm.addr(c.pk);
        c.admin = vm.envOr("ADMIN", c.deployer);
        c.usdc = vm.envOr("USDC_ADDRESS", address(0));
        c.feeRecipient = vm.envOr("FEE_RECIPIENT", c.admin);
        // The backend's gas relayer, which also submits pool withdrawals and publishes ASP roots.
        // Defaults to the deployer so a local run needs no extra configuration.
        c.relayer = vm.envOr("RELAYER_ADDRESS", c.deployer);

        // Wallets that may propose an outcome without posting a bond. They are not a shortcut past
        // the dispute window — a trusted proposal is challengeable on exactly the same terms as a
        // stranger's — so this is a speed grant, not an authority grant. Revocable at any time.
        c.resolverWallets = vm.envOr("RESOLVER_WALLETS", ",", new address[](0));

        // The arbitration quorum: the only thing that can overturn a proposal. Defaults to the admin
        // alone, which is a one-of-one quorum and honestly just the admin. Add signers before this
        // matters.
        c.signers = vm.envOr("MULTISIG_SIGNERS", ",", new address[](0));
        if (c.signers.length == 0) {
            c.signers = new address[](1);
            c.signers[0] = c.admin;
        }
        c.threshold = vm.envOr("MULTISIG_THRESHOLD", uint256(1));

        // One all-in fee, 1% by default: the platform's whole take, with gas sponsored out of it.
        c.tradeFeeBps = vm.envOr("TRADE_FEE_BPS", uint256(100));
        // 5 USDC. Not a UX preference — this is the bound that makes an unauthenticated relayer safe.
        // At 1% the smallest legal trade yields a 0.05 USDC fee, against a measured ~0.054 MON of
        // relayed gas. Those are different assets, so the margin is a price ratio and not a constant:
        // the floor holds while MON stays under roughly $0.10 and must be raised above that. Track
        // the ratio, not this number. See `LsLmsrMarket.minTradeCost`.
        c.minTradeCost = vm.envOr("MIN_TRADE_COST", uint256(5e6));
    }

    /// @dev Bond and reward settings. Read in their own function purely for stack room.
    function _readParameters() private view returns (OptimisticResolver.Parameters memory p) {
        // 25 USDC. Flat on every market: the bond deters spam and puts skin in the game, and
        // neither of those has a reason to grow with the pot. Large enough that a false proposal
        // costs real money, small enough that an honest trader is not priced out of correcting one.
        p.bond = vm.envOr("BOND", uint256(25e6));
        // 1 USDC to use the layer. Kept whether or not the proposer turns out to be right.
        p.proposalFee = vm.envOr("PROPOSAL_FEE", uint256(1e6));
        // Six hours: long enough that a losing holder in any timezone can see a false proposal,
        // short enough that an honest settlement is not held up for a day.
        p.disputeWindow = uint64(vm.envOr("DISPUTE_WINDOW", uint256(6 hours)));
        // Three days for the quorum to rule before anyone may unwind the dispute and return bonds.
        p.arbitrationTimeout = uint64(vm.envOr("ARBITRATION_TIMEOUT", uint256(3 days)));
        // 2% of what the market earned in fees, capped at 50 USDC.
        p.rewardBps = uint16(vm.envOr("REWARD_BPS", uint256(200)));
        p.rewardCap = vm.envOr("REWARD_CAP", uint256(50e6));
    }

    function _deployCore(Config memory c, AddressBook memory b) private {
        vm.startBroadcast(c.pk);

        // 1) Collateral. Real USDC in production; on testnet a faucet token, because Unlink's own
        //    faucet only dispenses tokens configured on their side — ours has to bring its own.
        //
        //    Reusing an existing token across a redeploy is the normal case, not the exception: a
        //    new collateral address strands every balance anybody has already been given. Hence the
        //    override — the seeding script mints against this flag, so carrying a faucet token
        //    forward has to carry the flag with it.
        c.deployedTestToken = c.usdc == address(0) || vm.envOr("USDC_IS_TEST_TOKEN", false);
        if (c.usdc == address(0)) {
            c.usdc = address(new TestUSDC(c.admin));
        }

        // 2) The ban list. First, because the engine holds it immutably and the resolver writes to
        //    it. Nothing else depends on the order, and nothing here can fail.
        TradingBlocklist blocklist = new TradingBlocklist(c.admin);

        // 3) Settlement authority. Every market binds to this and can never be rebound, so it is
        //    deliberately the thinnest contract in the system: a role gate and nothing else. What
        //    holds the role is what actually decides outcomes, and that is replaceable.
        TrustedResolver resolver = new TrustedResolver(c.admin);

        // 4) Gas relay, so a trader's market account never holds native gas and so never has to
        //    receive a public transfer that would deanonymise it.
        //
        //    Deployed before the engine because the engine trusts it immutably. The reverse edge —
        //    the forwarder's single permitted destination — is wired immediately below and frozen.
        NumeraForwarder forwarder = new NumeraForwarder(c.usdc, c.deployer);

        // 5) Pricing engine. One engine hosts every market; collateral is tracked per market.
        LsLmsrMarket lsLmsr =
            new LsLmsrMarket(c.admin, c.feeRecipient, address(forwarder), address(blocklist));

        // 5a) Close the cycle. `initialize` is gated on the deployer and reverts if called twice, so
        //     past this line the forwarder can never relay anywhere but this engine. Asserted rather
        //     than assumed: a half-wired relay fails every trade, and it should fail here instead.
        forwarder.initialize(address(lsLmsr));
        require(forwarder.market() == address(lsLmsr), "forwarder not wired to engine");
        require(lsLmsr.isTrustedForwarder(address(forwarder)), "engine does not trust forwarder");
        require(address(lsLmsr.blocklist()) == address(blocklist), "engine not wired to blocklist");

        // 6) Registry / catalog.
        MarketFactory factory = new MarketFactory(c.admin);

        vm.stopBroadcast();

        b.usdc = c.usdc;
        b.blocklist = address(blocklist);
        b.trustedResolver = address(resolver);
        b.lsLmsr = address(lsLmsr);
        b.forwarder = address(forwarder);
        b.factory = address(factory);
        b.deployedTestToken = c.deployedTestToken;
    }

    /// @dev The resolution layer, and the wiring that makes it the *only* way into the engine.
    function _deployResolution(Config memory c, AddressBook memory b) private {
        vm.startBroadcast(c.pk);

        // 7) The arbitration quorum. Its own admin decides membership; the signers decide outcomes.
        ResolverMultisig multisig = new ResolverMultisig(c.admin, c.signers, c.threshold);

        // 8) A second relay, so a proposer never holds gas either. Same shape as the trading one:
        //    a single frozen destination and a fixed selector set.
        ResolutionForwarder relay = new ResolutionForwarder(c.usdc, c.deployer);

        // 9) The optimistic layer itself.
        OptimisticResolver optimistic = new OptimisticResolver(
            c.admin,
            address(multisig),
            address(relay),
            c.usdc,
            b.trustedResolver,
            b.blocklist,
            _readParameters()
        );

        relay.initialize(address(optimistic));
        require(relay.resolver() == address(optimistic), "resolution relay not wired");
        require(optimistic.isTrustedForwarder(address(relay)), "resolver does not trust relay");

        vm.stopBroadcast();

        b.resolverMultisig = address(multisig);
        b.resolutionForwarder = address(relay);
        b.optimisticResolver = address(optimistic);

        _wireAuthority(c, b);
    }

    /**
     * @dev The shielded pool: where collateral lives between the wallet and the bet.
     *
     * Deployed after the engine because nothing else depends on it, and before `_finishAsAdmin` so
     * the roles below are granted in the same broadcast as everything else.
     *
     * The pool and its entrypoint each need the other's address at construction, which is a cycle.
     * It is broken by predicting one: the entrypoint is the very next contract this deployer
     * creates, so its address is `CREATE(deployer, nonce + 1)`. Predicting beats a two-step
     * initializer, because an entrypoint that can be re-pointed at a different pool later is an
     * entrypoint that can be re-pointed at an attacker's pool later. The assertion afterwards is
     * what turns a wrong guess into a failed deployment rather than a live pool nobody can use.
     *
     * Both Poseidon libraries are deployed and linked by forge automatically — they are `external`,
     * so every contract that hashes with them carries a 20-byte hole until they exist.
     */
    function _deployShieldedPool(Config memory c, AddressBook memory b) private {
        vm.startBroadcast(c.pk);

        WithdrawalVerifier withdrawalVerifier = new WithdrawalVerifier();
        CommitmentVerifier ragequitVerifier = new CommitmentVerifier();

        address predicted = vm.computeCreateAddress(c.deployer, vm.getNonce(c.deployer) + 1);
        PrivacyPoolComplex pool = new PrivacyPoolComplex(
            predicted, address(withdrawalVerifier), address(ragequitVerifier), b.usdc
        );
        NumeraPoolEntrypoint entrypoint =
            new NumeraPoolEntrypoint(c.admin, IPrivacyPool(address(pool)), IERC20(b.usdc));
        require(address(entrypoint) == predicted, "pool/entrypoint address prediction failed");

        // The relayer submits withdrawal proofs; the ASP service publishes association roots. Both
        // are the backend, and both are least-privilege: neither can move funds on its own, because
        // a payout goes only to the recipient sealed inside a proof.
        //
        // Skipped when the admin is somebody else, exactly as `_wireAuthority` does below: the
        // grants are the admin's to make, and a deployer that is not the admin cannot make them.
        // The report at the end prints what is left to do.
        if (c.admin == c.deployer) {
            entrypoint.grantRole(entrypoint.RELAYER_ROLE(), c.relayer);
            entrypoint.grantRole(entrypoint.ASP_POSTMAN_ROLE(), c.relayer);
        }

        vm.stopBroadcast();

        b.withdrawalVerifier = address(withdrawalVerifier);
        b.ragequitVerifier = address(ragequitVerifier);
        b.privacyPool = address(pool);
        b.poolEntrypoint = address(entrypoint);
    }

    /// @dev Move the settlement authority onto the optimistic layer and take it off the operator.
    ///
    ///      The revocation on the last line is the part that matters. `TrustedResolver` grants its
    ///      admin `RESOLVER_ROLE` at construction, and leaving that in place would give the operator
    ///      a direct route to the engine that skips the dispute window entirely — which would make
    ///      "an operator proposal can be challenged like anyone else's" untrue in one call.
    ///
    ///      Break glass is `grantRole(RESOLVER_ROLE, wallet)` from the resolver's admin. That is
    ///      deliberately a visible on-chain act rather than a standing power.
    function _wireAuthority(Config memory c, AddressBook memory b) private {
        if (c.admin != c.deployer) return;

        vm.startBroadcast(c.pk);

        // The optimistic layer is now the one thing that can settle a market.
        TrustedResolver(b.trustedResolver).grantRole(Roles.RESOLVER_ROLE, b.optimisticResolver);

        // It bans the accounts arbitration finds to have lied.
        TradingBlocklist(b.blocklist).grantRole(Roles.BLOCKLIST_ROLE, b.optimisticResolver);

        // The quorum may call it. Nothing else is in scope for the signers — not the engine, not
        // the factory, not the forwarders.
        ResolverMultisig(b.resolverMultisig).addTarget(b.optimisticResolver);

        // Wallets that propose without a bond.
        for (uint256 i = 0; i < c.resolverWallets.length; ++i) {
            OptimisticResolver(b.optimisticResolver).grantRole(Roles.RESOLVER_ROLE, c.resolverWallets[i]);
        }

        TrustedResolver(b.trustedResolver).revokeRole(Roles.RESOLVER_ROLE, c.admin);
        vm.stopBroadcast();

        require(
            TrustedResolver(b.trustedResolver).hasRole(Roles.RESOLVER_ROLE, b.optimisticResolver),
            "optimistic resolver cannot settle"
        );
        require(
            !TrustedResolver(b.trustedResolver).hasRole(Roles.RESOLVER_ROLE, c.admin),
            "operator retains a direct settlement path"
        );
    }

    /// @dev Engine registration, categories and fee configuration must all be signed by `admin`.
    ///      When the deployer is the admin we can finish here; otherwise the admin runs them
    ///      separately and this returns a sentinel.
    function _finishAsAdmin(Config memory c, AddressBook memory b) private returns (uint256 engineId) {
        engineId = type(uint256).max;
        if (c.admin != c.deployer) return engineId;

        vm.startBroadcast(c.pk);
        engineId =
            MarketFactory(b.factory).registerEngine(b.lsLmsr, MarketTypes.Kind.LsLmsr, "Damped LS-LMSR v1");
        // Only SPORTS is enabled: the category nav is backend-driven and self-hiding, so a single
        // enabled category renders no switcher. The rest are registered but disabled so enabling one
        // later is a config flip, not a deploy.
        MarketFactory(b.factory).setCategory(bytes32("SPORTS"), "Sports", true);
        MarketFactory(b.factory).setCategory(bytes32("ESPORTS"), "Esports", false);
        MarketFactory(b.factory).setCategory(bytes32("POLITICS"), "Politics", false);
        MarketFactory(b.factory).setCategory(bytes32("CRYPTO"), "Crypto", false);

        // The single all-in trading fee, and the floor that makes sponsored gas safe to offer. Set
        // here rather than in the constructor so the engine deploys fee-free and turning the fee on
        // is a reversible operational step.
        LsLmsrMarket(b.lsLmsr).setTradeFee(uint16(c.tradeFeeBps));
        LsLmsrMarket(b.lsLmsr).setMinTradeCost(b.usdc, c.minTradeCost);
        vm.stopBroadcast();
    }

    function _report(Config memory c, AddressBook memory b, uint256 engineId) private view {
        console2.log("=== Numera prediction market deployed ===");
        console2.log("chainid:              ", block.chainid);
        console2.log("admin:                ", b.admin);
        console2.log("collateral:           ", b.usdc);
        console2.log("TradingBlocklist:     ", b.blocklist);
        console2.log("TrustedResolver:      ", b.trustedResolver);
        console2.log("OptimisticResolver:   ", b.optimisticResolver);
        console2.log("ResolverMultisig:     ", b.resolverMultisig);
        console2.log("ResolutionForwarder:  ", b.resolutionForwarder);
        console2.log("LsLmsrMarket:         ", b.lsLmsr);
        console2.log("NumeraForwarder:      ", b.forwarder);
        console2.log("MarketFactory:        ", b.factory);
        console2.log("feeRecipient:         ", c.feeRecipient);
        console2.log("tradeFeeBps:          ", c.tradeFeeBps);
        console2.log("minTradeCost:         ", c.minTradeCost);
        console2.log("bond-free wallets:    ", c.resolverWallets.length + 1);
        console2.log("quorum:               ", c.threshold);
        console2.log("of signers:           ", c.signers.length);
        if (b.admin == b.deployer) {
            console2.log("engineId lsLmsr:      ", engineId);
        } else {
            console2.log("NOTE: admin != deployer - the admin must run registration and role wiring.");
        }
        console2.log("");
        console2.log("Settlement now runs ONLY through the optimistic layer. The operator holds no");
        console2.log("direct RESOLVER_ROLE on TrustedResolver; break glass is a visible grantRole.");
        console2.log("");
        console2.log("Next: fund the reward pool, then");
        console2.log("      backend: npm run seed:testnet   (drafts metadata + creates markets)");
    }

    /// @dev Emitted as JSON so the backend `.env` and the seeding script consume one artifact
    ///      rather than being hand-copied from console output — which is how address typos happen.
    function _writeAddressBook(AddressBook memory b) private {
        string memory obj = "addressBook";
        vm.serializeUint(obj, "chainId", block.chainid);
        // Where to start reading logs from. Without it every consumer either guesses a lookback —
        // which breaks once the deployment is old — or replays from genesis and gets rate limited.
        vm.serializeUint(obj, "deployBlock", block.number);
        vm.serializeAddress(obj, "admin", b.admin);
        vm.serializeAddress(obj, "deployer", b.deployer);
        vm.serializeAddress(obj, "usdc", b.usdc);
        vm.serializeBool(obj, "usdcIsTestToken", b.deployedTestToken);
        vm.serializeAddress(obj, "tradingBlocklist", b.blocklist);
        vm.serializeAddress(obj, "trustedResolver", b.trustedResolver);
        vm.serializeAddress(obj, "optimisticResolver", b.optimisticResolver);
        vm.serializeAddress(obj, "resolverMultisig", b.resolverMultisig);
        vm.serializeAddress(obj, "resolutionForwarder", b.resolutionForwarder);
        vm.serializeAddress(obj, "lsLmsrMarket", b.lsLmsr);
        vm.serializeAddress(obj, "numeraForwarder", b.forwarder);
        vm.serializeAddress(obj, "marketFactory", b.factory);
        vm.serializeAddress(obj, "privacyPool", b.privacyPool);
        vm.serializeAddress(obj, "withdrawalVerifier", b.withdrawalVerifier);
        vm.serializeAddress(obj, "ragequitVerifier", b.ragequitVerifier);
        string memory json = vm.serializeAddress(obj, "poolEntrypoint", b.poolEntrypoint);

        string memory path =
            string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("address book ->", path);
    }
}
