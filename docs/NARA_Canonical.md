# NARA v4 overview

This is the shortest complete description of the active protocol.

NARA v4 is an experimental fixed-outstanding-supply token and protocol stack on
Base. There are 1,000,000 permanently outstanding NARA and no admin mint
function. The token also supports a code-controlled, same-transaction ERC-3156
flash mint capped at 100,000 temporary NARA. A 650,000 NARA reward reserve is
deployed and sealed. Other contracts supporting the planned protocol have been
deployed, but the public product is not active.

The official NARA/USDC Uniswap v4 pool is registered but uninitialized. No
official liquidity has been added, so official pool-based buying and selling is
not available. The baskets application is the only planned launch interface and
remains in preview until verified deployment manifests exist.

Mining, jackpot, and all v3 contracts are retired. Bonds and the lockboard are
deferred. The old v3 Lotto and Arena implementations are inactive; possible v4
rebuilds are deferred. Do not use historical deployments as current services.

The canonical token address is:

```text
0x65E247AA3aa9C0131b2984b894c3D24c41341D7A
```

For component addresses and activation state, use
[Current state](CURRENT_STATE.md). For supply accounting, use
[Token and allocation](TOKEN_AND_ALLOCATION.md). For implementation details,
use the [public verification package](../verification/README.md).

No page, roadmap, deployment, or token allocation promises a market, value,
return, reward, launch date, or continued development.
