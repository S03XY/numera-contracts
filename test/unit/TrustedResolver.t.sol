// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TrustedResolver} from "../../src/resolvers/TrustedResolver.sol";
import {MockResolvableMarket} from "../../src/mocks/MockResolvableMarket.sol";
import {Roles} from "../../src/access/Roles.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TrustedResolverTest is Test {
    TrustedResolver resolver;
    MockResolvableMarket market;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");

    function setUp() public {
        resolver = new TrustedResolver(admin);
        market = new MockResolvableMarket(address(resolver));
    }

    // ----- construction -----

    function test_constructor_grantsAdminAndResolverRoles() public view {
        assertTrue(resolver.hasRole(resolver.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(resolver.hasRole(Roles.RESOLVER_ROLE, admin));
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(ZeroAddress.selector);
        new TrustedResolver(address(0));
    }

    // ----- positive: resolve / invalidate forwarding -----

    function test_resolveMarket_forwardsToMarket() public {
        vm.prank(admin);
        resolver.resolveMarket(address(market), 7, 1);
        assertTrue(market.resolved());
        assertEq(market.lastMarketId(), 7);
        assertEq(market.lastWinningOutcome(), 1);
    }

    function test_invalidateMarket_forwardsToMarket() public {
        vm.prank(admin);
        resolver.invalidateMarket(address(market), 42);
        assertTrue(market.invalidated());
        assertEq(market.lastMarketId(), 42);
    }

    function test_grantedOperatorCanResolve() public {
        vm.prank(admin);
        resolver.grantRole(Roles.RESOLVER_ROLE, operator);

        vm.prank(operator);
        resolver.resolveMarket(address(market), 3, 0);
        assertTrue(market.resolved());
    }

    // ----- negative: access control -----

    function test_resolveMarket_revertsForNonResolver() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.RESOLVER_ROLE
            )
        );
        resolver.resolveMarket(address(market), 1, 0);
    }

    function test_invalidateMarket_revertsForNonResolver() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.RESOLVER_ROLE
            )
        );
        resolver.invalidateMarket(address(market), 1);
    }

    function test_revokedOperatorCannotResolve() public {
        vm.startPrank(admin);
        resolver.grantRole(Roles.RESOLVER_ROLE, operator);
        resolver.revokeRole(Roles.RESOLVER_ROLE, operator);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, Roles.RESOLVER_ROLE
            )
        );
        resolver.resolveMarket(address(market), 1, 0);
    }

    // ----- negative: market enforces its bound resolver -----

    function test_marketRejectsDirectResolutionFromNonResolver() public {
        // Calling the market directly (not via the bound resolver) must fail.
        vm.prank(stranger);
        vm.expectRevert(MockResolvableMarket.OnlyResolver.selector);
        market.resolve(1, 0);
    }

    function test_wrongResolverContractCannotResolveMarket() public {
        // A different resolver instance is not the market's bound resolver.
        TrustedResolver other = new TrustedResolver(admin);
        vm.prank(admin);
        vm.expectRevert(MockResolvableMarket.OnlyResolver.selector);
        other.resolveMarket(address(market), 1, 0);
    }
}
