// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ParimutuelMarket} from "../../src/markets/ParimutuelMarket.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockExecutionAccount} from "../../src/mocks/MockExecutionAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice End-to-end proof that the engines are natively compatible with Unlink's `execute()` /
///         advanced-execute flow, and that trader privacy holds.
///
/// Model reproduced (from docs.unlink.xyz/execute + execute-advanced):
///   - Unlink withdraws collateral from its shielded pool into a fresh (or reused) ERC-4337
///     ExecutionAccount (here: {MockExecutionAccount}), which then calls the market.
///   - The whole thing is one atomic UserOperation: e.g. [approve(market), placeBet(...)].
///   - From the market's view, `msg.sender` is the ExecutionAccount address — unlinkable to the real
///     trader — and `tx.origin` is Unlink's bundler, which the market MUST ignore.
///   - Proceeds are paid to `msg.sender`, so the account can sweep them back to the pool (returnToPool).
contract UnlinkFlowTest is Test {
    ParimutuelMarket pari;
    LMSRMarket lmsr;
    TrustedResolver resolver;
    MockERC20 usdc;

    // Simulated Unlink shielded pool: holds collateral, funds ExecutionAccounts, receives sweeps.
    address shieldedPool = makeAddr("shieldedPool");
    // Owner keys that sign ExecutionIntents (the account owners). In production these never appear
    // to the market; here they only drive the mock account's `execute`.
    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");

    uint64 closeTime;
    uint256 constant USDC = 1e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pari = new ParimutuelMarket(address(this));
        lmsr = new LMSRMarket(address(this));
        resolver = new TrustedResolver(address(this));
        closeTime = uint64(block.timestamp + 1 days);
    }

    // --- helpers that mimic Unlink primitives ---

    /// @dev Unlink `withdrawFromPool`: move collateral from the shielded pool into an ExecutionAccount.
    function _withdrawFromPool(MockExecutionAccount acct, uint256 amount) internal {
        usdc.mint(address(acct), amount); // shielded pool is the funding source
    }

    function _call(address target, bytes memory data)
        internal
        pure
        returns (MockExecutionAccount.Call memory)
    {
        return MockExecutionAccount.Call({target: target, value: 0, data: data});
    }

    function _run(MockExecutionAccount acct, address owner, MockExecutionAccount.Call[] memory calls)
        internal
    {
        vm.prank(owner); // the bundler/owner drives it; tx.origin becomes `owner`
        acct.execute(calls);
    }

    // ======================================================================
    // Parimutuel via Unlink execute(): private bet -> resolve -> claim -> returnToPool
    // ======================================================================

    function test_parimutuel_privateBet_keyedToAccount_notTxOrigin() public {
        uint256 id = _createPari();

        // Unlink spins up a FRESH ExecutionAccount and withdraws 100 USDC into it.
        MockExecutionAccount acct = new MockExecutionAccount(ownerA);
        _withdrawFromPool(acct, 100 * USDC);

        // One atomic UserOp: approve + placeBet.
        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](2);
        calls[0] = _call(address(usdc), abi.encodeCall(IERC20.approve, (address(pari), 100 * USDC)));
        calls[1] = _call(address(pari), abi.encodeCall(ParimutuelMarket.placeBet, (id, 0, 100 * USDC)));
        _run(acct, ownerA, calls);

        // The position is owned by the ephemeral ACCOUNT, not the owner EOA (which is tx.origin).
        assertEq(pari.stakeOf(id, address(acct), 0), 100 * USDC);
        assertEq(pari.stakeOf(id, ownerA, 0), 0); // tx.origin got nothing
        assertEq(usdc.allowance(address(acct), address(pari)), 0); // approve fully consumed
        assertEq(address(acct).balance, 0); // no native gas needed (paymaster-sponsored)
    }

    function test_parimutuel_fullPrivateLifecycle_withReturnToPool() public {
        uint256 id = _createPari();

        // Two traders, each from a FRESH unlinkable account (bets are uncorrelated on-chain).
        MockExecutionAccount winner = new MockExecutionAccount(ownerA);
        MockExecutionAccount loser = new MockExecutionAccount(ownerB);
        _withdrawFromPool(winner, 100 * USDC);
        _withdrawFromPool(loser, 300 * USDC);
        _placeBet(winner, ownerA, id, 0, 100 * USDC);
        _placeBet(loser, ownerB, id, 1, 300 * USDC);
        assertTrue(address(winner) != address(loser));

        // Settle.
        vm.warp(closeTime);
        resolver.resolveMarket(address(pari), id, 0);

        // Winner reuses ITS account slot to claim, then sweeps proceeds back to the shielded pool —
        // all in one atomic UserOp (claim + returnToPool).
        uint256 payout = pari.claimable(id, address(winner));
        assertEq(payout, 400 * USDC); // sole winner takes the whole 400 pot (0 fee)

        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](2);
        calls[0] = _call(address(pari), abi.encodeCall(ParimutuelMarket.claim, (id)));
        calls[1] = _call(address(usdc), abi.encodeCall(IERC20.transfer, (shieldedPool, payout)));
        _run(winner, ownerA, calls);

        // Proceeds returned privately to the pool; nothing stranded in the account.
        assertEq(usdc.balanceOf(shieldedPool), payout);
        assertEq(usdc.balanceOf(address(winner)), 0);
    }

    function test_parimutuel_crossAccountClaimRejected_and_txOriginIrrelevant() public {
        uint256 id = _createPari();

        MockExecutionAccount betAcct = new MockExecutionAccount(ownerA);
        _withdrawFromPool(betAcct, 100 * USDC);
        _placeBet(betAcct, ownerA, id, 0, 100 * USDC);

        // Give the losing side so the market resolves normally.
        MockExecutionAccount loser = new MockExecutionAccount(ownerB);
        _withdrawFromPool(loser, 100 * USDC);
        _placeBet(loser, ownerB, id, 1, 100 * USDC);

        vm.warp(closeTime);
        resolver.resolveMarket(address(pari), id, 0);

        // A DIFFERENT account — even one owned by the SAME owner EOA (so tx.origin matches the
        // original bet) — cannot claim betAcct's winnings. Ownership is by account address only.
        MockExecutionAccount attacker = new MockExecutionAccount(ownerA);
        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](1);
        calls[0] = _call(address(pari), abi.encodeCall(ParimutuelMarket.claim, (id)));
        vm.prank(ownerA); // same tx.origin as the winning bet
        vm.expectRevert(); // reverts inside the batch (NothingToClaim) -> whole UserOp reverts
        attacker.execute(calls);

        // The rightful account can still claim.
        _run(betAcct, ownerA, calls);
        assertEq(usdc.balanceOf(address(betAcct)), 200 * USDC);
    }

    // ======================================================================
    // LMSR via Unlink execute(): private buy shifts PUBLIC price -> resolve -> redeem
    // ======================================================================

    function test_lmsr_privateBuy_shiftsPublicPrice_thenRedeemToPool() public {
        uint256 id = _createLmsr();

        uint256 yesBefore = lmsr.priceWad(id, 1);

        // Fresh account buys 300 "Yes" shares in one atomic UserOp (approve + buy).
        MockExecutionAccount trader = new MockExecutionAccount(ownerA);
        (,, uint256 cost) = lmsr.quoteBuy(id, 1, 300 * USDC);
        _withdrawFromPool(trader, cost);

        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](2);
        calls[0] = _call(address(usdc), abi.encodeCall(IERC20.approve, (address(lmsr), cost)));
        calls[1] =
            _call(address(lmsr), abi.encodeCall(LMSRMarket.buy, (id, 1, 300 * USDC, type(uint256).max)));
        _run(trader, ownerA, calls);

        // Trader identity hidden (position owned by ephemeral account), but the PRICE MOVE is public.
        assertEq(lmsr.sharesOf(id, address(trader), 1), 300 * USDC);
        assertEq(lmsr.sharesOf(id, ownerA, 1), 0);
        uint256 yesAfter = lmsr.priceWad(id, 1);
        assertGt(yesAfter, yesBefore); // public price shifted up on the private buy

        // Settle "Yes" and redeem winnings back into the shielded pool.
        vm.warp(closeTime);
        resolver.resolveMarket(address(lmsr), id, 1);

        MockExecutionAccount.Call[] memory redeemCalls = new MockExecutionAccount.Call[](2);
        redeemCalls[0] = _call(address(lmsr), abi.encodeCall(LMSRMarket.redeem, (id)));
        redeemCalls[1] = _call(address(usdc), abi.encodeCall(IERC20.transfer, (shieldedPool, 300 * USDC)));
        _run(trader, ownerA, redeemCalls);

        assertEq(usdc.balanceOf(shieldedPool), 300 * USDC); // winning shares redeemed 1:1, swept to pool
        assertEq(usdc.balanceOf(address(trader)), 0);
    }

    // ======================================================================
    // helpers
    // ======================================================================

    function _createPari() internal returns (uint256 id) {
        id = pari.createMarket(
            ParimutuelMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver),
                closeTime: closeTime,
                outcomeCount: 2,
                feeBps: 0,
                minBet: 0,
                category: bytes32("SPORTS"),
                metadataHash: keccak256("A vs B")
            })
        );
    }

    function _createLmsr() internal returns (uint256 id) {
        // LP (this contract) seeds the subsidy.
        usdc.mint(address(this), 10_000 * USDC);
        usdc.approve(address(lmsr), type(uint256).max);
        id = lmsr.createMarket(
            LMSRMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver),
                closeTime: closeTime,
                outcomeCount: 2,
                feeBps: 0,
                b: 1000 * USDC,
                category: bytes32("SPORTS"),
                metadataHash: keccak256("Will A win?")
            })
        );
    }

    function _placeBet(MockExecutionAccount acct, address owner, uint256 id, uint256 outcome, uint256 amt)
        internal
    {
        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](2);
        calls[0] = _call(address(usdc), abi.encodeCall(IERC20.approve, (address(pari), amt)));
        calls[1] = _call(address(pari), abi.encodeCall(ParimutuelMarket.placeBet, (id, outcome, amt)));
        _run(acct, owner, calls);
    }
}
