# NARA Risk Assessment Matrix

> This document describes how the protocol can fail.
> NARA does not guarantee adoption, profitability, or longevity.

## 1. Smart Contract Risks

| Risk                   | Severity | Probability | Mitigation                                                                                                                                                                                                         |
| :--------------------- | :------- | :---------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Reentrancy**         | High     | Low         | `ReentrancyGuard` on all external functions. Checks-Effects-Interactions pattern used in Jackpot logic.                                                                                                            |
| **Blockhash Grind**    | Critical | Low         | 2-Step Mining process (Commit -> Reveal). `block.prevrandao` mixed in for randomness.                                                                                                                              |
| **Overflow/Underflow** | High     | None        | Solidity 0.8+ has built-in overflow protection.                                                                                                                                                                    |
| **Admin Abuse**        | High     | Low         | Admin can tune parameters _only before lock_. After `lockParams()` / `lockTokenParams()`, all protocol parameters are immutable. Cannot withdraw user funds (except via `sweep` of unclaimed epochs after expiry). |

## 2. Sustainability & Economic Risks

### 2.1 The "Dilution Spiral" (Short-Term)

- **Scenario**: Massive surge in ETH deposits in a single epoch.
- **Impact**: Share per ticket drops drastically (High Dilution).
- **Analysis**: The system is designed for **19 Years**, not 19 minutes. Short-term dilution is offset by the longevity of the emission schedule. Users who persist through high-difficulty periods build Tier/Streak advantages that pay off over months/years.

### 2.2 Income Sustainability (Long-Term)

- **Claim**: "19 Years of Active Participation".
- **Risk**: Protocol revenue (Jackpot/Fees) fails to sustain interest after year 5.
- **Mitigation**: The fixed supply ensures scarcity increases over time. As emission per user drops, the NARA token must appreciate in value to sustain mining costs, creating a deflationary pressure on the "Real Yield".

### 2.3 Liquidity Absence

- **Risk**: Without active secondary markets, spot vs mining arbitrage breaks down and issuance may halt permanently.

### 2.4 Jackpot Variance

- **Scenario**: A user mines 1000 times and never wins.
- **Impact**: User rage-quits.
- **Reality**: It is a probability game. 1/400 odds means high variance. Jackpot outcomes are high variance; repeated participation can experience long losing streaks. Users should size participation accordingly.

## 3. Centralization Vectors

1.  **Parameter Tuning**: Admin can change `ticketPrice`, `baseEmission` _only before lock_. After `lockParams()`, parameters are immutable. This is necessary for initial game balancing.
2.  **AutoMiner Registry**: The `AutoMinerRegistry` contract is set by the admin. A malicious replacement could grief users. However, users must explicitly deposit into the registry, so they can opt out.

## 4. Worst-Case Scenarios

### 4.1 "The Empty Epoch"

- **Scenario**: No one mines in an epoch.
- **Outcome**: Tokens for that minute are not released. Supply growth slows. Lifespan extends beyond 19 years.
- **Rating**: Benign.

### 4.2 "The Whale Attack"

- **Scenario**: A whale brings 10,000 ETH to one epoch.
- **Outcome**: The square-root efficiency curve forces them to pay a huge premium. The fees generated from their attack fill the Jackpot, effectively redistributing their wealth to the community.
- **Rating**: System successfully turns an attack into a subsidy.
