// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestUSDC} from "../../src/testnet/TestUSDC.sol";

/// @title UsdcFidelityTest
/// @notice The ways this token deliberately behaves like Circle's, rather than like a convenient
///         ERC-20.
///
/// @dev Every assertion here exists because the difference it pins would otherwise be discovered on
///      mainnet, with real collateral, by a user. The token is testnet-only; the *behaviour* it
///      reproduces is not.
contract UsdcFidelityTest is Test {
    TestUSDC internal usdc;

    address internal admin = makeAddr("admin");
    address internal spender = makeAddr("spender");
    address internal alice;
    uint256 internal alicePk;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        usdc = new TestUSDC(admin);
        vm.warp(1_700_000_000);
        vm.prank(admin);
        usdc.mint(alice, 10_000e6);
    }

    function _domain(string memory version) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(usdc.name())),
                keccak256(bytes(version)),
                block.chainid,
                address(usdc)
            )
        );
    }

    function _sign(uint256 pk, bytes32 domain, bytes32 structHash)
        internal
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ============================================================ the EIP-712 domain

    function test_theDomainSeparatorUsesVersionTwo(uint256 valueRaw) public {
        // The single most consequential difference from OpenZeppelin's ERC20Permit, and the reason
        // this token does not use it. A client that assumes "1" signs a digest that recovers to a
        // different address, so `permit` reverts with `InvalidSignature` and nothing points at the
        // cause.
        uint256 value = bound(valueRaw, 1, 10_000e6);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, value, usdc.nonces(alice), deadline));

        (uint8 v, bytes32 r, bytes32 s) = _sign(alicePk, _domain("2"), structHash);
        usdc.permit(alice, spender, value, deadline, v, r, s);

        assertEq(usdc.allowance(alice, spender), value, "a version-2 permit must be accepted");
    }

    function test_aVersionOnePermitIsRejected() public {
        // The failure mode, pinned. If this ever starts passing, the token has drifted away from
        // Circle and the client's domain handling is no longer being tested against reality.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, 100e6, usdc.nonces(alice), deadline));

        (uint8 v, bytes32 r, bytes32 s) = _sign(alicePk, _domain("1"), structHash);
        vm.expectRevert(TestUSDC.InvalidSignature.selector);
        usdc.permit(alice, spender, 100e6, deadline, v, r, s);
    }

    function test_theContractAgreesWithTheDomainWeConstruct() public view {
        assertEq(usdc.DOMAIN_SEPARATOR(), _domain("2"));
    }

    function test_itDoesNotImplementErc5267LikeRealUsdc() public {
        // USDC predates ERC-5267 and does not expose `eip712Domain()`. Reproducing that absence is
        // the point: a client that discovers the domain through it would work here and fail against
        // the real token. Discovery has to go through `version()`.
        (bool ok,) = address(usdc).staticcall(abi.encodeWithSignature("eip712Domain()"));
        assertFalse(ok, "exposing eip712Domain would hide a client bug until mainnet");
    }

    function test_aPermitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, 100e6, usdc.nonces(alice), deadline));
        (uint8 v, bytes32 r, bytes32 s) = _sign(alicePk, _domain("2"), structHash);

        usdc.permit(alice, spender, 100e6, deadline, v, r, s);
        vm.expectRevert(TestUSDC.InvalidSignature.selector);
        usdc.permit(alice, spender, 100e6, deadline, v, r, s);
    }

    function test_anExpiredPermitIsRejected() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, 100e6, usdc.nonces(alice), deadline));
        (uint8 v, bytes32 r, bytes32 s) = _sign(alicePk, _domain("2"), structHash);

        vm.expectRevert(abi.encodeWithSelector(TestUSDC.PermitExpired.selector, deadline));
        usdc.permit(alice, spender, 100e6, deadline, v, r, s);
    }

    // =================================================================== blacklist

    function test_aBlacklistedAccountCannotSendOrReceive() public {
        vm.prank(admin);
        usdc.blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AccountBlacklisted.selector, alice));
        usdc.transfer(spender, 1e6);

        vm.prank(admin);
        usdc.mint(admin, 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AccountBlacklisted.selector, alice));
        usdc.transfer(alice, 1e6);
    }

    function test_aBlacklistedAccountCannotGrantAnAllowance() public {
        // Circle blocks approvals too, not just transfers. Otherwise a frozen account could still
        // hand out spending rights over a balance it cannot move itself.
        vm.prank(admin);
        usdc.blacklist(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AccountBlacklisted.selector, alice));
        usdc.approve(spender, 1e6);
    }

    function test_aBlacklistedAccountCannotPermit() public {
        vm.prank(admin);
        usdc.blacklist(alice);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, 100e6, usdc.nonces(alice), deadline));
        (uint8 v, bytes32 r, bytes32 s) = _sign(alicePk, _domain("2"), structHash);

        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AccountBlacklisted.selector, alice));
        usdc.permit(alice, spender, 100e6, deadline, v, r, s);
    }

    function test_blacklistingIsReversible() public {
        vm.prank(admin);
        usdc.blacklist(alice);
        vm.prank(admin);
        usdc.unBlacklist(alice);

        vm.prank(alice);
        usdc.transfer(spender, 1e6);
        assertEq(usdc.balanceOf(spender), 1e6);
    }

    function test_onlyTheBlacklisterMayFreeze() public {
        vm.prank(alice);
        vm.expectRevert(TestUSDC.NotBlacklister.selector);
        usdc.blacklist(spender);
    }

    // ======================================================================= pause

    function test_pauseStopsEveryBalanceChange() public {
        vm.prank(admin);
        usdc.pause();

        vm.prank(alice);
        vm.expectRevert();
        usdc.transfer(spender, 1e6);

        vm.prank(admin);
        vm.expectRevert();
        usdc.mint(alice, 1e6);

        vm.prank(spender);
        vm.expectRevert();
        usdc.faucet();
    }

    function test_unpauseRestoresIt() public {
        vm.prank(admin);
        usdc.pause();
        vm.prank(admin);
        usdc.unpause();

        vm.prank(alice);
        usdc.transfer(spender, 1e6);
        assertEq(usdc.balanceOf(spender), 1e6);
    }

    // =============================================================== minter roles

    function test_aConfiguredMinterSpendsItsAllowanceDown() public {
        address minter = makeAddr("minter");
        vm.prank(admin);
        usdc.configureMinter(minter, 500e6);

        vm.prank(minter);
        usdc.mint(spender, 200e6);
        assertEq(usdc.minterAllowance(minter), 300e6, "allowance did not decrement");

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.ExceedsMinterAllowance.selector, 400e6, 300e6));
        usdc.mint(spender, 400e6);
    }

    function test_anUncappedMinterStaysUncapped() public {
        // The deployer seeds markets and must not have to be reconfigured after every mint.
        vm.prank(admin);
        usdc.mint(spender, 1_000_000e6);
        assertEq(usdc.minterAllowance(admin), type(uint256).max);
    }

    function test_aRemovedMinterCannotMint() public {
        address minter = makeAddr("minter");
        vm.prank(admin);
        usdc.configureMinter(minter, 500e6);
        vm.prank(admin);
        usdc.removeMinter(minter);

        vm.prank(minter);
        vm.expectRevert(TestUSDC.NotMinter.selector);
        usdc.mint(spender, 1e6);
    }

    // ===================================================================== EIP-3009

    function _authorize(bytes32 typehash, address to, uint256 value, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s, uint256 after_, uint256 before_)
    {
        after_ = block.timestamp - 1;
        before_ = block.timestamp + 1 hours;
        (v, r, s) = _sign(
            alicePk, _domain("2"), keccak256(abi.encode(typehash, alice, to, value, after_, before_, nonce))
        );
    }

    function test_transferWithAuthorizationMovesValueOnASignature() public {
        // USDC's other gasless primitive. Worth having even though Numera uses `permit`: an account
        // with no native balance can pay someone directly, with no allowance step at all.
        bytes32 nonce = keccak256("n1");
        (uint8 v, bytes32 r, bytes32 s, uint256 a, uint256 b) =
            _authorize(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, spender, 250e6, nonce);

        usdc.transferWithAuthorization(alice, spender, 250e6, a, b, nonce, v, r, s);

        assertEq(usdc.balanceOf(spender), 250e6);
        assertTrue(usdc.authorizationState(alice, nonce), "nonce not burned");
    }

    function test_anAuthorizationCannotBeReplayed() public {
        bytes32 nonce = keccak256("n2");
        (uint8 v, bytes32 r, bytes32 s, uint256 a, uint256 b) =
            _authorize(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, spender, 100e6, nonce);

        usdc.transferWithAuthorization(alice, spender, 100e6, a, b, nonce, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AuthorizationAlreadyUsed.selector, nonce));
        usdc.transferWithAuthorization(alice, spender, 100e6, a, b, nonce, v, r, s);
    }

    function test_anAuthorizationRespectsItsWindow() public {
        bytes32 nonce = keccak256("n3");
        (uint8 v, bytes32 r, bytes32 s, uint256 a, uint256 b) =
            _authorize(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, spender, 100e6, nonce);

        vm.warp(b + 1);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AuthorizationExpired.selector, b));
        usdc.transferWithAuthorization(alice, spender, 100e6, a, b, nonce, v, r, s);
    }

    function test_receiveWithAuthorizationIsPayeeOnly() public {
        // Front-running protection: a bare `transferWithAuthorization` can be landed by anyone at a
        // moment of their choosing, which for some flows is exploitable.
        bytes32 nonce = keccak256("n4");
        (uint8 v, bytes32 r, bytes32 s, uint256 a, uint256 b) =
            _authorize(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, spender, 100e6, nonce);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        usdc.receiveWithAuthorization(alice, spender, 100e6, a, b, nonce, v, r, s);

        vm.prank(spender);
        usdc.receiveWithAuthorization(alice, spender, 100e6, a, b, nonce, v, r, s);
        assertEq(usdc.balanceOf(spender), 100e6);
    }

    function test_anAuthorizationCanBeCancelledBeforeUse() public {
        bytes32 nonce = keccak256("n5");
        (uint8 cv, bytes32 cr, bytes32 cs) = _sign(
            alicePk,
            _domain("2"),
            keccak256(
                abi.encode(keccak256("CancelAuthorization(address authorizer,bytes32 nonce)"), alice, nonce)
            )
        );
        usdc.cancelAuthorization(alice, nonce, cv, cr, cs);

        (uint8 v, bytes32 r, bytes32 s, uint256 a, uint256 b) =
            _authorize(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, spender, 100e6, nonce);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.AuthorizationAlreadyUsed.selector, nonce));
        usdc.transferWithAuthorization(alice, spender, 100e6, a, b, nonce, v, r, s);
    }
}
