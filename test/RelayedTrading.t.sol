// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LsLmsrMarket} from "../src/markets/LsLmsrMarket.sol";
import {NumeraForwarder, INumeraRelayable} from "../src/relay/NumeraForwarder.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";
import {MarketTypes} from "../src/libraries/MarketTypes.sol";
import {Roles} from "../src/access/Roles.sol";

// Published copy for fixtures. The engine checks it hashes to the commitment beside it.
string constant TEST_METADATA = "{\"title\":\"fixture\"}";


/// @title RelayedTradingTest
/// @notice The privacy claim, tested as a mechanism rather than asserted as a comment.
///
/// @dev Numera hides *who* trades by giving every (user, market) pair its own derived address, which
///      is funded by a shielded-pool withdrawal whose source is private. That link survives exactly
///      as long as nothing public ever connects the user to the account — and the thing most likely
///      to connect them is gas. One transfer of native token from the user's wallet to the market
///      account, even dust, publishes the association permanently and retroactively.
///
///      So the market account must be able to trade holding **zero** native balance, for its whole
///      life. Every test here keeps `marketAccount.balance == 0` and asserts it, because a test that
///      quietly funded the account would pass while the product leaked.
contract RelayedTradingTest is Test {
    LsLmsrMarket internal engine;
    NumeraForwarder internal forwarder;
    TestUSDC internal usdc;

    address internal admin = address(0xA11CE);
    address internal resolver = address(0x0BEEF);
    address internal feeSink = address(0xFEE5);
    /// The address paying for gas. Funded; the market account never is.
    address internal relayer = address(0x11AE);

    /// A trader's derived per-market account. Holds collateral, never holds gas.
    uint256 internal accountPk = 0xA11CE0000000000000000000000000000000000000000000000000000000B0B;
    address internal marketAccount;

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant SEED = 1000 * UNIT;
    uint256 internal constant MIN_TRADE = 5 * UNIT;
    uint16 internal constant FEE_BPS = 100; // 1%

    uint256 internal marketId;
    uint64 internal closeTime;

    bytes32 private constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        marketAccount = vm.addr(accountPk);

        vm.startPrank(admin);
        usdc = new TestUSDC(admin);
        // Deploy order mirrors `script/Deploy.s.sol`: forwarder first, engine trusting it, then the
        // one-shot wiring back. `admin` is the initializer here because it is the deploying address.
        forwarder = new NumeraForwarder(address(usdc), admin);
        engine = new LsLmsrMarket(admin, feeSink, address(forwarder), address(0));
        forwarder.initialize(address(engine));

        engine.setTradeFee(FEE_BPS);
        engine.setMinTradeCost(address(usdc), MIN_TRADE);

        usdc.mint(admin, 1_000_000 * UNIT);
        usdc.approve(address(engine), type(uint256).max);

        closeTime = uint64(block.timestamp + 7 days);
        marketId = engine.createMarket(
            LsLmsrMarket.CreateParams({
                collateral: address(usdc),
                resolver: resolver,
                startTime: 0,
                closeTime: closeTime,
                outcomeCount: 2,
                alpha: 0.025e18,
                sStar: 2000e18,
                seedPerOutcome: SEED,
                category: bytes32("SPORTS"),
                metadataHash: keccak256(bytes(TEST_METADATA)),
                metadata: TEST_METADATA
            })
        );

        // Collateral arrives as if withdrawn from the shielded pool: the account receives tokens and
        // nothing else. Deliberately no `vm.deal` — see the contract-level comment.
        usdc.mint(marketAccount, 1_000 * UNIT);
        vm.stopPrank();

        vm.deal(relayer, 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _domainSeparator(address verifying, string memory name, string memory version)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifying
            )
        );
    }

    /// @dev A real EIP-712 signature over the real typehash. Reconstructed here rather than taken
    ///      from the contract, so a change to either side shows up as a failure instead of both
    ///      moving together.
    function _sign(uint256 pk, address to, bytes memory data, uint256 gas, uint256 value, uint48 deadline)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory request)
    {
        address from = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(
                FORWARD_REQUEST_TYPEHASH,
                from,
                to,
                value,
                gas,
                forwarder.nonces(from),
                deadline,
                keccak256(data)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01", _domainSeparator(address(forwarder), "Numera Forwarder", "1"), structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        request = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: value,
            gas: gas,
            deadline: deadline,
            data: data,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _request(bytes memory data) internal view returns (ERC2771Forwarder.ForwardRequestData memory) {
        return _sign(accountPk, address(engine), data, 500_000, 0, uint48(block.timestamp + 1 hours));
    }

    function _buyData(uint256 shares, uint256 maxCost) internal view returns (bytes memory) {
        return abi.encodeCall(INumeraRelayable.buy, (marketId, 0, shares, maxCost));
    }

    /// @dev Sign an EIP-2612 approval so the account can authorise the engine without ever sending
    ///      a transaction of its own.
    function _permit(uint256 pk, uint256 value)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s, uint256 deadline)
    {
        address owner = vm.addr(pk);
        deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, address(engine), value, usdc.nonces(owner), deadline)
        );
        bytes32 digest = keccak256(
            // "USD Coin" / "2": the collateral mimics Circle's USDC, and the domain version is the
            // part a client is most likely to get wrong — so the tests sign the real one.
            abi.encodePacked("\x19\x01", _domainSeparator(address(usdc), "USD Coin", "2"), structHash)
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    /// @dev Approve the engine the way production does — by signature, relayed alongside a trade.
    function _approveByPermitAndBuy(uint256 shares) internal {
        (uint8 v, bytes32 r, bytes32 s, uint256 deadline) = _permit(accountPk, type(uint256).max);
        vm.prank(relayer);
        forwarder.executeWithPermit(
            marketAccount, type(uint256).max, deadline, v, r, s, _request(_buyData(shares, type(uint256).max))
        );
    }

    // =================================================== the claim this all exists for

    function test_marketAccountTradesHoldingZeroNativeBalance() public {
        assertEq(marketAccount.balance, 0, "precondition: the account must start with no gas");

        _approveByPermitAndBuy(10 * UNIT);

        assertEq(engine.sharesOf(marketId, marketAccount, 0), 10 * UNIT, "position not opened");
        assertEq(
            marketAccount.balance, 0, "LEAK: the market account acquired native balance and can now be linked"
        );
    }

    function test_positionIsCreditedToTheAccountAndNotTheForwarder() public {
        // The regression that thirty-one `msg.sender` sites exist to prevent. If any trader path had
        // kept `msg.sender`, every user's position would land on this one shared address — pooling
        // the whole platform's activity into a single publicly-visible account.
        _approveByPermitAndBuy(10 * UNIT);

        assertEq(engine.sharesOf(marketId, marketAccount, 0), 10 * UNIT, "trader has no position");
        assertEq(engine.sharesOf(marketId, address(forwarder), 0), 0, "FORWARDER WAS CREDITED AS THE TRADER");
        assertEq(engine.sharesOf(marketId, relayer, 0), 0, "relayer was credited as the trader");
    }

    function test_collateralIsPulledFromTheAccountNotTheRelayer() public {
        uint256 accountBefore = usdc.balanceOf(marketAccount);
        uint256 relayerBefore = usdc.balanceOf(relayer);

        _approveByPermitAndBuy(10 * UNIT);

        assertLt(usdc.balanceOf(marketAccount), accountBefore, "account paid nothing");
        assertEq(usdc.balanceOf(relayer), relayerBefore, "relayer paid the collateral");
    }

    function test_fullLifecycleIsRelayable() public {
        // Open, reduce, settle, collect — every leg through the forwarder, with the account never
        // holding gas at any point.
        _approveByPermitAndBuy(20 * UNIT);

        // 15 rather than 5: a partial sale must clear `minTradeCost` like any other relayed
        // operation, and 5 shares at roughly 0.50 would fetch about 2.50 — under the 5.00 floor.
        // Only a *complete* exit is exempt. See `test_aPartialSaleBelowTheFloorIsRefused`.
        vm.prank(relayer);
        forwarder.execute(_request(abi.encodeCall(INumeraRelayable.sell, (marketId, 0, 15 * UNIT, 0))));
        assertEq(engine.sharesOf(marketId, marketAccount, 0), 5 * UNIT, "sell did not reduce the position");

        vm.warp(closeTime + 1);
        vm.prank(resolver);
        engine.resolve(marketId, 0);

        uint256 before = usdc.balanceOf(marketAccount);
        vm.prank(relayer);
        forwarder.execute(_request(abi.encodeCall(INumeraRelayable.redeem, (marketId))));

        // Winning shares redeem 1:1 in base units, and settlement takes no further fee.
        assertEq(usdc.balanceOf(marketAccount) - before, 5 * UNIT, "winnings did not reach the account");
        assertEq(marketAccount.balance, 0, "LEAK: the account holds native balance after a full lifecycle");
    }

    // ============================================================ the forwarder's own rules

    function test_refusesAnyTargetButTheEngine() public {
        // The structural guarantee: this can never become a general-purpose relayer, no matter who
        // holds the relayer's key.
        ERC2771Forwarder.ForwardRequestData memory request = _sign(
            accountPk,
            address(usdc),
            _buyData(10 * UNIT, type(uint256).max),
            500_000,
            0,
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NumeraForwarder.TargetNotAllowed.selector, address(usdc)));
        forwarder.execute(request);
    }

    function test_refusesFunctionsOutsideTheTradingSet() public {
        // Allowlisting the contract is not enough. `createMarket` is the most expensive call on the
        // engine and moves seed capital; `resolve` decides who wins; `setFeeRecipient` redirects
        // revenue. None may be reachable by anyone willing to sign a message.
        bytes[] memory forbidden = new bytes[](3);
        forbidden[0] = abi.encodeCall(LsLmsrMarket.resolve, (marketId, 0));
        forbidden[1] = abi.encodeCall(LsLmsrMarket.setFeeRecipient, (address(0xBAD)));
        forbidden[2] = abi.encodeCall(LsLmsrMarket.redeemSeed, (marketId));

        for (uint256 i; i < forbidden.length; ++i) {
            ERC2771Forwarder.ForwardRequestData memory request = _request(forbidden[i]);
            vm.prank(relayer);
            vm.expectRevert(
                abi.encodeWithSelector(NumeraForwarder.SelectorNotAllowed.selector, bytes4(forbidden[i]))
            );
            forwarder.execute(request);
        }
    }

    function test_refusesNativeValue() public {
        ERC2771Forwarder.ForwardRequestData memory request = _sign(
            accountPk,
            address(engine),
            _buyData(10 * UNIT, type(uint256).max),
            500_000,
            1 wei,
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NumeraForwarder.ValueNotAllowed.selector, 1 wei));
        forwarder.execute{value: 1 wei}(request);
    }

    function test_refusesRequestsAboveTheGasCap() public {
        uint256 tooMuch = forwarder.MAX_RELAY_GAS() + 1;
        ERC2771Forwarder.ForwardRequestData memory request = _sign(
            accountPk,
            address(engine),
            _buyData(10 * UNIT, type(uint256).max),
            tooMuch,
            0,
            uint48(block.timestamp + 1 hours)
        );

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                NumeraForwarder.GasCapExceeded.selector, tooMuch, forwarder.MAX_RELAY_GAS()
            )
        );
        forwarder.execute(request);
    }

    function test_refusesCalldataTooShortToCarryASelector() public {
        ERC2771Forwarder.ForwardRequestData memory request = _request(hex"1234");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NumeraForwarder.CalldataTooShort.selector, 2));
        forwarder.execute(request);
    }

    function test_refusesBatches() public {
        ERC2771Forwarder.ForwardRequestData[] memory batch = new ERC2771Forwarder.ForwardRequestData[](1);
        batch[0] = _request(_buyData(10 * UNIT, type(uint256).max));

        vm.prank(relayer);
        vm.expectRevert(NumeraForwarder.BatchNotSupported.selector);
        forwarder.executeBatch(batch, payable(address(0)));
    }

    function test_refusesASignatureFromAnotherKey() public {
        // The account is derived from the user's own secret. Nobody else can move its collateral.
        uint256 attackerPk = 0xBAD;
        bytes memory data = _buyData(10 * UNIT, type(uint256).max);
        ERC2771Forwarder.ForwardRequestData memory request =
            _sign(attackerPk, address(engine), data, 500_000, 0, uint48(block.timestamp + 1 hours));
        request.from = marketAccount; // claim to be the trader

        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    function test_refusesAReplayOfAnExecutedRequest() public {
        _approveByPermitAndBuy(10 * UNIT);

        ERC2771Forwarder.ForwardRequestData memory request = _request(_buyData(10 * UNIT, type(uint256).max));
        vm.prank(relayer);
        forwarder.execute(request);

        // Same signed payload, replayed. The nonce has moved on.
        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    function test_refusesAnExpiredRequest() public {
        ERC2771Forwarder.ForwardRequestData memory request = _sign(
            accountPk,
            address(engine),
            _buyData(10 * UNIT, type(uint256).max),
            500_000,
            0,
            uint48(block.timestamp + 60)
        );

        vm.warp(block.timestamp + 61);
        vm.prank(relayer);
        vm.expectRevert();
        forwarder.execute(request);
    }

    function test_verifyRelayableMatchesWhatExecuteWillDo() public {
        // The relayer drops requests this returns false for, rather than paying for the revert. If
        // it ever disagreed with `execute`, the relayer would burn gas on doomed transactions.
        (uint8 v, bytes32 r, bytes32 s, uint256 deadline) = _permit(accountPk, type(uint256).max);
        vm.prank(relayer);
        usdc.permit(marketAccount, address(engine), type(uint256).max, deadline, v, r, s);

        assertTrue(
            forwarder.verifyRelayable(_request(_buyData(10 * UNIT, type(uint256).max))),
            "good request rejected"
        );
        assertFalse(
            forwarder.verifyRelayable(_request(abi.encodeCall(LsLmsrMarket.resolve, (marketId, 0)))),
            "forbidden selector accepted"
        );
        assertFalse(
            forwarder.verifyRelayable(
                _sign(accountPk, address(usdc), _buyData(1, 1), 500_000, 0, uint48(block.timestamp + 1 hours))
            ),
            "foreign target accepted"
        );
    }

    // ================================================================= wiring

    function test_initializeIsDeployerOnlyAndOneShot() public {
        NumeraForwarder fresh = new NumeraForwarder(address(usdc), admin);

        // Front-running the wiring would hand an attacker a forwarder aimed at a contract of their
        // choosing, funded by us.
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(NumeraForwarder.NotInitializer.selector, address(0xBAD)));
        fresh.initialize(address(engine));

        vm.prank(admin);
        fresh.initialize(address(engine));
        assertEq(fresh.market(), address(engine));

        vm.prank(admin);
        vm.expectRevert(NumeraForwarder.AlreadyInitialized.selector);
        fresh.initialize(address(0xBAD));
    }

    function test_anUninitializedForwarderRelaysNothing() public {
        NumeraForwarder fresh = new NumeraForwarder(address(usdc), admin);
        ERC2771Forwarder.ForwardRequestData memory request = _request(_buyData(10 * UNIT, type(uint256).max));

        vm.prank(relayer);
        vm.expectRevert(NumeraForwarder.NotInitialized.selector);
        fresh.execute(request);
    }

    function test_adminPathsRejectTheForwarderEvenIfItReachesThem() public {
        // The second of two independent locks. The selector allowlist already excludes these; this
        // proves the engine would refuse anyway, so one mistake in that list is not enough to
        // resolve a market or move the fee recipient.
        vm.prank(address(forwarder));
        vm.expectRevert(LsLmsrMarket.RelayNotAllowed.selector);
        engine.resolve(marketId, 0);

        vm.prank(address(forwarder));
        vm.expectRevert(LsLmsrMarket.RelayNotAllowed.selector);
        engine.pause();
    }

    function test_directTradingStillWorksWithoutTheRelay() public {
        // Relaying is an addition, not a replacement. An address holding its own gas trades as before.
        address direct = address(0xD1);
        vm.prank(admin);
        usdc.mint(direct, 1_000 * UNIT);
        vm.startPrank(direct);
        usdc.approve(address(engine), type(uint256).max);
        engine.buy(marketId, 0, 10 * UNIT, type(uint256).max);
        vm.stopPrank();

        assertEq(engine.sharesOf(marketId, direct, 0), 10 * UNIT);
    }
}
