// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @dev Drives random buy/sell sequences from a pool of actors against one LMSR market.
contract LMSRHandler is Test {
    LMSRMarket public market;
    MockERC20 public usdc;
    uint256 public id;
    uint32 public constant OUTCOMES = 3;
    address[] public actors;

    uint256 public buys;
    uint256 public sells;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new LMSRMarket(address(this));
        TrustedResolver r = new TrustedResolver(address(this));

        usdc.mint(address(this), 1e15);
        usdc.approve(address(market), type(uint256).max);
        // closeTime far in the future so trading is always open during the invariant run.
        id = market.createMarket(
            LMSRMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(r),
                closeTime: uint64(block.timestamp + 3650 days),
                outcomeCount: OUTCOMES,
                feeBps: 100, // 1% fee, so the accruedFees path is exercised
                b: 1000e6,
                category: "S",
                metadataHash: "m"
            })
        );

        for (uint256 i; i < 5; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(a);
            usdc.mint(a, 1e15);
            vm.prank(a);
            usdc.approve(address(market), type(uint256).max);
        }
    }

    function buy(uint256 aSeed, uint256 oSeed, uint256 sSeed) external {
        address a = actors[aSeed % actors.length];
        uint256 o = oSeed % OUTCOMES;
        uint256 s = bound(sSeed, 1, 5000e6);
        vm.prank(a);
        try market.buy(id, o, s, type(uint256).max) {
            buys++;
        } catch {}
    }

    function sell(uint256 aSeed, uint256 oSeed, uint256 sSeed) external {
        address a = actors[aSeed % actors.length];
        uint256 o = oSeed % OUTCOMES;
        uint256 have = market.sharesOf(id, a, o);
        if (have == 0) return;
        uint256 s = bound(sSeed, 1, have);
        vm.prank(a);
        try market.sell(id, o, s, 0) {
            sells++;
        } catch {}
    }
}

/// @notice Invariants that must hold after any random sequence of LMSR trades.
contract LMSRInvariantTest is Test {
    LMSRHandler handler;

    function setUp() public {
        handler = new LMSRHandler();
        targetContract(address(handler));
    }

    /// @dev No collateral is ever created or lost: contract balance == pot + accrued fees, exactly.
    function invariant_moneyConserved() public view {
        LMSRMarket m = handler.market();
        MockERC20 u = handler.usdc();
        uint256 id = handler.id();
        assertEq(u.balanceOf(address(m)), m.getMarket(id).pot + m.accruedFees(address(u)));
    }

    /// @dev The market is always solvent: the pot covers every outcome's winning shares 1:1.
    function invariant_solventForEveryOutcome() public view {
        LMSRMarket m = handler.market();
        uint256 id = handler.id();
        uint256 pot = m.getMarket(id).pot;
        for (uint256 i; i < handler.OUTCOMES(); ++i) {
            assertGe(pot, m.outcomeShares(id, i));
        }
    }

    /// @dev Prices are always a valid probability distribution (sum to ~1e18).
    function invariant_pricesSumToOne() public view {
        LMSRMarket m = handler.market();
        uint256[] memory p = m.prices(handler.id());
        uint256 sum;
        for (uint256 i; i < p.length; ++i) {
            sum += p[i];
        }
        assertApproxEqAbs(sum, 1e18, 100);
    }

    /// @dev Proves the handler actually executes trades (so the invariants above are non-trivial).
    function test_handlerProducesRealTrades() public {
        LMSRMarket m = handler.market();
        MockERC20 u = handler.usdc();
        uint256 potBefore = m.getMarket(handler.id()).pot;

        handler.buy(0, 0, 200e6);
        handler.buy(1, 1, 300e6);
        handler.sell(0, 0, type(uint256).max);

        assertGe(handler.buys(), 2);
        assertGe(handler.sells(), 1);
        assertGt(m.getMarket(handler.id()).pot, potBefore); // pot moved => trades really happened
        // conservation still exact after real trades
        assertEq(u.balanceOf(address(m)), m.getMarket(handler.id()).pot + m.accruedFees(address(u)));
    }
}
