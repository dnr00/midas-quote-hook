// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @dev IV4Router.ExactInputSingleParams as the mainnet UniversalRouter decodes it.
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @dev IV4Router.ExactOutputSingleParams.
struct ExactOutputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountOut;
    uint128 amountInMaximum;
    bytes hookData;
}

/// @dev IV4Quoter.QuoteExactSingleParams.
struct QuoteExactSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IV4Quoter {
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IMHyperFeed {
    function latestRound() external view returns (uint80);
    function setRoundData(int256 data) external;
}

interface IVaultCurator {
    function submit(bytes calldata data) external;
    function setForceDeallocatePenalty(address adapter, uint256 penalty) external;
}
