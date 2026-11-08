# Launch Verification Gates (`LAUNCH.md`)

NARA Protocol V5 uses strict, verifiable on-chain gates before and during launch so that every claim in this repository can be checked directly against **Base Mainnet (`8453`)**.

---

## 1. Completed Pre-Bind & Core Activation Gates

All irreversible core bindings and zero-delay fee periphery bindings passed verification at or before Base block **`54,778,829`**:

- **Source & Bytecode Verification:** All 35 V5 contracts (`Solidity 0.8.37`) are deployed and verified on Base Mainnet.
- **Zero-Admin Core Sealing:**
  - `NARATokenV5` (`0x91FB78A9F46B67f54BbD4489941d19666b2fAe0f`) has `owner = 0x0` and its flash-loan fee sink is permanently bound to `NARAEmissionReserveV5`.
  - `NARAEmissionReserveV5` (`0xf932178F24b0813C82093985F0Af6Db27Ae25930`) holds **`949,987 NARA`** (`94.9987%` of supply) and is permanently bound (`coreBound = true`, `bindingsSealed = true`) to `NARAEpochEngineV5`.
  - `NARAPrincipalLedgerV5`, `NARARewardLedgerV5`, and `NARARewardIngressV5` are permanently bound to `NARAEpochEngineV5`.
- **Live Position & Epoch Lifecycle Proof:**
  - `NARAEpochEngineV5` (`0xd93FbEbFb33FAc9288125074625D4750573B1a53`) is activated (`activated = true`, `bindingsSealed = true`) with `900s` (15-minute) epochs.
  - Live `Position #1` (`1.0 NARA`) is committed in `NARAPrincipalLedgerV5` and represented by `NARAP` Position NFT `#1` on `NARAPositionNFTV5` (`0x8C5F088D9d09dBB90aB6F3aaA049a8FD5D5FfFDA`).
- **Uniswap v4 Pool & Hook Binding:**
  - Canonical `NARA / USDC` Pool (`0x4a475299ef674bcc3d2c87c3917cfbecd38cf7237646a3553e37daba67da6e5f`) is initialized on Uniswap v4 `PoolManager` (`0x498581fF718922c3f8e6A244956aF099B2652b2b`).
  - `NARALiquidityHookV5` (`0x07d8F2Dfd121B10dE3176DeAb6A8C0eaa2646aCC`), `NARAFeeVaultV5` (`0xF1f361F803895BF5cf67eC6C506dbFEf2f6E88Cf`), and `NARAPOLPositionV5` (`0x01EF9de9f4e9197F2A3944b5B34A90eA2f558b64`) are bound with `100% POL` at launch, redirecting to Engine rewards once liquidity is built.
- **Separated `2-of-3` Multisig Governance:**
  - `Treasury Safe` (`0xe320C281c86079eA85f2Bc67864E873A61D551E3`), `OA-3` VRF Governance Safe (`0x9d415e070AF8e93890dcCaE27755C66E3A313f0F`), and `C1` Presentation Governor Safe (`0x0939BE9a5359764C2334a70A13eC567C7e38E017`) are active `2-of-3` Safes, and the deployer EOA holds zero administrative roles.

---

## 2. User-Interface Standards

Every NARA and CryptoSLIP interface interacting with V5 contracts follows clear transparency standards:

1. **Exact Contract & Network Display:** Always verify Chain ID `8453` (Base Mainnet) and the exact V5 contract addresses before prompting a wallet signature.
2. **Pre-Trade & Pre-Commit Clarity:** Show the exact input amount, commitment duration (`1–365 days`), quadratic weight multiplier (`1.00x–4.00x`), Hook fee (`4.63%–20%`), slippage tolerance, and maturity date before confirmation.
3. **Neutral Presentation:** Present protocol mechanics, fees, and risks factually without promising fixed returns or price appreciation.
