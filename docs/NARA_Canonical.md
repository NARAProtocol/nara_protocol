# NARA v4 overview

NARA v4 is an experimental fixed-outstanding-supply token and protocol stack on
Base. There are 1,000,000 permanently outstanding NARA and no admin mint
function. The token also supports a same-transaction ERC-3156 flash mint capped
at 100,000 temporary NARA.

The canonical token address is:

```text
0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1
```

The fresh core and liquidity contracts are deployed and source-verified. The
canonical NARA/USDC Uniswap v4 pool is registered, initialized, and seeded.
Receipt-pinned exact-input buy and sell tests verified the Hook fee path, and
the Compounder passed bounded validation before its Vault binding was frozen.

This liquidity activation does not make every product available. The baskets
application remains preview-only, the public locking journey remains gated,
and bonds, Lockboard, and composability products are unavailable or deferred.

Mining, jackpot behavior, the controlled Stage A deployment, and all v3
contracts are retired. Old v3 Lotto and Arena implementations are inactive; any
future v4 rebuild requires separate evidence.

For component addresses and activation state, use [Current state](CURRENT_STATE.md).
For pool evidence, use [Liquidity](LIQUIDITY.md). For implementation details,
use the [public verification package](../verification/README.md).

No page, roadmap, deployment, or token allocation promises a market, value,
return, reward, launch date, or continued development.
