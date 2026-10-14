// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {MidasQuoteHook} from "../src/MidasQuoteHook.sol";
import {IERC20Like, IVaultV2Like} from "./utils/ForkBase.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams,
    QuoteExactSingleParams,
    IUniversalRouter,
    IPermit2,
    IV4Quoter,
    IVaultCurator
} from "./utils/RouterTypes.sol";
import {Mainnet} from "./utils/Mainnet.sol";

interface IMidasFeed {
    function latestRound() external view returns (uint80);
    function setRoundDataSafe(int256 data) external;
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IVaultPreviewDeposit {
    function previewDeposit(uint256 assets) external view returns (uint256);
}

/// @dev Mainnet-fork fixture at block 26,190,200 (timestamp 1,791,974,387). State at the block, read with cast:
/// - mHYPER/USD round 126, answer 1.13327745, updatedAt 1,791,898,979 (75,408 s before the block);
/// - mALPHA/USD round 6, answer 1.01243740, updatedAt 1,791,551,615 (422,772 s before);
/// - mArb/USD round 2, answer 1.00000000, updatedAt 1,789,734,743 (2,239,644 s, about 25.9 days, before);
/// - all three tokens have 18 decimals and every feed 8; mHYPER and mALPHA sort below USDC, mArb above;
/// - vault idle is 0, so every bid force-deallocates; the PoolManager holds 536.28 mHYPER of other pools, no mALPHA
///   and no mArb.
/// The hook serves all three tokens. Each canonical pool is initialised at 1:1 by a third party, the maker posts
/// bid NAV - 50 bps and ask NAV x (1 + 5% APY x t / 365 days) x (1 + 30 bps), holds 1,000,000 of each token approved
/// to the hook and moves existing vault shares in. Expected amounts were computed outside Solidity with exact rational
/// arithmetic (Python fractions) from the formulas in the design, then floored or ceiled in the maker's favour.
abstract contract MidasHookForkBase is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant BLOCK = 26_190_200;
    uint256 constant BLOCK_TIME = 1_791_974_387;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address constant PROTOCOL_FEE_CONTROLLER = 0x89A5D5bF00a27D55c02951E49078a5C5771051dB;
    address constant VAULT_CURATOR = 0x75178137D3B4B9A0F771E0e149b00fB8167BA325;
    address constant SHARE_HOLDER = 0x933aDeDd85824dA75ec8a334a7907e69e7c02833;
    address constant USDC = Mainnet.USDC;
    address constant VAULT = Mainnet.VAULT;
    address constant MARKET_ADAPTER = Mainnet.MARKET_ADAPTER;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant MHYPER = 0x9b5528528656DBC094765E2abB79F293c21191B9;
    address constant MALPHA = 0x25BAC88afe5572F5A7F1670c22FD404BA47a30ad;
    address constant MARB = Mainnet.MARB;
    address constant MHYPER_FEED = 0x43881B05C3BE68B2d33eb70aDdF9F666C5005f68;
    address constant MALPHA_FEED = 0xB7cc7498dc7ac2da5f59fEFfeE2dbF5Ac1061616;
    address constant MARB_FEED = Mainnet.FEED;
    /// @dev Senders of every recent setRoundDataSafe on each feed (Etherscan txlist of the feed).
    address constant MHYPER_UPDATER = 0xd1E01471F3e1002d4eEC1b39b7DBD7aff952A99F;
    address constant MALPHA_UPDATER = 0x18A6daeF275bb72E4Fd9505D74D36A102F1a324E;
    address constant MARB_UPDATER = Mainnet.FEED_UPDATER;
    int256 constant MHYPER_NAV = 113_327_745;
    int256 constant MALPHA_NAV = 101_243_740;
    int256 constant MARB_NAV = 100_000_000;

    uint256 constant MAX_BID_BPS = 9_990;
    uint256 constant MIN_ASK_PREMIUM_BPS = 10;
    uint256 constant MAX_ACCRUAL = 35 days;
    uint16 constant BID_DISCOUNT = 50;
    uint16 constant ASK_PREMIUM = 30;
    uint16 constant ASK_APY = 500;
    uint128 constant REMAINING = 1_000_000e18;
    uint256 constant MAKER_INVENTORY = 1_000_000e18;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    /// @dev beforeInitialize | beforeSwap | beforeSwapReturnDelta.
    uint160 constant HOOK_FLAGS = 0x2088;
    /// @dev 1,234.567890123456789012 tokens: odd digits so every rounding shows.
    uint256 constant X = 1_234_567_890_123_456_789_012;

    bytes32 constant FORCE_DEALLOCATE_TOPIC =
        keccak256("ForceDeallocate(address,address,uint256,address,bytes32[],uint256)");

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    IVaultV2Like vault = IVaultV2Like(VAULT);
    MidasQuoteHook hook;
    uint256 makerPk = 0xA11CE;
    address maker;
    address trader = makeAddr("trader");
    uint40 validUntil;

    function setUp() public virtual {
        vm.createSelectFork("mainnet", BLOCK);
        assertEq(block.timestamp, BLOCK_TIME, "precondition: block time");
        maker = vm.addr(makerPk);
        validUntil = uint40(block.timestamp + 60 days);

        address hookAddr = address(uint160((uint256(keccak256("MidasQuoteHook")) & ~uint256(0x3FFF)) | HOOK_FLAGS));
        assertEq(hookAddr.code.length, 0, "hook address is empty on mainnet");
        deployCodeTo(
            "MidasQuoteHook.sol:MidasQuoteHook",
            abi.encode(
                POOL_MANAGER,
                VAULT,
                MARKET_ADAPTER,
                maker,
                _tokenList(),
                _feedList(),
                MAX_BID_BPS,
                MIN_ASK_PREMIUM_BPS,
                MAX_ACCRUAL
            ),
            hookAddr
        );
        hook = MidasQuoteHook(hookAddr);

        address[] memory toks = _tokenList();
        for (uint256 i; i < toks.length; ++i) {
            address token = toks[i];
            vm.prank(makeAddr("initializer"));
            pm.initialize(_key(token), SQRT_PRICE_1_1);
            MidasQuoteHook.Params memory p = _params(_round(token));
            vm.prank(maker);
            hook.setParams(token, p);
            deal(token, maker, MAKER_INVENTORY);
            vm.prank(maker);
            IERC20Like(token).approve(hookAddr, type(uint256).max);
            deal(token, trader, 2_000_000e18);
            _approveViaPermit2(trader, token);
        }
        deal(USDC, trader, 10_000_000e6);
        _approveViaPermit2(trader, USDC);

        uint256 shares = vault.previewWithdraw(1_000_000e6);
        vm.prank(SHARE_HOLDER);
        vault.transfer(maker, shares);
        vm.prank(maker);
        vault.approve(hookAddr, type(uint256).max);

        assertEq(IERC20Like(USDC).balanceOf(VAULT), 0, "precondition: vault idle");
        assertEq(uint256(IMidasFeed(MHYPER_FEED).latestRound()), 126, "precondition: mHYPER round");
        assertEq(uint256(IMidasFeed(MALPHA_FEED).latestRound()), 6, "precondition: mALPHA round");
        assertEq(uint256(IMidasFeed(MARB_FEED).latestRound()), 2, "precondition: mArb round");
    }

