// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {ParimutuelMarket} from "../../src/markets/ParimutuelMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Full-lifecycle conservation under load: many traders → resolve → every winner redeems →
///         LP settles → fees withdrawn. Asserts no collateral is stranded or conjured.
contract LifecycleConservationTest is Test {
    TrustedResolver resolver;
    MockERC20 usdc;
    uint256 constant USDC = 1e6;
    uint64 closeTime;
    address feeTo = makeAddr("feeTo");
    address[] traders;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        resolver = new TrustedResolver(address(this));
        closeTime = uint64(block.timestamp + 1 days);
        for (uint256 i; i < 40; ++i) {
            traders.push(address(uint160(uint256(keccak256(abi.encode("t", i))))));
        }
    }

    // ======================================================================
    // LMSR: settlement is EXACT (1:1 winning shares + exact LP remainder + fees) -> zero dust
    // ======================================================================

    function test_lmsr_fullLifecycle_zeroResidual() public {
        LMSRMarket m = new LMSRMarket(address(this));
        usdc.mint(address(this), 100_000_000 * USDC);
        usdc.approve(address(m), type(uint256).max);
        uint256 id = m.createMarket(
            LMSRMarket.CreateParams(
                address(usdc), address(resolver), closeTime, 3, 150, 50_000 * USDC, "S", "x"
            )
        );

        // Every trader buys a pseudo-random outcome/amount.
        for (uint256 i; i < traders.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode("lmsr", i)));
            address t = traders[i];
            uint256 outcome = r % 3;
            uint256 shares = ((r >> 8) % 900 + 100) * USDC;
            usdc.mint(t, 10_000_000 * USDC);
            vm.startPrank(t);
            usdc.approve(address(m), type(uint256).max);
            m.buy(id, outcome, shares, type(uint256).max);
            vm.stopPrank();
        }

        vm.warp(closeTime);
        uint256 winner = 1;
        resolver.resolveMarket(address(m), id, winner);

        // Every winner redeems; losers revert (caught).
        for (uint256 i; i < traders.length; ++i) {
            vm.prank(traders[i]);
            try m.redeem(id) {} catch {}
        }
        m.redeemLiquidity(id); // LP == this contract
        uint256 fees = m.accruedFees(address(usdc));
        if (fees > 0) m.withdrawFees(address(usdc), feeTo, fees);

        // LMSR redemptions are exact -> the vault is fully drained.
        assertEq(usdc.balanceOf(address(m)), 0);
    }

    // ======================================================================
    // Parimutuel: pro-rata payouts floor -> only sub-unit dust may remain (< #winners)
    // ======================================================================

    function test_parimutuel_fullLifecycle_onlyDustResidual() public {
        ParimutuelMarket m = new ParimutuelMarket(address(this));
        uint256 id = m.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 3, 200, 0, "S", "x")
        );

        uint256 winners;
        for (uint256 i; i < traders.length; ++i) {
            uint256 r = uint256(keccak256(abi.encode("pari", i)));
            address t = traders[i];
            uint256 outcome = r % 3;
            if (outcome == 2) winners++;
            uint256 amt = ((r >> 8) % 900 + 100) * USDC;
            usdc.mint(t, 10_000_000 * USDC);
            vm.startPrank(t);
            usdc.approve(address(m), type(uint256).max);
            m.placeBet(id, outcome, amt);
            vm.stopPrank();
        }

        vm.warp(closeTime);
        resolver.resolveMarket(address(m), id, 2); // outcome 2 wins

        uint256 totalIn = usdc.balanceOf(address(m));
        uint256 paidOut;
        for (uint256 i; i < traders.length; ++i) {
            vm.prank(traders[i]);
            try m.claim(id) returns (uint256 p) {
                paidOut += p;
            } catch {}
        }
        uint256 fees = m.accruedFees(address(usdc));
        m.withdrawFees(address(usdc), feeTo, fees);
        paidOut += fees;

        uint256 residual = usdc.balanceOf(address(m));
        // Never overpays; only floor-rounding dust remains, strictly bounded by the winner count.
        assertLe(paidOut, totalIn);
        assertEq(paidOut + residual, totalIn); // nothing lost
        assertLe(residual, winners == 0 ? 0 : winners); // dust < 1 unit per winning claim
    }
}
