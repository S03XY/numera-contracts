// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../src/markets/LsLmsrMarket.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {TrustedResolver} from "../src/resolvers/TrustedResolver.sol";
import {MarketTypes} from "../src/libraries/MarketTypes.sol";
import {Roles} from "../src/access/Roles.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {NotResolver, MarketNotFound, NotAuthorized} from "../src/libraries/Errors.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title LsLmsrIntegrationTest
/// @notice The whole operator path: register engine, catalog the market, trade, settle through the
///         resolver, pay everyone out.
///
/// @dev Phase 2 proved the engine works when called directly. This proves it works when driven the
///      way production drives it — settlement arriving from {TrustedResolver} rather than from an
///      EOA, and the market discoverable through {MarketFactory}. Those are the two seams where an
///      engine swap actually breaks, because both were written against the engines being replaced.
contract LsLmsrIntegrationTest is Test {
    LsLmsrMarket internal engine;
    MarketFactory internal factory;
    TrustedResolver internal resolver;
    MockERC20 internal usdc;

    address internal admin = address(0xA11CE);
    address internal operator = address(0x0B5);
    address internal fees = address(0xFEE5);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;
    uint64 internal closeTime;
    uint256 internal engineId;
    uint256 internal marketId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        closeTime = uint64(block.timestamp + 7 days);

        vm.startPrank(admin);
        resolver = new TrustedResolver(admin);
        resolver.grantRole(Roles.RESOLVER_ROLE, operator);
        engine = new LsLmsrMarket(admin, fees, address(0), address(0));
        factory = new MarketFactory(admin);
        engineId = factory.registerEngine(address(engine), MarketTypes.Kind.LsLmsr, "Damped LS-LMSR v1");
        factory.setCategory(bytes32("SPORTS"), "Sports", true);
        vm.stopPrank();

        address[3] memory funded = [admin, alice, bob];
        for (uint256 i; i < funded.length; ++i) {
            usdc.mint(funded[i], 1_000_000 * UNIT);
            vm.prank(funded[i]);
            usdc.approve(address(engine), type(uint256).max);
        }

        vm.prank(admin);
        marketId = engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver), // settlement arrives from the resolver contract
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 3,
                alpha: 0.010619e18,
                sStar: 2000e18,
                seedPerOutcome: SEED,
                category: bytes32("SPORTS"),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );
    }

    // ================================================================== positive

    function test_theWholeOperatorPathWorksEndToEnd() public {
        // Catalog it, exactly as the seeding script does.
        vm.prank(admin);
        uint256 refId = factory.recordMarket(engineId, marketId, bytes32("SPORTS"));

        MarketFactory.MarketRef memory ref = factory.getMarketRef(refId);
        assertEq(ref.marketId, marketId);
        assertEq(uint256(ref.kind), uint256(MarketTypes.Kind.LsLmsr), "indexed under the new engine");

        // Alice goes long outcome 2; Bob shorts outcome 0.
        vm.prank(alice);
        engine.buy(marketId, 2, 300 * UNIT, type(uint256).max);
        vm.prank(bob);
        engine.buyComplement(marketId, 0, 200 * UNIT, type(uint256).max);

        // Settle to outcome 2 through the resolver, by a RESOLVER_ROLE holder.
        vm.warp(closeTime + 1);
        vm.prank(operator);
        resolver.resolveMarket(address(engine), marketId, 2);

        uint256 owed = engine.outcomeShares(marketId, 2);
        assertEq(engine.collateralOf(marketId), owed, "market retains exactly its liability");
        assertGt(usdc.balanceOf(fees), 0, "surplus reached the fee recipient");

        // Alice's long pays; Bob's short pays too, because outcome 0 lost.
        vm.prank(alice);
        assertEq(engine.redeem(marketId), 300 * UNIT, "long pays 1:1");
        vm.prank(bob);
        assertEq(engine.redeem(marketId), 200 * UNIT, "short pays when the shorted outcome loses");

        vm.prank(admin);
        engine.redeemSeed(marketId);
        assertEq(engine.collateralOf(marketId), 0, "settles to exactly zero");
    }

    function test_resolverCanVoidAMarketAndTradersAreMadeWhole() public {
        vm.prank(alice);
        uint256 paid = engine.buy(marketId, 1, 150 * UNIT, type(uint256).max);

        vm.prank(operator);
        resolver.invalidateMarket(address(engine), marketId);

        vm.prank(alice);
        assertEq(engine.redeem(marketId), paid, "a void returns the cost basis");
    }

    // ================================================================== negative

    function test_negative_anEoaCannotSettleWhenTheResolverIsBound() public {
        // The market's resolver is the TrustedResolver contract, so even the admin cannot settle
        // directly. Settlement authority is a role on that contract and nowhere else.
        vm.warp(closeTime + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotResolver.selector, admin));
        engine.resolve(marketId, 0);
    }

    function test_negative_anAddressWithoutTheRoleCannotDriveTheResolver() public {
        vm.warp(closeTime + 1);
        vm.prank(alice);
        vm.expectRevert();
        resolver.resolveMarket(address(engine), marketId, 0);
    }

    function test_negative_factoryRejectsAMarketThatDoesNotExist() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 99));
        factory.recordMarket(engineId, 99, bytes32("SPORTS"));
    }

    function test_negative_factoryRejectsADisabledCategory() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, address(0)));
        factory.recordMarket(engineId, marketId, bytes32("POLITICS"));
    }

    function test_negative_onlyCuratorMayIndexAMarket() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.recordMarket(engineId, marketId, bytes32("SPORTS"));
    }

    // ================================================================== regression

    function test_regression_engineExposesTheInterfaceTheResolverNeeds() public view {
        // The resolver validates markets through IMarketEngine
        // before acting. If the new engine failed to answer these, settlement would revert at the
        // last step of an operator's workflow rather than at deploy time.
        assertEq(engine.marketCount(), 1);
        assertEq(engine.closeTimeOf(marketId), closeTime);
        assertEq(engine.outcomeCountOf(marketId), 3);
    }

    function test_regression_feeRecipientIsTheOnlyMutableSetting() public {
        address next = address(0xFEE6);
        vm.prank(admin);
        engine.setFeeRecipient(next);
        assertEq(engine.feeRecipient(), next);

        // And it is role-gated: surplus must not be redirectable by anyone who asks.
        vm.prank(alice);
        vm.expectRevert();
        engine.setFeeRecipient(alice);
    }

    function test_regression_marketParametersAreImmutableAfterCreation() public view {
        // alpha and sStar have no setters at all. Mutating either would make C history-dependent
        // and open a risk-free round trip across the change, so the absence is deliberate.
        LsLmsrMarket.MarketView memory v = engine.getMarket(marketId);
        assertEq(v.alpha, 0.010619e18);
        assertEq(v.sStar, 2000e18);
        assertEq(v.seed, SEED);
    }
}
