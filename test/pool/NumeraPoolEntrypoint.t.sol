// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {NumeraPoolEntrypoint} from "../../src/pool/NumeraPoolEntrypoint.sol";
import {PrivacyPoolComplex} from "../../src/pool/PrivacyPoolComplex.sol";
import {IPrivacyPool} from "../../src/pool/interfaces/IPrivacyPool.sol";
import {IState} from "../../src/pool/interfaces/IState.sol";
import {ProofLib} from "../../src/pool/lib/ProofLib.sol";
import {Constants} from "../../src/pool/lib/Constants.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {TestUSDC} from "../../src/testnet/TestUSDC.sol";
import {ZeroAddress, AmountZero} from "../../src/libraries/Errors.sol";

/**
 * @dev A verifier we can switch on and off.
 *
 * Groth16 proofs cannot be produced inside a Solidity test, so the arithmetic is verified against
 * the real verifier elsewhere — see `script/pool-e2e.mjs`, which deposits, proves with snarkjs and
 * relays for real. What is left here is everything around the proof: the state machine, the
 * nullifier set, the ASP gate, who is allowed to call what, and where the money lands. Those are
 * the parts a bad refactor breaks, and they are independent of whether the pairing check passes.
 */
contract SwitchableVerifier {
    bool public valid = true;

    function setValid(bool v) external {
        valid = v;
    }

    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[8] memory)
        external
        view
        returns (bool)
    {
        return valid;
    }

    function verifyProof(uint256[2] memory, uint256[2][2] memory, uint256[2] memory, uint256[4] memory)
        external
        view
        returns (bool)
    {
        return valid;
    }
}

