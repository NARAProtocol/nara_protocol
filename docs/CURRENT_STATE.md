# Current state

Last verified deployment checkpoint: **2026-08-09**

This page separates deployed blockchain facts, activated protocol paths, and
user-facing availability. “Deployed” or “activated” does not mean every NARA
product is available.

Verification checkpoint:

| Item | Value |
|---|---|
| Network | Base mainnet |
| Chain ID | `8453` |
| Verification block | `49736809` |
| Deployed source commit | `027af3f06bbe6dea2c187dfd8062e50c228f1c35` |
| Public evidence | [`verification/deployment.json`](../verification/deployment.json) |

## Canonical v4 deployment

| Component | Address | State |
|---|---|---|
| NARA token | [`0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1`](https://basescan.org/address/0xB6333F5D4cEd8dffA80F3F13697D6aA3BB3f19c1#code) | Source-verified; 1,000,000 permanently outstanding NARA |
| Launcher | [`0xb8CF0274d0Fb2dB2Ba5dC58b0Ab378F3b8f35BA2`](https://basescan.org/address/0xb8CF0274d0Fb2dB2Ba5dC58b0Ab378F3b8f35BA2#code) | Source-verified deployment utility |
| Engine | [`0x98ab6406D6B548F37dEF7110961bb45A399e5aFC`](https://basescan.org/address/0x98ab6406D6B548F37dEF7110961bb45A399e5aFC#code) | Source-verified; public locking flow remains separately gated |
| Reward reserve | [`0x8369CEf28128A4B24Bc5ed52aA6196D92D563F2f`](https://basescan.org/address/0x8369CEf28128A4B24Bc5ed52aA6196D92D563F2f#code) | Source-verified and funded with 650,000 NARA at deployment |
| Liquidity vault | [`0xD7f7b44BF65EBa3E90fDe0642687ed22A323084D`](https://basescan.org/address/0xD7f7b44BF65EBa3E90fDe0642687ed22A323084D#code) | Source-verified; Safe-owned; Compounder binding frozen |
| Hook deployer | [`0xDE9E3Cac08b7a31Db18c7432d4C45DF4584Fd646`](https://basescan.org/address/0xDE9E3Cac08b7a31Db18c7432d4C45DF4584Fd646#code) | Source-verified; Safe-owned |
| Pool hook | [`0x59AEf9799DEA01A7FB7dA73BEA10dfB08858A088`](https://basescan.org/address/0x59AEf9799DEA01A7FB7dA73BEA10dfB08858A088#code) | Source-verified; Safe-owned; canonical pool registered |
| Compounder | [`0xfeFcc45C0454D022586eaA8a5c51BD25DCe713DF`](https://basescan.org/address/0xfeFcc45C0454D022586eaA8a5c51BD25DCe713DF#code) | Source-verified; validated; owns LP NFT `2898486` |

“Source-verified” means Basescan publishes matching source information. It is
not an independent security audit, warranty, or statement of economic safety.

External Base infrastructure:

| Component | Address |
|---|---|
| Native USDC | [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) |
| Uniswap v4 PoolManager | [`0x498581fF718922c3f8e6A244956aF099B2652b2b`](https://basescan.org/address/0x498581fF718922c3f8e6A244956aF099B2652b2b) |
| Uniswap v4 PositionManager | [`0x7C5f5A4bBd8fD63184577525326123B519429bDc`](https://basescan.org/address/0x7C5f5A4bBd8fD63184577525326123B519429bDc) |

Canonical NARA/USDC pool ID:

```text
0x83edced1f39e6adf7469cd718eeb409824d948959263408d4cfb6e745c8db464
```

## Activated liquidity path

- Safe transaction
  [`0xaeb7c336…24799`](https://basescan.org/tx/0xaeb7c3365354de633dde977d9b2c951b240f6b8ff8be090cdd989edc4c924799)
  registered, initialized, and seeded the pool at block `49721188`.
- The initial full-range position used `60,000 NARA + 300 USDC` and minted LP
  NFT `2898124` to the production Safe.
- Receipt-pinned exact-input buys and sells exercised and reconciled the Hook,
  Vault records, token transfers, and fees.
- Compounder validation minted LP NFT `2898486`; a separate transaction then
  permanently froze the Vault’s Compounder binding.
- At verification block `49736809`, total active PoolManager liquidity was
  `4252096511257072`. This is Uniswap liquidity-unit accounting, not a dollar
  value or guarantee of executable depth.
- Exact-output swaps through this Hook are unsupported. Third-party pools and
  ordinary ERC-20 transfers are outside the canonical Hook fee path.

Later balances, prices, fee settings, and liquidity quantities require a fresh
block-pinned read. The checkpoint proves activation; it does not promise a
current price, minimum depth, or exit.

## Custody

The production admin is a `2-of-3` Safe at
`0xd65c0e390Dc187A22c52c03816591CC736C0D755`. At the checkpoint, Hook, Vault,
and Compounder ownership had been accepted by the Safe, and the Vault’s
Compounder binding was permanently frozen.

Multisignature custody reduces single-key risk but does not remove signer,
configuration, contract, or operational risk.

## Deployed but not publicly available

- The Engine exists, but the public lock, claim, and unlock user journey retains
  separate lifecycle, interface, monitoring, and release gates.
- A Position NFT baseline was deployed later under separate evidence, but its
  downstream integration and user-facing flow are not available from this
  liquidity checkpoint.
- The baskets application remains preview-only until its own manager, adapter,
  deployment, integration, and exit-path evidence passes.

## Deferred or unavailable

- Public basket transactions
- Public locking and reward claims
- Bonds
- Lockboard
- General public router and dashboard integration
- Composability products

## Retired

- Controlled Stage A and earlier incident deployments
- All v3 protocol contracts
- Mining and auto-mining behavior
- Jackpot behavior
- Old v3 keeper and cron assumptions

Retired contracts remain visible onchain because blockchain history cannot be
deleted. They are not current addresses or integration fallbacks.

## Historical products

The old v3 Lotto and Arena implementations are inactive and unsupported. Any
future v4 rebuild would require new source, deployment, and availability
evidence and is not part of the current launch.

## Transaction evidence

| Event | Block | Transaction |
|---|---:|---|
| Launcher deployment | 49718976 | [`0xcce4ab…fa9d78`](https://basescan.org/tx/0xcce4ab3a2e1b8da44321dc2f6e3f42802416585d46b03b1569c991ca7cfa9d78) |
| Token and Engine launch | 49718979 | [`0x009559…076c`](https://basescan.org/tx/0x00955909b2fc299fe010c72ecd9988dc8802ad0569a3964453287e221ff5076c) |
| Atomic pool activation | 49721188 | [`0xaeb7c3…24799`](https://basescan.org/tx/0xaeb7c3365354de633dde977d9b2c951b240f6b8ff8be090cdd989edc4c924799) |
| Compounder validation | 49736646 | [`0xf1ea7e…5890be`](https://basescan.org/tx/0xf1ea7e7dfdf8e1021ceebf26a943cba604e0a8c894eec5f527bc01656b5890be) |
| Compounder binding freeze | 49736809 | [`0xccd73c…084ef3`](https://basescan.org/tx/0xccd73cf07602f18412bea291812f0d171fa5cabd41fcff6b6894029978084ef3) |

## How to verify

Use a Base explorer and paste the full address. Confirm the network, compare
every character, inspect the source and transaction evidence, and check whether
this checkpoint has been superseded. Never rely only on a ticker, logo, wallet
search result, or social post.
