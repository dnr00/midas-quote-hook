// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Order} from "../../src/MorphoForceWithdrawPreInteraction.sol";

/// @dev Subset of 1inch Router v6 (Limit Order Protocol v4) used by the tests.
interface IRouterV6 {
    function hashOrder(Order calldata order) external view returns (bytes32);
    function fillOrderArgs(
        Order calldata order,
        bytes32 r,
        bytes32 vs,
        uint256 amount,
        uint256 takerTraits,
        bytes calldata args
    ) external payable returns (uint256 makingAmount, uint256 takingAmount, bytes32 orderHash);
    function fillContractOrderArgs(
        Order calldata order,
        bytes calldata signature,
        uint256 amount,
        uint256 takerTraits,
        bytes calldata args
    ) external returns (uint256 makingAmount, uint256 takingAmount, bytes32 orderHash);
    function remainingInvalidatorForOrder(address maker, bytes32 orderHash) external view returns (uint256);
    function increaseEpoch(uint96 series) external;
    function epoch(address maker, uint96 series) external view returns (uint256);
    function eq(uint256 value, bytes calldata data) external view returns (bool);
    function arbitraryStaticCall(address target, bytes calldata data) external view returns (uint256);
}

/// @dev Builds orders exactly as the off-chain signer must: bit layouts from LOP v4 MakerTraitsLib,
/// TakerTraitsLib, ExtensionLib and OffsetsLib.
library LopOrders {
    uint256 internal constant ALLOW_MULTIPLE_FILLS = 1 << 254;
    uint256 internal constant PRE_INTERACTION_CALL = 1 << 252;
    uint256 internal constant NEED_CHECK_EPOCH_MANAGER = 1 << 250;
    uint256 internal constant HAS_EXTENSION = 1 << 249;

    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(uint256 salt,address maker,address receiver,address makerAsset,address takerAsset,uint256 makingAmount,uint256 takingAmount,uint256 makerTraits)"
    );

    struct Spec {
        address maker;
        address receiver;
        address makerAsset;
        address takerAsset;
        uint256 makingAmount;
        uint256 takingAmount;
        uint40 expiration;
        uint40 epoch;
        uint40 series;
        address preInteraction; // zero: no pre-interaction
        bytes predicate; // empty: no predicate
        uint96 saltHigh;
    }

    function makerTraits(Spec memory s) internal pure returns (uint256 t) {
        t = ALLOW_MULTIPLE_FILLS | NEED_CHECK_EPOCH_MANAGER | (uint256(s.expiration) << 80) | (uint256(s.epoch) << 120)
            | (uint256(s.series) << 160);
        if (s.preInteraction != address(0)) t |= PRE_INTERACTION_CALL;
        if (s.preInteraction != address(0) || s.predicate.length > 0) t |= HAS_EXTENSION;
    }

    /// @dev Fields 0-3 and 5, 7 are empty; field 4 is the predicate, field 6 the pre-interaction target.
    function extension(Spec memory s) internal pure returns (bytes memory) {
        bytes memory pre = s.preInteraction == address(0) ? bytes("") : abi.encodePacked(s.preInteraction);
        if (pre.length == 0 && s.predicate.length == 0) return "";
        uint256 endPredicate = s.predicate.length;
        uint256 endPre = endPredicate + pre.length;
        uint256 offsets =
            (endPredicate << (32 * 4)) | (endPredicate << (32 * 5)) | (endPre << (32 * 6)) | (endPre << (32 * 7));
        return abi.encodePacked(offsets, s.predicate, pre);
    }

    function build(Spec memory s) internal pure returns (Order memory o, bytes memory ext) {
        ext = extension(s);
        uint256 salt = uint256(s.saltHigh) << 160;
        if (ext.length > 0) salt |= uint256(keccak256(ext)) & type(uint160).max;
        o = Order({
            salt: salt,
            maker: uint256(uint160(s.maker)),
            receiver: uint256(uint160(s.receiver)),
            makerAsset: uint256(uint160(s.makerAsset)),
            takerAsset: uint256(uint160(s.takerAsset)),
            makingAmount: s.makingAmount,
            takingAmount: s.takingAmount,
            makerTraits: makerTraits(s)
        });
    }

    /// @dev eq(round, arbitraryStaticCall(feed, latestRound())): true only while the feed is on the signed round.
    function roundPredicate(address feed, uint256 round) internal pure returns (bytes memory) {
        bytes memory latestRound = abi.encodeWithSignature("latestRound()");
        bytes memory call = abi.encodeCall(IRouterV6.arbitraryStaticCall, (feed, latestRound));
        return abi.encodeCall(IRouterV6.eq, (round, call));
    }

    function domainSeparator(address router) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("1inch Aggregation Router"),
                keccak256("6"),
                block.chainid,
                router
            )
        );
    }

    function digest(address router, Order memory o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(ORDER_TYPEHASH, o));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(router), structHash));
    }

    /// @dev amount is the taking amount (maker-amount flag unset); threshold is the minimum making amount.
    function takerTraits(uint256 extLength, uint256 minMakingAmount) internal pure returns (uint256) {
        return (extLength << 224) | minMakingAmount;
    }
}
