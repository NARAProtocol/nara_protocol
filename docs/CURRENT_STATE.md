# Current state

Last verified: **2026-07-28**

This page separates blockchain facts from future plans.

Verification checkpoint:

| Item | Value |
|---|---|
| Network | Base mainnet |
| Chain ID | `8453` |
| Verification block | `49217567` |
| Public evidence | [`verification/deployment.json`](../verification/deployment.json) |

## Deployed on Base

| Component | Address | Current state | Blockscout source |
|---|---|---|---|
| NARA token | [`0x65E247AA3aa9C0131b2984b894c3D24c41341D7A`](https://base.blockscout.com/address/0x65E247AA3aa9C0131b2984b894c3D24c41341D7A?tab=contract) | 1,000,000 permanently outstanding; temporary flash mint supported | Verified |
| Launcher | [`0x90505C8c382519B168C6ab773Ed15D5ac99c9956`](https://base.blockscout.com/address/0x90505C8c382519B168C6ab773Ed15D5ac99c9956?tab=contract) | Stage A deployment record | Verified |
| Engine | [`0xbC2492BA73dE35d1114b5c18d7db633aca8963c9`](https://base.blockscout.com/address/0xbC2492BA73dE35d1114b5c18d7db633aca8963c9?tab=contract) | Deployed; public lock/reward use not activated | **Not verified there at checkpoint** |
| Reward reserve | [`0x5F3FF409b74395b031e0C5D6abdD7D8895d2c7AD`](https://base.blockscout.com/address/0x5F3FF409b74395b031e0C5D6abdD7D8895d2c7AD?tab=contract) | Holds 650,000 NARA and is sealed | Verified |
| Vault | [`0xc0cf9bCf8879182368b1CdBDC81B6a143fFA2988`](https://base.blockscout.com/address/0xc0cf9bCf8879182368b1CdBDC81B6a143fFA2988?tab=contract) | Deployed; current verified balances are zero | Verified |
| Hook deployer | [`0xC045644303E43cbb1E3c3E3fC851246F5c590834`](https://base.blockscout.com/address/0xC045644303E43cbb1E3c3E3fC851246F5c590834?tab=contract) | Deployment utility | Verified |
| Pool hook | [`0x9a01c2DcF713cDB12B8ef4Eb264D5c3203b06088`](https://base.blockscout.com/address/0x9a01c2DcF713cDB12B8ef4Eb264D5c3203b06088?tab=contract) | Registered with the planned pool | Verified |
| Compounder | [`0xc327e50c14002a82c9F1477122204BB183f446Ab`](https://base.blockscout.com/address/0xc327e50c14002a82c9F1477122204BB183f446Ab?tab=contract) | Wired; not frozen | Verified |

“Verified” in the last column means Blockscout displayed matching source code at
the checkpoint. It is not a security audit or guarantee. The engine's release
source, artifact, address, and runtime hash are public in the
[verification package](../verification/README.md), but third-party explorer
source verification remains outstanding.

External Base infrastructure:

| Component | Address |
|---|---|
| Native USDC | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://base.blockscout.com/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) |
| Uniswap v4 PoolManager | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://base.blockscout.com/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| Uniswap v4 PositionManager | [`0x7C5f5A4bBd8fD63184577525326123B519429bDc`](https://base.blockscout.com/address/0x7C5f5A4bBd8fD63184577525326123B519429bDc) |

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
- Jackpot behavior
- Old keeper and cron assumptions

Retired contracts may still exist onchain because blockchain history cannot be
deleted. Their existence does not make them current or supported.

## Historical products deferred for possible v4 rebuilding

- Lotto
- Arena

Their old v3 implementations are inactive and unsupported. A possible future v4
rebuild has not been deployed, activated, or scheduled and is not part of the
current launch.

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

## Transaction evidence

| Event | Block | Transaction |
|---|---:|---|
| Launcher deployment | 49148235 | [`0x144407…f23740`](https://base.blockscout.com/tx/0x144407ea7a0bb623162e4a9c90d10e4154110a487f7d838aeaa2bc68d5f23740) |
| Token and engine launch | 49148334 | [`0x65180b…052783`](https://base.blockscout.com/tx/0x65180bee366a8af820f6be0c83bdd309557511b93c90f57241fca8830b052783) |
| Hook deployment | 49148343 | [`0x25f795…2cd0c`](https://base.blockscout.com/tx/0x25f795d491c63dffae66b9ba1d68531c469bd850aa543616472704d44ee2cd0c) |
| Pool registration | 49148421 | [`0xa72c30…bc7b6`](https://base.blockscout.com/tx/0xa72c306796071f1dd734dd9b71f22cfa85d7e36fcd6feea17e870d33005bc7b6) |
| Compounder deployment | 49153244 | [`0x918d77…99b93`](https://base.blockscout.com/tx/0x918d77fa343a713f4ce85f2eb89f8f485e73b602e162baabba562a2a51f99b93) |
| NARA depth execution | 49215671 | [`0x86d6f3…2b6ba`](https://base.blockscout.com/tx/0x86d6f37b9d35040a3bd1a89c6d0fe398b4ba65f7ce5a06a7360d80c75e12b6ba) |