    // ------------------------------------------------------------------ fixture data

    function _tokenList() internal pure returns (address[] memory t) {
        t = new address[](3);
        t[0] = MHYPER;
        t[1] = MALPHA;
        t[2] = MARB;
    }

    function _feedList() internal pure returns (address[] memory f) {
        f = new address[](3);
        f[0] = MHYPER_FEED;
        f[1] = MALPHA_FEED;
        f[2] = MARB_FEED;
    }

    function _round(address token) internal view returns (uint80) {
        return IMidasFeed(_feed(token)).latestRound();
    }

    function _feed(address token) internal pure returns (address) {
        if (token == MHYPER) return MHYPER_FEED;
        if (token == MALPHA) return MALPHA_FEED;
        return MARB_FEED;
    }

    function _params(uint80 round) internal view returns (MidasQuoteHook.Params memory) {
        return MidasQuoteHook.Params({
            round: round,
            validUntil: validUntil,
            bidDiscountBps: BID_DISCOUNT,
            askPremiumBps: ASK_PREMIUM,
            askApyBps: ASK_APY,
            bidRemaining: REMAINING,
            askRemaining: REMAINING
        });
    }

    function _key(address token) internal view returns (PoolKey memory) {
        (address c0, address c1) = token < USDC ? (token, USDC) : (USDC, token);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------ router

    function _approveViaPermit2(address owner, address asset) internal {
        vm.startPrank(owner);
        IERC20Like(asset).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(asset, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev Swapper buys the token (ask) or sells it (bid). zeroForOne follows from the token's side of the pool.
    function _zeroForOne(address token, bool buy) internal pure returns (bool) {
        return (token < USDC) != buy;
    }

    /// @dev V4_SWAP (0x10) with SWAP_EXACT_IN_SINGLE (0x06) or SWAP_EXACT_OUT_SINGLE (0x08), then SETTLE_ALL (0x0c) and
    /// TAKE_ALL (0x0f): the plan Uniswap's routing builds, in which the swapper pays only after the swap. `limit` is the
    /// minimum out for exact-in and the maximum in for exact-out.
    function _swap(address token, bool buy, bool exactIn, uint256 amount, uint256 limit)
        internal
        returns (uint256 gasUsed)
    {
        PoolKey memory key = _key(token);
        bool zeroForOne = _zeroForOne(token, buy);
        (address cin, address cout) = buy ? (USDC, token) : (token, USDC);
        bytes[] memory params = new bytes[](3);
        bytes memory actions;
        if (exactIn) {
            params[0] = abi.encode(
                ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: uint128(amount),
                    amountOutMinimum: uint128(limit),
                    hookData: ""
                })
            );
            params[1] = abi.encode(Currency.wrap(cin), amount);
            params[2] = abi.encode(Currency.wrap(cout), limit);
            actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        } else {
            params[0] = abi.encode(
                ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountOut: uint128(amount),
                    amountInMaximum: uint128(limit),
                    hookData: ""
                })
            );
            params[1] = abi.encode(Currency.wrap(cin), limit);
            params[2] = abi.encode(Currency.wrap(cout), amount);
            actions = abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f));
        }
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(trader);
        uint256 g = gasleft();
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        gasUsed = g - gasleft();
    }

    /// @dev Swaps and returns what the trader actually paid and received, from its balances.
    function _trade(address token, bool buy, bool exactIn, uint256 amount, uint256 limit)
        internal
        returns (uint256 paid, uint256 received)
    {
        (address cin, address cout) = buy ? (USDC, token) : (token, USDC);
        uint256 inBefore = IERC20Like(cin).balanceOf(trader);
        uint256 outBefore = IERC20Like(cout).balanceOf(trader);
        _swap(token, buy, exactIn, amount, limit);
        paid = inBefore - IERC20Like(cin).balanceOf(trader);
        received = IERC20Like(cout).balanceOf(trader) - outBefore;
    }

    /// @dev The PoolManager wraps a hook revert in ERC-7751 WrappedError and the router's V4_SWAP bubbles it as is.
    function _expectSwapRevert(bytes memory hookError) internal {
        vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, hookError));
    }

    function _wrapped(bytes4 hookSelector, bytes memory hookError) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            hookError,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    // ------------------------------------------------------------------ state readers

    function _claim(address currency) internal view returns (uint256) {
        return pm.balanceOf(address(hook), uint256(uint160(currency)));
    }

    function _remaining(address token) internal view returns (uint128 bid, uint128 ask) {
        (,,,,, bid, ask) = hook.params(token);
    }

    function _sumForceDeallocations(Vm.Log[] memory logs) internal view returns (uint256 n, uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != VAULT || logs[i].topics[0] != FORCE_DEALLOCATE_TOPIC) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(hook), "ForceDeallocate sender");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), maker, "ForceDeallocate onBehalf");
            (, uint256 assets,, uint256 penaltyAssets) =
                abi.decode(logs[i].data, (address, uint256, bytes32[], uint256));
            assertEq(penaltyAssets, 0);
            total += assets;
            ++n;
        }
    }

    function _filledDeallocated(Vm.Log[] memory logs) internal view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == MidasQuoteHook.Filled.selector) {
                (,,,, uint256 deallocated) =
                    abi.decode(logs[i].data, (MidasQuoteHook.Side, address, uint256, uint256, uint256));
                return deallocated;
            }
        }
        revert("no Filled event");
    }

    function _assertHookHoldsNoErc20() internal view {
        assertEq(IERC20Like(USDC).balanceOf(address(hook)), 0, "hook USDC");
        assertEq(IERC20Like(MHYPER).balanceOf(address(hook)), 0, "hook mHYPER");
        assertEq(IERC20Like(MALPHA).balanceOf(address(hook)), 0, "hook mALPHA");
        assertEq(IERC20Like(MARB).balanceOf(address(hook)), 0, "hook mArb");
        assertEq(vault.balanceOf(address(hook)), 0, "hook shares");
    }

    // ------------------------------------------------------------------ the four fills

    function _bidExactIn(address token, uint256 amountIn, uint256 expectedOut) internal {
        (uint128 bidBefore,) = _remaining(token);
        uint256 claimBefore = _claim(token);
        (uint256 paid, uint256 received) = _trade(token, false, true, amountIn, expectedOut);
        assertEq(paid, amountIn, "token paid");
        assertEq(received, expectedOut, "USDC received");
        _assertBidState(token, amountIn, bidBefore, claimBefore);
    }

    function _bidExactOut(address token, uint256 amountOut, uint256 expectedIn) internal {
        (uint128 bidBefore,) = _remaining(token);
        uint256 claimBefore = _claim(token);
        (uint256 paid, uint256 received) = _trade(token, false, false, amountOut, expectedIn);
        assertEq(paid, expectedIn, "token paid");
        assertEq(received, amountOut, "USDC received");
        _assertBidState(token, expectedIn, bidBefore, claimBefore);
    }

    function _assertBidState(address token, uint256 tokenIn, uint128 bidBefore, uint256 claimBefore) internal view {
        (uint128 bidAfter,) = _remaining(token);
        assertEq(bidAfter, bidBefore - tokenIn, "bidRemaining -= token in");
        assertEq(_claim(token), claimBefore + tokenIn, "token claim += token in");
        assertEq(_claim(USDC), 0, "no USDC claim on a bid");
        _assertHookHoldsNoErc20();
    }

    /// @dev Starts with no token claims, so the whole output comes from the maker's allowance.
    function _askExactIn(address token, uint256 amountIn, uint256 expectedOut) internal {
        assertEq(_claim(token), 0, "precondition: no token claims");
        (, uint128 askBefore) = _remaining(token);
        uint256 makerBefore = IERC20Like(token).balanceOf(maker);
        (uint256 paid, uint256 received) = _trade(token, true, true, amountIn, expectedOut);
        assertEq(paid, amountIn, "USDC paid");
        assertEq(received, expectedOut, "token received");
        _assertAskState(token, amountIn, expectedOut, askBefore, makerBefore);
    }

    function _askExactOut(address token, uint256 amountOut, uint256 expectedIn) internal {
        assertEq(_claim(token), 0, "precondition: no token claims");
        (, uint128 askBefore) = _remaining(token);
        uint256 makerBefore = IERC20Like(token).balanceOf(maker);
        (uint256 paid, uint256 received) = _trade(token, true, false, amountOut, expectedIn);
        assertEq(paid, expectedIn, "USDC paid");
        assertEq(received, amountOut, "token received");
        _assertAskState(token, expectedIn, amountOut, askBefore, makerBefore);
    }

    function _assertAskState(address token, uint256 usdcIn, uint256 tokenOut, uint128 askBefore, uint256 makerBefore)
        internal
        view
    {
        (, uint128 askAfter) = _remaining(token);
        assertEq(askAfter, askBefore - tokenOut, "askRemaining -= token out");
        assertEq(makerBefore - IERC20Like(token).balanceOf(maker), tokenOut, "maker delivered the token out");
        assertEq(_claim(USDC), usdcIn, "USDC claim = USDC in");
        assertEq(_claim(token), 0, "no token claim");
        _assertHookHoldsNoErc20();
    }
}

