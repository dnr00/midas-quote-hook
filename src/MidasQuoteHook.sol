// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {
    IVaultV2,
    IMorphoMarketV1AdapterV2,
    IMorpho,
    IAggregatorV3,
    IERC20
} from "./MorphoForceWithdrawPreInteraction.sol";

interface IVaultV2Deposit {
    function deposit(uint256 assets, address onBehalf) external returns (uint256 shares);
}

/// @dev Uniswap's V4FeeAdapter, the PoolManager's protocolFeeController on Ethereum, names the protocol fee recipient.
interface IProtocolFeeAdapter {
    function TOKEN_JAR() external view returns (address);
}

interface IERC20Ops {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title MidasQuoteHook
/// @notice Uniswap v4 hook that makes a two-sided market in up to three Midas mTokens against ASSET (USDC), one
/// canonical pool per token. The bid buys the token at NAV minus a discount, paid first from the hook's USDC claims
/// (proceeds of earlier asks) and then just in time from the maker's Morpho VaultV2 shares (force-deallocating the
/// shortfall market by market). The ask sells the token at NAV accrued
/// linearly at an assumed APY since the feed's last update, plus a premium, delivered from the hook's token claims
/// (inventory bought by earlier bids) and then from a maker allowance. Prices are computed at swap time from the
/// token's feed; the maker only sets parameters, each bound to the feed's current round and a validity timestamp.
/// @dev Routers always pass empty hookData. Ownerless, not upgradeable; every address and the token list are fixed at
/// construction. beforeSwap always consumes the whole specified amount, so the AMM is never asked to swap anything and
/// any liquidity added to the pool is never traded. Custom accounting does not bypass the v4 protocol fee: every fill
/// charges the swapper the pool's protocol fee for the swap direction, as Uniswap governance sets it in the
/// PoolManager, in ASSET, and pays it to the protocol fee controller's TokenJar (Uniswap's aggregator-hook
/// convention). Swappers are protected by immutable bands on every maker parameter: before the protocol fee, the bid
/// never pays less than NAV x (1 - MAX_BID_DISCOUNT_BPS / 10,000) and the ask never charges more than
/// NAV x (1 + MAX_ASK_APY_BPS x MAX_ACCRUAL / (10,000 x YEAR)) x (1 + MAX_ASK_PREMIUM_BPS / 10,000). The swapper's input is not yet in the PoolManager when beforeSwap
/// runs (routers settle after the swap), so the hook takes it as an ERC6909 claim; claims are the only thing the hook
/// holds, they are owed to MAKER, and anyone can sweep them: token claims to MAKER, USDC claims (plus any USDC sent to the
/// hook directly) deposited into VAULT for MAKER, or sent to MAKER if VAULT refuses the deposit. Requires two maker approvals: VAULT shares to this contract (bounds bid funding beyond the hook's USDC claims)
/// and each token to this contract (bounds ask delivery beyond the hook's token claims).
contract MidasQuoteHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;

    error NotPoolManager();
    error NotMaker();
    error WrongPool();
    error UnknownToken();
    error QuoteExpired();
    error StaleRound();
    error BadOracleAnswer();
    error PriceAboveCeiling();
    error PriceBelowFloor();
    error ZeroPrice();
    error ZeroAmount();
    error AmountExceedsRemaining();
    error PenaltyNotZero();
    error InsufficientLiquidity(uint256 shortfall);
    error MakerTransferFailed();
    error ApproveFailed();
    error AssetTransferFailed();
    error BadConfig();
    error DiscountAboveMax();
    error PremiumAboveMax();
    error ApyAboveMax();

    enum Side {
        Bid,
        Ask
    }

    /// @param round Feed round id both sides are valid for.
    /// @param validUntil Last timestamp at which either side fills; zero disables both.
    /// @param bidDiscountBps Bid = NAV x (1 - bidDiscountBps / 10,000).
    /// @param askPremiumBps Premium applied on top of the accrued NAV.
    /// @param askApyBps Assumed yearly NAV growth, accrued linearly since the feed's updatedAt.
    /// @param bidRemaining Token base units the hook still buys; zero disables the bid.
    /// @param askRemaining Token base units the hook still sells; zero disables the ask.
    struct Params {
        uint80 round;
        uint40 validUntil;
        uint16 bidDiscountBps;
        uint16 askPremiumBps;
        uint16 askApyBps;
        uint128 bidRemaining;
        uint128 askRemaining;
    }

