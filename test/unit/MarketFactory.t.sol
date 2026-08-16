// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {ParimutuelMarket} from "../../src/markets/ParimutuelMarket.sol";
import {LMSRMarket} from "../../src/markets/LMSRMarket.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MarketTypes} from "../../src/libraries/MarketTypes.sol";
import {Roles} from "../../src/access/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ZeroAddress, MarketNotFound, NotAuthorized} from "../../src/libraries/Errors.sol";

contract MarketFactoryTest is Test {
    MarketFactory factory;
    ParimutuelMarket pari;
    LMSRMarket lmsr;
    TrustedResolver resolver;
    MockERC20 usdc;

    address stranger = makeAddr("stranger");
    bytes32 constant SPORTS = bytes32("SPORTS");
    bytes32 constant POLITICS = bytes32("POLITICS");

    function setUp() public {
        factory = new MarketFactory(address(this));
        pari = new ParimutuelMarket(address(this));
        lmsr = new LMSRMarket(address(this));
        resolver = new TrustedResolver(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    function _createPariMarket() internal returns (uint256 id) {
        id = pari.createMarket(
            ParimutuelMarket.CreateParams({
                collateral: address(usdc),
                resolver: address(resolver),
                closeTime: uint64(block.timestamp + 1 days),
                outcomeCount: 2,
                feeBps: 0,
                minBet: 0,
                category: SPORTS,
                metadataHash: keccak256("x")
            })
        );
    }

    // ----- engine registry -----

    function test_registerEngine_storesInfo() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Parimutuel v1");
        assertEq(eid, 0);
        assertEq(factory.engineCount(), 1);
        MarketFactory.EngineInfo memory info = factory.getEngine(eid);
        assertEq(info.engine, address(pari));
        assertEq(uint8(info.kind), uint8(MarketTypes.Kind.Parimutuel));
        assertTrue(info.enabled);
        assertEq(info.label, "Parimutuel v1");
    }

    function test_registerEngine_multiple() public {
        factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        uint256 e2 = factory.registerEngine(address(lmsr), MarketTypes.Kind.LMSR, "LMSR");
        assertEq(e2, 1);
        assertEq(factory.engineCount(), 2);
    }

    function test_setEngineEnabled_toggles() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        factory.setEngineEnabled(eid, false);
        assertFalse(factory.getEngine(eid).enabled);
        factory.setEngineEnabled(eid, true);
        assertTrue(factory.getEngine(eid).enabled);
    }

    function test_registerEngine_revertsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        factory.registerEngine(address(0), MarketTypes.Kind.Parimutuel, "x");
    }

    function test_registerEngine_revertsNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0)
            )
        );
        factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "x");
    }

    // ----- category catalog -----

    function test_setCategory_addsAndEnables() public {
        factory.setCategory(SPORTS, "Sports", true);
        assertTrue(factory.isCategoryEnabled(SPORTS));
        assertEq(factory.categoryCount(), 1);
        assertEq(factory.categoryAt(0), SPORTS);
    }

    function test_setCategory_updateDoesNotDuplicate() public {
        factory.setCategory(SPORTS, "Sports", true);
        factory.setCategory(SPORTS, "Sports & Games", false);
        assertEq(factory.categoryCount(), 1); // still one entry
        assertFalse(factory.isCategoryEnabled(SPORTS));
    }

    function test_setCategory_revertsNonCurator() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.CURATOR_ROLE
            )
        );
        factory.setCategory(SPORTS, "Sports", true);
    }

    // ----- market index -----

    function test_recordMarket_indexesRealMarket() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        factory.setCategory(SPORTS, "Sports", true);
        uint256 marketId = _createPariMarket();

        uint256 refId = factory.recordMarket(eid, marketId, SPORTS);
        assertEq(refId, 0);
        assertEq(factory.marketCount(), 1);
        MarketFactory.MarketRef memory r = factory.getMarketRef(refId);
        assertEq(r.engineId, eid);
        assertEq(r.marketId, marketId);
        assertEq(r.category, SPORTS);
        assertEq(uint8(r.kind), uint8(MarketTypes.Kind.Parimutuel));
        assertEq(r.creator, address(this));
    }

    function test_getMarketsByCategory_filters() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        factory.setCategory(SPORTS, "Sports", true);
        factory.setCategory(POLITICS, "Politics", true);
        uint256 m0 = _createPariMarket();
        uint256 m1 = _createPariMarket();
        uint256 m2 = _createPariMarket();
        factory.recordMarket(eid, m0, SPORTS);
        factory.recordMarket(eid, m1, POLITICS);
        factory.recordMarket(eid, m2, SPORTS);

        MarketFactory.MarketRef[] memory sports = factory.getMarketsByCategory(SPORTS);
        assertEq(sports.length, 2);
        assertEq(sports[0].marketId, m0);
        assertEq(sports[1].marketId, m2);
        assertEq(factory.getMarketsByCategory(POLITICS).length, 1);
    }

    // ---- negative ----

    function test_recordMarket_revertsUnknownEngine() public {
        factory.setCategory(SPORTS, "Sports", true);
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 0));
        factory.recordMarket(0, 0, SPORTS);
    }

    function test_recordMarket_revertsDisabledEngine() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        factory.setCategory(SPORTS, "Sports", true);
        _createPariMarket();
        factory.setEngineEnabled(eid, false);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, address(pari)));
        factory.recordMarket(eid, 0, SPORTS);
    }

    function test_recordMarket_revertsDisabledCategory() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        _createPariMarket();
        // category never enabled
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, address(0)));
        factory.recordMarket(eid, 0, SPORTS);
    }

    function test_recordMarket_revertsNonexistentMarketId() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        factory.setCategory(SPORTS, "Sports", true);
        // no markets created yet -> marketId 0 does not exist
        vm.expectRevert(abi.encodeWithSelector(MarketNotFound.selector, 0));
        factory.recordMarket(eid, 0, SPORTS);
    }

    function test_recordMarket_revertsNonCurator() public {
        uint256 eid = factory.registerEngine(address(pari), MarketTypes.Kind.Parimutuel, "Pari");
        factory.setCategory(SPORTS, "Sports", true);
        _createPariMarket();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.CURATOR_ROLE
            )
        );
        factory.recordMarket(eid, 0, SPORTS);
    }
}
