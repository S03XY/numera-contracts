// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {ResolutionForwarder} from "../src/relay/ResolutionForwarder.sol";
import {OptimisticResolver} from "../src/resolvers/OptimisticResolver.sol";
import {TrustedResolver} from "../src/resolvers/TrustedResolver.sol";
import {TradingBlocklist} from "../src/access/TradingBlocklist.sol";
import {MockOptimisticMarket} from "../src/mocks/MockOptimisticMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Roles} from "../src/access/Roles.sol";

/// @title RelayedResolutionTest
/// @notice The privacy half: a market account proposes and disputes while holding zero native gas.
///
/// @dev This is the property the whole design rests on. If a proposer ever has to send their own
///      transaction, they need gas; if they need gas, someone has to fund them; and a public
///      transfer into a market account retroactively deanonymises every position it holds. So the
///      account signs and never sends, exactly as it does when trading.
///
///      On every other prediction market, whoever proposes an outcome reveals which side they hold.
contract RelayedResolutionTest is Test {
    bytes32 internal constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    ResolutionForwarder internal forwarder;
    OptimisticResolver internal resolver;
    TrustedResolver internal trusted;
    TradingBlocklist internal blocklist;
    MockOptimisticMarket internal market;
    MockERC20 internal usdc;

    address internal operator = makeAddr("operator");
    address internal arbitrator = makeAddr("arbitrator");
    address internal relayer = makeAddr("relayer");
    address internal deployer = address(this);

    uint256 internal proposerPk = 0xA11CE;
    uint256 internal disputerPk = 0xB0B;
    address internal proposer;
    address internal disputer;

    uint256 internal constant USDC = 1e6;
    uint256 internal constant BOND = 50 * USDC;
    uint256 internal constant FEE = 1 * USDC;
    uint256 internal constant REWARD = 10 * USDC;
    uint256 internal constant START = 500 * USDC;
    uint64 internal constant DISPUTE_WINDOW = 6 hours;
    uint64 internal constant ARBITRATION_TIMEOUT = 7 days;

    uint256 internal constant MARKET_ID = 1;
    uint64 internal closeTime;

    function setUp() public {
        proposer = vm.addr(proposerPk);
        disputer = vm.addr(disputerPk);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(block.timestamp + 1 days);

        blocklist = new TradingBlocklist(operator);
        trusted = new TrustedResolver(operator);
        forwarder = new ResolutionForwarder(address(usdc), deployer);

        OptimisticResolver.Parameters memory p;
        p.bond = BOND;
        p.proposalFee = FEE;
        p.disputeWindow = DISPUTE_WINDOW;
        p.arbitrationTimeout = ARBITRATION_TIMEOUT;
        p.rewardBps = 200; // 2% of the market's fee revenue
        p.rewardCap = 25 * USDC;

        resolver = new OptimisticResolver(
            operator, arbitrator, address(forwarder), address(usdc), address(trusted), address(blocklist), p
        );
        forwarder.initialize(address(resolver));

        vm.startPrank(operator);
        trusted.grantRole(Roles.RESOLVER_ROLE, address(resolver));
        blocklist.grantRole(Roles.BLOCKLIST_ROLE, address(resolver));
        vm.stopPrank();

        market = new MockOptimisticMarket(address(trusted), closeTime, 3, 10_000 * USDC);
        market.setFees(500 * USDC); // → a 10 USDC reward, under the cap
        usdc.mint(address(resolver), 1_000 * USDC);

        address[2] memory accounts = [proposer, disputer];
        for (uint256 i = 0; i < accounts.length; ++i) {
            usdc.mint(accounts[i], START);
            vm.prank(accounts[i]);
            usdc.approve(address(resolver), type(uint256).max);
        }

        vm.deal(relayer, 10 ether);
        vm.warp(closeTime);
    }

    // ------------------------------------------------------------------ helpers

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("Numera Resolution Forwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(forwarder)
            )
        );
    }

    /// @dev A real EIP-712 signature over the real typehash, reconstructed rather than taken from
    ///      the contract, so a change to either side fails instead of both moving together.
    function _sign(uint256 pk, bytes memory data, uint256 gas)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory request)
    {
        address from = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(
                FORWARD_REQUEST_TYPEHASH,
                from,
                address(resolver),
                uint256(0),
                gas,
                forwarder.nonces(from),
                uint48(block.timestamp + 1 hours),
                keccak256(data)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        request = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: address(resolver),
            value: 0,
            gas: gas,
            deadline: uint48(block.timestamp + 1 hours),
            data: data,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _proposeData(uint256 outcomeId) internal view returns (bytes memory) {
        return abi.encodeCall(OptimisticResolver.propose, (address(market), MARKET_ID, outcomeId));
    }

    function _disputeData(uint256 counterOutcomeId) internal view returns (bytes memory) {
        return abi.encodeCall(OptimisticResolver.dispute, (address(market), MARKET_ID, counterOutcomeId));
    }

    function _relay(uint256 pk, bytes memory data) internal {
        vm.prank(relayer);
        forwarder.execute(_sign(pk, data, 300_000));
    }

    function _proposal() internal view returns (OptimisticResolver.Proposal memory) {
        return resolver.getProposal(address(market), MARKET_ID);
    }

    // ------------------------------------------------------------------ the property

    function test_marketAccountProposesWithZeroGas() public {
        assertEq(proposer.balance, 0, "precondition: the account holds no native gas");

        _relay(proposerPk, _proposeData(2));

        // The bond came from the market account, and the resolver recorded IT as the proposer —
        // not the relayer that paid for the transaction.
        assertEq(_proposal().proposer, proposer, "the account is on record, not the relayer");
        assertEq(usdc.balanceOf(proposer), START - BOND - FEE, "the account paid");
        assertEq(proposer.balance, 0, "the account still holds no native gas");
        assertEq(usdc.balanceOf(relayer), 0, "the relayer paid nothing but gas");
    }

    function test_marketAccountDisputesWithZeroGas() public {
        _relay(proposerPk, _proposeData(0));
        _relay(disputerPk, _disputeData(2));

        OptimisticResolver.Proposal memory p = _proposal();
        assertEq(p.disputer, disputer, "the disputing account is on record");
        assertEq(p.counterOutcome, 2, "and so is what it says the answer is");
        assertEq(uint8(p.phase), uint8(OptimisticResolver.Phase.Disputed), "phase moved");
        assertEq(disputer.balance, 0, "still no gas");
    }

    /// @dev End to end through the relay: a false proposal is caught, the watcher is paid, the liar
    ///      forfeits the stake, and the liar's account loses the right to trade — all of it landing
    ///      on shielded accounts that never held a wei of gas.
    function test_fullDisputedFlowThroughTheRelay() public {
        _relay(proposerPk, _proposeData(0));
        _relay(disputerPk, _disputeData(2));

        uint256 disputerAfterBonding = usdc.balanceOf(disputer);

        vm.prank(arbitrator);
        resolver.arbitrate(address(market), MARKET_ID, 2);

        assertTrue(market.resolved(), "settled");
        assertEq(market.lastWinningOutcome(), 2, "to the disputer's answer");
        assertEq(usdc.balanceOf(disputer), disputerAfterBonding + BOND + REWARD, "stake back plus reward");
        assertEq(usdc.balanceOf(proposer), START - BOND - FEE, "the liar is out a whole bond");
        assertTrue(blocklist.isBanned(proposer), "and off the market");
        assertFalse(blocklist.isBanned(disputer), "the watcher is untouched");
    }

    /// @dev The uncontested path, which is what most settlements will actually be.
    function test_fullUncontestedFlowThroughTheRelay() public {
        _relay(proposerPk, _proposeData(2));

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        resolver.finalize(address(market), MARKET_ID);

        assertTrue(market.resolved(), "settled");
        assertEq(usdc.balanceOf(proposer), START - FEE + REWARD, "paid for the service, less the fee");
        assertFalse(blocklist.isBanned(proposer), "nobody was wrong");
    }

    // ------------------------------------------------------------------ the guards

    function test_forwarder_relaysNothingButProposeAndDispute() public view {
        assertTrue(forwarder.isRelayable(OptimisticResolver.propose.selector), "propose");
        assertTrue(forwarder.isRelayable(OptimisticResolver.dispute.selector), "dispute");

        // Everything that moves money on the operator's authority, or out of the pool, is unreachable.
        bytes4[4] memory forbidden = [
            OptimisticResolver.arbitrate.selector,
            OptimisticResolver.withdrawRewardPool.selector,
            OptimisticResolver.sweepFees.selector,
            OptimisticResolver.setParameters.selector
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            assertFalse(forwarder.isRelayable(forbidden[i]), "forbidden selector is relayable");
        }
    }

    function test_forwarder_rejectsAForbiddenSelector() public {
        bytes memory data =
            abi.encodeCall(OptimisticResolver.withdrawRewardPool, (address(0xdead), 1_000 * USDC));
        ERC2771Forwarder.ForwardRequestData memory request = _sign(proposerPk, data, 300_000);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionForwarder.SelectorNotAllowed.selector, bytes4(data)));
        forwarder.execute(request);
    }

    function test_forwarder_rejectsAnyTargetButTheResolver() public {
        ERC2771Forwarder.ForwardRequestData memory request = _sign(proposerPk, _proposeData(0), 300_000);
        request.to = address(market);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ResolutionForwarder.TargetNotAllowed.selector, address(market))
        );
        forwarder.execute(request);
    }

    function test_forwarder_rejectsAnAbsurdGasRequest() public {
        uint256 tooMuch = forwarder.MAX_RELAY_GAS() + 1;
        ERC2771Forwarder.ForwardRequestData memory request = _sign(proposerPk, _proposeData(0), tooMuch);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ResolutionForwarder.GasCapExceeded.selector, tooMuch, forwarder.MAX_RELAY_GAS()
            )
        );
        forwarder.execute(request);
    }

    function test_forwarder_refusesBatches() public {
        ERC2771Forwarder.ForwardRequestData[] memory batch = new ERC2771Forwarder.ForwardRequestData[](1);
        batch[0] = _sign(proposerPk, _proposeData(0), 300_000);

        vm.prank(relayer);
        vm.expectRevert(ResolutionForwarder.BatchNotSupported.selector);
        forwarder.executeBatch(batch, payable(relayer));
    }

    function test_forwarder_initializeIsOneShotAndDeployerOnly() public {
        ResolutionForwarder fresh = new ResolutionForwarder(address(usdc), deployer);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ResolutionForwarder.NotInitializer.selector, relayer));
        fresh.initialize(address(resolver));

        fresh.initialize(address(resolver));
        vm.expectRevert(ResolutionForwarder.AlreadyInitialized.selector);
        fresh.initialize(address(resolver));
    }

    /// @dev The relayer's pre-flight. It should drop a request it can predict will fail rather than
    ///      pay for the revert, and it must agree with what the chain actually enforces.
    function test_verifyRelayable_agreesWithExecute() public view {
        ERC2771Forwarder.ForwardRequestData memory good = _sign(proposerPk, _proposeData(0), 300_000);
        assertTrue(forwarder.verifyRelayable(good), "a good request");

        ERC2771Forwarder.ForwardRequestData memory wrongTarget = good;
        wrongTarget.to = address(market);
        assertFalse(forwarder.verifyRelayable(wrongTarget), "wrong target");

        ERC2771Forwarder.ForwardRequestData memory badSelector = _sign(
            proposerPk, abi.encodeCall(OptimisticResolver.finalize, (address(market), MARKET_ID)), 300_000
        );
        assertFalse(forwarder.verifyRelayable(badSelector), "unrelayable selector");
    }

    /// @dev The signature is the whole authorisation. A relayer that alters the payload gets nothing,
    ///      which is what makes it safe for the relayer to be unauthenticated.
    function test_relayerCannotAlterTheProposedOutcome() public {
        ERC2771Forwarder.ForwardRequestData memory request = _sign(proposerPk, _proposeData(2), 300_000);
        request.data = _proposeData(0);

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    /// @dev Regression on the counter-outcome, which is new to this signature. It is part of the
    ///      signed payload, so a relayer cannot quietly change what a disputer claims the answer is
    ///      and thereby cost them the reward.
    function test_relayerCannotAlterTheDisputedCounterOutcome() public {
        _relay(proposerPk, _proposeData(0));

        ERC2771Forwarder.ForwardRequestData memory request = _sign(disputerPk, _disputeData(2), 300_000);
        request.data = _disputeData(1);

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    /// @dev The second of the two independent locks. Even if the selector allowlist were wrong, a
    ///      relayed call cannot reach arbitration.
    function test_arbitrationIsUnreachableThroughTheRelayEvenIfSelectorsWereWrong() public {
        _relay(proposerPk, _proposeData(0));

        vm.prank(address(forwarder));
        vm.expectRevert(OptimisticResolver.RelayNotAllowed.selector);
        resolver.arbitrate(address(market), MARKET_ID, 2);
    }
}
