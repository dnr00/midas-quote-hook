// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Ethereum mainnet addresses and the pinned fork block. State observed at FORK_BLOCK: vault idle = 0, no
/// liquidity adapter, one MorphoMarketV1AdapterV2 over 13 markets, forceDeallocatePenalty = 0, mArb/USD round 2 at
/// 1.00000000.
library Mainnet {
    uint256 internal constant FORK_BLOCK = 26_188_227;

    address internal constant ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65; // 1inch Router v6 = LOP v4
    address internal constant VAULT = 0x093272C07700d3cA5301C3Bf9B3A392624179E2F; // Hyperithm USDC Apex (VaultV2)
    address internal constant MARKET_ADAPTER = 0x92872B97d89B54646D036E3aFd2BcCb84d8e3CA1;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MARB = 0xee53eE4c6532cF81B63EA49bE4bbDB0c2aB398be;
    address internal constant FEED = 0xDf5B71c27A3639455B160e0D78D6D3248EA5a718; // mArb/USD, 8 decimals
    address internal constant FEED_UPDATER = 0x9ba743471f8AF2A951c69C400f7669eC1660cD0A; // calls setRoundDataSafe
}
