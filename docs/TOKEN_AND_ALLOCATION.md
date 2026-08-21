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

| Bucket | NARA | Share | Status | On-Chain Custody |
|---|---:|---:|---|---|
| Reward reserve | 650,000 | 65% | Sealed emission custody | `NARARewardReserve` (`0x8369...3F2f`) |
| Deferred bonds | 200,000 | 20% | Unsold bond inventory | `NARABondVaultV4` |
| Initial public liquidity | 70,000 | 7% | Seeded into Uniswap v4 pool / POL | Uniswap v4 Pool (`0x83ed...`) |
| Deferred external team vesting | 40,000 | 4% | External vesting timelock | Vesting Safe |
| Treasury | 40,000 | 4% | Strategic ecosystem buffer | Treasury Safe (`0xfe3A...1E8e`) |
| **Total** | **1,000,000** | **100%** | | `NARAToken` (`0xB633...19c1`) |

## Circulating supply oracle (`NARACirculatingSupplyV1`)

NARA reports its trustless, real-time market circulating supply on-chain via `NARACirculatingSupplyV1.sol`:

$$\text{Circulating Supply} = 1,000,000 - \sum \text{balanceOf}(\text{Excluded Accounts})$$

* **Excluded Set:** `NARARewardReserve` (650k), `NARABondVaultV4` (200k), Team Vesting (40k), and Burn Sink (`0x...dead`).
* **Real Initial Public Float:** Only `~110,000 NARA` (~11% of Total Supply).
* **Voluntary User Locks:** Tokens locked by holders in `NARAEngine` are voluntarily illiquid for 1 to 52 weeks (earning up to a 4.00x duration yield boost). While counted as circulating for CoinGecko/CMC market cap standards, the **effective sellable liquid float on DEX pools is typically < 30,000 NARA**.

## Open-market buybacks and reserve top-up sinks

Anyone can purchase NARA on the open market and transfer tokens into protocol contracts to tighten the circulating supply:

1. **Top up `NARARewardReserve` (`0x8369CEf28128A4B24Bc5ed52aA6196D92D563F2f`):**
   Tokens transferred here are permanently locked because `NaraSweepForbidden()` prevents any admin extraction. The `balanceOf(RewardReserve)` increases, which instantly reduces the on-chain circulating supply and market cap reported to CoinGecko/DexScreener.
2. **Top up `NARABondVaultV4`:**
   Increases bond inventory, which is excluded from circulating supply and can be sold in future bond tranches to accumulate permanent Protocol-Owned Liquidity (POL).
3. **Direct Yield Injection (`NARAEngine`):**
   Tokens sent via `depositRewards()` or `notifyRewards()` are distributed directly to active lockers as instant yield.

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