/// @title NumeraPoolEntrypointTest
/// @notice The shielded pool's contract surface: deposits in, relayed withdrawals out.
///
/// @dev The privacy claim rests on one mechanical fact, pinned by
///      `test_aRelayerCannotRedirectAPayout`: the recipient is folded into the proof's `context`,
///      so the only party who can name it is the person who generated the proof. Everything else in
///      this file protects that claim's preconditions.
contract NumeraPoolEntrypointTest is Test {
    using ProofLib for ProofLib.WithdrawProof;

    NumeraPoolEntrypoint internal entrypoint;
    PrivacyPoolComplex internal pool;
    SwitchableVerifier internal verifier;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal relayer = address(0xBEEF);
    address internal postman = address(0xB05);
    address internal alice = address(0xA1);
    /// Stands in for a market execution account: an address with no gas and no link to Alice.
    address internal marketAccount = address(0x3EC);

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant ASP_ROOT = 0x1234;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        verifier = new SwitchableVerifier();

        // The pool needs its entrypoint at construction and the entrypoint needs its pool, so one
        // of them is computed ahead of time. `vm.computeCreateAddress` beats a two-step initializer:
        // an entrypoint that can be pointed at a different pool later is an entrypoint that can be
        // pointed at an attacker's pool later.
        address entrypointAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pool = new PrivacyPoolComplex(entrypointAddress, address(verifier), address(verifier), address(usdc));
        entrypoint = new NumeraPoolEntrypoint(admin, IPrivacyPool(address(pool)), IERC20(address(usdc)));
        assertEq(address(entrypoint), entrypointAddress, "address prediction drifted");

        vm.startPrank(admin);
        entrypoint.grantRole(entrypoint.RELAYER_ROLE(), relayer);
        entrypoint.grantRole(entrypoint.ASP_POSTMAN_ROLE(), postman);
        vm.stopPrank();

        vm.prank(postman);
        entrypoint.updateRoot(ASP_ROOT);

        usdc.mint(alice, 1_000 * UNIT);
        vm.prank(alice);
        usdc.approve(address(entrypoint), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _deposit(address who, uint256 value, uint256 precommitment) internal returns (uint256 commitment) {
        vm.prank(who);
        commitment = entrypoint.deposit(value, precommitment);
    }

    /// @dev A withdrawal whose `context` is computed exactly as the pool will recompute it.
    function _withdrawal(address recipient) internal view returns (IPrivacyPool.Withdrawal memory w) {
        w = IPrivacyPool.Withdrawal({processooor: address(entrypoint), data: abi.encode(recipient)});
    }

    function _proof(IPrivacyPool.Withdrawal memory w, uint256 value, uint256 nullifierHash)
        internal
        view
        returns (ProofLib.WithdrawProof memory p)
    {
        // Reduced into the field: the tree rejects any leaf at or above the SNARK modulus, which
        // a fixture has to respect even when the proof itself is mocked.
        p.pubSignals[0] =
            uint256(keccak256(abi.encode("new commitment", nullifierHash))) % Constants.SNARK_SCALAR_FIELD;
        p.pubSignals[1] = nullifierHash % Constants.SNARK_SCALAR_FIELD;
        p.pubSignals[2] = value;
        p.pubSignals[3] = pool.currentRoot();
        p.pubSignals[4] = 1; // stateTreeDepth
        p.pubSignals[5] = entrypoint.latestRoot();
        p.pubSignals[6] = 1; // ASPTreeDepth
        p.pubSignals[7] = uint256(keccak256(abi.encode(w, pool.SCOPE()))) % Constants.SNARK_SCALAR_FIELD;
    }

    // ------------------------------------------------------------------ deposit: positive

    function test_aDepositShieldsCollateralAndReturnsANote() public {
        uint256 commitment = _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));

        assertGt(commitment, 0, "no commitment returned");
        assertEq(usdc.balanceOf(address(pool)), 100 * UNIT, "the pool should hold the collateral");
        assertEq(usdc.balanceOf(alice), 900 * UNIT, "the depositor should be debited exactly once");
    }

    function test_theEntrypointKeepsNothing() public {
        // A balance stranded on the entrypoint is money nobody can prove ownership of.
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        assertEq(usdc.balanceOf(address(entrypoint)), 0, "the entrypoint must not retain collateral");
    }

    function test_anyoneMayDeposit_becauseTheReturnLegNeedsIt() public {
        // A market execution account sweeping back into the pool calls this directly. If deposits
        // were restricted to known wallets there would be no way home for the float.
        usdc.mint(marketAccount, 50 * UNIT);
        vm.prank(marketAccount);
        usdc.approve(address(entrypoint), type(uint256).max);

        uint256 commitment = _deposit(marketAccount, 50 * UNIT, uint256(keccak256("returning")));
        assertGt(commitment, 0);
    }

    // ------------------------------------------------------------------ deposit: negative

    function test_aZeroDepositIsRejected() public {
        vm.expectRevert(AmountZero.selector);
        vm.prank(alice);
        entrypoint.deposit(0, uint256(keccak256("p")));
    }

    function test_depositingMoreThanYouHoldReverts() public {
        vm.expectRevert();
        vm.prank(alice);
        entrypoint.deposit(10_000 * UNIT, uint256(keccak256("p")));
    }

    // ------------------------------------------------------------------ relay: positive

    function test_aRelayedWithdrawalPaysTheRecipientInTheProof() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));

        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));

        vm.prank(relayer);
        entrypoint.relay(w, p);

        assertEq(usdc.balanceOf(marketAccount), 40 * UNIT, "the recipient was not paid");
        assertEq(usdc.balanceOf(address(pool)), 60 * UNIT, "the remainder should stay shielded");
        assertEq(usdc.balanceOf(address(entrypoint)), 0, "nothing should stick to the entrypoint");
    }

    function test_theDepositorIsNeverNamedInTheWithdrawal() public {
        // The whole point: Alice deposits, the market account is paid, and no call in between takes
        // Alice's address as an argument.
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);

        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));
        vm.prank(relayer);
        entrypoint.relay(w, p);

        assertEq(usdc.balanceOf(alice), 900 * UNIT, "the depositor's public balance must not move");
    }

    // ------------------------------------------------------------------ relay: negative

    function test_aRelayerCannotRedirectAPayout() public {
        // The load-bearing test of the entire design. The relayer holds the proof and submits the
        // transaction, so if it could swap the recipient it could simply steal every withdrawal.
        // It cannot, because the recipient is inside `context`, which the pool recomputes.
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));

        IPrivacyPool.Withdrawal memory honest = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(honest, 40 * UNIT, uint256(keccak256("nullifier")));

        IPrivacyPool.Withdrawal memory tampered = _withdrawal(relayer);

        vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
        vm.prank(relayer);
        entrypoint.relay(tampered, p);

        assertEq(usdc.balanceOf(relayer), 0, "the relayer must not be payable this way");
    }

    function test_aNullifierCannotBeSpentTwice() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));

        vm.prank(relayer);
        entrypoint.relay(w, p);

        // Same note, same proof, replayed. Without the nullifier set this drains the pool.
        vm.expectRevert(IState.NullifierAlreadySpent.selector);
        vm.prank(relayer);
        entrypoint.relay(w, p);
    }

    function test_anInvalidProofIsRejected() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        verifier.setValid(false);

        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));
        vm.expectRevert(IPrivacyPool.InvalidProof.selector);
        vm.prank(relayer);
        entrypoint.relay(w, p);
    }

    function test_aProofAgainstAStaleAssociationRootIsRejected() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));

        // The ASP advances between proof generation and submission — an ordinary race, and the
        // reason the client must re-read the root immediately before proving.
        vm.prank(postman);
        entrypoint.updateRoot(ASP_ROOT + 1);

        vm.expectRevert(IPrivacyPool.IncorrectASPRoot.selector);
        vm.prank(relayer);
        entrypoint.relay(w, p);
    }

    function test_aProofAgainstAnUnknownStateRootIsRejected() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));
        p.pubSignals[3] = uint256(keccak256("a tree that never existed"));

        vm.expectRevert(IPrivacyPool.UnknownStateRoot.selector);
        vm.prank(relayer);
        entrypoint.relay(w, p);
    }

    function test_onlyTheRelayerMaySubmit() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, entrypoint.RELAYER_ROLE()
            )
        );
        vm.prank(alice);
        entrypoint.relay(w, p);
    }

    function test_aWithdrawalMustBeProcessedByTheEntrypoint() public {
        // If `processooor` were the recipient, the pool would pay them directly and the forward
        // below would send a second payment out of the entrypoint's own balance.
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w =
            IPrivacyPool.Withdrawal({processooor: marketAccount, data: abi.encode(marketAccount)});

        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));
        vm.expectRevert(
            abi.encodeWithSelector(NumeraPoolEntrypoint.RecipientMismatch.selector, marketAccount, address(entrypoint))
        );
        vm.prank(relayer);
        entrypoint.relay(w, p);
    }

    function test_aWithdrawalToNowhereIsRejected() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        IPrivacyPool.Withdrawal memory w = _withdrawal(address(0));

        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(relayer);
        entrypoint.relay(w, p);
    }

    // ------------------------------------------------------------------ association set

    function test_onlyThePostmanMayPublishARoot() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, entrypoint.ASP_POSTMAN_ROLE()
            )
        );
        vm.prank(alice);
        entrypoint.updateRoot(999);
    }

    function test_republishingTheSameRootIsRejected() public {
        // A no-op update would let a wedged ASP service look healthy while every withdrawal that
        // needs a newer root quietly fails.
        vm.expectRevert(NumeraPoolEntrypoint.RootUnchanged.selector);
        vm.prank(postman);
        entrypoint.updateRoot(ASP_ROOT);
    }

    function test_theEmptyRootIsRejected() public {
        // Zero is what an uninitialised entrypoint reads as, and a proof cannot be generated
        // against it. Publishing it would take the pool down in a way that looks like a config bug.
        vm.expectRevert(NumeraPoolEntrypoint.RootZero.selector);
        vm.prank(postman);
        entrypoint.updateRoot(0);
    }

    function test_rootsAreCountedSoAMissedUpdateIsVisible() public {
        assertEq(entrypoint.rootIndex(), 1, "setUp published one root");
        vm.prank(postman);
        uint256 index = entrypoint.updateRoot(ASP_ROOT + 1);
        assertEq(index, 2);
        assertEq(entrypoint.latestRoot(), ASP_ROOT + 1);
    }

    // ------------------------------------------------------------------ construction

    function test_theEntrypointCannotBeBuiltAroundNothing() public {
        vm.expectRevert(ZeroAddress.selector);
        new NumeraPoolEntrypoint(address(0), IPrivacyPool(address(pool)), IERC20(address(usdc)));

        vm.expectRevert(ZeroAddress.selector);
        new NumeraPoolEntrypoint(admin, IPrivacyPool(address(0)), IERC20(address(usdc)));

        vm.expectRevert(ZeroAddress.selector);
        new NumeraPoolEntrypoint(admin, IPrivacyPool(address(pool)), IERC20(address(0)));
    }

    function test_thePoolOnlyTakesDepositsFromItsEntrypoint() public {
        // Bypassing the entrypoint would skip the ASP accounting entirely.
        vm.expectRevert(IState.OnlyEntrypoint.selector);
        vm.prank(alice);
        pool.deposit(alice, 10 * UNIT, uint256(keccak256("p")));
    }

    // ------------------------------------------------------------------ regression

    function test_partialWithdrawalsLeaveTheRestSpendable() public {
        // The note model is one-in two-out: spending part of a note mints a fresh note for the
        // remainder. If the remainder were dropped, a partial withdrawal would burn the difference.
        _deposit(alice, 100 * UNIT, uint256(keccak256("precommitment")));
        uint256 rootBefore = pool.currentRoot();

        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("nullifier")));
        vm.prank(relayer);
        entrypoint.relay(w, p);

        assertTrue(pool.currentRoot() != rootBefore, "the new commitment was not inserted");
        assertEq(usdc.balanceOf(address(pool)), 60 * UNIT, "the remainder must stay in the pool");
    }

    function test_twoDepositsAreIndependentlySpendable() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("first")));
        _deposit(alice, 30 * UNIT, uint256(keccak256("second")));

        IPrivacyPool.Withdrawal memory w = _withdrawal(marketAccount);
        ProofLib.WithdrawProof memory p = _proof(w, 40 * UNIT, uint256(keccak256("n1")));
        vm.prank(relayer);
        entrypoint.relay(w, p);
        ProofLib.WithdrawProof memory second = _proof(w, 20 * UNIT, uint256(keccak256("n2")));
        vm.prank(relayer);
        entrypoint.relay(w, second);

        assertEq(usdc.balanceOf(marketAccount), 60 * UNIT, "both notes should be spendable");
    }

    // ------------------------------------------------------------------ depositFor: the return leg

    /**
     * @dev The domain the browser must sign against, written out longhand.
     *
     * Deliberately not read from `entrypoint.eip712Domain()`: that would make this a tautology, and
     * the failure being guarded against is a client signing the wrong domain. Spelling out the name
     * and version means changing either of them in the contract breaks this test, which is the only
     * warning anyone gets before every gasless return silently stops verifying.
     */
    function _shieldDigest(NumeraPoolEntrypoint.ShieldRequest memory req, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Numera Shielded Pool"),
                keccak256("1"),
                block.chainid,
                address(entrypoint)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Shield(address owner,uint256 value,uint256 precommitment,uint256 nonce,uint256 deadline)"),
                req.owner,
                req.value,
                req.precommitment,
                nonce,
                req.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 pk, NumeraPoolEntrypoint.ShieldRequest memory req, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _shieldDigest(req, nonce));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A market account: funded with collateral, holding not one wei of gas.
    function _fundedMarketAccount(uint256 amount) internal returns (uint256 pk, address account) {
        pk = 0xACC0;
        account = vm.addr(pk);
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(entrypoint), type(uint256).max);
        assertEq(account.balance, 0, "a market account must never hold gas");
    }

    function test_aGaslessAccountCanShieldItsBalanceBySignature() public {
        (uint256 pk, address account) = _fundedMarketAccount(40 * UNIT);

        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 40 * UNIT,
            precommitment: uint256(keccak256("return note")),
            deadline: block.timestamp + 1 hours
        });

        // Submitted by the relayer, which is any address at all: the signature is the authority.
        vm.prank(relayer);
        uint256 commitment = entrypoint.depositFor(req, _sign(pk, req, 0));

        assertGt(commitment, 0, "no note was created");
        assertEq(usdc.balanceOf(account), 0, "the account should have been swept");
        assertEq(usdc.balanceOf(address(pool)), 40 * UNIT, "the pool should hold the returned value");
        assertEq(entrypoint.shieldNonces(account), 1, "the nonce should have advanced");
    }

    function test_anyoneMayPayTheGasForSomeoneElsesReturn() public {
        (uint256 pk, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _sign(pk, req, 0);

        // No role, no relationship to the account. Submitting only helps the owner, and the
        // submitter pays — which is why this is deliberately not gated.
        vm.prank(address(0xD00D));
        entrypoint.depositFor(req, signature);

        assertEq(usdc.balanceOf(address(pool)), 10 * UNIT);
    }

    /// @dev The property the whole design rests on: the note is named inside the signature.
    function test_aSubmitterCannotRedirectTheNoteToThemselves() public {
        (uint256 pk, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("the owner's note")),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _sign(pk, req, 0);

        req.precommitment = uint256(keccak256("the thief's note"));

        vm.prank(relayer);
        vm.expectRevert(NumeraPoolEntrypoint.InvalidShieldSignature.selector);
        entrypoint.depositFor(req, signature);
    }

    function test_aSubmitterCannotInflateTheAmount() public {
        (uint256 pk, address account) = _fundedMarketAccount(100 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _sign(pk, req, 0);

        req.value = 100 * UNIT;

        vm.prank(relayer);
        vm.expectRevert(NumeraPoolEntrypoint.InvalidShieldSignature.selector);
        entrypoint.depositFor(req, signature);
    }

    function test_aShieldSignatureCannotBeReplayed() public {
        (uint256 pk, address account) = _fundedMarketAccount(20 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _sign(pk, req, 0);

        vm.prank(relayer);
        entrypoint.depositFor(req, signature);

        // Same bytes, second time: the nonce has moved on, so the digest no longer recovers.
        vm.prank(relayer);
        vm.expectRevert(NumeraPoolEntrypoint.InvalidShieldSignature.selector);
        entrypoint.depositFor(req, signature);
    }

    function test_anExpiredShieldRequestIsRefused() public {
        (uint256 pk, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });
        bytes memory signature = _sign(pk, req, 0);

        vm.warp(req.deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NumeraPoolEntrypoint.ShieldExpired.selector, req.deadline));
        entrypoint.depositFor(req, signature);
    }

    function test_aSignatureFromTheWrongKeyIsRefused() public {
        (, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });

        vm.prank(relayer);
        vm.expectRevert(NumeraPoolEntrypoint.InvalidShieldSignature.selector);
        entrypoint.depositFor(req, _sign(0xBADBAD, req, 0));
    }

    function test_aShieldOfNothingIsRefused() public {
        (uint256 pk, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 0,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });

        vm.prank(relayer);
        vm.expectRevert(AmountZero.selector);
        entrypoint.depositFor(req, _sign(pk, req, 0));
    }

    /// @dev A signature for one pool must not work against another. Bound by `verifyingContract`.
    function test_aShieldSignatureIsBoundToThisEntrypoint() public {
        (uint256 pk, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: block.timestamp + 1 hours
        });

        bytes32 foreignDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Numera Shielded Pool"),
                keccak256("1"),
                block.chainid,
                address(0xDEAD)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Shield(address owner,uint256 value,uint256 precommitment,uint256 nonce,uint256 deadline)"),
                req.owner,
                req.value,
                req.precommitment,
                uint256(0),
                req.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", foreignDomain, structHash)));

        vm.prank(relayer);
        vm.expectRevert(NumeraPoolEntrypoint.InvalidShieldSignature.selector);
        entrypoint.depositFor(req, abi.encodePacked(r, s, v));
    }

    /// @dev Regression: the shielded path must not disturb the ordinary one.
    function test_aSignedReturnAndAnOrdinaryDepositShareTheSameTree() public {
        _deposit(alice, 100 * UNIT, uint256(keccak256("alice")));
        uint256 rootAfterAlice = pool.currentRoot();

        (uint256 pk, address account) = _fundedMarketAccount(10 * UNIT);
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 10 * UNIT,
            precommitment: uint256(keccak256("returned")),
            deadline: block.timestamp + 1 hours
        });

        vm.prank(relayer);
        entrypoint.depositFor(req, _sign(pk, req, 0));

        assertTrue(pool.currentRoot() != rootAfterAlice, "the returned note was not inserted");
        assertEq(usdc.balanceOf(address(pool)), 110 * UNIT, "both deposits should be held");
        assertEq(usdc.balanceOf(address(entrypoint)), 0, "the entrypoint must never retain value");
    }
}