    /// @notice Immutable price bands. The maker-side bounds cap what the maker can lose to a mispriced parameter; the
    /// swapper-side bounds cap how far the maker can move a price against a swap already in flight.
    /// @param maxBidBps Maker side: the bid never exceeds NAV x maxBidBps / 10,000.
    /// @param maxBidDiscountBps Swapper side: the bid never falls below NAV x (1 - maxBidDiscountBps / 10,000).
    /// @param minAskPremiumBps Maker side: the ask never falls below NAV x (1 + minAskPremiumBps / 10,000).
    /// @param maxAskPremiumBps Swapper side: askPremiumBps never exceeds it.
    /// @param maxAskApyBps Swapper side: askApyBps never exceeds it.
    /// @param maxAccrual The most seconds of APY accrual the ask ever adds; at most 60 days.
    struct Bounds {
        uint256 maxBidBps;
        uint256 maxBidDiscountBps;
        uint256 minAskPremiumBps;
        uint256 maxAskPremiumBps;
        uint256 maxAskApyBps;
        uint256 maxAccrual;
    }

    /// @param token The mToken this pool trades against ASSET.
    /// @param tokenIsCurrency0 The token sorts below ASSET.
    /// @param scaleExp tokenDecimals + feedDecimals - assetDecimals.
    /// @param feed The token's NAV feed.
    struct Market {
        address token;
        bool tokenIsCurrency0;
        uint8 scaleExp;
        address feed;
    }

