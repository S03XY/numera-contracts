// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ParimutuelMarket} from "../../src/markets/ParimutuelMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @dev Drives random betting across a pool of actors and outcomes against one parimutuel market.
contract ParimutuelHandler is Test {
    ParimutuelMarket public market;
    MockERC20 public usdc;
    uint256 public id;
    uint32 public constant OUTCOMES = 4;
    address[] public actors;

    uint256 public bets;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new ParimutuelMarket(address(this));
        TrustedResolver r = new TrustedResolver(address(this));
        id = market.createMarket(
            ParimutuelMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(r),
                closeTime: uint64(block.timestamp + 3650 days),
                outcomeCount: OUTCOMES,
                feeBps: 200,
                minBet: 0,
                category: "S",
                metadataHash: "m"
            })
        );
        for (uint256 i; i < 6; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(a);
            usdc.mint(a, 1e15);
            vm.prank(a);
            usdc.approve(address(market), type(uint256).max);
        }
    }

    function bet(uint256 aSeed, uint256 oSeed, uint256 amtSeed) external {
        address a = actors[aSeed % actors.length];
        uint256 o = oSeed % OUTCOMES;
        uint256 amt = bound(amtSeed, 1, 100_000e6);
        vm.prank(a);
        try market.placeBet(id, o, amt) {
            bets++;
        } catch {}
    }
}

/// @notice Invariants that must hold after any random sequence of parimutuel bets.
contract ParimutuelInvariantTest is Test {
    ParimutuelHandler handler;

    function setUp() public {
        handler = new ParimutuelHandler();
        targetContract(address(handler));
    }

    /// @dev During trading, the vault holds exactly the total pool (no fee taken until resolution).
    function invariant_balanceEqualsTotalPool() public view {
        ParimutuelMarket m = handler.market();
        MockERC20 u = handler.usdc();
        uint256 id = handler.id();
        assertEq(u.balanceOf(address(m)), m.getMarket(id).totalPool);
    }

    /// @dev Internal consistency: the sum of the per-outcome pools equals the total pool.
    function invariant_outcomePoolsSumToTotal() public view {
        ParimutuelMarket m = handler.market();
        uint256 id = handler.id();
        uint256[] memory pools = m.getOutcomePools(id);
        uint256 sum;
        for (uint256 i; i < pools.length; ++i) {
            sum += pools[i];
        }
        assertEq(sum, m.getMarket(id).totalPool);
    }

    /// @dev Prices sum to ~1e18 once the market has any volume, else 0.
    function invariant_pricesSumToOne() public view {
        ParimutuelMarket m = handler.market();
        uint256 id = handler.id();
        uint256[] memory p = m.getPrices(id);
        uint256 sum;
        for (uint256 i; i < p.length; ++i) {
            sum += p[i];
        }
        if (m.getMarket(id).totalPool == 0) {
            assertEq(sum, 0);
        } else {
            assertApproxEqAbs(sum, 1e18, 10);
        }
    }

    /// @dev Proves the handler actually places bets (so the invariants above are non-trivial).
    function test_handlerProducesRealBets() public {
        ParimutuelMarket m = handler.market();
        handler.bet(0, 0, 1000e6);
        handler.bet(1, 2, 5000e6);
        assertGe(handler.bets(), 2);
        assertGt(m.getMarket(handler.id()).totalPool, 0);
    }
}
