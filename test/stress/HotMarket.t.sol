// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MarketTypes} from "../../src/libraries/MarketTypes.sol";

/// @notice Stress test: a "hot" market (FIFA World Cup final) with thousands of interleaved buys and
///         sells. Measures per-op gas, total fees generated, and derives throughput + sponsor gas-cost
///         estimates. Also asserts the solvency/price invariants hold under heavy continuous trading.
///
/// Outcomes: 0 = Argentina, 1 = Draw, 2 = France (full-time result market).
contract HotMarketStressTest is Test {
    LMSRMarket market;
    TrustedResolver resolver;
    MockERC20 usdc;

    uint256 constant USDC = 1e6;
    uint256 constant B = 200_000 * USDC; // deep liquidity so a hot book stays stable
    uint16 constant FEE_BPS = 200; // 2% trading fee
    uint256 constant N_TRADERS = 50;
    uint256 constant OPS = 3000; // interleaved buy/sell operations

    // --- Assumptions for throughput / cost estimates (edit with live Monad numbers) ---
    uint256 constant MONAD_BLOCK_GAS_LIMIT = 150_000_000; // assumed per-block gas budget
    uint256 constant MONAD_BLOCK_TIME_MS = 500; // assumed 0.5s blocks
    uint256 constant UNLINK_AA_OVERHEAD_GAS = 150_000; // est. ERC-4337 acct deploy + paymaster + bundler
    uint256 constant MONAD_GAS_PRICE_GWEI = 50; // assumed gas price for the sponsor's bill

    uint64 closeTime;
    uint256 id;
    address[] traders;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new LMSRMarket(address(this));
        resolver = new TrustedResolver(address(this));
        closeTime = uint64(block.timestamp + 3 hours); // roughly a match window

        usdc.mint(address(this), 2_000_000_000 * USDC); // LP funds the subsidy
        usdc.approve(address(market), type(uint256).max);

        id = market.createMarket(
            LMSRMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver),
                closeTime: closeTime,
                outcomeCount: 3,
                feeBps: FEE_BPS,
                b: B,
                category: bytes32("SPORTS"),
                metadataHash: keccak256("World Cup Final: Argentina/Draw/France")
            })
        );

        for (uint256 i; i < N_TRADERS; ++i) {
            address t = address(uint160(uint256(keccak256(abi.encode("trader", i)))));
            traders.push(t);
            usdc.mint(t, 100_000_000 * USDC);
            vm.prank(t);
            usdc.approve(address(market), type(uint256).max);
        }
    }

    function test_hotMarket_worldCupFinal() public {
        uint256 buyGas;
        uint256 sellGas;
        uint256 buys;
        uint256 sells;
        uint256 volume; // total notional traded (buy cost + sell proceeds), in base units

        for (uint256 i; i < OPS; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i, "wc-final")));
            address t = traders[r % traders.length];
            uint256 outcome = (r >> 8) % 3;
            bool wantSell = ((r >> 16) & 1) == 1;

            uint256 have = market.sharesOf(id, t, outcome);
            if (wantSell && have >= 10 * USDC) {
                uint256 sh = have / 3;
                vm.prank(t);
                uint256 g = gasleft();
                uint256 refund = market.sell(id, outcome, sh, 0);
                sellGas += g - gasleft();
                unchecked {
                    ++sells;
                    volume += refund;
                }
            } else {
                uint256 sh = ((r % 400) + 10) * USDC; // 10..409 shares
                vm.prank(t);
                uint256 g = gasleft();
                uint256 paid = market.buy(id, outcome, sh, type(uint256).max);
                buyGas += g - gasleft();
                unchecked {
                    ++buys;
                    volume += paid;
                }
            }
        }

        // --- invariants under load ---
        uint256[] memory p = market.prices(id);
        assertApproxEqAbs(p[0] + p[1] + p[2], 1e18, 20); // prices still sum to 1
        uint256 fees = market.accruedFees(address(usdc));

        vm.warp(closeTime);
        resolver.resolveMarket(address(market), id, 0); // Argentina wins
        LMSRMarket.MarketView memory v = market.getMarket(id);
        uint256 winningShares = market.outcomeShares(id, 0);
        assertGe(v.pot, winningShares); // solvent: pot covers every winning share 1:1
        assertEq(v.lpPayout, v.pot - winningShares); // exact LP remainder

        _report(buys, sells, volume, fees, buyGas, sellGas, v.pot);
    }

    function _report(
        uint256 buys,
        uint256 sells,
        uint256 volume,
        uint256 fees,
        uint256 buyGas,
        uint256 sellGas,
        uint256 pot
    ) internal view {
        uint256 avgBuyGas = buys == 0 ? 0 : buyGas / buys;
        uint256 avgSellGas = sells == 0 ? 0 : sellGas / sells;
        uint256 totalGas = buyGas + sellGas;

        console2.log("================ HOT MARKET: World Cup Final ================");
        console2.log("liquidity b (USDC)      :", B / USDC);
        console2.log("fee (bps)               :", FEE_BPS);
        console2.log("traders                 :", N_TRADERS);
        console2.log("operations total        :", buys + sells);
        console2.log("  buys                  :", buys);
        console2.log("  sells                 :", sells);
        console2.log("traded volume (USDC)    :", volume / USDC);
        console2.log("final pot backing (USDC):", pot / USDC);
        console2.log("---- FEES GENERATED ----");
        console2.log("total fees (USDC)       :", fees / USDC);
        console2.log("fees (micro-USDC)       :", fees);
        if (volume > 0) console2.log("effective fee (bps)     :", (fees * 10_000) / volume);

        console2.log("---- GAS (market execution portion) ----");
        console2.log("avg gas / BUY           :", avgBuyGas);
        console2.log("avg gas / SELL          :", avgSellGas);
        console2.log("total market gas used   :", totalGas);

        // Full private bet ~= market execution + ERC-4337/paymaster/bundler overhead.
        uint256 fullBetGas = avgBuyGas + UNLINK_AA_OVERHEAD_GAS;
        uint256 betsPerBlock = MONAD_BLOCK_GAS_LIMIT / fullBetGas;
        uint256 betsPerSec = (betsPerBlock * 1000) / MONAD_BLOCK_TIME_MS;

        console2.log("---- THROUGHPUT ESTIMATE (assumptions below) ----");
        console2.log("assumed block gas limit :", MONAD_BLOCK_GAS_LIMIT);
        console2.log("assumed block time (ms) :", MONAD_BLOCK_TIME_MS);
        console2.log("assumed AA overhead gas :", UNLINK_AA_OVERHEAD_GAS);
        console2.log("=> full private bet gas :", fullBetGas);
        console2.log("=> bets / block         :", betsPerBlock);
        console2.log("=> bets / second (chain):", betsPerSec);

        // Sponsor's gas bill (paymaster pays; users pay nothing).
        uint256 opsCount = buys + sells;
        uint256 sponsoredGas = totalGas + opsCount * UNLINK_AA_OVERHEAD_GAS;
        uint256 gasCostWei = sponsoredGas * MONAD_GAS_PRICE_GWEI * 1e9; // gwei -> wei
        console2.log("---- SPONSOR GAS BILL (paymaster) ----");
        console2.log("assumed gas price (gwei):", MONAD_GAS_PRICE_GWEI);
        console2.log("est. sponsored gas total:", sponsoredGas);
        console2.log("est. gas cost (wei)      :", gasCostWei);
        console2.log("est. gas cost (milli-MON):", gasCostWei / 1e15);
        if (opsCount > 0) {
            console2.log("est. gas cost per bet(gwei):", (sponsoredGas * MONAD_GAS_PRICE_GWEI) / opsCount);
        }
        console2.log("============================================================");
    }
}
