# Liquidity

## What a liquidity pool does

A liquidity pool holds two assets so users can swap between them. The planned
official pool pairs NARA with native USDC on Base using Uniswap v4.

Liquidity providers supply the assets and receive control of a liquidity
position. They face risks including price movement, smart-contract failure,
fee uncertainty, and losses relative to simply holding the assets.

## Current NARA status

The official pool is registered but uninitialized. It contains no official
liquidity and no LP NFT exists. Official pool-based trading is therefore not
available.

The reviewed working seed scenario is:

| Input | Planning amount |
|---|---:|
| NARA | 60,000 |
| USDC | 300 |
| Arithmetic starting ratio | 0.005 USDC per NARA |
| Approximate two-sided pool size | 600 USDC |
| Implied FDV at that ratio | 5,000 USDC |

These figures are unexecuted planning inputs. They do not establish fair value,
a minimum price, available exit liquidity, or a return. A small trade can move a
small pool substantially.

The full liquidity allocation is 70,000 NARA. The remaining 10,000 NARA is not
part of the initial seed scenario and requires a separate later decision.

## Before any pool transaction

Operators must verify token ordering, decimals, hook permissions, starting price,
slippage bounds, balances, approvals, chain ID, deployed bytecode, role custody,
and the exact recipient of the LP position. A human signer must compare the
wallet request with the approved transaction plan.

## Third-party pools

Anyone can create an unofficial pool. Its existence does not make it approved,
supported, or safe. Confirm the token address, pool identifier, hook, and current
official status before interacting.
