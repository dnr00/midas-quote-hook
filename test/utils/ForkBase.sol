// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {MorphoForceWithdrawPreInteraction, Order} from "../../src/MorphoForceWithdrawPreInteraction.sol";
import {IRouterV6, LopOrders} from "./LopOrders.sol";
import {Mainnet} from "./Mainnet.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IVaultV2Like is IERC20Like {
    function totalAssets() external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function forceDeallocatePenalty(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IMarketAdapterLike {
    function marketIdsLength() external view returns (uint256);
    function marketIds(uint256) external view returns (bytes32);
    function expectedSupplyAssets(bytes32) external view returns (uint256);
}

interface IMorphoLike {
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
}

interface IFeedLike {
    function latestRound() external view returns (uint80);
    function lastAnswer() external view returns (int256);
    function setRoundDataSafe(int256 data) external;
}

/// @dev Mainnet-fork fixture shared by the unit and invariant suites: deploys the pre-interaction for a test
/// maker, moves existing vault shares to it (vault idle stays zero) and funds a seller with mArb.
abstract contract ForkBase is Test {
    uint256 constant FORK_BLOCK = Mainnet.FORK_BLOCK;
    address constant ROUTER = Mainnet.ROUTER;
    address constant VAULT = Mainnet.VAULT;
    address constant MARKET_ADAPTER = Mainnet.MARKET_ADAPTER;
    address constant MORPHO = Mainnet.MORPHO;
    address constant USDC = Mainnet.USDC;
    address constant MARB = Mainnet.MARB;
    address constant FEED = Mainnet.FEED;
    address constant FEED_UPDATER = Mainnet.FEED_UPDATER;

    uint256 constant MAX_PRICE_BPS = 9_990; // never pay more than 99.90% of NAV
    uint256 constant DISCOUNT_BPS = 50; // the signer quotes NAV - 0.50%
    uint96 constant SERIES = 7;

    bytes32 constant FORCE_DEALLOCATE_TOPIC =
        keccak256("ForceDeallocate(address,address,uint256,address,bytes32[],uint256)");

    IRouterV6 router = IRouterV6(ROUTER);
    IVaultV2Like vault = IVaultV2Like(VAULT);
    MorphoForceWithdrawPreInteraction pre;

    uint256 makerPk = 0xA11CE;
    address maker;
    address seller = makeAddr("seller");

    function _setUpFork() internal {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        maker = vm.addr(makerPk);
        pre = new MorphoForceWithdrawPreInteraction(ROUTER, VAULT, MARKET_ADAPTER, maker, MARB, FEED, MAX_PRICE_BPS);

        _fundMakerShares(5_000_000e6);

        vm.startPrank(maker);
        vault.approve(address(pre), type(uint256).max);
        IERC20Like(USDC).approve(ROUTER, type(uint256).max);
        vm.stopPrank();

        deal(MARB, seller, 10_000_000e18);
        vm.prank(seller);
        IERC20Like(MARB).approve(ROUTER, type(uint256).max);

        assertEq(IERC20Like(USDC).balanceOf(VAULT), 0, "precondition: vault idle is zero");
        assertEq(uint256(IFeedLike(FEED).latestRound()), 2, "precondition: feed round");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Moves existing shares (no new assets, so idle stays zero) from the largest holders at FORK_BLOCK
    /// (Multicall3 balanceOf over every Transfer recipient).
    function _fundMakerShares(uint256 assetsWanted) internal {
        address[8] memory holders = [
            0x933aDeDd85824dA75ec8a334a7907e69e7c02833,
            0x68e7E72938db36a5CBbCa7b52c71DBBaaDfB8264,
            0x08d49c032f268D3AC4265d1909c28DfaAb440040,
            0x79Ce4692Ca056F71dB460815E8fE66ceC26cfBa3,
            0xea32a33300D64BDdB9f09A8308D44c23616eC706,
            0x51a37969dcb027636e4B080F5b4a97D10625e925,
            0xE4136EA71e7FD3218AB28aC94ba43efE2c3b5884,
            0x23c4b0E39266934cc0A9019D2C2d6950c38B7a67
        ];
        uint256 sharesWanted = vault.previewWithdraw(assetsWanted);
        for (uint256 i; i < holders.length && vault.balanceOf(maker) < sharesWanted; ++i) {
            uint256 bal = vault.balanceOf(holders[i]);
            uint256 take = sharesWanted - vault.balanceOf(maker);
            if (take > bal) take = bal;
            if (take == 0) continue;
            vm.prank(holders[i]);
            vault.transfer(maker, take);
        }
        require(vault.balanceOf(maker) >= sharesWanted, "not enough holder shares on fork");
    }

    function _nav() internal view returns (uint256) {
        return uint256(IFeedLike(FEED).lastAnswer());
    }

    /// @dev USDC (6dp) the signer pays for `marbAmount` (18dp) at NAV (8dp) minus `discountBps`, rounded down.
    function _quote(uint256 marbAmount, uint256 discountBps) internal view returns (uint256) {
        return marbAmount * _nav() * (10_000 - discountBps) / 1e20 / 10_000;
    }

    function _spec(uint256 takingMarb, uint256 discountBps) internal view returns (LopOrders.Spec memory s) {
        s = LopOrders.Spec({
            maker: maker,
            receiver: address(0),
            makerAsset: USDC,
            takerAsset: MARB,
            makingAmount: _quote(takingMarb, discountBps),
            takingAmount: takingMarb,
            expiration: uint40(block.timestamp + 1 hours),
            epoch: uint40(router.epoch(maker, SERIES)),
            series: uint40(SERIES),
            preInteraction: address(pre),
            predicate: LopOrders.roundPredicate(FEED, IFeedLike(FEED).latestRound()),
            saltHigh: 1
        });
    }

    function _sign(uint256 pk, Order memory o) internal view returns (bytes32 r, bytes32 vs) {
        (uint8 v, bytes32 r_, bytes32 s) = vm.sign(pk, router.hashOrder(o));
        r = r_;
        vs = bytes32((uint256(v - 27) << 255) | uint256(s));
    }

    function _fill(Order memory o, bytes memory ext, uint256 pk, uint256 takingMarb, uint256 minUsdc)
        internal
        returns (uint256 making, uint256 taking)
    {
        (bytes32 r, bytes32 vs) = _sign(pk, o);
        vm.prank(seller);
        (making, taking,) = router.fillOrderArgs(o, r, vs, takingMarb, LopOrders.takerTraits(ext.length, minUsdc), ext);
    }

    function _expectFillRevert(Order memory o, bytes memory ext, uint256 pk, uint256 takingMarb, bytes memory err)
        internal
    {
        (bytes32 r, bytes32 vs) = _sign(pk, o);
        uint256 tt = LopOrders.takerTraits(ext.length, 0);
        vm.prank(seller);
        vm.expectRevert(err);
        router.fillOrderArgs(o, r, vs, takingMarb, tt, ext);
    }

    function _countForceDeallocations(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == VAULT && logs[i].topics[0] == FORCE_DEALLOCATE_TOPIC) ++n;
        }
    }

    function _assertAdapterHoldsNothing() internal view {
        assertEq(IERC20Like(USDC).balanceOf(address(pre)), 0, "adapter USDC");
        assertEq(IERC20Like(MARB).balanceOf(address(pre)), 0, "adapter mArb");
        assertEq(vault.balanceOf(address(pre)), 0, "adapter shares");
    }
}
