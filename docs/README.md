# NARA Protocol V5 Documentation

Welcome to the official documentation for **NARA Protocol V5** on **Base Mainnet (Chain ID `8453`)**.

NARA is an immutable, rule-based liquidity and time-commitment protocol with a fixed supply of **1,000,000 NARA**, zero team or VC token allocations, 15-minute reward epochs, liquid **Position NFTs (`NARAP`)** with a built-in native-`ETH` secondary market, and self-compounding Uniswap v4 protocol-owned liquidity (**POL**).

---

## Start Here

- **[Master Project Knowledge Base (`PROJECT_KNOWLEDGE_BASE.md`)](PROJECT_KNOWLEDGE_BASE.md)** — Complete single-page V5 reference (tokenomics, 15-minute pulses, `0.1 NARA` CryptoSLIP Grid, `5%` NFT market, two-phase Hook fees, two-way Range Manager, and all 35 verified Base Mainnet contracts).
- **[CryptoSLIP (V3.2) Public Overview, Architecture & Legal FAQ (`CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md`)](CRYPTOSLIP_PUBLIC_OVERVIEW_AND_LEGAL_FAQ.md)** — Complete overview of what CryptoSLIP solves, how V3.2 works on Base Mainnet (`0x38BF0321FA7489576978353a6a8da4A3e85C2F18`), why it is 100% non-custodial software, and 25 user, security, and regulatory Q&As.
- **[Investor & Community Q&A (`NARA_INVESTOR_QNA.md`)](NARA_INVESTOR_QNA.md)** — Institutional and community due-diligence Q&A covering AMM fee routing, supply custody, Range Manager mechanics, and security boundaries.
- **[Beginner Guide (`User_Guide.md`)](User_Guide.md)** — Step-by-step guide to swapping, committing `NARA`, claiming 15-minute epoch rewards, trading Position NFTs, and using **CryptoSLIP** (`0.1 NARA` fractional Grid).
- **[What NARA Is (`NARA_Canonical.md`)](NARA_Canonical.md)** — Plain-English overview of how NARA V5 works and what makes it different.
- **[Current On-Chain State (`CURRENT_STATE.md`)](CURRENT_STATE.md)** — Verified Base Mainnet (`8453`) contract addresses, supply custody, and live configuration (synchronized through Block `54,778,829`, `2026-11-08`).

---

## Core Protocol Guides

| Guide | What You Will Learn |
|---|---|
| **[Token & Supply Allocation](TOKEN_AND_ALLOCATION.md)** | How the fixed `1,000,000 NARA` supply is sealed on-chain (`94.9987%` Emission Reserve, `4.9997%` Range Manager, `0%` team/VC). |
| **[Liquidity & Uniswap v4 Hook](LIQUIDITY.md)** | How the canonical `NARA / USDC` pool, dynamic `4.63%–20%` Hook fee, `100% POL` routing, and Two-Way Range Manager work. |
| **[15-Minute Epoch Rewards](REWARDS.md)** | How `NARAEpochEngineV5` distributes `NARA`, `ETH`, and `USDC` every 15 minutes (`96 epochs/day`) based on `1.00x–4.00x` time-commitment weight. |
| **[Technical Architecture](Technical_Architecture.md)** | Full V5 smart-contract architecture (`Solidity 0.8.37`), segregated principal custody, 100% on-chain SVG Position NFT rendering, and security invariants. |
| **[Governance, Safes & Withdrawal Delays](ADMIN_POWERS.md)** | Which V5 contracts have zero owner (`0x0`), which bindings are permanently sealed, and what the `2-of-3` Safes can and cannot do. |

---

## Reference & Disclosures

- **[Roadmap & Milestones](ROADMAP.md)** — Completed V5 mainnet deployment milestones and upcoming ecosystem integrations.
- **[Launch Verification Gates](LAUNCH.md)** — Pre-bind and post-bind verification checks completed for V5.
- **[Risk Assessment](Risk_Assessment.md)** — Smart-contract, market, liquidity, and operational risks.
- **[Glossary](GLOSSARY.md)** — Plain-English definitions of protocol and blockchain terms.
- **[Version History](HISTORY.md)** — Public documentation and protocol release history.
- **[Legal Notice](../LEGAL.md)** — Educational and non-promotional disclosures.
