# Token & Supply Allocation (`NARATokenV5`)

## Token Identity

| Field | Verified Value |
|---|---|
| **Name** | `NARA` |
| **Symbol** | `NARA` |
| **Network** | Base Mainnet (Chain ID `8453`) |
| **Contract Address** | [`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`](https://basescan.org/address/0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f) |
| **Decimals** | `18` |
| **Fixed Total Supply** | **`1,000,000 NARA`** (`1,000,000 * 10^18` wei) |
| **Mint Capability** | **None** — Minted once at deployment; supply can never increase |
| **Contract Owner** | **None (`0x0000000000000000000000000000000000000000`)** |
| **Standards** | `ERC-20`, `ERC-20Permit` (EIP-2612 gasless approvals), `ERC-3156` (Flash Loans), `ERC-1363` (`transferAndCall` / `approveAndCall`), `Multicall` |

---

## Verified On-Chain Supply Allocation (Block `59,502,291`, `2026-11-19`)

Unlike traditional token launches that reserve 20%–40% of supply for team vesting, venture capital cliffs, or private bond discounts, **99.9945% (`999,944.60 NARA`) of all `NARA` is non-circulating inside verified V5 protocol contracts**, and `Treasury Safe` holds **`0.000000 NARA`** liquid (`Safe Nonce 29`):

| Allocation Bucket | Contract / Holder | Balance (`NARA`) | % of Supply | Custody & Release Rules |
|---|---|---:|---:|---|
| **1. Epoch Emission Reserve** | [`NARAEmissionReserveV5`](https://basescan.org/address/0xf932178F24b0813C82093985F0Af6Db27Ae25930) | **`949,834.95`** | **`94.9835%`** | **Ownerless & permanently sealed (`owner = 0x0`, `coreBound = true`)** to `NARAEpochEngineV5`. Funded with `949,987 NARA` (`94.9987%`) at genesis (`54,778,829`); no admin sweep exists, released strictly via 15-minute epochs (`96/day`). |
| **2. Committed Principal & Ownerless Genesis Shield** | [`NARAPrincipalLedgerV5`](https://basescan.org/address/0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2) & [`NARAGenesisShieldVaultV5`](https://basescan.org/address/0xe42aD8951f486f19E396Eb23bDE352BA92Dd2e56) | **`46,002.16`** | **`4.6002%`** | **`45,000.00 NARA`** sealed permanently inside ownerless `NARAGenesisShieldVaultV5` (`owner = 0x0`, `seedingClosed = true`, Positions `#6..#9` across `90d/180d/270d/365d`, recycling `100%` of rewards — `52.24 NARA` queued in `NARARewardLedgerV5` — and retiring `100%` of principal to `NARAEmissionReserveV5` at maturity) + **`1,002.16 NARA`** across active `>1d` commitments including `29` Wave 1 Vault Receipts (`#16..#44`). |
| **3. Two-Way Range Liquidity** | [`NARATreasuryRangeManagerV5`](https://basescan.org/address/0x221c625d2BC416460C397035C1286C1f4A4D3A7C) (`Legacy` [`0xa725...`](https://basescan.org/address/0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288) = `0.00`) | **`4,055.25`** | **`0.4055%`** | `4,050.41 NARA` in active vault + `4.8340 NARA` across `12` live upside rungs. The queued `49,997 NARA` migration from legacy `0xa725...` completed on `2026-11-14` (Block `57,380,992`), sealing `45,000 NARA` into ownerless `NARAGenesisShieldVaultV5`. Raw `NARA` withdrawals enforce a **7-day waiting period** (extendable to **1 year**). |
| **4. Open Circulating Supply** | DEX LPs (`v4` & `v3`), Unclaimed User Rewards, CryptoSLIP Vaults & Wallets | **`55.40`** | **`0.0055%`** | `0.000000 NARA` liquid in `Treasury Safe` (`Safe Nonce 29`, `586.25 USDC` + `0.0041 ETH`), `1.90 NARA` short-horizon (`<=1d` `#48`), `26.20 NARA` unclaimed user rewards in `NARARewardLedgerV5`, `2.80 NARA` across CryptoSLIP vaults (`v33` + `v32`), and `24.50 NARA` across Uniswap v4/v3 LP, `pNARA`, and wallets. |
| **Team / Founders / VCs** | — | **`0.00`** | **`0.0000%`** | **Zero team allocation, zero investor cliffs, zero advisor tokens.** |
| **Total Supply** | — | **`1,000,000.00`** | **`100.0000%`** | **Fixed forever** (`999,944.60 NARA` non-circulating incl. `52.24 NARA` Shield recycle queue). |

---

## Built-In Token Features

### 1. Zero Transfer Tax on Normal Wallet Transfers
Moving `NARA` between wallets, sending `NARA` via a **CryptoSLIP** link, or committing `NARA` into `NARAEpochEngineV5` incurs **0% token transfer tax**. Swap fees (`4.63%–20%`) apply only when trading inside the Uniswap v4 `NARA / USDC` pool via `NARALiquidityHookV5`.

### 2. ERC-20Permit (Gasless Approvals)
`NARATokenV5` supports EIP-2612 `permit()`, allowing users and integrated apps to approve token spending with a free off-chain signature instead of a separate approval transaction.

### 3. ERC-3156 Flash Loans (Revenue for Committed Holders)
`NARATokenV5` includes a native ERC-3156 flash-loan facility:
- **Maximum Flash Loan:** `100,000 NARA` (`10%` of total supply) temporarily borrowed per transaction.
- **Flash Fee:** `0.10%` (`10 bps`).
- **Fee Destination:** Every flash-loan fee is sent directly to `NARAEmissionReserveV5` (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`), replenishing the reward reserve for committed `NARA` holders. If the loan plus fee is not repaid within the same transaction, the entire transaction reverts.
