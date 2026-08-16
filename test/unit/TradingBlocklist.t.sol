// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TradingBlocklist} from "../../src/access/TradingBlocklist.sol";
import {Roles} from "../../src/access/Roles.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";

/// @title TradingBlocklistTest
/// @notice The ban list is the one place a trader loses a right, so what matters is that only the
///         intended callers can write to it and that the record is exact.
contract TradingBlocklistTest is Test {
    TradingBlocklist internal list;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x8E50);
    address internal stranger = address(0xBAD);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    address internal market = address(0x1234);

    event Banned(address indexed account, address indexed context, uint256 marketId, uint64 at);
    event Unbanned(address indexed account, address indexed by);

    function setUp() public {
        list = new TradingBlocklist(admin);
        vm.prank(admin);
        list.grantRole(Roles.BLOCKLIST_ROLE, resolver);
    }

    // ---------------------------------------------------------------------
    // Positive
    // ---------------------------------------------------------------------

    function test_banMarksAccountAndRecordsWhen() public {
        vm.warp(1_700_000_000);
        vm.prank(resolver);
        list.ban(alice, market, 7);

        assertTrue(list.isBanned(alice), "alice should be banned");
        assertEq(list.bannedAt(alice), 1_700_000_000, "ban timestamp");
        assertEq(list.bannedCount(), 1, "count");
    }

    function test_banEmitsTheContextThatCausedIt() public {
        vm.warp(1_700_000_000);
        vm.expectEmit(true, true, false, true, address(list));
        emit Banned(alice, market, 7, 1_700_000_000);
        vm.prank(resolver);
        list.ban(alice, market, 7);
    }

    function test_adminHoldsBlocklistRoleFromConstruction() public view {
        assertTrue(list.hasRole(Roles.BLOCKLIST_ROLE, admin), "admin can ban");
        assertTrue(list.hasRole(list.DEFAULT_ADMIN_ROLE(), admin), "admin is admin");
    }

    function test_unbanRestoresTrading() public {
        vm.prank(resolver);
        list.ban(alice, market, 7);

        vm.expectEmit(true, true, false, false, address(list));
        emit Unbanned(alice, admin);
        vm.prank(admin);
        list.unban(alice);

        assertFalse(list.isBanned(alice), "alice free again");
        assertEq(list.bannedAt(alice), 0, "timestamp cleared");
        assertEq(list.bannedCount(), 0, "count back to zero");
    }

    function test_bansAreIndependentAcrossAccounts() public {
        vm.startPrank(resolver);
        list.ban(alice, market, 1);
        list.ban(bob, market, 2);
        vm.stopPrank();

        assertEq(list.bannedCount(), 2, "two banned");

        vm.prank(admin);
        list.unban(alice);

        assertFalse(list.isBanned(alice), "alice free");
        assertTrue(list.isBanned(bob), "bob still banned");
        assertEq(list.bannedCount(), 1, "count follows");
    }

    function test_unbannedAccountCanBeBannedAgain() public {
        vm.prank(resolver);
        list.ban(alice, market, 1);
        vm.prank(admin);
        list.unban(alice);

        vm.warp(block.timestamp + 1000);
        vm.prank(resolver);
        list.ban(alice, market, 2);

        assertTrue(list.isBanned(alice), "banned again");
        assertEq(list.bannedAt(alice), uint64(block.timestamp), "fresh timestamp");
        assertEq(list.bannedCount(), 1, "counted once");
    }

    /// @dev An operator banning directly has no market to point at, so zero is a legal context.
    function test_operatorCanBanWithoutAMarketContext() public {
        vm.prank(admin);
        list.ban(alice, address(0), 0);
        assertTrue(list.isBanned(alice), "banned");
    }

    // ---------------------------------------------------------------------
    // Negative
    // ---------------------------------------------------------------------

    function test_strangerCannotBan() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.BLOCKLIST_ROLE
            )
        );
        vm.prank(stranger);
        list.ban(alice, market, 7);
    }

    /// @dev The role that writes bans deliberately cannot lift them. Applying a rule and making
    ///      exceptions to it are different powers.
    function test_blocklistRoleCannotUnban() public {
        vm.prank(resolver);
        list.ban(alice, market, 7);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, resolver, bytes32(0)
            )
        );
        vm.prank(resolver);
        list.unban(alice);
    }

    function test_cannotBanTwice() public {
        vm.prank(resolver);
        list.ban(alice, market, 7);

        vm.expectRevert(abi.encodeWithSelector(TradingBlocklist.AlreadyBanned.selector, alice));
        vm.prank(resolver);
        list.ban(alice, market, 8);
    }

    function test_cannotUnbanSomebodyWhoIsNotBanned() public {
        vm.expectRevert(abi.encodeWithSelector(TradingBlocklist.NotBanned.selector, alice));
        vm.prank(admin);
        list.unban(alice);
    }

    function test_cannotBanTheZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(resolver);
        list.ban(address(0), market, 7);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(ZeroAddress.selector);
        new TradingBlocklist(address(0));
    }

    // ---------------------------------------------------------------------
    // Regression
    // ---------------------------------------------------------------------

    /// @dev A revoked writer must stop working immediately, which is the whole reason the list is
    ///      role-gated rather than owned by one address.
    function test_revokedWriterCannotBan() public {
        vm.prank(admin);
        list.revokeRole(Roles.BLOCKLIST_ROLE, resolver);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, resolver, Roles.BLOCKLIST_ROLE
            )
        );
        vm.prank(resolver);
        list.ban(alice, market, 7);
    }

    /// @dev `bannedCount` is maintained by hand around two `unchecked` blocks. A double unban would
    ///      underflow it to `type(uint256).max` and make the operator dashboard meaningless, so the
    ///      guard that prevents it is worth pinning.
    function test_countNeverUnderflows() public {
        vm.prank(resolver);
        list.ban(alice, market, 1);
        vm.startPrank(admin);
        list.unban(alice);
        vm.expectRevert(abi.encodeWithSelector(TradingBlocklist.NotBanned.selector, alice));
        list.unban(alice);
        vm.stopPrank();

        assertEq(list.bannedCount(), 0, "count stays at zero");
    }

    /// @dev Zero must mean "not banned" for an account nobody has ever touched, since the engine
    ///      reads exactly this on every trade.
    function test_unknownAccountIsNotBanned() public view {
        assertFalse(list.isBanned(address(0xDEAD)), "unknown account trades freely");
        assertEq(list.bannedAt(address(0xDEAD)), 0, "no timestamp");
    }
}