    event ParamsSet(address indexed token, Params params);
    /// @param amountIn What the swapper paid.
    /// @param amountOut What the swapper received.
    /// @param protocolFee The ASSET paid to the TokenJar out of the swap: the maker paid amountOut + protocolFee on a
    /// bid and received amountIn - protocolFee on an ask.
    event Filled(
        address indexed token,
        Side side,
        address sender,
        uint256 amountIn,
        uint256 amountOut,
        uint256 protocolFee,
        uint256 deallocated
    );
    /// @dev Same shape as Uniswap's aggregator hooks' ProtocolFees event.
    event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);
    /// @param deposited ASSET only: true when deposited into VAULT for MAKER, false when VAULT refused the deposit and
    /// the ASSET went to MAKER directly. Always false for a token, which always goes to MAKER as the token.
    event Swept(address indexed currency, uint256 amount, bool deposited);
    /// @dev OpenZeppelin uniswap-hooks IHookEvents.HookSwap: amounts from the swapper's side, positive for input and
    /// negative for output; no hook LP fee.
    event HookSwap(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 private constant PIPS = 1_000_000;
    /// @dev Upper bound on maxAccrual, so the ask's swapper-side ceiling is bounded by the constructor alone.
    uint256 private constant MAX_ACCRUAL_LIMIT = 60 days;
    /// @dev Gas for the controller's TOKEN_JAR() lookup. The deployed V4FeeAdapter answers from an immutable for well
    /// under 1,000 gas; the cap keeps a replaced controller from consuming the swap's gas.
    uint256 private constant TOKEN_JAR_GAS = 50_000;
    int24 public constant TICK_SPACING = 1;
    uint256 public constant MAX_TOKENS = 3;
    /// @dev Keeps 10 ** scaleExp and the products below it far from overflow.
    uint256 private constant MAX_SCALE_EXP = 38;

    IPoolManager public immutable POOL_MANAGER;
    IVaultV2 public immutable VAULT;
    IMorphoMarketV1AdapterV2 public immutable MARKET_ADAPTER;
    IMorpho public immutable MORPHO;
    address public immutable ASSET;
    address public immutable MAKER;
    /// @notice The bid never exceeds NAV x MAX_BID_BPS / 10,000.
    uint256 public immutable MAX_BID_BPS;
    /// @notice The bid never falls below NAV x (1 - MAX_BID_DISCOUNT_BPS / 10,000).
    uint256 public immutable MAX_BID_DISCOUNT_BPS;
    /// @notice The ask never falls below NAV x (1 + MIN_ASK_PREMIUM_BPS / 10,000).
    uint256 public immutable MIN_ASK_PREMIUM_BPS;
    /// @notice askPremiumBps never exceeds MAX_ASK_PREMIUM_BPS.
    uint256 public immutable MAX_ASK_PREMIUM_BPS;
    /// @notice askApyBps never exceeds MAX_ASK_APY_BPS.
    uint256 public immutable MAX_ASK_APY_BPS;
    /// @notice The most seconds of APY accrual the ask ever adds.
    uint256 public immutable MAX_ACCRUAL;
    /// @dev ERC6909 id of ASSET in the PoolManager.
    uint256 private immutable ASSET_ID;

    /// @dev Written once in the constructor; nothing adds or removes a token later.
    address[] private _tokens;
    /// @notice The canonical pool of each token: {token, ASSET} sorted, static zero LP fee, TICK_SPACING, this hook.
    mapping(PoolId => Market) public markets;
    mapping(address token => PoolId) public poolIdOf;
    mapping(address token => Params) public params;

    constructor(
        address poolManager,
        address vault,
        address marketAdapter,
        address maker,
        address[] memory tokens_,
        address[] memory feeds,
        Bounds memory b
    ) {
        if (
            poolManager == address(0) || vault == address(0) || marketAdapter == address(0) || maker == address(0)
                || tokens_.length == 0 || tokens_.length > MAX_TOKENS || tokens_.length != feeds.length
        ) revert BadConfig();
        // Each band must be non-empty: some discount d satisfies BPS - maxBidBps <= d <= maxBidDiscountBps < BPS, and
        // some premium satisfies minAskPremiumBps <= premium <= maxAskPremiumBps.
        if (
            b.maxBidBps == 0 || b.maxBidBps > BPS || b.maxBidDiscountBps >= BPS
                || BPS - b.maxBidBps > b.maxBidDiscountBps || b.maxAskPremiumBps > BPS
                || b.minAskPremiumBps > b.maxAskPremiumBps || b.maxAskApyBps > BPS || b.maxAccrual > MAX_ACCRUAL_LIMIT
        ) revert BadConfig();
        if (IMorphoMarketV1AdapterV2(marketAdapter).parentVault() != vault) revert BadConfig();
        if (!IVaultV2(vault).isAdapter(marketAdapter)) revert BadConfig();

        POOL_MANAGER = IPoolManager(poolManager);
        VAULT = IVaultV2(vault);
        MARKET_ADAPTER = IMorphoMarketV1AdapterV2(marketAdapter);
        MORPHO = IMorpho(IMorphoMarketV1AdapterV2(marketAdapter).morpho());
        address asset = IVaultV2(vault).asset();
        ASSET = asset;
        MAKER = maker;
        MAX_BID_BPS = b.maxBidBps;
        MAX_BID_DISCOUNT_BPS = b.maxBidDiscountBps;
        MIN_ASK_PREMIUM_BPS = b.minAskPremiumBps;
        MAX_ASK_PREMIUM_BPS = b.maxAskPremiumBps;
        MAX_ASK_APY_BPS = b.maxAskApyBps;
        MAX_ACCRUAL = b.maxAccrual;
        ASSET_ID = uint256(uint160(asset));

        uint256 assetDecimals = IERC20(asset).decimals();
        for (uint256 i; i < tokens_.length; ++i) {
            address token = tokens_[i];
            address feed = feeds[i];
            if (token == address(0) || feed == address(0) || token == asset) revert BadConfig();
            if (PoolId.unwrap(poolIdOf[token]) != 0) revert BadConfig();

            uint256 scaleDecimals = uint256(IERC20(token).decimals()) + IAggregatorV3(feed).decimals();
            if (scaleDecimals < assetDecimals || scaleDecimals - assetDecimals > MAX_SCALE_EXP) revert BadConfig();

            (address c0, address c1) = token < asset ? (token, asset) : (asset, token);
            PoolId id = PoolKey({
                    currency0: Currency.wrap(c0),
                    currency1: Currency.wrap(c1),
                    fee: 0,
                    tickSpacing: TICK_SPACING,
                    hooks: IHooks(address(this))
                }).toId();
            markets[id] = Market({
                token: token,
                tokenIsCurrency0: token < asset,
                scaleExp: uint8(scaleDecimals - assetDecimals),
                feed: feed
            });
            poolIdOf[token] = id;
            _tokens.push(token);
        }

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    /// @notice The tokens this hook serves, in constructor order.
    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    // ------------------------------------------------------------------ maker

    /// @notice Replaces `token`'s parameters. `validUntil = 0`, or both remainings zero, is the kill switch and skips
    /// every check, so the maker can always stop a token, even while its feed is broken. Otherwise `p.round` must be
    /// the feed's current round (a future round's NAV cannot be pre-approved), the feed must answer above zero and each
    /// open side must sit inside its bands: 10,000 - MAX_BID_BPS <= bidDiscountBps <= MAX_BID_DISCOUNT_BPS;
    /// MIN_ASK_PREMIUM_BPS <= askPremiumBps <= MAX_ASK_PREMIUM_BPS and askApyBps <= MAX_ASK_APY_BPS. A side with zero
    /// remaining is closed and not checked.
    function setParams(address token, Params calldata p) external {
        if (msg.sender != MAKER) revert NotMaker();
        PoolId id = poolIdOf[token];
        if (PoolId.unwrap(id) == 0) revert UnknownToken();
        if (p.validUntil != 0 && (p.bidRemaining != 0 || p.askRemaining != 0)) {
            (uint80 roundId, int256 answer,,,) = IAggregatorV3(markets[id].feed).latestRoundData();
            if (roundId != p.round) revert StaleRound();
            if (answer <= 0) revert BadOracleAnswer();
            if (p.bidRemaining != 0) {
                if (p.bidDiscountBps >= BPS) revert ZeroPrice();
                if (BPS - p.bidDiscountBps > MAX_BID_BPS) revert PriceAboveCeiling();
                if (p.bidDiscountBps > MAX_BID_DISCOUNT_BPS) revert DiscountAboveMax();
            }
            if (p.askRemaining != 0) {
                if (p.askPremiumBps < MIN_ASK_PREMIUM_BPS) revert PriceBelowFloor();
                if (p.askPremiumBps > MAX_ASK_PREMIUM_BPS) revert PremiumAboveMax();
                if (p.askApyBps > MAX_ASK_APY_BPS) revert ApyAboveMax();
            }
        }
        params[token] = p;
        emit ParamsSet(token, p);
    }

    // ------------------------------------------------------------------ sweep

    /// @notice Empties the hook's ERC6909 claim on `currency`: a token claim goes to MAKER as the token. For ASSET, the
    /// claim is taken to this contract and its whole ASSET balance (the claim plus anything sent here directly) is
    /// deposited into VAULT for MAKER; if VAULT refuses the deposit, the approval is reset and the ASSET is transferred
    /// to MAKER instead, so a vault gate can never strand it. Permissionless; destinations are fixed. Returns the amount
    /// moved; nothing to move returns 0 without emitting (and without unlocking when there is no claim).
    function sweep(address currency) external returns (uint256 amount) {
        if (currency != ASSET && PoolId.unwrap(poolIdOf[currency]) == 0) revert UnknownToken();
        address[] memory currencies = new address[](1);
        currencies[0] = currency;
        amount = _sweep(currencies)[0];
    }

    /// @notice `sweep` for every token and ASSET in one unlock. Returns the amounts in `tokens()` order, then ASSET.
    function sweepAll() external returns (uint256[] memory amounts) {
        uint256 n = _tokens.length;
        address[] memory currencies = new address[](n + 1);
        for (uint256 i; i < n; ++i) {
            currencies[i] = _tokens[i];
        }
        currencies[n] = ASSET;
        amounts = _sweep(currencies);
    }

    function _sweep(address[] memory currencies) private returns (uint256[] memory amounts) {
        uint256 n = currencies.length;
        amounts = new uint256[](n);
        bool any;
        for (uint256 i; i < n; ++i) {
            amounts[i] = POOL_MANAGER.balanceOf(address(this), uint256(uint160(currencies[i])));
            if (amounts[i] != 0) any = true;
        }
        if (any) POOL_MANAGER.unlock(abi.encode(currencies, amounts));
        for (uint256 i; i < n; ++i) {
            bool deposited;
            if (currencies[i] == ASSET) {
                amounts[i] = IERC20(ASSET).balanceOf(address(this));
                if (amounts[i] == 0) continue;
                deposited = _payAsset(amounts[i]);
            } else if (amounts[i] == 0) {
                continue;
            }
            emit Swept(currencies[i], amounts[i], deposited);
        }
    }

    /// @dev Deposits `amount` ASSET into VAULT for MAKER, or, if the deposit reverts for any reason (a curator gate, a
    /// pause, a callee running out of gas), resets the approval and transfers the ASSET to MAKER.
    function _payAsset(uint256 amount) private returns (bool deposited) {
        if (!_call(ASSET, abi.encodeCall(IERC20Ops.approve, (address(VAULT), amount)))) revert ApproveFailed();
        try IVaultV2Deposit(address(VAULT)).deposit(amount, MAKER) {
            return true;
        } catch {
            if (!_call(ASSET, abi.encodeCall(IERC20Ops.approve, (address(VAULT), 0)))) revert ApproveFailed();
            if (!_call(ASSET, abi.encodeCall(IERC20Ops.transfer, (MAKER, amount)))) revert AssetTransferFailed();
        }
    }

    /// @dev The PoolManager only calls back the account that unlocked it, and `_sweep` is this contract's only unlock.
    /// ASSET is taken to this contract for the deposit that follows the unlock; tokens go straight to MAKER.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address[] memory currencies, uint256[] memory amounts) = abi.decode(data, (address[], uint256[]));
        for (uint256 i; i < currencies.length; ++i) {
            if (amounts[i] == 0) continue;
            address currency = currencies[i];
            POOL_MANAGER.burn(address(this), uint256(uint160(currency)), amounts[i]);
            POOL_MANAGER.take(Currency.wrap(currency), currency == ASSET ? address(this) : MAKER, amounts[i]);
        }
        return "";
    }

    // ------------------------------------------------------------------ hooks

    /// @notice Accepts only the canonical pools; the PoolManager itself refuses a second initialisation. Any
    /// sqrtPriceX96 is fine: every swap reaches Pool.swap with amountSpecified 0, which returns before checking the
    /// price limit or moving the price.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (markets[key.toId()].token == address(0)) revert WrongPool();
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Fills the whole swap at the hook's price and returns a delta that leaves the AMM nothing to swap.
    /// Swapper sells the token: bid. Swapper buys the token: ask.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata sp, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Market memory m = markets[id];
        if (m.token == address(0)) revert WrongPool();
        ProtocolFee memory pf = _protocolFee(id, sp.zeroForOne);
        (uint256 amountIn, uint256 amountOut) = _fill(sender, m, sp, pf);
        return (IHooks.beforeSwap.selector, _delta(id, sender, sp, amountIn, amountOut), 0);
    }

    /// @dev amountIn and amountOut are the swapper's. Specified is the input for exact-in and the output for
    /// exact-out. A positive hook delta is owed to the hook, a negative one is owed by it; the swapper's side is the
    /// negation.
    function _delta(PoolId id, address sender, IPoolManager.SwapParams calldata sp, uint256 amountIn, uint256 amountOut)
        private
        returns (BeforeSwapDelta)
    {
        int128 inDelta = amountIn.toInt128();
        int128 outDelta = amountOut.toInt128();
        if (sp.zeroForOne) emit HookSwap(PoolId.unwrap(id), sender, inDelta, -outDelta, 0, 0);
        else emit HookSwap(PoolId.unwrap(id), sender, -outDelta, inDelta, 0, 0);
        return sp.amountSpecified < 0 ? toBeforeSwapDelta(inDelta, -outDelta) : toBeforeSwapDelta(-outDelta, inDelta);
    }

    /// @dev Prices and spends the fill, clears the hook's PoolManager deltas for it, pays the protocol fee and emits
    /// Filled. Swapper sells the token: bid. Swapper buys the token: ask. Returns the swapper's amounts.
    function _fill(address sender, Market memory m, IPoolManager.SwapParams calldata sp, ProtocolFee memory pf)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        Side side = sp.zeroForOne == m.tokenIsCurrency0 ? Side.Bid : Side.Ask;
        bool exactInput = sp.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-sp.amountSpecified) : uint256(sp.amountSpecified);
        // tokenAmount and assetAmount are the maker's legs at the maker's price; the protocol fee sits between the
        // maker's ASSET leg and the swapper's.
        (uint256 tokenAmount, uint256 assetAmount, uint256 fee) = _consume(m, side, exactInput, specified, pf.pips);
        uint256 deallocated;
        if (side == Side.Bid) {
            deallocated = _settleBid(m.token, tokenAmount, assetAmount);
            (amountIn, amountOut) = (tokenAmount, assetAmount - fee);
        } else {
            _settleAsk(m.token, assetAmount, tokenAmount);
            (amountIn, amountOut) = (assetAmount + fee, tokenAmount);
        }
        if (fee != 0) {
            POOL_MANAGER.take(Currency.wrap(ASSET), pf.recipient, fee);
            emit ProtocolFeesCollected(pf.recipient, Currency.wrap(ASSET), fee);
        }
        emit Filled(m.token, side, sender, amountIn, amountOut, fee, deallocated);
    }

    // ------------------------------------------------------------------ protocol fee

    /// @param pips The pool's protocol fee for the swap direction, in hundredths of a bip (at most 1,000).
    /// @param recipient The TokenJar it is paid to.
    struct ProtocolFee {
        uint256 pips;
        address recipient;
    }

    /// @dev Reads the pool's protocol fee for the swap direction from the PoolManager, where Uniswap governance sets it
    /// through the protocolFeeController, and resolves the TokenJar from that controller. With no fee, or no
    /// resolvable TokenJar, nothing is charged (Uniswap's aggregator hooks do the same). The lookup is gas-capped and
    /// reads one word, and any failure, short answer, or word that is not an address means no TokenJar, so a replaced
    /// controller can never block swaps.
    function _protocolFee(PoolId id, bool zeroForOne) private view returns (ProtocolFee memory pf) {
        (,, uint24 raw,) = POOL_MANAGER.getSlot0(id);
        uint256 pips = zeroForOne ? raw.getZeroForOneFee() : raw.getOneForZeroFee();
        if (pips == 0) return pf;
        address controller = POOL_MANAGER.protocolFeeController();
        if (controller.code.length == 0) return pf;
        bytes4 selector = IProtocolFeeAdapter.TOKEN_JAR.selector;
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(TOKEN_JAR_GAS, controller, ptr, 0x04, ptr, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            word := mload(ptr)
        }
        if (!ok || word == 0 || word >> 160 != 0) return pf;
        pf = ProtocolFee({pips: pips, recipient: address(uint160(word))});
    }

    // ------------------------------------------------------------------ pricing

    /// @dev Checks the parameters against the feed, prices the fill and spends it from the side's remaining. Returns
    /// the maker's legs and the protocol fee, all at the maker's price; remaining counts tokenAmount on both sides.
    /// The fee is `feePips` of the gross ASSET flow, rounded up:
    /// - Bid exact-in (token in): swapper receives assetAmount - fee, fee = ceil(assetAmount x f / 1e6).
    /// - Bid exact-out (ASSET out): assetAmount = out + fee, fee = ceil(out x f / (1e6 - f)).
    /// - Ask exact-in (ASSET in): assetAmount = in - fee, fee = ceil(in x f / 1e6).
    /// - Ask exact-out (token out): swapper pays assetAmount + fee, fee = ceil(assetAmount x f / (1e6 - f)).
    function _consume(Market memory m, Side side, bool exactInput, uint256 specified, uint256 feePips)
        private
        returns (uint256 tokenAmount, uint256 assetAmount, uint256 fee)
    {
        Params storage ps = params[m.token];
        Params memory p = ps;
        if (block.timestamp > p.validUntil) revert QuoteExpired();
        uint256 remaining = side == Side.Bid ? p.bidRemaining : p.askRemaining;
        if (remaining == 0) revert AmountExceedsRemaining();

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = IAggregatorV3(m.feed).latestRoundData();
        if (roundId != p.round) revert StaleRound();
        if (answer <= 0) revert BadOracleAnswer();
        uint256 scale = 10 ** m.scaleExp;

        if (side == Side.Bid) {
            if (exactInput) {
                tokenAmount = specified;
                assetAmount = _bidAsset(uint256(answer), scale, p.bidDiscountBps, tokenAmount);
                fee = FullMath.mulDivRoundingUp(assetAmount, feePips, PIPS);
                if (assetAmount <= fee) revert ZeroAmount();
            } else {
                fee = FullMath.mulDivRoundingUp(specified, feePips, PIPS - feePips);
                assetAmount = specified + fee;
                if (specified == 0) revert ZeroAmount();
                tokenAmount = _bidToken(uint256(answer), scale, p.bidDiscountBps, assetAmount);
            }
            _checkBidCeiling(uint256(answer), scale, tokenAmount, assetAmount);
            if (tokenAmount > remaining) revert AmountExceedsRemaining();
            ps.bidRemaining = uint128(remaining - tokenAmount);
        } else {
            (uint256 num, uint256 den) = _askPrice(uint256(answer), scale, updatedAt, p);
            if (exactInput) {
                fee = FullMath.mulDivRoundingUp(specified, feePips, PIPS);
                assetAmount = specified - fee;
                tokenAmount = FullMath.mulDiv(assetAmount, den, num);
            } else {
                tokenAmount = specified;
                assetAmount = FullMath.mulDivRoundingUp(tokenAmount, num, den);
                fee = FullMath.mulDivRoundingUp(assetAmount, feePips, PIPS - feePips);
            }
            if (tokenAmount == 0) revert ZeroAmount();
            _checkAskFloor(uint256(answer), scale, tokenAmount, assetAmount);
            if (tokenAmount > remaining) revert AmountExceedsRemaining();
            ps.askRemaining = uint128(remaining - tokenAmount);
        }
    }

    /// @dev NAV = feed answer, `scale` = 10 ** (tokenDecimals + feedDecimals - assetDecimals). The bid in ASSET base
    /// units per token base unit is NAV x (10,000 - bidDiscountBps) / (scale x 10,000). ASSET for `tokenAmount`,
    /// rounded down (in the maker's favour).
    function _bidAsset(uint256 nav, uint256 scale, uint256 discountBps, uint256 tokenAmount)
        private
        pure
        returns (uint256 assetAmount)
    {
        assetAmount = FullMath.mulDiv(tokenAmount, nav * (BPS - discountBps), scale * BPS);
        if (assetAmount == 0) revert ZeroAmount();
    }

    /// @dev Tokens for `assetAmount` at the bid, rounded up (in the maker's favour).
    function _bidToken(uint256 nav, uint256 scale, uint256 discountBps, uint256 assetAmount)
        private
        pure
        returns (uint256)
    {
        return FullMath.mulDivRoundingUp(assetAmount, scale * BPS, nav * (BPS - discountBps));
    }

    /// @dev The ceiling on the realised maker legs: assetAmount x scale x 10,000 <= tokenAmount x NAV x MAX_BID_BPS.
    function _checkBidCeiling(uint256 nav, uint256 scale, uint256 tokenAmount, uint256 assetAmount) private view {
        if (assetAmount * scale * BPS > tokenAmount * nav * MAX_BID_BPS) revert PriceAboveCeiling();
    }

    /// @dev t = min(block.timestamp - updatedAt, MAX_ACCRUAL). The ask in ASSET base units per token base unit is
    /// num / den = NAV x (10,000 x YEAR + askApyBps x t) x (10,000 + askPremiumBps) / (scale x 10,000 x YEAR x 10,000),
    /// with YEAR = 365 days: NAV x (1 + apy x t / YEAR) x (1 + premium). Callers round tokens out down and ASSET in up.
    function _askPrice(uint256 nav, uint256 scale, uint256 updatedAt, Params memory p)
        private
        view
        returns (uint256 num, uint256 den)
    {
        // A feed stamped in the future is broken; refuse rather than guess its age.
        if (updatedAt > block.timestamp) revert BadOracleAnswer();
        uint256 t = block.timestamp - updatedAt;
        if (t > MAX_ACCRUAL) t = MAX_ACCRUAL;
        num = nav * (BPS * YEAR + uint256(p.askApyBps) * t) * (BPS + p.askPremiumBps);
        den = scale * BPS * YEAR * BPS;
    }

    /// @dev The floor on the realised maker legs: assetAmount x scale x 10,000 >= tokenAmount x NAV x
    /// (10,000 + MIN_ASK_PREMIUM_BPS).
    function _checkAskFloor(uint256 nav, uint256 scale, uint256 tokenAmount, uint256 assetAmount) private view {
        if (assetAmount * scale * BPS < tokenAmount * nav * (BPS + MIN_ASK_PREMIUM_BPS)) revert PriceBelowFloor();
    }

    // ------------------------------------------------------------------ settlement

    /// @dev Clears the hook's PoolManager deltas for a bid: +amountIn token as a claim, -amountOut ASSET paid first by
    /// burning the hook's ASSET claims, then from the maker's vault shares straight into the PoolManager; only that
    /// vault part is deallocated. The sync/settle pair here overwrites any sync the caller
    /// left pending, so a caller that syncs and transfers its input before calling swap and settles afterwards reverts
    /// with CurrencyNotSettled; routers that sync, pay and settle atomically (UniversalRouter V4Router) are unaffected.
    function _settleBid(address token, uint256 amountIn, uint256 amountOut) private returns (uint256 deallocated) {
        // The seller's token reaches the PoolManager only when the router settles after this swap, so it cannot be
        // taken yet; the claim is backed by that settlement and is maker inventory for later asks or a sweep.
        POOL_MANAGER.mint(address(this), uint256(uint160(token)), amountIn);

        uint256 fromClaims = _min(POOL_MANAGER.balanceOf(address(this), ASSET_ID), amountOut);
        if (fromClaims != 0) POOL_MANAGER.burn(address(this), ASSET_ID, fromClaims);
        uint256 fromVault = amountOut - fromClaims;
        if (fromVault == 0) return 0;

        uint256 idle = IERC20(ASSET).balanceOf(address(VAULT));
        if (idle < fromVault) {
            deallocated = fromVault - idle;
            _deallocate(deallocated);
        }
        POOL_MANAGER.sync(Currency.wrap(ASSET));
        VAULT.withdraw(fromVault, address(POOL_MANAGER), MAKER);
        POOL_MANAGER.settle();
    }

    /// @dev Clears the hook's PoolManager deltas for an ask: +amountIn ASSET as a claim (the buyer pays after the swap),
    /// -amountOut token paid first by burning the hook's token claims, then by moving the rest from MAKER into the
    /// PoolManager under the maker's allowance. Same sync/settle caveat as `_settleBid`; in addition, a non-zero
    /// protocol fee is `take`n from the PoolManager's ASSET balance in `_fill`, so a caller that syncs and transfers
    /// ASSET before calling swap and settles afterwards reverts with CurrencyNotSettled even when this function does
    /// not sync.
    function _settleAsk(address token, uint256 amountIn, uint256 amountOut) private {
        POOL_MANAGER.mint(address(this), ASSET_ID, amountIn);

        uint256 tokenId = uint256(uint160(token));
        uint256 fromClaims = _min(POOL_MANAGER.balanceOf(address(this), tokenId), amountOut);
        if (fromClaims != 0) POOL_MANAGER.burn(address(this), tokenId, fromClaims);
        uint256 fromMaker = amountOut - fromClaims;
        if (fromMaker != 0) {
            POOL_MANAGER.sync(Currency.wrap(token));
            if (!_call(token, abi.encodeCall(IERC20Ops.transferFrom, (MAKER, address(POOL_MANAGER), fromMaker)))) {
                revert MakerTransferFailed();
            }
            POOL_MANAGER.settle();
        }
    }

    // ------------------------------------------------------------------ funding

    /// @dev Pulls `need` assets back to the vault's idle balance, taking from each market the smaller of the
    /// adapter's supply and the market's free liquidity. Accrual raises supply and borrow assets by the same
    /// interest, so stored free liquidity equals post-accrual free liquidity.
    /// The market list is snapshotted first: deallocating a market to zero swap-and-pops it out of the adapter's
    /// `marketIds`, so walking the live list by index would skip markets and read past its end.
    function _deallocate(uint256 need) private {
        // A non-zero penalty would be charged to the maker's shares; refuse rather than pay it.
        if (VAULT.forceDeallocatePenalty(address(MARKET_ADAPTER)) != 0) revert PenaltyNotZero();

        uint256 n = MARKET_ADAPTER.marketIdsLength();
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = MARKET_ADAPTER.marketIds(i);
        }
        for (uint256 i; i < n && need > 0; ++i) {
            bytes32 id = ids[i];
            uint256 supplied = MARKET_ADAPTER.expectedSupplyAssets(id);
            if (supplied == 0) continue;
            (uint128 totalSupplyAssets,, uint128 totalBorrowAssets,,,) = MORPHO.market(id);
            uint256 amount = _min(_min(supplied, totalSupplyAssets - totalBorrowAssets), need);
            if (amount == 0) continue;
            VAULT.forceDeallocate(address(MARKET_ADAPTER), abi.encode(MORPHO.idToMarketParams(id)), amount, MAKER);
            need -= amount;
        }
        if (need > 0) revert InsufficientLiquidity(need);
    }

    /// @dev ERC-20 call that accepts both bool-returning and non-returning tokens.
    function _call(address token, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(data);
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
