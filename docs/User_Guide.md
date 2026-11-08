# Beginner Guide

A quick, plain-English guide to using **NARA** on **Base**.

> ⚠️ **Read First — No Promised Returns:** NARA is autonomous smart-contract software on Base, not a bank account or investment product. **We do not promise rewards, yield, profit, or price support.** Every 15-minute distribution depends on smart-contract rules and real on-chain activity, is never guaranteed, and **can be zero (`0`)**.

---

## 1. What You Need

1. **A Wallet on Base:** MetaMask, Coinbase Wallet, Rabby, or the [**CryptoSLIP App**](https://cryptoslip-g29s.4everland.app/?v=cs-1794113891779) on **Base (`Chain ID: 8453`)**.
2. **A Little `ETH` on Base:** A few cents of `ETH` for Base network gas.
3. **Official `NARA` Token Address:**
   ```text
   0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f
   ```

---

## 2. Step 1 — Get `NARA`

Swap `USDC` for `NARA` on Base (directly in the [**CryptoSLIP App**](https://cryptoslip-g29s.4everland.app/?v=cs-1794113891779) or via the canonical Uniswap v4 pool).

* Standard swaps pay a ~`4.92%` pool fee that automatically builds permanent pool liquidity first, and once liquidity is built, flows into the 15-minute reward pool for committed `NARA` holders.

---

## 3. Step 2 — Commit `NARA` (`1` to `365 Days`)

Commit your `NARA` to start receiving a share of every **15-minute reward cycle (`96x per day`)**:

* **`1.0+ NARA` Direct Commitment:** Commit **`1.0 NARA` or more** on `NARAPrincipalLedgerV5` to mint your own **Position NFT (`NARAP`)** directly to your wallet.
* **`0.1 NARA` via CryptoSLIP (`NARA Grid` & Payment Slips):** Because a direct Position NFT requires `1.0 NARA` minimum, the [**CryptoSLIP App**](https://cryptoslip-g29s.4everland.app/?v=cs-1794113891779) lets you participate with **`0.1 NARA` per slot** in the shared 10-slot **NARA Grid** (`10 × 0.1 NARA = 1.0 NARA` Position NFT, where each slot receives **10%** of the position's 15-minute rewards and principal) or send/receive fractional `NARA` Slips via instant links and QR codes. *(Have questions about how CryptoSLIP works? Read the [**CryptoSLIP Public Overview & Legal FAQ**](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md).)*
* **Pick Your Commitment Time (`1` to `365 Days`):** Longer commitments get up to **4x more weight** in every 15-minute cycle:
  * **1 Day:** `1.00x` weight
  * **30 Days:** `1.06x` weight
  * **90 Days:** `1.28x` weight
  * **180 Days:** `1.85x` weight
  * **365 Days (Max):** **`4.00x` weight**

*(Note: New commitments activate after a 2-hour warm-up.)*

---

## 4. Step 3 — Claim Every 15 Minutes

* Every **15 minutes**, the engine distributes `NARA` from the **`949,987 NARA` reserve** plus protocol fees (`NARA`, `ETH`, and `USDC`) across active positions based on weight.
* **Claim Anytime:** Claim your accumulated `NARA`, `ETH`, and `USDC` to your wallet (or wrap them directly into a shareable CryptoSLIP voucher) whenever you want without closing your position.

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
