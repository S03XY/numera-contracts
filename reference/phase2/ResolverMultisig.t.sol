// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ResolverMultisig} from "../../src/access/ResolverMultisig.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockResolvableMarket} from "../../src/mocks/MockResolvableMarket.sol";
import {Roles} from "../../src/access/Roles.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";

/// @notice The settlement quorum: who may raise a call, when it fires, and what a signer-set
///         change does to approvals already gathered.
contract ResolverMultisigTest is Test {
    ResolverMultisig sig;
    TrustedResolver resolver;
    MockResolvableMarket market;

    address operator = makeAddr("operator"); // the admin: decides WHO may settle
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    /// @dev 2-of-3 by default: 1-of-1 would pass most of these tests without exercising a quorum.
    function setUp() public {
        sig = new ResolverMultisig(operator, _signers3(), 2);
        resolver = new TrustedResolver(address(sig));
        vm.prank(operator);
        sig.addTarget(address(resolver));
        market = new MockResolvableMarket(address(resolver));
    }

    function _signers3() private view returns (address[] memory s) {
        s = new address[](3);
        (s[0], s[1], s[2]) = (alice, bob, carol);
    }

    function _signers1(address only) private pure returns (address[] memory s) {
        s = new address[](1);
        s[0] = only;
    }

    function _resolveCall(uint256 marketId, uint256 outcome) private view returns (bytes memory) {
        return abi.encodeCall(TrustedResolver.resolveMarket, (address(market), marketId, outcome));
    }

    // ----- construction -----

    function test_constructor_recordsSignersAndThreshold() public view {
        assertEq(sig.signerCount(), 3);
        assertEq(sig.threshold(), 2);
        assertTrue(sig.isSigner(alice));
        assertFalse(sig.isSigner(stranger));
        assertEq(sig.signers().length, 3);
    }

    function test_constructor_revertsOnEmptySignerSet() public {
        vm.expectRevert(ResolverMultisig.NoSigners.selector);
        new ResolverMultisig(operator, new address[](0), 1);
    }

    function test_constructor_revertsOnThresholdAboveSignerCount() public {
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.InvalidThreshold.selector, 4, 3));
        new ResolverMultisig(operator, _signers3(), 4);
    }

    function test_constructor_revertsOnZeroThreshold() public {
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.InvalidThreshold.selector, 0, 3));
        new ResolverMultisig(operator, _signers3(), 0);
    }

    function test_constructor_revertsOnDuplicateSigner() public {
        address[] memory dup = new address[](2);
        (dup[0], dup[1]) = (alice, alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.AlreadySigner.selector, alice));
        new ResolverMultisig(operator, dup, 1);
    }

    function test_constructor_revertsOnZeroSigner() public {
        vm.expectRevert(ZeroAddress.selector);
        new ResolverMultisig(operator, _signers1(address(0)), 1);
    }

    // ----- scope: what the set may call -----

    function test_targets_startEmptyAndAreAdminManaged() public {
        ResolverMultisig fresh = new ResolverMultisig(operator, _signers3(), 2);
        assertEq(fresh.targets().length, 0);

        // A quorum that has been adopted by nobody can call nothing at all.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverMultisig.TargetNotAllowed.selector, address(resolver))
        );
        fresh.propose(address(resolver), _resolveCall(1, 0));

        vm.prank(operator);
        fresh.addTarget(address(resolver));
        assertTrue(fresh.isTarget(address(resolver)));
        assertEq(fresh.targets().length, 1);
    }

    /// @dev Membership and scope are the operator's, not the signers'. A signer who could adopt a
    ///      target could point the quorum at a contract nobody agreed to govern.
    function test_addTarget_isAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        sig.addTarget(address(0xBEEF));
        assertFalse(sig.isTarget(address(0xBEEF)));
    }

    function test_addTarget_rejectsDuplicatesAndZero() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverMultisig.AlreadyTarget.selector, address(resolver))
        );
        sig.addTarget(address(resolver));

        vm.prank(operator);
        vm.expectRevert(ZeroAddress.selector);
        sig.addTarget(address(0));
    }

    /// @dev Revoking scope has to bite on the call that matters, not merely on new proposals —
    ///      otherwise an already-approved proposal outlives the decision to stop governing it.
    function test_removeTarget_stopsAnAlreadyApprovedProposalFromExecuting() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(operator);
        sig.removeTarget(address(resolver));

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverMultisig.TargetNotAllowed.selector, address(resolver))
        );
        sig.confirm(id);
        assertFalse(market.resolved());
    }

    function test_propose_rejectsAnUnadoptedTarget() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ResolverMultisig.TargetNotAllowed.selector, address(market))
        );
        sig.propose(address(market), abi.encodeCall(MockResolvableMarket.resolve, (1, 0)));
    }

    // ----- the quorum itself -----

    function test_singleConfirmationDoesNotSettle() public {
        vm.prank(alice);
        sig.propose(address(resolver), _resolveCall(7, 1));
        assertFalse(market.resolved());
        assertEq(sig.proposalAt(0).confirmations, 1);
    }

    function test_secondConfirmationSettles() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(bob);
        sig.confirm(id);

        assertTrue(market.resolved());
        assertEq(market.lastMarketId(), 7);
        assertEq(market.lastWinningOutcome(), 1);
        assertTrue(sig.proposalAt(id).executed);
    }

    function test_invalidateAlsoRoutesThroughQuorum() public {
        bytes memory data = abi.encodeCall(TrustedResolver.invalidateMarket, (address(market), 42));
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), data);
        vm.prank(bob);
        sig.confirm(id);

        assertTrue(market.invalidated());
        assertEq(market.lastMarketId(), 42);
    }

    function test_thresholdOfOneSettlesOnPropose() public {
        ResolverMultisig solo = new ResolverMultisig(operator, _signers1(alice), 1);
        TrustedResolver soloResolver = new TrustedResolver(address(solo));
        vm.prank(operator);
        solo.addTarget(address(soloResolver));
        MockResolvableMarket soloMarket = new MockResolvableMarket(address(soloResolver));

        vm.prank(alice);
        solo.propose(
            address(soloResolver),
            abi.encodeCall(TrustedResolver.resolveMarket, (address(soloMarket), 1, 0))
        );
        assertTrue(soloMarket.resolved());
    }

    // ----- access -----

    function test_propose_revertsForNonSigner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.NotSigner.selector, stranger));
        sig.propose(address(resolver), _resolveCall(1, 0));
    }

    function test_confirm_revertsForNonSigner() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(1, 0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.NotSigner.selector, stranger));
        sig.confirm(id);
    }

    function test_confirm_revertsOnDoubleConfirm() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(1, 0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.AlreadyConfirmed.selector, id, alice));
        sig.confirm(id);
    }

    /// @dev The whole point of putting both roles behind the multisig: no single signer, and no
    ///      outsider, can reach the resolver directly.
    function test_signerCannotBypassTheQuorum() public {
        vm.prank(alice);
        vm.expectRevert();
        resolver.resolveMarket(address(market), 1, 0);
        assertFalse(market.resolved());
    }

    // ----- deduplication -----

    function test_duplicateProposalIsRejectedWithTheOpenId() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.ProposalOpen.selector, id));
        sig.propose(address(resolver), _resolveCall(7, 1));
    }

    function test_pendingProposal_findsTheOpenIdAndClearsOnExecute() public {
        bytes memory data = _resolveCall(7, 1);

        (bool exists,) = sig.pendingProposal(address(resolver), data);
        assertFalse(exists);

        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), data);

        uint256 found;
        (exists, found) = sig.pendingProposal(address(resolver), data);
        assertTrue(exists);
        assertEq(found, id);

        vm.prank(bob);
        sig.confirm(id);

        (exists,) = sig.pendingProposal(address(resolver), data);
        assertFalse(exists);
    }

    function test_differentOutcomesAreDifferentProposals() public {
        vm.prank(alice);
        uint256 first = sig.propose(address(resolver), _resolveCall(7, 0));
        vm.prank(bob);
        uint256 second = sig.propose(address(resolver), _resolveCall(7, 1));
        assertTrue(first != second);
        assertFalse(market.resolved());
    }

    // ----- revoke / cancel -----

    function test_revoke_withdrawsAConfirmation() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(alice);
        sig.revoke(id);
        assertEq(sig.proposalAt(id).confirmations, 0);

        // With alice withdrawn, bob's confirmation alone is not a quorum.
        vm.prank(bob);
        sig.confirm(id);
        assertFalse(market.resolved());
    }

    function test_revoke_revertsWhenNotConfirmed() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.NotConfirmed.selector, id, bob));
        sig.revoke(id);
    }

    function test_cancel_isProposerOnlyAndFreesTheAction() public {
        bytes memory data = _resolveCall(7, 1);
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), data);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.NotProposer.selector, bob));
        sig.cancel(id);

        vm.prank(alice);
        sig.cancel(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.ProposalClosed.selector, id));
        sig.confirm(id);

        // Cancelling releases the dedup slot, so the same action can be raised again.
        vm.prank(bob);
        uint256 again = sig.propose(address(resolver), data);
        assertTrue(again != id);
    }

    // ----- failure surfacing -----

    function test_failingTargetCallRevertsTheWholeTransaction() public {
        // A market bound to a different resolver rejects this one.
        MockResolvableMarket foreign = new MockResolvableMarket(address(0xdead));
        bytes memory data =
            abi.encodeCall(TrustedResolver.resolveMarket, (address(foreign), 1, 0));

        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), data);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                ResolverMultisig.CallFailed.selector,
                abi.encodeWithSelector(MockResolvableMarket.OnlyResolver.selector)
            )
        );
        sig.confirm(id);

        // The failed confirmation left no trace: bob may still confirm once the blocker clears.
        assertEq(sig.proposalAt(id).confirmations, 1);
        assertFalse(sig.hasConfirmed(id, bob));
    }

    function test_execute_revertsBelowThreshold() public {
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.QuorumNotReached.selector, 1, 2));
        sig.execute(id);
        assertFalse(market.resolved());
    }


    // ----- membership: the operator's half -----

    function test_addSigner_isAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        sig.addSigner(stranger);
        assertFalse(sig.isSigner(stranger));

        vm.prank(operator);
        sig.addSigner(stranger);
        assertTrue(sig.isSigner(stranger));
        assertEq(sig.signerCount(), 4);
    }

    /// @dev The operator holds no vote of their own. Deciding who settles and deciding what settles
    ///      are separate, and an admin who wants both has to add themselves visibly.
    function test_adminIsNotASignerUnlessAdded() public {
        assertFalse(sig.isSigner(operator));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.NotSigner.selector, operator));
        sig.propose(address(resolver), _resolveCall(7, 1));
    }

    function test_removeSigner_bumpsEpochAndStrandsInFlightProposals() public {
        // Raise a settlement first, then change the signer set under it.
        vm.prank(alice);
        uint256 settle = sig.propose(address(resolver), _resolveCall(7, 1));
        assertEq(sig.proposalAt(settle).epoch, 0);

        vm.prank(operator);
        sig.removeSigner(carol);

        assertFalse(sig.isSigner(carol));
        assertEq(sig.signerEpoch(), 1);

        // The settlement raised in the old epoch is dead and must be raised again — otherwise a
        // removed signer's confirmation would still count toward a quorum they have left.
        assertFalse(sig.proposalAt(settle).current);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.ProposalStale.selector, settle));
        sig.confirm(settle);

        vm.prank(bob);
        uint256 reraised = sig.propose(address(resolver), _resolveCall(7, 1));
        vm.prank(alice);
        sig.confirm(reraised);
        assertTrue(market.resolved());
    }

    function test_removeSigner_cannotStrandTheThreshold() public {
        vm.prank(operator);
        sig.removeSigner(carol);
        assertEq(sig.signerCount(), 2);

        // 2 signers at threshold 2: removing another would leave a quorum that can never be met.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.InvalidThreshold.selector, 2, 1));
        sig.removeSigner(bob);
    }

    function test_removeSigner_revertsForUnknownSigner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.UnknownSigner.selector, stranger));
        sig.removeSigner(stranger);
    }

    function test_setThreshold_changesTheQuorumWithoutVoidingProposals() public {
        vm.prank(alice);
        uint256 settle = sig.propose(address(resolver), _resolveCall(7, 1));

        vm.prank(operator);
        sig.setThreshold(3);
        assertEq(sig.threshold(), 3);
        assertEq(sig.signerEpoch(), 0, "a threshold change invalidates no confirmation");

        // Still valid, just short of the new bar: two confirmations, three now needed.
        vm.prank(bob);
        sig.confirm(settle);
        assertFalse(market.resolved());

        vm.prank(carol);
        sig.confirm(settle);
        assertTrue(market.resolved());
    }

    function test_setThreshold_rejectsMoreThanSignerCount() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.InvalidThreshold.selector, 4, 3));
        sig.setThreshold(4);
    }

    function test_setThreshold_isAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        sig.setThreshold(1);
        assertEq(sig.threshold(), 2);
    }

    /// @dev A threshold lowered under a proposal that already has enough approvals fires through
    ///      {execute}, without asking a signer who already agreed to agree twice.
    function test_execute_firesAProposalTheThresholdCaughtUpWith() public {
        vm.prank(operator);
        sig.setThreshold(3);

        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), _resolveCall(7, 1));
        vm.prank(bob);
        sig.confirm(id);
        assertFalse(market.resolved());

        vm.prank(operator);
        sig.setThreshold(2);

        vm.prank(carol);
        sig.execute(id);
        assertTrue(market.resolved());
    }

    /// @dev The multisig owns DEFAULT_ADMIN_ROLE on the resolver, so it can also re-grant
    ///      RESOLVER_ROLE — but only by quorum. This is how a new settlement contract is adopted.
    function test_quorumCanGrantResolverRoleOnTheResolver() public {
        bytes memory data =
            abi.encodeWithSignature("grantRole(bytes32,address)", Roles.RESOLVER_ROLE, stranger);
        vm.prank(alice);
        uint256 id = sig.propose(address(resolver), data);
        vm.prank(bob);
        sig.confirm(id);

        assertTrue(resolver.hasRole(Roles.RESOLVER_ROLE, stranger));
    }

    // ----- views -----

    function test_proposalAt_revertsForUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.UnknownProposal.selector, 3));
        sig.proposalAt(3);
    }

    function test_confirm_revertsForUnknownId() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ResolverMultisig.UnknownProposal.selector, 0));
        sig.confirm(0);
    }

}
