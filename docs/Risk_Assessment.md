# Risk Assessment (`Risk_Assessment.md`)

Interacting with decentralized smart contracts and digital assets involves significant risk. Losses can be partial or total, and blockchain transactions are irreversible. Review the risks below carefully before using NARA Protocol V5.

---

## 1. Market, Price & Liquidity Risk
- **Price Volatility:** `NARA` has a fixed `1,000,000` total supply and a small circulating float (`99.9984%` is sealed in `NARAEmissionReserveV5` and `NARATreasuryRangeManagerV5`). Small buy or sell orders can cause large percentage changes in spot price.
- **Swap Fees & Slippage:** Swaps on the canonical `NARA / USDC` Uniswap v4 pool pay a **`4.63%` base Hook fee** (and up to **`20.00%`** if multiple swaps occur in the same block). Always check your expected output and minimum received amount before confirming a swap.
- **No Guaranteed Exit Price:** The Zero-Delay Fee Periphery (`NARAFeeVaultV5` + `NARATreasuryFeeControllerV5`) and the Two-Way Range Manager (`NARATreasuryRangeManagerV5`) manage fees and pool liquidity according to on-chain rules, but they do not guarantee a price floor, buyback price, or zero-slippage exit.

## 2. Time-Commitment & Secondary Market Risk
- **Commitment Duration (`1 to 365 Days`):** Principal committed in `NARAPrincipalLedgerV5` (`1.0 NARA` minimum per Position NFT) cannot be withdrawn directly from the ledger until the chosen commitment timer reaches maturity.
- **Secondary NFT Market Pricing (`NARAPositionSaleV5`):** While you can list your `NARAP` Position NFT for sale in native `ETH` before maturity on `NARAPositionSaleV5`, secondary market execution depends on another buyer choosing to purchase your listing, which may occur at a discount to spot value.
- **Variable Epoch Rewards:** 15-minute epoch rewards depend on your share of total active weight, the emission schedule, and actual protocol fee volume. There is no fixed or guaranteed APY.

## 3. Smart Contract & Technical Risk
- **Code Risk:** Although NARA V5 contracts (`Solidity 0.8.37`) isolate principal custody (`NARAPrincipalLedgerV5`) from reward reserves (`NARAEmissionReserveV5`) and have undergone extensive testing and invariant checks, no smart contract system can be guaranteed to be 100% free of unknown vulnerabilities.
- **Flash-Loan Composability:** `NARATokenV5` supports ERC-3156 flash loans of up to `100,000 NARA` per transaction (`0.10%` fee to `NARAEmissionReserveV5`). Third-party contracts integrating `NARA` must never rely on instantaneous spot balances or single-block spot prices for security-critical calculations.

## 4. Governance & Operational Risk
- **Bounded Multisig Scope:** While core V5 contracts (`NARATokenV5`, `NARAEmissionReserveV5`, `NARAPrincipalLedgerV5`, `NARAEpochEngineV5`) have zero admin owner (`0x0`), liquidity and range parameters are managed by `2-of-3` Gnosis Safes (`Treasury Safe`, `VRF Safe`, `Presentation Safe`). Signer error or delayed rebalancing can affect pool parameters within their hard-coded bounds.

## 5. Third-Party & Infrastructure Risk
- **External Dependencies:** NARA V5 operates on **Base Mainnet (`8453`)** and integrates with **Uniswap v4** (`PoolManager` `0x498581fF718922c3f8e6A244956aF099B2652b2b`) and **USDC** (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`). Sequencer downtime, RPC outages, stablecoin depegging, or upstream protocol vulnerabilities are outside NARA's control.

## 6. Wallet Security & Impersonation Risk
- **Phishing & Fake Tokens:** Scammers frequently deploy copycat tokens with the same ticker symbol. Always verify the exact Base Mainnet contract address for `NARA`: **`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`**.
- **Self-Custody Responsibility:** Never share your seed phrase or private key. Anyone with access to your wallet or your `NARAP` Position NFT controls your funds.
