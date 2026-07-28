# Technical architecture

## System layers

```text
User wallet
    |
    v
Baskets interface (preview only)
    |
    v
Periphery and verified deployment manifests (not complete)
    |
    +--> NARA v4 token
    +--> NARA engine and reward reserve
    +--> NARA/USDC Uniswap v4 pool and hook
    |
    v
Base network and third-party infrastructure
```

Each layer has a different job:

- The **interface** explains and prepares user-selected actions.
- **Periphery contracts** should coordinate actions without changing frozen core
  behavior.
- The **token** records NARA balances and transfers.
- The **engine** contains v4 protocol accounting.
- The **reward reserve** holds the sealed reward allocation.
- The **pool hook** integrates planned NARA/USDC pool behavior with Uniswap v4.
- The **compounder** supports planned fee handling but is not frozen.
- **Base, Uniswap, and USDC** are external systems NARA does not control.

## Source of truth

The public docs simplify the system. Integration code must use the exact v4
artifacts, ABIs, source snapshot, and sanitized deployment manifest in the
[public verification package](../verification/README.md). Archived v3 contracts
must not be imported or called.

## Immutability and controls

“Onchain” does not always mean immutable. Some contracts can expose roles,
configuration, or emergency controls. Current administration also uses EOAs,
which creates single-key risk. Review actual source, role assignments, ownership,
and verified state instead of relying on labels such as decentralized or
trustless.

## Integration rule

An integration must fail closed when a required manifest, address, chain ID,
ABI, or verification result is absent. It must never silently substitute a
historical address.

## Not part of active architecture

- v3 token, engine, or reward contracts
- mining or auto-mining
- jackpot behavior
- old v3 Lotto and Arena implementations
- historical keepers and cron jobs
- experimental omnichain token code

Lotto and Arena may be reconsidered as clean v4 projects later. They have no
active v4 architecture or current launch role.

See [Current state](CURRENT_STATE.md) for exact deployed addresses and
[Admin powers](ADMIN_POWERS.md) for control risks.