contract MidasQuoteHookForkTest is MidasHookForkBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ config

    function test_config() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "exactly three flags");
        assertEq(hook.ASSET(), USDC);
        assertEq(hook.MAKER(), maker);
        assertEq(hook.MAX_BID_BPS(), MAX_BID_BPS);
        assertEq(hook.MIN_ASK_PREMIUM_BPS(), MIN_ASK_PREMIUM_BPS);
        assertEq(hook.MAX_ACCRUAL(), MAX_ACCRUAL);
        address[] memory toks = hook.tokens();
        assertEq(toks.length, 3);
        for (uint256 i; i < 3; ++i) {
            address token = toks[i];
            assertEq(token, _tokenList()[i]);
            assertEq(IERC20Meta(token).decimals(), 18, "token decimals");
            assertEq(IERC20Meta(_feed(token)).decimals(), 8, "feed decimals");
            PoolId id = _key(token).toId();
            assertEq(PoolId.unwrap(hook.poolIdOf(token)), PoolId.unwrap(id), "canonical pool id");
            (address mToken, bool tokenIsCurrency0, uint8 scaleExp, address feed) = hook.markets(id);
            assertEq(mToken, token);
            assertEq(tokenIsCurrency0, token < USDC);
            assertEq(scaleExp, 20, "18 + 8 - 6");
            assertEq(feed, _feed(token));
        }
        assertTrue(MHYPER < USDC && MALPHA < USDC && MARB > USDC, "currency order");
    }

    function test_constructor_wrongHookAddress_reverts() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MidasQuoteHook(
            POOL_MANAGER,
            VAULT,
            MARKET_ADAPTER,
            maker,
            _tokenList(),
            _feedList(),
            MAX_BID_BPS,
            MIN_ASK_PREMIUM_BPS,
            MAX_ACCRUAL
        );
    }

    function test_constructor_badTokenLists_revert() public {
        address[] memory t = _tokenList();
        address[] memory f = _feedList();

        t[1] = USDC; // the vault asset
        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, t, f, MAX_BID_BPS, 10, MAX_ACCRUAL);

        t[1] = MHYPER; // duplicate
        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, t, f, MAX_BID_BPS, 10, MAX_ACCRUAL);

        address[] memory four = new address[](4);
        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, four, four, MAX_BID_BPS, 10, MAX_ACCRUAL);

        address[] memory two = new address[](2);
        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, _tokenList(), two, MAX_BID_BPS, 10, MAX_ACCRUAL);

        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, _tokenList(), _feedList(), 10_001, 10, 1);
    }

    /// @dev MIN_ASK_PREMIUM_BPS above 10,000 would exceed any uint16-representable premium the maker could need and
    /// is refused; 10,000 passes the config checks and reaches the hook-address check.
    function test_constructor_minAskPremiumAboveBps_reverts() public {
        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(
            POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, _tokenList(), _feedList(), MAX_BID_BPS, 10_001, MAX_ACCRUAL
        );
        vm.expectRevert(MidasQuoteHook.BadConfig.selector);
        new MidasQuoteHook(
            POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, _tokenList(), _feedList(), MAX_BID_BPS, 65_536, MAX_ACCRUAL
        );
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MidasQuoteHook(
            POOL_MANAGER, VAULT, MARKET_ADAPTER, maker, _tokenList(), _feedList(), MAX_BID_BPS, 10_000, MAX_ACCRUAL
        );
    }

    // ------------------------------------------------------------------ fills: mHYPER (currency0)

    function test_mHYPER_bidExactIn() public {
        _bidExactIn(MHYPER, X, 1_392_112_410); // floor(X x 1.13327745 x 0.995 / 1e12)
    }

    function test_mHYPER_bidExactOut() public {
        _bidExactOut(MHYPER, 1_000e6, 886_830_604_128_001_226_459); // ceil(1e9 x 1e12 / (1.13327745 x 0.995))
    }

    function test_mHYPER_askExactIn() public {
        _askExactIn(MHYPER, 1_000e6, 879_652_009_606_167_333_034); // t = 75,408 s
    }

    function test_mHYPER_askExactOut() public {
        _askExactOut(MHYPER, X, 1_403_473_052);
    }

    // ------------------------------------------------------------------ fills: mALPHA (currency0)

    function test_mALPHA_bidExactIn() public {
        _bidExactIn(MALPHA, X, 1_243_673_091);
    }

    function test_mALPHA_bidExactOut() public {
        _bidExactOut(MALPHA, 1_000e6, 992_678_782_538_200_093_673);
    }

    function test_mALPHA_askExactIn() public {
        _askExactIn(MALPHA, 1_000e6, 984_101_461_500_787_843_462); // t = 422,772 s
    }

    function test_mALPHA_askExactOut() public {
        _askExactOut(MALPHA, X, 1_254_512_811);
    }

    // ------------------------------------------------------------------ fills: mArb (currency1)

    function test_mArb_bidExactIn() public {
        _bidExactIn(MARB, X, 1_228_395_050);
    }

    function test_mArb_bidExactOut() public {
        _bidExactOut(MARB, 1_000e6, 1_005_025_125_628_140_703_518);
    }

    function test_mArb_askExactIn() public {
        _askExactIn(MARB, 1_000e6, 993_481_188_670_372_030_005); // t = 2,239,644 s
    }

    function test_mArb_askExactOut() public {
        _askExactOut(MARB, X, 1_242_668_613);
    }

    // ------------------------------------------------------------------ events

    function test_events_bidOnCurrency0_askOnCurrency1() public {
        PoolId mhyperPool = _key(MHYPER).toId();
        vm.expectEmit(true, false, false, true, address(hook));
        emit MidasQuoteHook.Filled(
            MHYPER,
            MidasQuoteHook.Side.Bid,
            UNIVERSAL_ROUTER,
            X,
            1_392_112_410,
            1_392_112_410 // idle 0: all deallocated
        );
        vm.expectEmit(true, true, false, true, address(hook));
        emit MidasQuoteHook.HookSwap(
            PoolId.unwrap(mhyperPool), UNIVERSAL_ROUTER, int128(int256(X)), -int128(1_392_112_410), 0, 0
        );
        _swap(MHYPER, false, true, X, 0);

        // mArb is currency1: buying it is zeroForOne with USDC as currency0 in.
        PoolId marbPool = _key(MARB).toId();
        vm.expectEmit(true, false, false, true, address(hook));
        emit MidasQuoteHook.Filled(
            MARB, MidasQuoteHook.Side.Ask, UNIVERSAL_ROUTER, 1_000e6, 993_481_188_670_372_030_005, 0
        );
        vm.expectEmit(true, true, false, true, address(hook));
        emit MidasQuoteHook.HookSwap(
            PoolId.unwrap(marbPool), UNIVERSAL_ROUTER, int128(1_000e6), -int128(993_481_188_670_372_030_005), 0, 0
        );
        _swap(MARB, true, true, 1_000e6, 0);
    }

    // ------------------------------------------------------------------ ask accrual

    /// @dev mArb's last update is 2,239,644 s old. Exact-out 1,000 mArb costs ceil(1000 x NAV x (1 + 0.05 t / YEAR) x
    /// 1.003) USDC: +137,397 base units per day until t reaches MAX_ACCRUAL (35 days), then flat.
    function test_askAccrual_linearThenCapped() public {
        uint256[5] memory expected = [
            uint256(1_006_561_586), // t = 2,239,644
            1_006_698_983, // + 1 day
            1_006_836_380, // + 2 days
            1_007_808_905, // + 10 days: t = 3,103,644 capped at 3,024,000
            1_007_808_905 // + 20 days: capped
        ];
        uint256[5] memory dayOffsets = [uint256(0), 1, 2, 10, 20];
        uint256[5] memory paid;
        for (uint256 i; i < 5; ++i) {
            vm.warp(BLOCK_TIME + dayOffsets[i] * 1 days);
            assertEq(_round(MARB), 2, "same round throughout");
            (paid[i],) = _trade(MARB, true, false, 1_000e18, type(uint128).max);
            assertEq(paid[i], expected[i], "ask exact-out 1,000 mArb");
        }
        assertEq(paid[1] - paid[0], 137_397, "day 1 accrual");
        assertEq(paid[2] - paid[1], 137_397, "day 2 accrual, linear");
        assertEq(paid[4], paid[3], "capped at MAX_ACCRUAL");
    }

    /// @dev Bounds: bid discount at least 10,000 - MAX_BID_BPS = 10 bps, ask premium at least MIN_ASK_PREMIUM_BPS. At
    /// the bounds the fills sit exactly on the ceiling and the floor (APY 0).
    function test_setParams_bounds_andFillsAtBounds() public {
        MidasQuoteHook.Params memory p = _params(126);
        vm.startPrank(maker);
        p.bidDiscountBps = 9;
        vm.expectRevert(MidasQuoteHook.PriceAboveCeiling.selector);
        hook.setParams(MHYPER, p);
        p.bidDiscountBps = 10_000;
        vm.expectRevert(MidasQuoteHook.ZeroPrice.selector);
        hook.setParams(MHYPER, p);
        p.bidDiscountBps = 10;
        p.askPremiumBps = 9;
        vm.expectRevert(MidasQuoteHook.PriceBelowFloor.selector);
        hook.setParams(MHYPER, p);
        // A closed side is not checked.
        p.askRemaining = 0;
        hook.setParams(MHYPER, p);
        p.bidRemaining = 0;
        p.bidDiscountBps = 0;
        p.askRemaining = REMAINING;
        p.askPremiumBps = 10;
        hook.setParams(MHYPER, p);
        // Exactly at the bounds.
        p.bidRemaining = REMAINING;
        p.bidDiscountBps = 10;
        p.askApyBps = 0;
        hook.setParams(MHYPER, p);
        vm.stopPrank();

        (, uint256 usdcOut) = _trade(MHYPER, false, true, 1_000e18, 0);
        assertEq(usdcOut, 1_132_144_172, "floor(1000 x 1.13327745 x 0.999)");
        (uint256 usdcIn,) = _trade(MHYPER, true, false, 1_000e18, type(uint128).max);
        assertEq(usdcIn, 1_134_410_728, "ceil(1000 x 1.13327745 x 1.001)");
    }

    // ------------------------------------------------------------------ ask inventory

    function test_ask_fromClaimsFirst_thenMakerAllowance() public {
        _swap(MHYPER, false, true, 10_000e18, 0); // the hook buys 10,000 mHYPER as a claim
        assertEq(_claim(MHYPER), 10_000e18);
        uint256 makerBefore = IERC20Like(MHYPER).balanceOf(maker);
        uint256 pmBefore = IERC20Like(MHYPER).balanceOf(POOL_MANAGER);

        (uint256 paid, uint256 got) = _trade(MHYPER, true, false, 4_000e18, type(uint128).max);
        assertEq(paid, 4_547_252_728);
        assertEq(got, 4_000e18);
        assertEq(IERC20Like(MHYPER).balanceOf(maker), makerBefore, "claims only: maker untouched");
        assertEq(_claim(MHYPER), 6_000e18, "claims burned");
        assertEq(IERC20Like(MHYPER).balanceOf(POOL_MANAGER), pmBefore - 4_000e18, "paid from the PoolManager");

        (paid, got) = _trade(MHYPER, true, false, 8_000e18, type(uint128).max);
        assertEq(paid, 9_094_505_456);
        assertEq(got, 8_000e18);
        assertEq(_claim(MHYPER), 0, "all claims used first");
        assertEq(makerBefore - IERC20Like(MHYPER).balanceOf(maker), 2_000e18, "rest from the maker");
        (, uint128 ask) = _remaining(MHYPER);
        assertEq(ask, REMAINING - 12_000e18);
        assertEq(_claim(USDC), 4_547_252_728 + 9_094_505_456, "USDC claims");
        _assertHookHoldsNoErc20();
    }

    function test_ask_makerAllowanceExhausted_reverts() public {
        vm.prank(maker);
        IERC20Like(MARB).approve(address(hook), 100e18);
        (uint256 paid, uint256 got) = _trade(MARB, true, false, 100e18, type(uint128).max);
        assertEq(got, 100e18);
        assertEq(paid, 100_656_159);
        assertEq(IERC20Meta(MARB).allowance(maker, address(hook)), 0, "allowance spent");

        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.MakerTransferFailed.selector));
        _swap(MARB, true, false, 1e18, type(uint128).max);

        // A claim from a bid restores capacity for exactly its size.
        _swap(MARB, false, true, 5e18, 0);
        _swap(MARB, true, false, 5e18, type(uint128).max);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.MakerTransferFailed.selector));
        _swap(MARB, true, false, 1, type(uint128).max);
    }

    // ------------------------------------------------------------------ bid funding and sweep

    function test_bid_vaultIdleZero_forceDeallocates() public {
        uint256 amountIn = 100_000e18;
        uint256 expectedOut = 112_761_106_275; // floor(100,000 x 1.13327745 x 0.995 x 1e6)
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 expectedShares = vault.previewWithdraw(expectedOut);

        vm.recordLogs();
        uint256 gasUsed = _swap(MHYPER, false, true, amountIn, expectedOut);
        console2.log("gas: router execute, bid 100,000 mHYPER force-deallocating", gasUsed);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 n, uint256 total) = _sumForceDeallocations(logs);
        assertGt(n, 1, "several markets");
        assertEq(total, expectedOut, "deallocated = amountOut - idle");
        assertEq(IERC20Like(USDC).balanceOf(trader), 10_000_000e6 + expectedOut);
        assertEq(sharesBefore - vault.balanceOf(maker), expectedShares, "shares burned = previewWithdraw");
        assertEq(IERC20Like(USDC).balanceOf(VAULT), 0, "deallocated exactly the need");
        _assertHookHoldsNoErc20();
    }

    function test_sweepAll_tokensToMaker_usdcDepositedForMaker() public {
        _swap(MHYPER, false, true, X, 0);
        _swap(MARB, false, true, X, 0);
        _swap(MALPHA, true, true, 1_000e6, 0); // ask from the maker allowance: a 1,000 USDC claim
        assertEq(_claim(USDC), 1_000e6);

        uint256 mhyperBefore = IERC20Like(MHYPER).balanceOf(maker);
        uint256 marbBefore = IERC20Like(MARB).balanceOf(maker);
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 expectedShares = IVaultPreviewDeposit(VAULT).previewDeposit(1_000e6);
        uint256 idleBefore = IERC20Like(USDC).balanceOf(VAULT);
        uint256 pmUsdcBefore = IERC20Like(USDC).balanceOf(POOL_MANAGER);

        vm.prank(makeAddr("anyone"));
        uint256[] memory amounts = hook.sweepAll();

        assertEq(amounts.length, 4);
        assertEq(amounts[0], X, "mHYPER swept");
        assertEq(amounts[1], 0, "no mALPHA claim");
        assertEq(amounts[2], X, "mArb swept");
        assertEq(amounts[3], 1_000e6, "USDC swept");
        assertEq(IERC20Like(MHYPER).balanceOf(maker) - mhyperBefore, X, "maker mHYPER");
        assertEq(IERC20Like(MARB).balanceOf(maker) - marbBefore, X, "maker mArb");
        assertGt(expectedShares, 0);
        assertEq(vault.balanceOf(maker) - sharesBefore, expectedShares, "maker shares += previewDeposit");
        assertEq(IERC20Like(USDC).balanceOf(VAULT) - idleBefore, 1_000e6, "USDC back in the vault, idle");
        assertEq(pmUsdcBefore - IERC20Like(USDC).balanceOf(POOL_MANAGER), 1_000e6, "USDC left the PoolManager");
        assertEq(_claim(MHYPER) + _claim(MARB) + _claim(USDC), 0, "claims cleared");
        assertEq(IERC20Meta(USDC).allowance(address(hook), VAULT), 0, "exact approval consumed");
        _assertHookHoldsNoErc20();

        vm.recordLogs();
        amounts = hook.sweepAll();
        assertEq(amounts[0] + amounts[1] + amounts[2] + amounts[3], 0);
        assertEq(vm.getRecordedLogs().length, 0, "nothing to sweep: no unlock, no event");
    }

    function test_sweep_single() public {
        _swap(MALPHA, false, true, X, 0);
        _swap(MALPHA, true, true, 500e6, 0); // paid from the X claim
        uint256 claimLeft = _claim(MALPHA);
        uint256 makerBefore = IERC20Like(MALPHA).balanceOf(maker);
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 expectedShares = IVaultPreviewDeposit(VAULT).previewDeposit(500e6);

        assertEq(hook.sweep(MALPHA), claimLeft);
        assertEq(IERC20Like(MALPHA).balanceOf(maker) - makerBefore, claimLeft);
        assertEq(hook.sweep(USDC), 500e6);
        assertEq(vault.balanceOf(maker) - sharesBefore, expectedShares);
        assertEq(hook.sweep(MARB), 0, "zero claim");
        _assertHookHoldsNoErc20();

        vm.expectRevert(MidasQuoteHook.UnknownToken.selector);
        hook.sweep(WETH);
    }

    /// @dev An ask leaves a USDC claim; a later bid (any token: the claim is per currency) pays from it first and
    /// touches the vault not at all when it covers the whole output.
    function test_bid_paidFromUsdcClaims_whenTheyCover() public {
        _swap(MHYPER, true, true, 2_000e6, 0);
        assertEq(_claim(USDC), 2_000e6);
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 pmUsdcBefore = IERC20Like(USDC).balanceOf(POOL_MANAGER);

        vm.expectCall(VAULT, abi.encodeWithSignature("withdraw(uint256,address,address)"), 0);
        vm.recordLogs();
        (uint256 paid, uint256 got) = _trade(MALPHA, false, false, 1_000e6, type(uint128).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(got, 1_000e6);
        assertEq(paid, 992_678_782_538_200_093_673, "same bid price");
        (uint256 n,) = _sumForceDeallocations(logs);
        assertEq(n, 0, "no deallocation");
        assertEq(_filledDeallocated(logs), 0, "Filled.deallocated");
        assertEq(_claim(USDC), 1_000e6, "claims burned by the output");
        assertEq(vault.balanceOf(maker), sharesBefore, "maker shares untouched");
        assertEq(IERC20Like(USDC).balanceOf(VAULT), 0, "vault idle untouched");
        assertEq(pmUsdcBefore - IERC20Like(USDC).balanceOf(POOL_MANAGER), 1_000e6, "paid out of the PoolManager");
        assertEq(_claim(MALPHA), paid, "token claim");
        _assertHookHoldsNoErc20();
    }

    /// @dev Claims cover part of the bid: they are burned in full and only the rest is withdrawn and deallocated.
    function test_bid_paidFromUsdcClaims_thenVault() public {
        _swap(MARB, true, true, 1_000e6, 0);
        assertEq(_claim(USDC), 1_000e6);
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 expectedShares = vault.previewWithdraw(500e6);

        vm.recordLogs();
        (uint256 paid, uint256 got) = _trade(MARB, false, false, 1_500e6, type(uint128).max);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(got, 1_500e6);
        assertEq(paid, 1_507_537_688_442_211_055_277, "ceil(1.5e9 x 1e12 / 0.995)");
        (, uint256 total) = _sumForceDeallocations(logs);
        assertEq(total, 500e6, "deallocated only the vault part");
        assertEq(_filledDeallocated(logs), 500e6, "Filled.deallocated");
        assertEq(_claim(USDC), 0, "claims used first");
        assertEq(sharesBefore - vault.balanceOf(maker), expectedShares, "shares burned = previewWithdraw(500 USDC)");
        assertEq(IERC20Like(USDC).balanceOf(VAULT), 0, "vault idle");
        _assertHookHoldsNoErc20();
    }

    /// @dev VAULT refusing the hook's deposit (a curator gate, a pause) must not strand USDC: the sweep still
    /// succeeds, the approval is reset and MAKER receives the USDC directly. Token sweeps are unaffected.
    function test_sweep_depositReverts_usdcGoesToMakerDirectly() public {
        _swap(MHYPER, false, true, X, 0);
        _swap(MALPHA, true, true, 1_000e6, 0);
        _swap(MARB, true, true, 400e6, 0);
        vm.mockCallRevert(
            VAULT, abi.encodeWithSignature("deposit(uint256,address)"), abi.encodeWithSignature("DepositPaused()")
        );
        uint256 makerUsdcBefore = IERC20Like(USDC).balanceOf(maker);
        uint256 makerMhyperBefore = IERC20Like(MHYPER).balanceOf(maker);
        uint256 sharesBefore = vault.balanceOf(maker);

        vm.expectEmit(true, false, false, true, address(hook));
        emit MidasQuoteHook.Swept(USDC, 1_400e6, false);
        assertEq(hook.sweep(USDC), 1_400e6);
        assertEq(IERC20Like(USDC).balanceOf(maker) - makerUsdcBefore, 1_400e6, "MAKER got the USDC directly");
        assertEq(IERC20Meta(USDC).allowance(address(hook), VAULT), 0, "approval reset");
        assertEq(_claim(USDC), 0, "USDC claim cleared");
        assertEq(vault.balanceOf(maker), sharesBefore, "no shares minted");

        // sweepAll with the deposit still refused: token claims as usual, nothing left in USDC.
        _swap(MARB, true, true, 100e6, 0);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MidasQuoteHook.Swept(MHYPER, X, false);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MidasQuoteHook.Swept(USDC, 100e6, false);
        uint256[] memory amounts = hook.sweepAll();
        assertEq(amounts[0], X);
        assertEq(amounts[3], 100e6);
        assertEq(IERC20Like(MHYPER).balanceOf(maker) - makerMhyperBefore, X, "maker mHYPER");
        assertEq(IERC20Like(USDC).balanceOf(maker) - makerUsdcBefore, 1_500e6, "maker USDC");
        assertEq(IERC20Meta(USDC).allowance(address(hook), VAULT), 0, "approval reset");
        assertEq(_claim(MHYPER) + _claim(USDC), 0, "claims cleared");
        _assertHookHoldsNoErc20();
    }

    /// @dev The normal path emits deposited = true and leaves no approval behind.
    function test_sweep_usdc_depositPath_event() public {
        _swap(MARB, true, true, 1_000e6, 0);
        uint256 expectedShares = IVaultPreviewDeposit(VAULT).previewDeposit(1_000e6);
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 makerUsdcBefore = IERC20Like(USDC).balanceOf(maker);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MidasQuoteHook.Swept(USDC, 1_000e6, true);
        hook.sweep(USDC);
        assertEq(vault.balanceOf(maker) - sharesBefore, expectedShares);
        assertEq(IERC20Like(USDC).balanceOf(maker), makerUsdcBefore, "not sent directly");
        assertEq(IERC20Meta(USDC).allowance(address(hook), VAULT), 0);
    }

    /// @dev USDC sent to the hook as an ERC-20 (not a claim) is swept with the claim, or alone when there is no claim.
    function test_sweep_strayUsdc() public {
        deal(USDC, address(hook), 250e6);
        uint256 sharesBefore = vault.balanceOf(maker);
        uint256 expectedShares = IVaultPreviewDeposit(VAULT).previewDeposit(250e6);
        assertEq(hook.sweep(USDC), 250e6, "stray alone");
        assertEq(vault.balanceOf(maker) - sharesBefore, expectedShares, "deposited for MAKER");
        _assertHookHoldsNoErc20();

        _swap(MARB, true, true, 1_000e6, 0);
        deal(USDC, address(hook), 7e6);
        sharesBefore = vault.balanceOf(maker);
        expectedShares = IVaultPreviewDeposit(VAULT).previewDeposit(1_007e6);
        uint256[] memory amounts = hook.sweepAll();
        assertEq(amounts[3], 1_007e6, "claim + stray");
        assertEq(vault.balanceOf(maker) - sharesBefore, expectedShares);
        assertEq(_claim(USDC), 0);
        _assertHookHoldsNoErc20();
    }

    function test_unlockCallback_notPoolManager_reverts() public {
        vm.expectRevert(MidasQuoteHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(new address[](0), new uint256[](0)));
    }

    // ------------------------------------------------------------------ round binding and kill switch

    function test_roundAdvanced_bothSidesRevert_untilReopened() public {
        vm.prank(MALPHA_UPDATER);
        IMidasFeed(MALPHA_FEED).setRoundDataSafe(MALPHA_NAV);
        assertEq(_round(MALPHA), 7);

        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.StaleRound.selector));
        _swap(MALPHA, false, true, X, 0);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.StaleRound.selector));
        _swap(MALPHA, true, true, 1_000e6, 0);

        vm.prank(maker);
        hook.setParams(MALPHA, _params(7));
        (, uint256 out) = _trade(MALPHA, false, true, X, 0);
        assertEq(out, 1_243_673_091, "same NAV, same bid");
        (, out) = _trade(MALPHA, true, true, 1_000e6, 0);
        assertEq(out, 984_761_105_309_580_352_147, "fresh update: t = 0, premium only");
    }

    /// @dev mHYPER and mArb updaters, round binding on their feeds too (other sides covered above).
    function test_roundAdvanced_otherFeeds() public {
        vm.prank(MHYPER_UPDATER);
        IMidasFeed(MHYPER_FEED).setRoundDataSafe(MHYPER_NAV);
        vm.prank(MARB_UPDATER);
        IMidasFeed(MARB_FEED).setRoundDataSafe(MARB_NAV);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.StaleRound.selector));
        _swap(MHYPER, true, true, 1_000e6, 0);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.StaleRound.selector));
        _swap(MARB, false, true, X, 0);
    }

    function test_validUntil_boundary() public {
        vm.warp(validUntil);
        _swap(MHYPER, false, true, 1e18, 0);
        _swap(MHYPER, true, true, 1e6, 0);
        vm.warp(uint256(validUntil) + 1);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.QuoteExpired.selector));
        _swap(MHYPER, false, true, 1e18, 0);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.QuoteExpired.selector));
        _swap(MHYPER, true, true, 1e6, 0);
    }

    function test_remainingExceeded_reverts() public {
        MidasQuoteHook.Params memory p = _params(2);
        p.bidRemaining = 600e18;
        p.askRemaining = 300e18;
        vm.prank(maker);
        hook.setParams(MARB, p);

        _swap(MARB, false, true, 100e18, 0);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.AmountExceedsRemaining.selector));
        _swap(MARB, false, true, 500e18 + 1, 0);
        _swap(MARB, false, true, 500e18, 0);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.AmountExceedsRemaining.selector));
        _swap(MARB, false, true, 1, 0);

        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.AmountExceedsRemaining.selector));
        _swap(MARB, true, false, 300e18 + 1, type(uint128).max);
        _swap(MARB, true, false, 300e18, type(uint128).max);
        (uint128 bid, uint128 ask) = _remaining(MARB);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    /// @dev Disabling skips the feed checks, so a broken feed cannot keep a quote alive.
    function test_killSwitch_worksWithBrokenFeed() public {
        vm.mockCall(
            MHYPER_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(126), int256(-1), uint256(0), block.timestamp, uint80(126))
        );
        vm.startPrank(maker);
        vm.expectRevert(MidasQuoteHook.BadOracleAnswer.selector);
        hook.setParams(MHYPER, _params(126));
        // Both remainings zero.
        MidasQuoteHook.Params memory p = _params(126);
        p.bidRemaining = 0;
        p.askRemaining = 0;
        hook.setParams(MHYPER, p);
        vm.stopPrank();
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.AmountExceedsRemaining.selector));
        _swap(MHYPER, false, true, 1e18, 0);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.AmountExceedsRemaining.selector));
        _swap(MHYPER, true, true, 1e6, 0);

        // validUntil zero, everything else garbage.
        p = MidasQuoteHook.Params({
            round: 0,
            validUntil: 0,
            bidDiscountBps: type(uint16).max,
            askPremiumBps: 0,
            askApyBps: 0,
            bidRemaining: type(uint128).max,
            askRemaining: type(uint128).max
        });
        vm.prank(maker);
        hook.setParams(MHYPER, p);
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.QuoteExpired.selector));
        _swap(MHYPER, false, true, 1e18, 0);
    }

    /// @dev Opening a side requires the feed's current round: neither a future nor a past round is accepted. The kill
    /// switch takes any round.
    function test_setParams_requiresCurrentRound() public {
        vm.startPrank(maker);
        vm.expectRevert(MidasQuoteHook.StaleRound.selector);
        hook.setParams(MHYPER, _params(127));
        vm.expectRevert(MidasQuoteHook.StaleRound.selector);
        hook.setParams(MHYPER, _params(125));
        MidasQuoteHook.Params memory p = _params(127);
        p.bidRemaining = 0;
        vm.expectRevert(MidasQuoteHook.StaleRound.selector);
        hook.setParams(MHYPER, p); // ask side alone still opens
        p.askRemaining = 0;
        hook.setParams(MHYPER, p); // kill switch: any round
        p = _params(127);
        p.validUntil = 0;
        hook.setParams(MHYPER, p); // kill switch: any round
        vm.stopPrank();

        vm.prank(MHYPER_UPDATER);
        IMidasFeed(MHYPER_FEED).setRoundDataSafe(MHYPER_NAV);
        vm.prank(maker);
        hook.setParams(MHYPER, _params(127));
        (, uint256 out) = _trade(MHYPER, false, true, X, 0);
        assertEq(out, 1_392_112_410, "round 127 opens");
    }

    function test_setParams_notMaker_orUnknownToken_reverts() public {
        vm.expectRevert(MidasQuoteHook.NotMaker.selector);
        hook.setParams(MHYPER, _params(126));
        vm.prank(maker);
        vm.expectRevert(MidasQuoteHook.UnknownToken.selector);
        hook.setParams(WETH, _params(126));
        vm.prank(maker);
        vm.expectRevert(MidasQuoteHook.UnknownToken.selector);
        hook.setParams(USDC, _params(126));
    }

    function test_zeroOutput_reverts() public {
        // One USDC base unit costs 886,830,604,128.001... wei of mHYPER at the bid, so this is worth just under one.
        _expectSwapRevert(abi.encodeWithSelector(MidasQuoteHook.ZeroAmount.selector));
        _swap(MHYPER, false, true, 886_830_604_128, 0);
    }

    // ------------------------------------------------------------------ pool guards

    function test_wrongPools_reverts() public {
        PoolKey memory other = _key(MHYPER);
        other.tickSpacing = 60;
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(MidasQuoteHook.WrongPool.selector))
        );
        pm.initialize(other, SQRT_PRICE_1_1);

        other = _key(MARB);
        other.fee = 3000;
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(MidasQuoteHook.WrongPool.selector))
        );
        pm.initialize(other, SQRT_PRICE_1_1);

        // A token the hook does not serve.
        other = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(MidasQuoteHook.WrongPool.selector))
        );
        pm.initialize(other, SQRT_PRICE_1_1);

        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        pm.initialize(_key(MALPHA), SQRT_PRICE_1_1);
    }

    function test_hookCalledDirectly_reverts() public {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
        vm.expectRevert(MidasQuoteHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), _key(MHYPER), p, "");
        vm.expectRevert(MidasQuoteHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), _key(MHYPER), SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------ protocol fee

    function test_maxProtocolFee_takesNothing() public {
        PoolKey memory key = _key(MHYPER);
        vm.prank(PROTOCOL_FEE_CONTROLLER);
        pm.setProtocolFee(key, 1000 | (1000 << 12));
        uint256 feesUsdc = pm.protocolFeesAccrued(Currency.wrap(USDC));
        uint256 feesMhyper = pm.protocolFeesAccrued(Currency.wrap(MHYPER));

        (, uint256 out) = _trade(MHYPER, false, true, X, 0);
        assertEq(out, 1_392_112_410, "bid unchanged");
        (uint256 paid,) = _trade(MHYPER, true, false, X, type(uint128).max);
        assertEq(paid, 1_403_473_052, "ask unchanged");

        assertEq(pm.protocolFeesAccrued(Currency.wrap(USDC)), feesUsdc, "USDC protocol fees unchanged");
        assertEq(pm.protocolFeesAccrued(Currency.wrap(MHYPER)), feesMhyper, "mHYPER protocol fees unchanged");
    }

    // ------------------------------------------------------------------ liquidity

    function test_liquidityAllowed_neverTraded_currency0() public {
        _liquidityNeverTraded(
            MHYPER, [uint256(1_392_112_410), 886_830_604_128_001_226_459, 879_652_009_606_167_333_034, 1_403_473_052]
        );
    }

    /// @dev mArb is currency1: the same four fills run in the opposite zeroForOne directions.
    function test_liquidityAllowed_neverTraded_currency1() public {
        _liquidityNeverTraded(
            MARB, [uint256(1_228_395_050), 1_005_025_125_628_140_703_518, 993_481_188_670_372_030_005, 1_242_668_613]
        );
    }

    /// @dev Adds a small position around the 1:1 price, runs bid exact-in X, bid exact-out 1,000 USDC, ask exact-in
    /// 1,000 USDC and ask exact-out X through the router at their no-liquidity amounts (`expected`, in that order),
    /// then removes it: the pool price, liquidity and fee growth never move, the position earns nothing, and it
    /// returns its principal.
    function _liquidityNeverTraded(address token, uint256[4] memory expected) private {
        PoolKey memory key = _key(token);
        deal(token, address(this), 1e18);
        deal(USDC, address(this), 1_000e6);
        int256 liquidity = 1e10;

        (BalanceDelta added, BalanceDelta addFees) =
            abi.decode(pm.unlock(abi.encode(key, liquidity)), (BalanceDelta, BalanceDelta));
        assertLt(added.amount0(), 0, "paid currency0");
        assertLt(added.amount1(), 0, "paid currency1");
        assertEq(BalanceDelta.unwrap(addFees), 0);

        _swapAllWays_assertPoolUntouched(token, key.toId(), uint128(uint256(liquidity)), expected);

        (BalanceDelta removed, BalanceDelta removeFees) =
            abi.decode(pm.unlock(abi.encode(key, -liquidity)), (BalanceDelta, BalanceDelta));
        assertEq(BalanceDelta.unwrap(removeFees), 0, "position earned no fees");
        // Adding rounds the owed amounts up and removing rounds the returned amounts down: at most 1 wei each.
        assertApproxEqAbs(int256(removed.amount0()), -int256(added.amount0()), 1, "principal 0 returned");
        assertApproxEqAbs(int256(removed.amount1()), -int256(added.amount1()), 1, "principal 1 returned");
        assertLe(int256(removed.amount0()), -int256(added.amount0()));
        assertLe(int256(removed.amount1()), -int256(added.amount1()));
    }

    function _swapAllWays_assertPoolUntouched(address token, PoolId id, uint128 liquidity, uint256[4] memory expected)
        private
    {
        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(pm, id);
        (uint256 fg0Before, uint256 fg1Before) = StateLibrary.getFeeGrowthGlobals(pm, id);
        assertEq(StateLibrary.getLiquidity(pm, id), liquidity);

        (, uint256 out) = _trade(token, false, true, X, 0);
        assertEq(out, expected[0], "bid exact-in unchanged");
        (uint256 paid,) = _trade(token, false, false, 1_000e6, type(uint128).max);
        assertEq(paid, expected[1], "bid exact-out unchanged");
        (, out) = _trade(token, true, true, 1_000e6, 0);
        assertEq(out, expected[2], "ask exact-in unchanged");
        (paid,) = _trade(token, true, false, X, type(uint128).max);
        assertEq(paid, expected[3], "ask exact-out unchanged");

        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(pm, id);
        (uint256 fg0After, uint256 fg1After) = StateLibrary.getFeeGrowthGlobals(pm, id);
        assertEq(sqrtAfter, sqrtBefore, "price unmoved");
        assertEq(tickAfter, tickBefore);
        assertEq(fg0After, fg0Before, "no fee growth 0");
        assertEq(fg1After, fg1Before, "no fee growth 1");
        assertEq(StateLibrary.getLiquidity(pm, id), liquidity, "liquidity unchanged");
    }

    /// @dev Modifies a [-10, 10] position from inside the PoolManager unlock and pays or takes the deltas.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int256 liquidityDelta) = abi.decode(data, (PoolKey, int256));
        (BalanceDelta callerDelta, BalanceDelta fees) = pm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -10, tickUpper: 10, liquidityDelta: liquidityDelta, salt: 0
            }),
            ""
        );
        _settleOrTake(key.currency0, callerDelta.amount0());
        _settleOrTake(key.currency1, callerDelta.amount1());
        return abi.encode(callerDelta, fees);
    }

    function _settleOrTake(Currency currency, int128 amount) private {
        if (amount < 0) {
            pm.sync(currency);
            IERC20Like(Currency.unwrap(currency)).transfer(POOL_MANAGER, uint128(-amount));
            pm.settle();
        } else if (amount > 0) {
            pm.take(currency, address(this), uint128(amount));
        }
    }

    // ------------------------------------------------------------------ quoter

    /// @dev Uniswap's off-chain routing prices v4 pools through this quoter with empty hookData.
    function test_quoter_matchesSwap_bidAndAsk() public {
        (uint256 quotedBid,) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                QuoteExactSingleParams({
                    poolKey: _key(MHYPER), zeroForOne: _zeroForOne(MHYPER, false), exactAmount: uint128(X), hookData: ""
                })
            );
        (uint256 quotedAsk,) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                QuoteExactSingleParams({
                    poolKey: _key(MARB), zeroForOne: _zeroForOne(MARB, true), exactAmount: 1_000e6, hookData: ""
                })
            );
        assertEq(_claim(MHYPER) + _claim(USDC), 0, "quotes left no state");
        (uint128 bid,) = _remaining(MHYPER);
        assertEq(bid, REMAINING);

        (, uint256 bidOut) = _trade(MHYPER, false, true, X, 0);
        (, uint256 askOut) = _trade(MARB, true, true, 1_000e6, 0);
        assertEq(quotedBid, bidOut, "bid quote = swap");
        assertEq(quotedAsk, askOut, "ask quote = swap");
        assertEq(quotedBid, 1_392_112_410);
        assertEq(quotedAsk, 993_481_188_670_372_030_005);
    }

    // ------------------------------------------------------------------ gas

    function test_gas_bidWithDeallocation_askFromClaims_askFromMaker() public {
        uint256 g = _swap(MHYPER, false, true, X, 0);
        console2.log("gas: router execute, bid exact-in with deallocation", g);
        g = _swap(MHYPER, true, false, 1_000e18, type(uint128).max);
        console2.log("gas: router execute, ask exact-out from claims", g);
        assertEq(_claim(MHYPER), X - 1_000e18, "served from claims");
        uint256 makerBefore = IERC20Like(MALPHA).balanceOf(maker);
        g = _swap(MALPHA, true, false, 1_000e18, type(uint128).max);
        console2.log("gas: router execute, ask exact-out from maker allowance", g);
        assertEq(makerBefore - IERC20Like(MALPHA).balanceOf(maker), 1_000e18, "served from the maker");
    }
}
