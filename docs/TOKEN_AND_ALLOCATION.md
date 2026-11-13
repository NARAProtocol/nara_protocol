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

## Verified On-Chain Supply Allocation (Block `56,767,987`)

Unlike traditional token launches that reserve 20%–40% of supply for team vesting, venture capital cliffs, or private bond discounts, **99.9974% (`999,974.32 NARA`) of all `NARA` is committed or sealed inside verified V5 protocol contracts**:

| Allocation Bucket | Contract / Holder | Balance (`NARA`) | % of Supply | Custody & Release Rules |
|---|---|---:|---:|---|
| **1. Epoch Emission Reserve** | [`NARAEmissionReserveV5`](https://basescan.org/address/0xf932178F24b0813C82093985F0Af6Db27Ae25930) | **`949,923.04`** | **`94.9923%`** | **Permanently sealed (`coreBound = true`)** to `NARAEpochEngineV5`. Funded with `949,987 NARA` (`94.9987%`) at genesis (`54,778,829`); no admin sweep exists, released strictly via 15-minute epochs (`96/day`). |
| **2. Two-Way Range Liquidity** | [`NARATreasuryRangeManagerV5`](https://basescan.org/address/0x221c625d2BC416460C397035C1286C1f4A4D3A7C) + [`Legacy`](https://basescan.org/address/0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288) | **`50,048.08`** | **`5.0048%`** | `51.0811 NARA` in active `0x221c62...` (`46.2471 NARA` liquid + `4.8340 NARA` in `12` live upside rungs) + `49,997 NARA` in legacy `0xa725...` (7-day withdrawal queued at `Safe Nonce 9`, maturing `2026-11-14T14:27:48Z`). Raw `NARA` withdrawals enforce a **7-day waiting period** (extendable to **1 year**). |
| **3. Committed Position Principal** | [`NARAPrincipalLedgerV5`](https://basescan.org/address/0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2) | **`3.20`** | **`0.0003%`** | Segregated 1-for-1 principal across active `>1d` commitments (`Positions #2` & `#4`, including `Treasury Safe` `Position #4` at `2.20 NARA`, `365d`, `4.00x`). |
| **4. Circulating Liquid & LP Inventory** | [`Treasury Safe`](https://basescan.org/address/0xe320C281c86079eA85f2Bc67864E873A61D551E3), LP Pools, CryptoSLIP Vaults & Wallets | **`25.68`** | **`0.0026%`** | `1.9613 NARA` liquid in `Treasury Safe` (`Safe Nonce 23`), `0.8445 NARA` unclaimed in `NARARewardLedgerV5`, `1.2170 NARA` across CryptoSLIP vaults (`v33` + `v32`), and `21.6577 NARA` across Uniswap v4 LP, secondary V3 LP (`#6541142..#6541149`), `pNARA`, and wallets. |
| **Team / Founders / VCs** | — | **`0.00`** | **`0.0000%`** | **Zero team allocation, zero investor cliffs, zero advisor tokens.** |
| **Total Supply** | — | **`1,000,000.00`** | **`100.0000%`** | **Fixed forever.** |

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
