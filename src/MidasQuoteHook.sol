// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
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
/// any liquidity added to the pool is never traded. The swapper's input is not yet in the PoolManager when beforeSwap
/// runs (routers settle after the swap), so the hook takes it as an ERC6909 claim; claims are the only thing the hook
/// holds, they are owed to MAKER, and anyone can sweep them: token claims to MAKER, USDC claims (plus any USDC sent to the
/// hook directly) deposited into VAULT for MAKER, or sent to MAKER if VAULT refuses the deposit. Requires two maker approvals: VAULT shares to this contract (bounds bid funding beyond the hook's USDC claims)
/// and each token to this contract (bounds ask delivery beyond the hook's token claims).
contract MidasQuoteHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

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
    event Filled(
        address indexed token, Side side, address sender, uint256 amountIn, uint256 amountOut, uint256 deallocated
    );
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
    /// @notice The ask never falls below NAV x (1 + MIN_ASK_PREMIUM_BPS / 10,000).
    uint256 public immutable MIN_ASK_PREMIUM_BPS;
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
        uint256 maxBidBps,
        uint256 minAskPremiumBps,
        uint256 maxAccrual
    ) {
        if (
            poolManager == address(0) || vault == address(0) || marketAdapter == address(0) || maker == address(0)
                || maxBidBps == 0 || maxBidBps > BPS || minAskPremiumBps > BPS || tokens_.length == 0
                || tokens_.length > MAX_TOKENS || tokens_.length != feeds.length
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
        MAX_BID_BPS = maxBidBps;
        MIN_ASK_PREMIUM_BPS = minAskPremiumBps;
        MAX_ACCRUAL = maxAccrual;
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
    /// open side must respect its bound: bidDiscountBps < 10,000 and 10,000 - bidDiscountBps <= MAX_BID_BPS;
    /// askPremiumBps >= MIN_ASK_PREMIUM_BPS. A side with zero remaining is closed and not checked.
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
            }
            if (p.askRemaining != 0 && p.askPremiumBps < MIN_ASK_PREMIUM_BPS) revert PriceBelowFloor();
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

        bool exactInput = sp.amountSpecified < 0;
        (uint256 amountIn, uint256 amountOut) = _fill(
            sender,
            m,
            sp.zeroForOne == m.tokenIsCurrency0 ? Side.Bid : Side.Ask,
            exactInput,
            exactInput ? uint256(-sp.amountSpecified) : uint256(sp.amountSpecified)
        );

        // Specified is the input for exact-in and the output for exact-out. A positive hook delta is owed to the hook,
        // a negative one is owed by it; the swapper's side is the negation.
        int128 inDelta = amountIn.toInt128();
        int128 outDelta = amountOut.toInt128();
        if (sp.zeroForOne) emit HookSwap(PoolId.unwrap(id), sender, inDelta, -outDelta, 0, 0);
        else emit HookSwap(PoolId.unwrap(id), sender, -outDelta, inDelta, 0, 0);
        BeforeSwapDelta delta =
            exactInput ? toBeforeSwapDelta(inDelta, -outDelta) : toBeforeSwapDelta(-outDelta, inDelta);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @dev Prices and spends the fill, clears the hook's PoolManager deltas for it and emits Filled.
    function _fill(address sender, Market memory m, Side side, bool exactInput, uint256 specified)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut) = _consume(m, side, exactInput, specified);
        uint256 deallocated;
        if (side == Side.Bid) deallocated = _settleBid(m.token, amountIn, amountOut);
        else _settleAsk(m.token, amountIn, amountOut);
        emit Filled(m.token, side, sender, amountIn, amountOut, deallocated);
    }

    // ------------------------------------------------------------------ pricing

    /// @dev Checks the parameters against the feed, prices the fill and spends it from the side's remaining.
    /// Bid: in = token, out = ASSET, remaining counts token in. Ask: in = ASSET, out = token, remaining counts token out.
    function _consume(Market memory m, Side side, bool exactInput, uint256 specified)
        private
        returns (uint256 amountIn, uint256 amountOut)
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
            (amountIn, amountOut) = _bidAmounts(uint256(answer), scale, p.bidDiscountBps, exactInput, specified);
            if (amountIn > remaining) revert AmountExceedsRemaining();
            ps.bidRemaining = uint128(remaining - amountIn);
        } else {
            (amountIn, amountOut) = _askAmounts(uint256(answer), scale, updatedAt, p, exactInput, specified);
            if (amountOut > remaining) revert AmountExceedsRemaining();
            ps.askRemaining = uint128(remaining - amountOut);
        }
    }

    /// @dev NAV = feed answer, `scale` = 10 ** (tokenDecimals + feedDecimals - assetDecimals). The bid in ASSET base
    /// units per token base unit is NAV x (10,000 - bidDiscountBps) / (scale x 10,000).
    /// Exact-in (token in): out = floor(in x NAV x (10,000 - d) / (scale x 10,000)).
    /// Exact-out (ASSET out): in = ceil(out x scale x 10,000 / (NAV x (10,000 - d))).
    /// Both round in the maker's favour. The fill is then checked against the ceiling on the realised amounts:
    /// out x scale x 10,000 <= in x NAV x MAX_BID_BPS.
    function _bidAmounts(uint256 nav, uint256 scale, uint256 discountBps, bool exactInput, uint256 specified)
        private
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        uint256 num = nav * (BPS - discountBps);
        uint256 den = scale * BPS;
        if (exactInput) {
            amountIn = specified;
            amountOut = FullMath.mulDiv(amountIn, num, den);
        } else {
            amountOut = specified;
            amountIn = FullMath.mulDivRoundingUp(amountOut, den, num);
        }
        if (amountOut == 0) revert ZeroAmount();
        if (amountOut * den > amountIn * nav * MAX_BID_BPS) revert PriceAboveCeiling();
    }

    /// @dev t = min(block.timestamp - updatedAt, MAX_ACCRUAL). The ask in ASSET base units per token base unit is
    /// NAV x (10,000 x YEAR + askApyBps x t) x (10,000 + askPremiumBps) / (scale x 10,000 x YEAR x 10,000), with
    /// YEAR = 365 days: NAV x (1 + apy x t / YEAR) x (1 + premium).
    /// Exact-in (ASSET in): out = floor(in x den / num). Exact-out (token out): in = ceil(out x num / den).
    /// Both round in the maker's favour. The fill is then checked against the floor on the realised amounts:
    /// in x scale x 10,000 >= out x NAV x (10,000 + MIN_ASK_PREMIUM_BPS).
    function _askAmounts(
        uint256 nav,
        uint256 scale,
        uint256 updatedAt,
        Params memory p,
        bool exactInput,
        uint256 specified
    ) private view returns (uint256 amountIn, uint256 amountOut) {
        // A feed stamped in the future is broken; refuse rather than guess its age.
        if (updatedAt > block.timestamp) revert BadOracleAnswer();
        uint256 t = block.timestamp - updatedAt;
        if (t > MAX_ACCRUAL) t = MAX_ACCRUAL;
        uint256 num = nav * (BPS * YEAR + uint256(p.askApyBps) * t) * (BPS + p.askPremiumBps);
        uint256 den = scale * BPS * YEAR * BPS;
        if (exactInput) {
            amountIn = specified;
            amountOut = FullMath.mulDiv(amountIn, den, num);
        } else {
            amountOut = specified;
            amountIn = FullMath.mulDivRoundingUp(amountOut, num, den);
        }
        if (amountOut == 0) revert ZeroAmount();
        if (amountIn * scale * BPS < amountOut * nav * (BPS + MIN_ASK_PREMIUM_BPS)) revert PriceBelowFloor();
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
    /// PoolManager under the maker's allowance. Same sync/settle caveat as `_settleBid`.
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
