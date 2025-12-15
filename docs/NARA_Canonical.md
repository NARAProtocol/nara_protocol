# NARA

## Competitive Token Issuance via Simulated Proof-of-Work on EVM

---

## Abstract

NARA is a token issuance mechanism that replaces programmatic inflation with **competitive cost discovery**.

Instead of minting new supply on a fixed schedule, NARA requires participants to **spend ETH into the protocol** to produce tokens. The aggregate ETH committed in each issuance window determines the **production cost** of new supply. If participation drops to zero, issuance halts automatically.

This design adapts the core property of Proof-of-Work—_tokens have a transparent cost basis_—to Ethereum, where capital is the scarce resource rather than electricity.

NARA makes inflation **optional**, demand-driven, and visible.

---

## 1. Core Properties

- **Fixed Maximum Supply:** 3,333,333 NARA
- **Epoch Length:** 3 minutes
- **Base Emission:** ~1 NARA per epoch
- **Issuance Condition:** Tokens are released _only if ETH is spent_
- **Pre-Minted Supply:** All 3,333,333 NARA are minted at launch and distributed between initial liquidity (1 NARA) and the miner reward pool
- **Escrow Release:** Tokens are distributed from this pool through participation, not minted on-demand
- **Base Chain:** Base (cross-chain functionality may be evaluated later)

NARA does not promise yield, price support, or adoption. Participation is permissionless and optional.

---

## Genesis Distribution

At deployment, the full fixed supply of 3,333,333 NARA is created once.

Before mining begins:

- **1 NARA** is allocated to a designated liquidity address for initial DEX bootstrapping
- **All remaining NARA** is transferred into the miner reward pool

No other allocations exist.
There are no team, investor, or treasury token grants.
All NARA beyond the initial 1-token liquidity seed is distributed exclusively through the mining mechanism.

---

## 2. The Issuance Mechanism

### 2.1 Epoch Mining

NARA operates in discrete epochs:

1. An epoch opens (3 minutes)
2. Participants commit ETH to the protocol during the epoch
3. A fixed amount of NARA is made available for that epoch
4. Distribution is **pro-rata by ETH committed**
5. If total ETH committed is zero → **zero tokens are released**

There is no background inflation.

---

### 2.2 Production Cost and “Difficulty”

In NARA, difficulty is **economic**, not computational.

The production cost of NARA in a given epoch is:

```
Total ETH committed ÷ NARA released
```

Examples (illustrative):

- Low participation → low production cost
- High participation → high production cost

The protocol does not set a price floor.
Participants collectively determine whether producing new supply is worth the cost.

---

## 3. Market Equilibrium

NARA creates a natural arbitrage boundary:

- **If market price < production cost:**
  Rational actors buy existing supply; mining slows or halts.

- **If market price > production cost:**
  Rational actors mine new supply; issuance increases.

This mirrors Proof-of-Work behavior, where miners enter or exit based on profitability.
Inflation becomes **conditional on demand**, not guaranteed.

---

## 4. Variable Emission and Lifespan

### 4.1 Base and Surge Emission

- **Normal mode:** ~1 NARA per epoch
- **Surge mode:** Emission may increase (up to a capped multiple) during sustained high participation

Surge emission **compresses the timeline**, not the total supply.

> **Disclaimer:** All surge values shown are illustrative unless explicitly labeled ‘Deployment Parameters’. Actual surge thresholds and caps are immutable after deployment and verifiable on-chain.

- Low sustained demand → longer lifespan (~19 years theoretical)
- High sustained demand → shorter lifespan (~6 years theoretical)

Actual lifespan depends entirely on participation and may be shorter.

---

### 4.2 Deflationary Pauses

If participation falls below required thresholds:

- Issuance halts automatically
- No tokens are released
- Supply growth pauses until demand returns

There is no manual intervention required to stop inflation.

---

## 5. Variance Redistribution (Jackpot Mechanism)

Participants have different risk preferences:

- Some prefer **low-variance accumulation** (steady cost-basis mining)
- Others prefer **high-variance outcomes** (convex, lottery-like payoff)

