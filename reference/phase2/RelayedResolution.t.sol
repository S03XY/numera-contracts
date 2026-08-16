// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {ResolutionForwarder} from "../src/relay/ResolutionForwarder.sol";
import {PrivateOptimisticResolver} from "../src/resolvers/PrivateOptimisticResolver.sol";
import {TrustedResolver} from "../src/resolvers/TrustedResolver.sol";
import {MockOptimisticMarket} from "../src/mocks/MockOptimisticMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {Roles} from "../src/access/Roles.sol";

/// @notice The privacy half: a market account proposes an outcome while holding zero native gas.
///
/// @dev This is the property the whole design rests on. If a proposer ever has to send their own
///      transaction, they need gas; if they need gas, someone has to fund them; and a public
///      transfer into a market account retroactively deanonymises every position it holds. So the
///      account signs and never sends, exactly as it does when trading.
contract RelayedResolutionTest is Test {
    bytes32 constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    ResolutionForwarder forwarder;
    PrivateOptimisticResolver resolver;
    TrustedResolver trusted;
    MockOptimisticMarket market;
    MockERC20 usdc;

    address operator = makeAddr("operator");
    address relayer = makeAddr("relayer");
    address deployer = address(this);

    uint256 proposerPk = 0xA11CE;
    uint256 disputerPk = 0xB0B;
    address proposer;
    address disputer;

    uint256 constant USDC = 1e6;
    uint256 constant BOND = 50 * USDC;
    uint64 constant DISPUTE_WINDOW = 6 hours;
    uint64 constant ARBITRATION_TIMEOUT = 7 days;
    uint64 closeTime;

    function setUp() public {
        proposer = vm.addr(proposerPk);
        disputer = vm.addr(disputerPk);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(block.timestamp + 1 days);

        trusted = new TrustedResolver(operator);
        forwarder = new ResolutionForwarder(address(usdc), deployer);
        resolver = new PrivateOptimisticResolver(
            operator,
            address(forwarder),
            address(usdc),
            address(trusted),
            BOND,
            DISPUTE_WINDOW,
            ARBITRATION_TIMEOUT,
            100,
            25 * USDC
        );
        forwarder.initialize(address(resolver));

        vm.prank(operator);
        trusted.grantRole(Roles.RESOLVER_ROLE, address(resolver));

        market = new MockOptimisticMarket(address(trusted), closeTime, 3, 10_000 * USDC);
        usdc.mint(address(resolver), 1_000 * USDC);

        address[2] memory accounts = [proposer, disputer];
        for (uint256 i = 0; i < accounts.length; ++i) {
            usdc.mint(accounts[i], 500 * USDC);
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
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
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
        return abi.encodeCall(PrivateOptimisticResolver.propose, (address(market), 1, outcomeId));
    }

    function _disputeData() internal view returns (bytes memory) {
        return abi.encodeCall(PrivateOptimisticResolver.dispute, (address(market), 1));
    }

    // ------------------------------------------------------------------ the property

    function test_marketAccountProposesWithZeroGas() public {
        assertEq(proposer.balance, 0, "precondition: the account holds no native gas");

        ERC2771Forwarder.ForwardRequestData memory request = _sign(proposerPk, _proposeData(2), 300_000);
        vm.prank(relayer);
        forwarder.execute(request);

        // The bond came from the market account, and the resolver recorded IT as the proposer —
        // not the relayer that paid for the transaction.
        PrivateOptimisticResolver.Proposal memory p = resolver.getProposal(address(market), 1);
        assertEq(p.proposer, proposer);
        assertEq(usdc.balanceOf(proposer), 450 * USDC);
        assertEq(proposer.balance, 0, "the account still holds no native gas");
    }

    function test_marketAccountDisputesWithZeroGas() public {
        vm.prank(relayer);
        forwarder.execute(_sign(proposerPk, _proposeData(0), 300_000));

        vm.prank(relayer);
        forwarder.execute(_sign(disputerPk, _disputeData(), 300_000));

        PrivateOptimisticResolver.Proposal memory p = resolver.getProposal(address(market), 1);
        assertEq(p.disputer, disputer);
        assertEq(uint8(p.phase), uint8(PrivateOptimisticResolver.Phase.Disputed));
        assertEq(disputer.balance, 0);
    }

    /// @dev End to end through the relay: a false proposal is caught, and the watcher walks away
    ///      with both bonds plus the reward, all of it landing in shielded accounts.
    function test_fullDisputedFlowThroughTheRelay() public {
        vm.prank(relayer);
        forwarder.execute(_sign(proposerPk, _proposeData(0), 300_000));
        vm.prank(relayer);
        forwarder.execute(_sign(disputerPk, _disputeData(), 300_000));

        uint256 disputerAfter = usdc.balanceOf(disputer);

        vm.prank(operator);
        resolver.arbitrate(address(market), 1, 2);

        assertTrue(market.resolved());
        assertEq(usdc.balanceOf(disputer), disputerAfter + BOND * 2 + 25 * USDC);
        assertEq(usdc.balanceOf(proposer), 450 * USDC, "the liar is out one bond");
    }

    // ------------------------------------------------------------------ the guards

    function test_forwarder_relaysNothingButProposeAndDispute() public {
        assertTrue(forwarder.isRelayable(PrivateOptimisticResolver.propose.selector));
        assertTrue(forwarder.isRelayable(PrivateOptimisticResolver.dispute.selector));

        // Everything that moves money on the operator's authority, or out of the pool, is unreachable.
        bytes4[3] memory forbidden = [
            PrivateOptimisticResolver.arbitrate.selector,
            PrivateOptimisticResolver.withdrawRewardPool.selector,
            PrivateOptimisticResolver.setParameters.selector
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            assertFalse(forwarder.isRelayable(forbidden[i]));
        }
    }

    function test_forwarder_rejectsAForbiddenSelector() public {
        bytes memory data = abi.encodeCall(
            PrivateOptimisticResolver.withdrawRewardPool, (address(0xdead), 1_000 * USDC)
        );
        ERC2771Forwarder.ForwardRequestData memory request = _sign(proposerPk, data, 300_000);

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ResolutionForwarder.SelectorNotAllowed.selector, bytes4(data)
            )
        );
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
        vm.expectRevert(
            abi.encodeWithSelector(ResolutionForwarder.NotInitializer.selector, relayer)
        );
        fresh.initialize(address(resolver));

        fresh.initialize(address(resolver));
        vm.expectRevert(ResolutionForwarder.AlreadyInitialized.selector);
        fresh.initialize(address(resolver));
    }

    /// @dev The relayer's pre-flight. It should drop a request it can predict will fail rather than
    ///      pay for the revert, and it must agree with what the chain actually enforces.
    function test_verifyRelayable_agreesWithExecute() public {
        ERC2771Forwarder.ForwardRequestData memory good = _sign(proposerPk, _proposeData(0), 300_000);
        assertTrue(forwarder.verifyRelayable(good));

        ERC2771Forwarder.ForwardRequestData memory wrongTarget = good;
        wrongTarget.to = address(market);
        assertFalse(forwarder.verifyRelayable(wrongTarget));

        ERC2771Forwarder.ForwardRequestData memory badSelector =
            _sign(proposerPk, abi.encodeCall(PrivateOptimisticResolver.finalize, (address(market), 1)), 300_000);
        assertFalse(forwarder.verifyRelayable(badSelector));
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
}
