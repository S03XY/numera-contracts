// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsr} from "../src/libraries/LsLmsr.sol";

/// @notice Drives random buy / sell / short sequences against the curve, tracking collateral the
///         way a market would.
///
/// @dev This is the load-bearing test of the whole design. Everything else checks that a formula is
///      the formula it claims to be; this checks the property the product is sold on — that the
///      pool cannot run out of money — under sequences nobody wrote by hand.
///
///      Collateral is accumulated exactly as {Market} will: every buy adds the rounded-up cost,
///      every sell subtracts the rounded-down proceeds. If the rounding were symmetric, or the cost
///      function were not path independent, the running balance would drift below `max(qᵢ)` and the
///      invariant would catch it.
contract LsLmsrHandler is Test {
    uint256 public constant ALPHA = 0.025e18;
    uint256 public constant S_STAR = 2000e18;

    /// @dev The creator's seed, locked until resolution. `s` may never fall below it, which is what
    ///      keeps `b` away from zero and quoted spreads finite.
    uint256 public constant SEED = 1000e18;

    uint256[] internal _q;
    uint256 public collateral;

    /// Counters, so a run that silently rejected everything is visible rather than green.
    uint256 public buys;
    uint256 public sells;
    uint256 public shorts;

    constructor(uint256 n) {
        for (uint256 i; i < n; ++i) {
            _q.push(SEED);
        }
        // The creator pays C(seed) up front; from here the pool is self-funding.
        collateral = LsLmsr.cost(_q, ALPHA, S_STAR);
    }

    function q() external view returns (uint256[] memory) {
        return _q;
    }

    function maxQ() external view returns (uint256 m) {
        for (uint256 i; i < _q.length; ++i) {
            if (_q[i] > m) m = _q[i];
        }
    }

    function buy(uint256 i, uint256 sh) external {
        i = bound(i, 0, _q.length - 1);
        sh = bound(sh, 1, 1e22);
        collateral += LsLmsr.costToBuy(_q, ALPHA, S_STAR, i, sh);
        _q[i] += sh;
        ++buys;
    }

    function sell(uint256 i, uint256 sh) external {
        i = bound(i, 0, _q.length - 1);
        // Never below the locked seed: that floor is the market's, not the trader's, to spend.
        if (_q[i] <= SEED) return;
        sh = bound(sh, 1, _q[i] - SEED);
        uint256 proceeds = LsLmsr.proceedsToSell(_q, ALPHA, S_STAR, i, sh);
        // A pool that cannot pay is the failure this whole suite exists to rule out, so assert it
        // here rather than letting an arithmetic underflow revert and be swallowed.
        assertLe(proceeds, collateral, "sale proceeds exceeded collateral");
        collateral -= proceeds;
        _q[i] -= sh;
        ++sells;
    }

    function buyComplement(uint256 i, uint256 sh) external {
        i = bound(i, 0, _q.length - 1);
        sh = bound(sh, 1, 1e22);
        collateral += LsLmsr.costToBuyComplement(_q, ALPHA, S_STAR, i, sh);
        for (uint256 j; j < _q.length; ++j) {
            if (j != i) _q[j] += sh;
        }
        ++shorts;
    }
}

contract LsLmsrInvariantTest is Test {
    LsLmsrHandler internal handler;

    function setUp() public {
        handler = new LsLmsrHandler(3);
        targetContract(address(handler));
    }

    /// @notice The pool always holds at least the largest possible payout.
    function invariant_solvent() public view {
        assertGe(handler.collateral(), handler.maxQ(), "INSOLVENT: collateral < max(q_i)");
    }

    /// @notice Collateral tracks `C(q)` to within fixed-point noise.
    ///
    /// @dev Asserted with a tolerance, and the reason is worth recording because it is the one place
    ///      the implementation cannot deliver the idealised invariant.
    ///
    ///      In exact arithmetic `collateral ≥ C(q)` telescopes: every buy adds `C(q') − C(q)` rounded
    ///      up and every sell subtracts it rounded down, so the balance can only gain margin. In
    ///      fixed point the *computed* `Ĉ` is not perfectly monotone — for a dust-sized sell,
    ///      `Ĉ(q − δ·eᵢ)` can land a few wei ABOVE `Ĉ(q)`. {LsLmsr.proceedsToSell} then correctly
    ///      pays nothing, but the ledger has stopped tracking `Ĉ` exactly, and a run of ~4,500 calls
    ///      drifts by ~173 wei.
    ///
    ///      That drift is economically meaningless and, importantly, cannot threaten solvency: the
    ///      gap between `C(q)` and `max(qᵢ)` is the entropy term `b·ln(…)`, on the order of 1e20 wei
    ///      here — eighteen orders of magnitude more headroom than the drift consumes. Solvency is
    ///      therefore defined against `max(qᵢ)` in {invariant_solvent}, which is the claim that
    ///      actually protects depositors and which holds exactly.
    function invariant_collateralTracksCostFunction() public view {
        uint256[] memory state = handler.q();
        uint256 c = LsLmsr.cost(state, handler.ALPHA(), handler.S_STAR());
        // 1e12 wei = 1e-6 of one collateral unit.
        assertGe(handler.collateral() + 1e12, c, "collateral drifted materially below C(q)");
    }

    /// @notice The solvency buffer is the entropy term, and it legitimately vanishes.
    ///
    /// @dev Measured, because it changes the architecture. The gap `C(q) − max(qᵢ)` is
    ///      `b·ln(1 + Σe^((qᵢ−m)/b))`, which shrinks toward zero as the book approaches certainty:
    ///      a skewed run left a buffer of 0.0035 units on a 27,477-unit book. That is correct — at
    ///      probability 1 the market should hold exactly the winning payout and not a unit more —
    ///      but it means the buffer is NOT a safety margin that can be relied on to absorb the
    ///      wei-scale drift documented in {invariant_collateralTracksCostFunction}.
    ///
    ///      The consequence for Phase 2: `Market` must assert `collateral ≥ max(qᵢ)` as a
    ///      post-condition on every state change and revert, exactly as the brief requires, rather
    ///      than trusting the curve to be self-enforcing. This test records the reason that
    ///      requirement is load-bearing instead of ceremonial.
    function invariant_bufferIsNonNegativeButMayBeThin() public view {
        uint256[] memory state = handler.q();
        uint256 m;
        for (uint256 i; i < state.length; ++i) {
            if (state[i] > m) m = state[i];
        }
        // The only guarantee is non-negativity. Asserting any positive floor here would fail the
        // moment the book approaches certainty, which is a normal end state for a resolving market.
        assertGe(handler.collateral(), m, "buffer went negative -- insolvent");
    }

    /// @notice The run actually exercised the handler.
    ///
    /// @dev Deliberately `afterInvariant` and not an `invariant_`: Foundry evaluates invariants once
    ///      against the post-`setUp` state, before any call is made, so a counter assertion written
    ///      as an invariant fails on an empty sequence every time.
    ///
    ///      Worth having at all because a misconfigured target or an always-rejecting bound would
    ///      otherwise produce a perfectly green suite that executed nothing.
    function afterInvariant() public view {
        assertGt(handler.buys(), 0, "no buys executed");
        assertGt(handler.sells(), 0, "no sells executed");
        assertGt(handler.shorts(), 0, "no shorts executed");
    }
}
