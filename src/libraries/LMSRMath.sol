// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SD59x18, convert} from "@prb/math/src/SD59x18.sol";
import {Constants} from "./Constants.sol";

/// @title LMSRMath
/// @notice Hanson's Logarithmic Market Scoring Rule (LMSR), the classic automated market maker for
///         prediction markets, implemented in 18-decimal fixed point via PRBMath.
///
/// @dev Definitions (all quantities in collateral base units; `b` is the liquidity parameter):
///        Cost:   C(q) = b * ln( Σ_i exp(q_i / b) )
///        Price:  p_i  = exp(q_i / b) / Σ_j exp(q_j / b)          (prices are true probabilities, Σ p = 1)
///        Trade:  paying C(q') - C(q) moves the state from q to q'.
///
///      Buying shares of an outcome raises `q_i`, which raises `p_i` — this is the public price shift.
///      Numerical stability: every exponent is computed as (q_i - qmax)/b <= 0, so `exp` stays in
///      (0, 1] and never overflows, and `ln` only ever sees a sum >= 1. Rounding is deliberately
///      asymmetric — buy costs round UP, sell refunds round DOWN — so the pool always holds >= C(q)
///      and stays solvent (C(q) >= q_i for every i, so winners are always fully covered).
///
///      Bounded loss: the maker's worst-case subsidy is exactly C(0) = b * ln(N). Seeding a market
///      with that amount makes the collateral held identically equal to C(q) at all times.
library LMSRMath {
    /// @dev C(q) as a fixed-point real (base-unit valued). Pure; does not mutate `q`.
    function _costFP(uint256[] memory q, uint256 b) private pure returns (SD59x18) {
        uint256 n = q.length;
        uint256 qmax;
        for (uint256 i; i < n; ++i) {
            if (q[i] > qmax) qmax = q[i];
        }
        SD59x18 bfp = convert(int256(b));
        SD59x18 qmaxFp = convert(int256(qmax));
        SD59x18 sum = convert(0);
        for (uint256 i; i < n; ++i) {
            SD59x18 ratio = (convert(int256(q[i])) - qmaxFp) / bfp; // <= 0
            sum = sum + ratio.exp(); // in (0, 1]
        }
        return qmaxFp + bfp * sum.ln(); // qmax + b*ln(Σ exp) ; ln(sum) >= 0 since sum >= 1
    }

    /// @notice Total cost C(q) of a state, rounded UP to base units (subsidy at q=0 is b*ln(N)).
    function cost(uint256[] memory q, uint256 b) internal pure returns (uint256) {
        return uint256(convert(_costFP(q, b).ceil()));
    }

    /// @notice Collateral required to buy `delta` shares of outcome `k` (rounded UP).
    function costToBuy(uint256[] memory q, uint256 b, uint256 k, uint256 delta)
        internal
        pure
        returns (uint256)
    {
        SD59x18 c0 = _costFP(q, b);
        q[k] += delta;
        SD59x18 c1 = _costFP(q, b);
        q[k] -= delta; // restore caller's array
        return uint256(convert((c1 - c0).ceil()));
    }

    /// @notice Collateral refunded for selling `delta` shares of outcome `k` (rounded DOWN).
    function refundToSell(uint256[] memory q, uint256 b, uint256 k, uint256 delta)
        internal
        pure
        returns (uint256)
    {
        SD59x18 c0 = _costFP(q, b);
        q[k] -= delta;
        SD59x18 c1 = _costFP(q, b);
        q[k] += delta; // restore caller's array
        return uint256(convert((c0 - c1).floor()));
    }

    /// @notice Marginal prices for every outcome in WAD (1e18 == 100%); sums to ~1e18.
    function prices(uint256[] memory q, uint256 b) internal pure returns (uint256[] memory p) {
        uint256 n = q.length;
        p = new uint256[](n);
        uint256 qmax;
        for (uint256 i; i < n; ++i) {
            if (q[i] > qmax) qmax = q[i];
        }
        SD59x18 bfp = convert(int256(b));
        SD59x18 qmaxFp = convert(int256(qmax));
        SD59x18[] memory e = new SD59x18[](n);
        SD59x18 sum = convert(0);
        for (uint256 i; i < n; ++i) {
            e[i] = ((convert(int256(q[i])) - qmaxFp) / bfp).exp();
            sum = sum + e[i];
        }
        for (uint256 i; i < n; ++i) {
            // e_i/sum is in [0,1]; its raw 18-dec representation IS the WAD price.
            p[i] = uint256((e[i] / sum).unwrap());
        }
    }
}
