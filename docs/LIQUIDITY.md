# Liquidity

## What a liquidity pool does

A liquidity pool holds two assets so users can swap between them. The canonical
NARA pool pairs NARA with native USDC on Base through Uniswap v4.

Liquidity providers face price movement, smart-contract, fee, custody,
front-running, and loss-versus-holding risks. Pool activation does not guarantee
that a particular trade or exit can be completed at an acceptable price.

## Canonical NARA/USDC pool

| Item | Verified checkpoint |
|---|---|
| Pool ID | `0x83edced1f39e6adf7469cd718eeb409824d948959263408d4cfb6e745c8db464` |
| Pair | Native USDC / NARA |
| Fee parameter | `3000` |
| Tick spacing | `60` |
| Hook | `0x59AEf9799DEA01A7FB7dA73BEA10dfB08858A088` |
| Initial seed | `60,000 NARA + 300 USDC` |
| Seed LP NFT | `2898124`, production-Safe owned |
| Compounder LP NFT | `2898486`, Compounder owned |
| Verification block | `49736809` |

The pool was registered, initialized, and seeded in Base transaction
[`0xaeb7c336…24799`](https://basescan.org/tx/0xaeb7c3365354de633dde977d9b2c951b240f6b8ff8be090cdd989edc4c924799).
Receipt-pinned exact-input buy and sell tests reconciled Hook fees, Vault
records, token transfers, and transaction outcomes.

The opening seed ratio was `0.005 USDC per NARA`, implying a historical opening
FDV of approximately `5,000 USDC` on the fixed 1,000,000 NARA supply. That is
checkpoint arithmetic, not a current price, fair-value opinion, floor, or
promise.

## Hook fee boundary

Supported exact-input swaps through this one registered pool pay the configured
Hook fee in the input currency. Exact-output swaps are rejected. Ordinary NARA
transfers and third-party or unregistered pools are outside this Hook.

Fee inventory can be one-sided. Only a balanced NARA/USDC subset can become
active liquidity; unmatched inventory remains banked until matching inventory
exists. Do not interpret fee collection as instant protocol-owned liquidity.

## Current-state warning

Liquidity, balances, pool price, and fee settings can change after the recorded
checkpoint. Check a recent block-pinned read before relying on current depth or
preparing a transaction.

## Third-party pools

Anyone can create another pool. Its existence does not make it canonical,
supported, or safe. Confirm the token address, pool ID, Hook, network, current
state, expected output, fees, slippage, and exit path before interacting.
