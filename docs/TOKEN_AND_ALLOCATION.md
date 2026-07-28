# Token and allocation

## Token facts

| Item | Value |
|---|---|
| Name | NARA |
| Symbol | NARA |
| Written social convention | `$NARA` |
| Network | Base |
| Standards | ERC-20, EIP-2612 permit, ERC-3156 flash lending, ERC-1363 |
| Permanently outstanding supply | 1,000,000 NARA |
| Additional admin minting | Not available |
| Contract | `0x65E247AA3aa9C0131b2984b894c3D24c41341D7A` |

The original 1,000,000 NARA was minted once. No owner or administrator can mint
additional permanent supply. This does not mean the token has a fixed price,
stable value, or guaranteed scarcity value.

## Temporary flash minting

The token supports ERC-3156 flash loans. A compatible contract can temporarily
mint up to 100,000 NARA, but the temporary amount must be returned and burned
before the same blockchain transaction finishes. If repayment fails, the entire
transaction reverts.

The fixed flash fee is 0.10% and is sent to the immutable engine address. Flash
minting can make `totalSupply()` temporarily exceed 1,000,000 inside that single
transaction. It is not an administrator mint function and cannot create
permanent additional supply.

Flash loans increase integration and market-manipulation risk. Other protocols
must not assume that a NARA balance observed inside one transaction came from
long-term token ownership.

## Canonical allocation

| Bucket | NARA | Share | Status |
|---|---:|---:|---|
| Reward reserve | 650,000 | 65% | Deployed and sealed |
| Deferred bonds | 200,000 | 20% | Deferred; not a live bond product |
| Liquidity envelope | 70,000 | 7% | 60,000 prepared for initial pool depth; liquidity not seeded |
| Deferred external team vesting | 40,000 | 4% | External vesting arrangement still required |
| Treasury | 40,000 | 4% | Treasury allocation |
| **Total** | **1,000,000** | **100%** | |

“Allocated” describes intended accounting. It does not by itself prove that
tokens are locked, vested, liquid, distributed, or unavailable to the holder.
Use verified contracts and transactions to confirm custody and restrictions.

## No ownership rights

Holding NARA does not, by itself, represent equity, debt, a bank deposit, legal
ownership of protocol assets, a claim on revenue, a guaranteed reward, or a
right to profit. Any future utility must be documented and technically enabled
before users rely on it.

## Price is not encoded in the token

The token contract does not set a market price. Any market price would emerge
from available liquidity and user trades. A small pool can move sharply, and an
implied fully diluted valuation is only arithmetic based on a price; it is not a
company valuation, floor, forecast, or promise.
