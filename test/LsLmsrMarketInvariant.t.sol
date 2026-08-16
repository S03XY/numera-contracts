// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../src/markets/LsLmsrMarket.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @notice Random trading against a live market, with real token transfers.
///
/// @dev The library-level campaign proved the curve is solvent. This proves the *contract* is: it
///      includes ERC-20 movement, per-market accounting, the spread overlay and directed rounding at
///      the collateral boundary — every place an off-by-one could quietly leak value that pure maths
///      would never show.
///
///      Two invariants matter and they are different claims:
///        - each market can pay its own largest possible liability, and
///        - the engine actually holds the sum of what every market thinks it has.
///      The second is what makes "no cross-market subsidy" true rather than aspirational: one pooled
///      token balance backs many books, so if it ever drifted below the sum, one market would be
///      spending another's collateral.
contract MarketHandler is Test {
    LsLmsrMarket public engine;
    MockERC20 public usdc;
    uint256 public marketA;
    uint256 public marketB;

    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];

    uint256 public buys;
    uint256 public sells;
    uint256 public shorts;

    constructor(LsLmsrMarket engine_, MockERC20 usdc_, uint256 a, uint256 b) {
        engine = engine_;
        usdc = usdc_;
        marketA = a;
        marketB = b;
        for (uint256 i; i < actors.length; ++i) {
            usdc.mint(actors[i], 50_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(engine), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _market(uint256 seed) internal view returns (uint256) {
        return seed % 2 == 0 ? marketA : marketB;
    }

    function buy(uint256 who, uint256 which, uint256 outcome, uint256 shares) external {
        uint256 id = _market(which);
        outcome = bound(outcome, 0, engine.outcomeCountOf(id) - 1);
        shares = bound(shares, 1, 100_000e6);
        vm.prank(_actor(who));
        engine.buy(id, outcome, shares, type(uint256).max);
        ++buys;
    }

    function buyComplement(uint256 who, uint256 which, uint256 outcome, uint256 shares) external {
        uint256 id = _market(which);
        outcome = bound(outcome, 0, engine.outcomeCountOf(id) - 1);
        shares = bound(shares, 1, 100_000e6);
        vm.prank(_actor(who));
        engine.buyComplement(id, outcome, shares, type(uint256).max);
        ++shorts;
    }

    function sell(uint256 who, uint256 which, uint256 outcome, uint256 shares) external {
        uint256 id = _market(which);
        address actor = _actor(who);
        outcome = bound(outcome, 0, engine.outcomeCountOf(id) - 1);
        uint256 held = engine.sharesOf(id, actor, outcome);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(actor);
        engine.sell(id, outcome, shares, 0);
        ++sells;
    }
}

contract LsLmsrMarketInvariantTest is Test {
    LsLmsrMarket internal engine;
    MockERC20 internal usdc;
    MarketHandler internal handler;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal fees = address(0xFEE5);

    uint256 internal marketA;
    uint256 internal marketB;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.prank(admin);
        engine = new LsLmsrMarket(admin, fees, address(0), address(0));

        usdc.mint(admin, 10_000_000e6);
        vm.prank(admin);
        usdc.approve(address(engine), type(uint256).max);

        marketA = _create(2, 0.025e18);
        marketB = _create(3, 0.010619e18);

        handler = new MarketHandler(engine, usdc, marketA, marketB);
        targetContract(address(handler));
    }

    function _create(uint32 n, uint256 alpha) internal returns (uint256) {
        vm.prank(admin);
        return engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: uint64(block.timestamp + 3650 days),
                outcomeCount: n,
                alpha: alpha,
                sStar: 2000e18,
                seedPerOutcome: 1000e6,
                category: bytes32("SPORTS"),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    function _maxQ(uint256 id) internal view returns (uint256 m) {
        uint32 n = engine.outcomeCountOf(id);
        for (uint256 i; i < n; ++i) {
            uint256 v = engine.outcomeShares(id, i);
            if (v > m) m = v;
        }
    }

    /// @notice Every market can pay its own largest liability.
    function invariant_eachMarketSolvent() public view {
        assertGe(engine.collateralOf(marketA), _maxQ(marketA), "market A insolvent");
        assertGe(engine.collateralOf(marketB), _maxQ(marketB), "market B insolvent");
    }

    /// @notice The engine really holds what its markets claim, so no book funds another.
    function invariant_tokenBalanceBacksEveryMarket() public view {
        uint256 claimed = engine.collateralOf(marketA) + engine.collateralOf(marketB);
        assertGe(usdc.balanceOf(address(engine)), claimed, "engine holds less than markets claim");
    }

    /// @notice Traders can never extract more than they put in, in aggregate.
    /// @dev The market maker's loss is bounded by `b·ln(n)` per book and nothing else. If the actors'
    ///      combined balance ever exceeded what they started with, the curve would be a faucet.
    function invariant_tradersCannotExtractValue() public view {
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            total += usdc.balanceOf(handler.actors(i));
        }
        assertLe(total, 3 * 50_000_000e6, "traders extracted value from the curve");
    }

    function afterInvariant() public view {
        assertGt(handler.buys(), 0, "no buys executed");
        assertGt(handler.sells(), 0, "no sells executed");
        assertGt(handler.shorts(), 0, "no shorts executed");
    }
}

/// @notice Every invariant above, re-run with the trading fee switched on.
///
/// @dev Fees are the one change that touches the solvency argument: they move money into the engine
///      that is *not* market collateral. The single-trade tests assert that separation directly;
///      this asserts it survives 8,192 fuzzed trades against two books, which is where an accounting
///      slip would actually show up.
contract LsLmsrMarketFeeInvariantTest is LsLmsrMarketInvariantTest {
    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        engine.setTradeFee(100); // 1%
    }

    /// @notice Every unit the engine holds is either backing a market or waiting to be swept.
    /// @dev Exact, not a bound. A fee counted as collateral, or collateral counted as a fee, breaks
    ///      this on the first trade — and either direction is a path to paying a winner with money
    ///      that has already been swept.
    function invariant_feesAreHeldOutsideMarketCollateral() public view {
        assertEq(
            usdc.balanceOf(address(engine)),
            engine.collateralOf(marketA) + engine.collateralOf(marketB) + engine.feesAccrued(address(usdc)),
            "engine balance != market collateral + accrued fees"
        );
    }
}
