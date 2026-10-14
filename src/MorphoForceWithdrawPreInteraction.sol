// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev 1inch Limit Order Protocol v4 order. `Address` and `MakerTraits` are uint256 user-defined value types in the
/// protocol, so this struct is ABI-identical and the `preInteraction` selector matches `IPreInteraction`.
struct Order {
    uint256 salt;
    uint256 maker;
    uint256 receiver;
    uint256 makerAsset;
    uint256 takerAsset;
    uint256 makingAmount;
    uint256 takingAmount;
    uint256 makerTraits;
}

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IVaultV2 {
    function asset() external view returns (address);
    function isAdapter(address account) external view returns (bool);
    function forceDeallocatePenalty(address adapter) external view returns (uint256);
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256);
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256);
}

interface IMorphoMarketV1AdapterV2 {
    function parentVault() external view returns (address);
    function morpho() external view returns (address);
    function marketIdsLength() external view returns (uint256);
    function marketIds(uint256 index) external view returns (bytes32);
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}

interface IMorpho {
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title MorphoForceWithdrawPreInteraction
/// @notice 1inch LOP v4 pre-interaction that funds one maker's USDC-for-mToken orders just in time from a Morpho
/// VaultV2 whose capital sits in Morpho Market V1 markets: it force-deallocates the shortfall market by market, then
/// withdraws exactly the fill's making amount to the maker. The router then moves that USDC from the maker to the taker.
/// @dev Stateless, ownerless, not upgradeable, holds no tokens. Every address is immutable and assets only ever move
/// to MAKER (withdraw receiver) or back into VAULT (deallocation). Requires two maker approvals: VAULT shares to this
/// contract (bounds the funding exposure) and ASSET to the router.
contract MorphoForceWithdrawPreInteraction {
    error NotRouter();
    error WrongMaker();
    error WrongMakerAsset();
    error WrongTakerAsset();
    error WrongReceiver();
    error BadOracleAnswer();
    error PriceAboveCeiling();
    error PenaltyNotZero();
    error InsufficientLiquidity(uint256 shortfall);
    error BadConfig();

    uint256 private constant BPS = 10_000;

    address public immutable ROUTER;
    IVaultV2 public immutable VAULT;
    IMorphoMarketV1AdapterV2 public immutable MARKET_ADAPTER;
    IMorpho public immutable MORPHO;
    address public immutable ASSET;
    address public immutable MAKER;
    address public immutable TAKER_ASSET;
    IAggregatorV3 public immutable FEED;
    /// @notice The most the maker ever pays per taker-asset unit, in bps of the feed answer.
    uint256 public immutable MAX_PRICE_BPS;
    /// @dev 10 ** (takerAssetDecimals + feedDecimals - assetDecimals).
    uint256 public immutable PRICE_SCALE;

    constructor(
        address router,
        address vault,
        address marketAdapter,
        address maker,
        address takerAsset,
        address feed,
        uint256 maxPriceBps
    ) {
        if (
            router == address(0) || vault == address(0) || marketAdapter == address(0) || maker == address(0)
                || takerAsset == address(0) || feed == address(0) || maxPriceBps == 0 || maxPriceBps > BPS
        ) revert BadConfig();
        if (IMorphoMarketV1AdapterV2(marketAdapter).parentVault() != vault) revert BadConfig();
        if (!IVaultV2(vault).isAdapter(marketAdapter)) revert BadConfig();
        if (takerAsset == IVaultV2(vault).asset()) revert BadConfig();

        ROUTER = router;
        VAULT = IVaultV2(vault);
        MARKET_ADAPTER = IMorphoMarketV1AdapterV2(marketAdapter);
        MORPHO = IMorpho(IMorphoMarketV1AdapterV2(marketAdapter).morpho());
        ASSET = IVaultV2(vault).asset();
        MAKER = maker;
        TAKER_ASSET = takerAsset;
        FEED = IAggregatorV3(feed);
        MAX_PRICE_BPS = maxPriceBps;

        uint256 assetDecimals = IERC20(ASSET).decimals();
        uint256 scaleDecimals = uint256(IERC20(takerAsset).decimals()) + IAggregatorV3(feed).decimals();
        if (scaleDecimals < assetDecimals) revert BadConfig();
        PRICE_SCALE = 10 ** (scaleDecimals - assetDecimals);
    }

    /// @notice Called by the router after the order's signature, expiry, epoch and predicate checks and before the
    /// maker asset transfer.
    function preInteraction(
        Order calldata order,
        bytes calldata, /* extension */
        bytes32, /* orderHash */
        address, /* taker */
        uint256 makingAmount,
        uint256 takingAmount,
        uint256, /* remainingMakingAmount */
        bytes calldata /* extraData */
    ) external {
        if (msg.sender != ROUTER) revert NotRouter();
        if (address(uint160(order.maker)) != MAKER) revert WrongMaker();
        if (address(uint160(order.makerAsset)) != ASSET) revert WrongMakerAsset();
        if (address(uint160(order.takerAsset)) != TAKER_ASSET) revert WrongTakerAsset();
        address receiver = address(uint160(order.receiver));
        if (receiver != address(0) && receiver != MAKER) revert WrongReceiver();

        // Ceiling against the live feed, independent of the price the order was signed at.
        (, int256 answer,,,) = FEED.latestRoundData();
        if (answer <= 0) revert BadOracleAnswer();
        if (makingAmount * PRICE_SCALE * BPS > takingAmount * uint256(answer) * MAX_PRICE_BPS) {
            revert PriceAboveCeiling();
        }

        uint256 idle = IERC20(ASSET).balanceOf(address(VAULT));
        if (idle < makingAmount) _deallocate(makingAmount - idle);

        VAULT.withdraw(makingAmount, MAKER, MAKER);
    }

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

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
