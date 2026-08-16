// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestUSDC} from "../../src/testnet/TestUSDC.sol";
import {ZeroAddress} from "../../src/libraries/Errors.sol";

contract TestUSDCTest is Test {
    TestUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new TestUSDC(admin);
        // Faucet eligibility is a timestamp comparison; starting at 0 would make
        // "never claimed" and "claimed at genesis" indistinguishable.
        vm.warp(1_700_000_000);
    }

    // ---------------------------------------------------------------- metadata

    function test_metadataMatchesRealUSDC() public view {
        assertEq(usdc.decimals(), 6, "must match USDC so amount formatting agrees");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.name(), "USD Coin");
        // The one that is not cosmetic. OpenZeppelin's ERC20Permit hardcodes "1"; Circle uses "2".
        // A client that assumes "1" signs permits that recover to a different address entirely.
        assertEq(usdc.version(), "2", "EIP-712 domain version must match Circle");
        assertEq(usdc.owner(), admin);
        assertEq(usdc.masterMinter(), admin);
    }

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(ZeroAddress.selector);
        new TestUSDC(address(0));
    }

    // ------------------------------------------------------------------ faucet

    function test_faucetMintsToCaller() public {
        vm.prank(alice);
        usdc.faucet();

        assertEq(usdc.balanceOf(alice), usdc.FAUCET_AMOUNT());
        assertEq(usdc.totalSupply(), usdc.FAUCET_AMOUNT());
        assertEq(usdc.nextFaucetAt(alice), block.timestamp + usdc.FAUCET_COOLDOWN());
    }

    function test_faucetEmitsClaimWithNextEligibility() public {
        uint256 expectedNext = block.timestamp + usdc.FAUCET_COOLDOWN();

        vm.expectEmit(true, false, false, true);
        emit TestUSDC.FaucetClaimed(alice, usdc.FAUCET_AMOUNT(), expectedNext);

        vm.prank(alice);
        usdc.faucet();
    }

    function test_faucetIsFirstComeForAnyFreshAddress() public {
        vm.prank(alice);
        usdc.faucet();
        // Bob's eligibility is independent of Alice's — the cooldown is per-account.
        vm.prank(bob);
        usdc.faucet();

        assertEq(usdc.balanceOf(bob), usdc.FAUCET_AMOUNT());
    }

    // ---------------------------------------------------------- faucet negative

    function test_faucetRevertsInsideCooldown() public {
        vm.prank(alice);
        usdc.faucet();
        uint256 availableAt = usdc.nextFaucetAt(alice);

        vm.expectRevert(abi.encodeWithSelector(TestUSDC.FaucetCooldown.selector, availableAt));
        vm.prank(alice);
        usdc.faucet();
    }

    function test_faucetRevertsOneSecondBeforeEligibility() public {
        vm.prank(alice);
        usdc.faucet();

        // Boundary: the cooldown is inclusive of its final second.
        vm.warp(usdc.nextFaucetAt(alice) - 1);
        vm.expectRevert();
        vm.prank(alice);
        usdc.faucet();
    }

    function test_faucetSucceedsExactlyAtEligibility() public {
        vm.prank(alice);
        usdc.faucet();

        vm.warp(usdc.nextFaucetAt(alice));
        vm.prank(alice);
        usdc.faucet();

        assertEq(usdc.balanceOf(alice), usdc.FAUCET_AMOUNT() * 2);
    }

    function testFuzz_faucetNeverExceedsOneClaimPerCooldown(uint32 elapsed) public {
        vm.prank(alice);
        usdc.faucet();

        vm.warp(block.timestamp + elapsed);
        bool eligible = elapsed >= usdc.FAUCET_COOLDOWN();

        vm.prank(alice);
        if (eligible) {
            usdc.faucet();
            assertEq(usdc.balanceOf(alice), usdc.FAUCET_AMOUNT() * 2);
        } else {
            vm.expectRevert();
            usdc.faucet();
            assertEq(usdc.balanceOf(alice), usdc.FAUCET_AMOUNT());
        }
    }

    // ------------------------------------------------------------ cooldown view

    function test_cooldownRemainingIsZeroBeforeFirstClaim() public view {
        assertEq(usdc.faucetCooldownRemaining(alice), 0);
    }

    function test_cooldownRemainingCountsDownToZero() public {
        vm.prank(alice);
        usdc.faucet();

        assertEq(usdc.faucetCooldownRemaining(alice), usdc.FAUCET_COOLDOWN());

        vm.warp(block.timestamp + 1 hours);
        assertEq(usdc.faucetCooldownRemaining(alice), usdc.FAUCET_COOLDOWN() - 1 hours);

        vm.warp(usdc.nextFaucetAt(alice));
        assertEq(usdc.faucetCooldownRemaining(alice), 0, "never underflows past eligibility");
    }

    // ----------------------------------------------------------- admin minting

    function test_adminCanMintForLiquiditySeeding() public {
        vm.prank(admin);
        usdc.mint(alice, 500_000e6);
        assertEq(usdc.balanceOf(alice), 500_000e6);
    }

    function test_adminMintDoesNotConsumeRecipientFaucetAllowance() public {
        vm.prank(admin);
        usdc.mint(alice, 500_000e6);

        // A seeded LP must still be able to claim from the faucet.
        vm.prank(alice);
        usdc.faucet();
        assertEq(usdc.balanceOf(alice), 500_000e6 + usdc.FAUCET_AMOUNT());
    }

    function test_mintRevertsForNonMinter() public {
        vm.expectRevert(TestUSDC.NotMinter.selector);
        vm.prank(alice);
        usdc.mint(alice, 1e6);
    }

    function test_mintRevertsEvenForAddressThatUsedFaucet() public {
        vm.prank(alice);
        usdc.faucet();

        // Using the faucet grants no minting authority — the guard is on msg.sender only.
        vm.expectRevert(TestUSDC.NotMinter.selector);
        vm.prank(alice);
        usdc.mint(alice, 1e6);
    }

    // -------------------------------------------------------------- regression

    function test_behavesAsAStandardERC20() public {
        vm.prank(alice);
        usdc.faucet();

        vm.prank(alice);
        usdc.approve(bob, 100e6);
        assertEq(usdc.allowance(alice, bob), 100e6);

        vm.prank(bob);
        usdc.transferFrom(alice, bob, 100e6);

        assertEq(usdc.balanceOf(bob), 100e6);
        assertEq(usdc.balanceOf(alice), usdc.FAUCET_AMOUNT() - 100e6);
    }
}
