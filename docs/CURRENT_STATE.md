# Current state

Last verified: **2026-07-28**

This page separates blockchain facts from future plans.

## Deployed on Base

| Component | Address | Current state |
|---|---|---|
| NARA token | `0x65E247AA3aa9C0131b2984b894c3D24c41341D7A` | Fixed supply created |
| Launcher | `0x90505C8c382519B168C6ab773Ed15D5ac99c9956` | Stage A deployment record |
| Engine | `0xbC2492BA73dE35d1114b5c18d7db633aca8963c9` | Deployed; public lock/reward use not activated |
| Reward reserve | `0x5F3FF409b74395b031e0C5D6abdD7D8895d2c7AD` | Holds 650,000 NARA and is sealed |
| Vault | `0xc0cf9bCf8879182368b1CdBDC81B6a143fFA2988` | Deployed; current verified balances are zero |
| Hook deployer | `0xC045644303E43cbb1E3c3E3fC851246F5c590834` | Deployment utility |
| Pool hook | `0x9a01c2DcF713cDB12B8ef4Eb264D5c3203b06088` | Registered with the planned pool |
| Compounder | `0xc327e50c14002a82c9F1477122204BB183f446Ab` | Wired and source-verified; not frozen |

External Base infrastructure:

| Component | Address |
|---|---|
| Native USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Uniswap v4 PositionManager | `0x7C5f5A4bBd8fD63184577525326123B519429bDc` |

Planned pool identifier:

```text
0xbb3287f32b95e96301c9582e8bf7e81fa362e4b9eea00cf016c537cf5970dff3
```

## Verified but not activated

- The planned NARA/USDC pool is registered but uninitialized.
- The pool has no official liquidity and no LP NFT.
- The protocol-side NARA depth is 60,000 NARA.
- The baskets application remains preview-only and must fail closed until
  verified basket manager and adapter manifests exist.
- The compounder is not frozen.

These facts mean that deployment is incomplete from a user's point of view.
Do not interpret deployed contracts as permission or readiness to transact.

## Not deployed or deferred

- Basket manager and launch adapter manifests
- Public position NFT
- Public bonds
- Public lockboard
- General-purpose router and public lenses
- Activated public locking and reward claims

## Retired

- All v3 protocol contracts
- Mining and auto-miner behavior
- Jackpot and lotto behavior
- Arena
- Old keeper and cron assumptions

Retired contracts may still exist onchain because blockchain history cannot be
deleted. Their existence does not make them current or supported.

## Custody warning

The final Stage A admin and treasury are currently externally owned accounts
rather than a Safe multisignature wallet. That creates key-person and
single-key-compromise risk. Safe migration and custody acceptance are launch
requirements, not completed protections.

## How to verify

Use a Base block explorer and paste the full address. Confirm:

1. the network is Base;
2. every character matches this page;
3. the contract source and observed state match the intended component; and
4. this page has not been superseded by a newer verified release.

Never rely only on a token logo, ticker, wallet search result, or social post.
