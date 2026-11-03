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
| **Standards** | `ERC-20`, `ERC-20Permit` (EIP-2612 gasless approvals), `ERC-3156` (Flash Loans) |

---

## Verified On-Chain Supply Allocation (Block `53,422,831`)

Unlike traditional token launches that reserve 20%–40% of supply for team vesting, venture capital cliffs, or private bond discounts, **99.9984% of all `NARA` is sealed directly inside immutable V5 protocol contracts**:

| Allocation Bucket | Contract / Holder | Balance (`NARA`) | % of Supply | Custody & Release Rules |
|---|---|---:|---:|---|
| **1. Epoch Emission Reserve** | [`NARAEmissionReserveV5`](https://basescan.org/address/0xf932178F24b0813C82093985F0Af6Db27Ae25930) | **`949,987.00`** | **`94.9987%`** | **Permanently sealed (`coreBound = true`)** to `NARAEpochEngineV5`. No admin sweep or withdrawal function exists. Released strictly through 15-minute reward epochs (`96/day`) to active positions. |
| **2. Two-Way Range Liquidity** | [`NARATreasuryRangeManagerV5`](https://basescan.org/address/0xa72557fcBE56B3eC739dF3aF7b6b893B6Db4D288) | **`49,997.00`** | **`4.9997%`** | Two-way range manager: supplies `NARA` sell rungs on upside moves to collect `USDC`, then uses collected `USDC` to place buy rungs and **buy `NARA` back** on dips. `NARA` withdrawals have a **7-day withdrawal delay** at launch (extendable to **1 year** once live operation is proven). |
| **3. Initial Pool Seed** | [`Treasury Safe (2-of-3)`](https://basescan.org/address/0xe320C281c86079eA85f2Bc67864E873A61D551E3) | **`3.00`** | **`0.0003%`** | Paired with `301.00 USDC` in the Treasury Safe to seed the canonical Uniswap v4 `NARA / USDC` pool at `$100.00 / NARA` (`3 NARA + 300 USDC`). |
| **4. Live Principal Custody** | [`NARAPrincipalLedgerV5`](https://basescan.org/address/0x7F866a9fbe41D54F0d9C35b6892fcf27Ea766DB2) | **`1.00`** | **`0.0001%`** | Committed 1-for-1 in live `Position #1` (`NARAP` NFT `#1`). |
| **5. Circulating Verification Float** | Verification Wallets | **`12.00`** | **`0.0012%`** | Used for live mainnet smoke testing, CryptoSLIP payment links, and `NARA Grid` verification. |
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