/**
 * @title ShieldWithPermitTest
 * @notice The allowance half of the return leg, against a collateral that actually implements
 *         EIP-2612.
 *
 * @dev Separate contract because `MockERC20` has no `permit`, and giving it one would let the main
 *      suite pass against a token that behaves unlike the deployed collateral. `TestUSDC` is the
 *      real testnet token, including its EIP-712 version `"2"` — the detail that silently breaks
 *      permits when a client assumes `"1"`.
 */
contract ShieldWithPermitTest is Test {
    NumeraPoolEntrypoint internal entrypoint;
    PrivacyPoolComplex internal pool;
    SwitchableVerifier internal verifier;
    TestUSDC internal usdc;

    uint256 internal constant UNIT = 1e6;
    uint256 internal accountKey = 0xACC1;
    address internal account;

    function setUp() public {
        usdc = new TestUSDC(address(this));
        verifier = new SwitchableVerifier();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pool = new PrivacyPoolComplex(predicted, address(verifier), address(verifier), address(usdc));
        entrypoint = new NumeraPoolEntrypoint(address(this), IPrivacyPool(address(pool)), IERC20(address(usdc)));

        account = vm.addr(accountKey);
        usdc.mint(account, 50 * UNIT);
    }

    function _shieldSignature(NumeraPoolEntrypoint.ShieldRequest memory req, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Numera Shielded Pool"),
                keccak256("1"),
                block.chainid,
                address(entrypoint)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Shield(address owner,uint256 value,uint256 precommitment,uint256 nonce,uint256 deadline)"),
                req.owner,
                req.value,
                req.precommitment,
                nonce,
                req.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _permit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                account,
                address(entrypoint),
                value,
                usdc.nonces(account),
                deadline
            )
        );
        (v, r, s) = vm.sign(accountKey, keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash)));
    }

    function test_anAccountWithNoAllowanceAndNoGasCanStillReturnItsBalance() public {
        assertEq(usdc.allowance(account, address(entrypoint)), 0, "precondition: no allowance");
        assertEq(account.balance, 0, "precondition: no gas");

        uint256 deadline = block.timestamp + 1 hours;
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 50 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: deadline
        });
        (uint8 v, bytes32 r, bytes32 s) = _permit(50 * UNIT, deadline);

        entrypoint.depositForWithPermit(req, _shieldSignature(req, 0), deadline, v, r, s);

        assertEq(usdc.balanceOf(account), 0, "the account should have been swept");
        assertEq(usdc.balanceOf(address(pool)), 50 * UNIT, "the pool should hold the returned value");
    }

    /**
     * @dev A permit is a bearer authorisation, so anybody watching the mempool can land it first.
     *      The deposit must survive that rather than reverting on a consumed nonce.
     */
    function test_aFrontRunPermitDoesNotBreakTheReturn() public {
        uint256 deadline = block.timestamp + 1 hours;
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 50 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: deadline
        });
        (uint8 v, bytes32 r, bytes32 s) = _permit(50 * UNIT, deadline);

        vm.prank(address(0xF00D));
        usdc.permit(account, address(entrypoint), 50 * UNIT, deadline, v, r, s);

        entrypoint.depositForWithPermit(req, _shieldSignature(req, 0), deadline, v, r, s);

        assertEq(usdc.balanceOf(address(pool)), 50 * UNIT, "the return should have completed anyway");
    }

    /// @dev A swallowed permit must not swallow the failure it was covering for.
    function test_aBadPermitStillFailsWhenThereIsNoAllowanceBehindIt() public {
        uint256 deadline = block.timestamp + 1 hours;
        NumeraPoolEntrypoint.ShieldRequest memory req = NumeraPoolEntrypoint.ShieldRequest({
            owner: account,
            value: 50 * UNIT,
            precommitment: uint256(keccak256("note")),
            deadline: deadline
        });

        vm.expectRevert();
        entrypoint.depositForWithPermit(req, _shieldSignature(req, 0), deadline, 27, bytes32(0), bytes32(0));
    }
}
