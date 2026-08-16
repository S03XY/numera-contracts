// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../../src/mocks/MockFeeOnTransferERC20.sol";
import {MockExecutionAccount} from "../../src/mocks/MockExecutionAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Sanity tests for the test doubles used by the rest of the suite.
contract MocksTest is Test {
    MockERC20 usdc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    // ----- MockERC20 -----

    function test_usdc_hasSixDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_usdc_mintAndBurn() public {
        usdc.mint(alice, 1000e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
        usdc.burn(alice, 400e6);
        assertEq(usdc.balanceOf(alice), 600e6);
    }

    // ----- MockFeeOnTransferERC20 -----

    function test_feeOnTransfer_burnsOnTransfer() public {
        MockFeeOnTransferERC20 fee = new MockFeeOnTransferERC20(100); // 1%
        fee.mint(alice, 1000e6);
        vm.prank(alice);
        fee.transfer(bob, 1000e6);
        assertEq(fee.balanceOf(bob), 990e6); // 1% burned
        assertEq(fee.totalSupply(), 990e6);
    }

    // ----- MockExecutionAccount -----

    function test_executionAccount_batchIsAtomicAndCallerIsAccount() public {
        // Simulate Unlink: owner EOA drives the account, which becomes msg.sender to targets.
        MockExecutionAccount acct = new MockExecutionAccount(alice);
        usdc.mint(address(acct), 500e6); // simulate withdrawFromPool

        // Batch: approve(bob, 100) then transfer(bob, 100) — as one UserOp.
        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](2);
        calls[0] = MockExecutionAccount.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(IERC20.approve, (bob, 100e6))
        });
        calls[1] = MockExecutionAccount.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(IERC20.transfer, (bob, 100e6))
        });

        vm.prank(alice);
        acct.execute(calls);

        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(usdc.allowance(address(acct), bob), 100e6);
    }

    function test_executionAccount_onlyOwnerCanExecute() public {
        MockExecutionAccount acct = new MockExecutionAccount(alice);
        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](0);
        vm.prank(bob);
        vm.expectRevert(MockExecutionAccount.NotOwner.selector);
        acct.execute(calls);
    }

    function test_executionAccount_revertsWholeBatchOnSubcallFailure() public {
        MockExecutionAccount acct = new MockExecutionAccount(alice);
        // No balance -> transfer will revert; the whole batch must revert.
        MockExecutionAccount.Call[] memory calls = new MockExecutionAccount.Call[](1);
        calls[0] = MockExecutionAccount.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(IERC20.transfer, (bob, 100e6))
        });
        vm.prank(alice);
        vm.expectRevert();
        acct.execute(calls);
    }
}
