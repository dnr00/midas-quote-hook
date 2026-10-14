# MidasQuoteHook

A Uniswap v4 hook that makes a two-sided market in up to three Midas mTokens (mHYPER, mALPHA, mArb) against USDC,
priced from each token's Midas NAV feed at swap time. The maker's USDC stays deposited in a Morpho VaultV2 and earns
yield until a bid needs it; inside the swap the hook pulls exactly the USDC it needs out of the vault.

Status: prototype, **not deployed**. Its single-token, bid-only predecessor is live:
[morpho-funded-quote-hook](https://github.com/dnr00/morpho-funded-quote-hook).

## Pricing

Each token has one canonical pool: {token, USDC} sorted, static LP fee 0, tickSpacing 1, this hook. `beforeSwap`
(with `beforeSwapReturnsDelta`) fills the whole swap at the hook's price, so the AMM amount is always 0. The pool's
`sqrtPriceX96` is never used, liquidity added to the pool is never traded, and no v4 protocol fee can apply. Routers pass
empty `hookData`; nothing is signed off-chain.

| Side | Swapper | Price per token |
|---|---|---|
| Bid | sells the token | NAV x (1 - `bidDiscountBps`) |
| Ask | buys the token | NAV x (1 + `askApyBps` x min(now - `updatedAt`, `MAX_ACCRUAL`) / 365 days) x (1 + `askPremiumBps`) |

NAV is the feed's latest answer and `updatedAt` its timestamp, so the ask's linear accrual restarts from zero at every
new round and only the fixed premium remains. Rounding always favours the maker. Two immutable bounds hold whatever the
parameters: the bid never pays more than NAV x `MAX_BID_BPS`, and the ask never sells below NAV x
(1 + `MIN_ASK_PREMIUM_BPS`).

## Maker parameters

`setParams(token, Params)`, maker only, one set per token:

- `round`: the feed round both sides are valid for. It must be the feed's current round when a side opens, and a new
  round stops every fill until the maker re-posts. A quote can never fill against a NAV the maker has not seen.
- `validUntil`: the last timestamp either side fills.
- `bidDiscountBps`, `askPremiumBps`, `askApyBps`.
- `bidRemaining`, `askRemaining`: token amounts still bought or sold. Zero closes that side.

Kill switch: `validUntil = 0`, or both remainings 0. It skips every feed call, so it works even while a feed is broken.

## Settlement

- **Bid** (USDC out): paid first from the hook's USDC claims (proceeds of earlier asks). The rest comes from the maker's
  vault shares: if the vault's idle USDC is short, the hook calls `forceDeallocate` market by market for the shortfall
  (penalty must be 0), then `sync`, `VAULT.withdraw(amount, PoolManager, MAKER)`, `settle`. The swapper's token is
  taken as an ERC-6909 claim, because routers settle the input after the swap returns.
- **Ask** (token out): delivered first by burning the hook's token claims (inventory from earlier bids), the rest by
  `transferFrom(MAKER)` under the maker's token allowance. The swapper's USDC is taken as an ERC-6909 claim.
- **Sweep**: `sweep(currency)` and `sweepAll()` are permissionless with fixed destinations. Token claims go to `MAKER`.
  USDC claims, plus any USDC sent to the hook directly, are deposited into the vault for `MAKER`. If the vault refuses
  the deposit, the approval is reset and the USDC is transferred to `MAKER` instead.

Events: `ParamsSet`, `Filled`, `HookSwap` (OpenZeppelin uniswap-hooks `IHookEvents`), `Swept(currency, amount,
deposited)`.

## Safety properties

- No owner, not upgradeable. Every address and the token list are fixed in the constructor.
- Assets only ever move to `MAKER`, into the vault for `MAKER`, or out to a swapper at the hook's price.
- Exposure is bounded by the per-side remainings and by the maker's two approvals: vault shares (bid funding beyond USDC
  claims) and each token (ask delivery beyond token claims).
- The only state between transactions is ERC-6909 claims owed to `MAKER`.

## Known risks

- **NAV update ordering.** Midas feed updates are ordinary transactions. mALPHA's updates were observed in the public
  mempool 5 to 11 s before inclusion, and their calldata carries the new NAV. A watcher can sell into the old-round bid
  ahead of a falling update. Round binding stops everything after the update lands, so the loss per update is bounded
  by (drop - bid discount) x `bidRemaining`. Size the discount and remaining per token; the kill switch stops a token.
- The mTokens and feeds are upgradeable Midas proxies.
- A permissionless sweep can move ask inventory (token claims) to `MAKER`, after which asks need the maker's token
  allowance (liveness only, no loss).
- A caller that syncs and pays its input before calling `swap` reverts with `CurrencyNotSettled`; no value is lost.
  UniversalRouter's V4Router is unaffected.

## Tests

Mainnet-fork tests (Foundry) at a pinned block, swapping through the mainnet UniversalRouter with empty `hookData`.
`test/MidasQuoteHook.fork.t.sol` (45 tests) covers:

- bid and ask, exact-in and exact-out, for tokens sorted as currency0 and as currency1;
- force-deallocation, USDC-claim-funded bids, token-claim and allowance-funded asks;
- ask accrual, linear and then capped;
- round, validity, floor, ceiling and kill-switch guards;
- sweep and sweepAll, including the deposit fallback and stray USDC;
- liquidity in the pool never traded, the maximum protocol fee taking nothing, and V4Quoter parity.

```sh
git clone --recurse-submodules https://github.com/dnr00/midas-quote-hook
cd midas-quote-hook
MAINNET_RPC_URL=<your mainnet RPC> forge test
```

Build settings: solc 0.8.28, optimizer 1,000,000 runs, cancun, `bytecode_hash = "none"`, v4-core v4.0.0.

`src/MorphoForceWithdrawPreInteraction.sol` is a sibling 1inch Limit Order Protocol pre-interaction doing the same
Morpho funding; the hook imports its interface declarations.

## Review status

Reviewed internally by several independent model reviewers, adversarial and correctness passes. There is no
third-party audit.
