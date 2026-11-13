# Beginner Guide

A quick, plain-English guide to using **NARA** on **Base**.

> ⚠️ **Read First — No Promised Returns:** NARA is autonomous smart-contract software on Base, not a bank account or investment product. **We do not promise rewards, yield, profit, or price support.** Every 15-minute distribution depends on smart-contract rules and real on-chain activity, is never guaranteed, and **can be zero (`0`)**.

---

## 1. What You Need

1. **A Wallet on Base:** MetaMask, Coinbase Wallet, Rabby, or the [**CryptoSLIP App**](https://slip.naraprotocol.io) ([ENS/IPFS mirror](https://cryptoslip.eth.limo)) on **Base (`Chain ID: 8453`)**.
2. **A Little `ETH` on Base:** A few cents of `ETH` for Base network gas.
3. **Official `NARA` Token Address:**
   ```text
   0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f
   ```

---

## 2. Step 1 — Get `NARA`

Swap `USDC` (or `ETH` via 2-hop routing) for `NARA` on Base — directly in the live console on [**`naraprotocol.io`**](https://naraprotocol.io), in the [**CryptoSLIP App**](https://slip.naraprotocol.io/?tab=nara&action=buy), or via the canonical Uniswap v4 pool (`100%` of official app NARA trades route exclusively through `NARALiquidityHookV5`).

* Standard swaps pay a ~`4.92%` pool fee (`4.63%` Hook fee + `0.30%` LP fee) collected in `NARAFeeVaultV5` (`0xF1f361F803895BF5cf67eC6C506dbFEf2f6E88Cf`), where `NARATreasuryFeeControllerV5` (`0xB6A436b48222C94fe427ecAfB263DF9cf42646b9`) can route swap fees (`USDC` and `NARA`) with `0-second delay` to deepen pool liquidity, replenish `NARAEmissionReserveV5`, or stream directly into the 15-minute reward pool for committed `NARA` holders.

---

## 3. Step 2 — Commit `NARA` (`1` to `365 Days`)

Commit your `NARA` to start receiving a share of every **15-minute reward cycle (`96x per day`)**:

* **`1.0+ NARA` Direct Commitment (`Commit NARA`):** Commit **`1.0 NARA` or more** on `NARAPrincipalLedgerV5` (directly on [`naraprotocol.io`](https://naraprotocol.io) or via the `Commit NARA` tab in the [**CryptoSLIP App**](https://slip.naraprotocol.io/?tab=nara)) to mint your own individual 1:1 **Position NFT (`NARAP`)** directly to your wallet. Position NFTs are never split, fractionalized, or fused—every position is weighted strictly by commitment duration.
* **Micro-Minimum `NARA` Payment Slips (`0.000001+ NARA` via CryptoSLIP `v33`):** Want to send, receive, keep (`0%` fee), split payment slips with automatic change, or combine up to 10 smaller payment slips into one? Use the **`NARA Slip`** tab in the [**CryptoSLIP App**](https://slip.naraprotocol.io) starting from **`0.000001 NARA`** (`0%` token transfer tax). *(Have questions about how CryptoSLIP works? Read the [**CryptoSLIP Public Overview & Legal FAQ**](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md).)*
* **Pick Your Commitment Time (`1` to `365 Days`):** Longer commitments get up to **4x more weight** in every 15-minute cycle:
  * **1 Day:** `1.00x` weight
  * **30 Days:** `1.06x` weight
  * **90 Days:** `1.28x` weight
  * **180 Days:** `1.85x` weight
  * **365 Days (Max):** **`4.00x` weight**

*(Note: New commitments activate after a 2-hour warm-up.)*

---

## 4. Step 3 — Claim Every 15 Minutes

* Every **15 minutes**, the engine distributes `NARA` from **`NARAEmissionReserveV5`** (`949,987 NARA` genesis funding; `949,923.04 NARA` / `94.9923%` remaining at block `56,767,987`) plus protocol fees (`NARA`, `ETH`, and `USDC`) across active positions based on weight.
* **Claim Anytime:** Claim your accumulated `NARA`, `ETH`, and `USDC` to your wallet (or wrap them directly into a shareable CryptoSLIP voucher for `>= 0.1 NARA`) whenever you want without closing your position.

---

## 5. Step 4 — Withdraw 1-for-1 or Sell Your NFT Anytime

You have two ways to exit:

1. **Wait for Your Timer to Finish (Withdraw 1-for-1):**
   When your chosen commitment period ends, withdraw **100% of your committed `NARA` back 1-for-1** with zero withdrawal fee (or recharge your matured position with `rechargeCommon` to start a new commitment).
2. **Exit Early — Sell Your Position NFT for `ETH`:**
   Don't want to wait for your timer? List your active `NARAP` Position NFT on `NARAPositionSaleV5` (`0x04Ac83045d26259D46400Ce6beb9bBd0641df225`) for **`ETH`**. When another user buys it, you receive **95% of the `ETH`** (`5%` goes to the 15-minute reward pool). *(Tip — claim any pending rewards before selling your NFT, since unclaimed rewards travel with the NFT.)*

---

## 6. Quick Safety Rules

* **Never share your seed phrase or private key.** Nobody from NARA will ever DM you first.
* **Always check the token address:** `0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f` on **Base (`8453`)**.
