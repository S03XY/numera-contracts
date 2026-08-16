// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {ParimutuelMarket} from "../../src/markets/ParimutuelMarket.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockToggleFeeERC20} from "../../src/mocks/MockToggleFeeERC20.sol";
import {MarketTypes} from "../../src/libraries/MarketTypes.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {
    ZeroAddress,
    MarketNotFound,
    MarketNotResolved,
    InvalidOutcome,
    AmountBelowMin,
    AlreadyClaimed,
    NotAuthorized,
    LiquidityTooHigh,
    AmountTooLarge,
    ZeroLiquidity
} from "../../src/libraries/Errors.sol";

/// @notice Targeted edge/negative tests that close branch-coverage gaps and exercise the new input
///         bounds and defensive guards across every contract.
contract EdgeCasesTest is Test {
    LMSRMarket lmsr;
    ParimutuelMarket pari;
    MarketFactory factory;
    TrustedResolver resolver;
    MockERC20 usdc;

    address alice = makeAddr("alice");
    address feeTo = makeAddr("feeTo");
    uint64 closeTime;
    uint256 constant USDC = 1e6;
    uint256 constant B = 1000 * USDC;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lmsr = new LMSRMarket(address(this));
        pari = new ParimutuelMarket(address(this));
        resolver = new TrustedResolver(address(this));
        factory = new MarketFactory(address(this));
        closeTime = uint64(block.timestamp + 1 days);

        usdc.mint(address(this), 100_000_000 * USDC);
        usdc.approve(address(lmsr), type(uint256).max);
        usdc.mint(alice, 100_000_000 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(lmsr), type(uint256).max);
        usdc.approve(address(pari), type(uint256).max);
        vm.stopPrank();
    }

    function _lmsr(uint256 b) internal returns (uint256) {
        return lmsr.createMarket(
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, b, "SPORTS", "m")
        );
    }

    // ======================================================================
    // LMSR input bounds (new)
    // ======================================================================

    function test_lmsr_create_revertsBTooHigh() public {
        uint256 tooBig = Constants.MAX_LIQUIDITY_PARAM + 1;
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityTooHigh.selector, tooBig, Constants.MAX_LIQUIDITY_PARAM)
        );
        lmsr.createMarket(
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, tooBig, "", "")
        );
    }

    function test_lmsr_create_revertsBZero() public {
        vm.expectRevert(ZeroLiquidity.selector);
        lmsr.createMarket(
            LMSRMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, 0, "", "")
        );
    }

    function test_lmsr_buy_revertsSharesTooLarge() public {
        uint256 id = _lmsr(B);
        uint256 tooMany = Constants.MAX_SHARES_PER_TRADE + 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AmountTooLarge.selector, tooMany, Constants.MAX_SHARES_PER_TRADE)
        );
        lmsr.buy(id, 0, tooMany, type(uint256).max);
    }

    function test_lmsr_create_maxBoundaryAllowed() public {
        // b exactly at the max is allowed by the bound check; subsidy = b*ln(2) ~ 6.9e29, so fund it.
        usdc.mint(address(this), 1e31);
        uint256 id = _lmsr(Constants.MAX_LIQUIDITY_PARAM);
        assertEq(lmsr.getMarket(id).b, Constants.MAX_LIQUIDITY_PARAM);
    }

    // ======================================================================
    // LMSR deflationary-collateral guard (received < required)
    // ======================================================================

    function test_lmsr_buy_revertsIfCollateralTakesTransferFee() public {
        MockToggleFeeERC20 tkn = new MockToggleFeeERC20();
        tkn.mint(address(this), 1_000_000e18);
        tkn.approve(address(lmsr), type(uint256).max);
        // create while fee is OFF so the subsidy transfers in full
        uint256 id = lmsr.createMarket(
            LMSRMarket.CreateParams(address(tkn), address(resolver), closeTime, 2, 0, 1000e18, "", "")
        );
        tkn.mint(alice, 1_000_000e18);
        vm.prank(alice);
        tkn.approve(address(lmsr), type(uint256).max);

        tkn.setFee(100); // now 1% burned on transfer -> received < totalPaid
        vm.prank(alice);
        vm.expectRevert(); // AmountBelowMin(received, totalPaid)
        lmsr.buy(id, 0, 100e18, type(uint256).max);
    }

    // ======================================================================
    // LMSR view reverts + settlement-state guards
    // ======================================================================

    function test_lmsr_priceWad_revertsInvalidOutcome() public {
        uint256 id = _lmsr(B);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 9, 2));
        lmsr.priceWad(id, 9);
    }

    function test_lmsr_quoteBuy_revertsInvalidOutcome() public {
        uint256 id = _lmsr(B);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 9, 2));
        lmsr.quoteBuy(id, 9, 1);
    }

    function test_lmsr_quoteSell_revertsInvalidOutcome() public {
        uint256 id = _lmsr(B);
        vm.expectRevert(abi.encodeWithSelector(InvalidOutcome.selector, 9, 2));
        lmsr.quoteSell(id, 9, 1);
    }

    function test_lmsr_redeem_revertsWhenTrading() public {
        uint256 id = _lmsr(B);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarketNotResolved.selector, id));
        lmsr.redeem(id);
    }

    function test_lmsr_redeemLiquidity_revertsBeforeSettlement() public {
        uint256 id = _lmsr(B);
        vm.expectRevert(abi.encodeWithSelector(MarketNotResolved.selector, id));
        lmsr.redeemLiquidity(id); // LP == this contract, but market still Trading
    }

    function test_lmsr_redeemLiquidity_doubleRedeemReverts() public {
        uint256 id = _lmsr(B);
        vm.prank(alice);
        lmsr.buy(id, 0, 100 * USDC, type(uint256).max);
        vm.warp(closeTime);
        resolver.resolveMarket(address(lmsr), id, 0);
        lmsr.redeemLiquidity(id);
        vm.expectRevert(AlreadyClaimed.selector);
        lmsr.redeemLiquidity(id);
    }

    function test_lmsr_getters_marketNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 0));
        lmsr.getMarket(0);
    }

    function test_lmsr_engineGetters() public {
        uint256 id = _lmsr(B);
        assertEq(lmsr.closeTimeOf(id), closeTime);
        assertEq(lmsr.outcomeCountOf(id), 2);
    }

    function test_lmsr_withdrawFees_revertsZeroTo() public {
        vm.expectRevert(ZeroAddress.selector);
        lmsr.withdrawFees(address(usdc), address(0), 1);
    }

    // ======================================================================
    // Parimutuel view edges
    // ======================================================================

    function test_pari_claimable_zeroWhenTrading() public {
        uint256 id = pari.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, 0, "SPORTS", "m")
        );
        vm.prank(alice);
        pari.placeBet(id, 0, 100 * USDC);
        assertEq(pari.claimable(id, alice), 0); // not resolved yet
    }

    function test_pari_claimable_zeroAfterClaim() public {
        uint256 id = pari.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 2, 0, 0, "SPORTS", "m")
        );
        vm.prank(alice);
        pari.placeBet(id, 0, 100 * USDC);
        usdc.mint(feeTo, 100 * USDC);
        vm.prank(feeTo);
        usdc.approve(address(pari), type(uint256).max);
        vm.prank(feeTo);
        pari.placeBet(id, 1, 100 * USDC);
        vm.warp(closeTime);
        resolver.resolveMarket(address(pari), id, 0);
        vm.prank(alice);
        pari.claim(id);
        assertEq(pari.claimable(id, alice), 0); // already claimed
    }

    function test_pari_engineGetters() public {
        uint256 id = pari.createMarket(
            ParimutuelMarket.CreateParams(address(usdc), address(resolver), closeTime, 3, 0, 0, "S", "m")
        );
        assertEq(pari.closeTimeOf(id), closeTime);
        assertEq(pari.outcomeCountOf(id), 3);
    }

    function test_pari_withdrawFees_revertsZeroTo() public {
        vm.expectRevert(ZeroAddress.selector);
        pari.withdrawFees(address(usdc), address(0), 1);
    }

    // ======================================================================
    // MarketFactory view reverts
    // ======================================================================

    function test_factory_getEngine_revertsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 0));
        factory.getEngine(0);
    }

    function test_factory_getMarketRef_revertsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 0));
        factory.getMarketRef(0);
    }

    function test_factory_setEngineEnabled_revertsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 5));
        factory.setEngineEnabled(5, false);
    }

    function test_factory_setCategory_revertsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        factory.setCategory(bytes32(0), "x", true);
    }

    function test_factory_getMarketsByCategory_empty() public view {
        assertEq(factory.getMarketsByCategory(bytes32("NONE")).length, 0);
    }
}