NARA allows variance-seeking participants to pay a premium for convex outcomes.
That premium increases aggregate ETH committed per epoch, raising production cost.

This mechanism **redistributes variance**, not value guarantees:

- No participant is promised positive expected return
- No subsidy is guaranteed
- Increased production cost is an emergent effect, not an obligation

---

## 6. Treasury and Capital Accumulation

The protocol accumulates capital in two forms:

- **ETH:** from a portion of committed mining ETH
- **NARA:** from protocol-level transfer fees, if enabled

### Treasury properties:

- Funds are on-chain and transparent
- No guaranteed intervention or price support
- No obligation to act

### Possible (non-guaranteed) uses:

- Opportunistic buy-and-burn during extreme dislocations
- Liquidity provisioning to reduce volatility
- Treasury may support ecosystem sustainability (liquidity, buybacks, development), but **cannot increase total supply or emission capacity after parameter lock**.

The treasury exists to act **counter-cyclically when conditions allow**, not to guarantee outcomes.

---

## 6b. Transfer Fee Mechanics

All NARA transfers incur a fixed 0.1% transfer fee. Half is to treasury, half funds protocol variance mechanisms. This fee is immutable after lock.

Fee allocation:

- **50%** is routed to the **Treasury**
- **50%** is routed to the `feeRecipient` (Protocol Variance / Jackpot)

This fee can be disabled by setting the fee to 0 before parameter lock.
After `lockTokenParams()` is called, the fee rate and recipient cannot be changed.

**Treasury Note**: The treasury does not receive an upfront token allocation. Treasury NARA accumulation occurs only through protocol-level transfer fees, if enabled.

---

## 7. Whale Resistance and Fairness

To reduce concentration risk, NARA applies diminishing returns to large single-actor participation within an epoch.

A representative form:

```
E(n) = L + √(n − L)
```

Where marginal effectiveness decreases as contribution size increases.

This makes domination economically self-penalizing:

- Large actors raise global production cost for themselves
- Distributed participation is structurally cheaper than monopolization

---

## 8. Loyalty and Participation Effects

NARA may include time-based or activity-based bonuses.

> At genesis, the mining hold duration may be temporarily zero to allow initial distribution. This value is set to its final value before parameters are locked.

**Critical constraint:**

> Loyalty effects modify _relative distribution within an epoch_.
> They **do not** reduce the aggregate ETH cost required to earn supply.

Effective production cost cannot fall below a protocol-defined minimum relative to average epoch cost.

This prevents long-term insiders from earning supply materially cheaper than newcomers.

---

## 9. Governance and Mutability

- The protocol may be owner-configurable at launch to respond to unforeseen issues
- All tunable parameters are explicitly defined
- A one-way `lockParams()` function permanently disables further changes

After locking, the protocol becomes immutable.

---

## 10. Failure Modes and Risks

NARA is an experiment. It can fail.

### Economic Risks

- Sustained lack of participation → issuance halts permanently
- Market price ignores production cost → mining ceases
- Liquidity absence → arbitrage breaks down

### Participation Risks

- Early epochs may lack sufficient distribution
- Concentrated participation may damage narrative despite penalties

### Treasury Risks

- Poor discretionary decisions reduce trust
- Treasury inactivity may fail to dampen volatility

### Technical Risks

- Smart contract bugs
- MEV and timing advantages (reduced but not eliminated by epoch aggregation)
- External infrastructure failures

### No Guarantees

- No guaranteed income
- No guaranteed price floor
- No guaranteed adoption
- Loss of ETH is possible

---

## 11. What NARA Is — and Is Not

**NARA is:**

- A competitive issuance primitive
- A transparent cost-basis system
- A demand-driven alternative to inflationary emissions

**NARA is not:**

- A yield product
- A price-stabilization scheme
- A promise of profit
- A substitute for market risk

---

## Conclusion

NARA exposes a simple question transparently:

> _What is the market willing to pay to produce new supply, right now?_

If the answer is “nothing,” issuance stops.
If the answer is “a lot,” production cost rises.

Either outcome is valid.
The protocol does not decide—participants do.

---

**Status:** Experimental
**Participation:** Permissionless
**Risk:** Non-trivial
