# Risk assessment

Crypto assets are high risk. Losses can be total and irreversible. This list is
not exhaustive and is not a statement that unlisted risks are absent.

## Protocol and contract risk

Smart contracts can contain design, implementation, integration, or accounting
errors. Tests and audits reduce some uncertainty but cannot prove that code is
bug-free. Deployed code may interact with unexpected tokens or external state.

## Early-stage and availability risk

The official pool is not initialized, official liquidity is absent, and several
user-facing components are deferred. Features may never launch or may change
before activation.

## Liquidity and market risk

A small pool can experience extreme price changes, slippage, manipulation,
front-running, and difficult exits. There may be no buyer. FDV is an arithmetic
figure, not money in the protocol or evidence of fair value.

## Administration and key risk

Current Stage A administration uses EOAs. A lost or compromised key could disrupt
operations or expose controlled assets and settings. Planned multisignature
migration is not protection until completed and verified.

## Wallet and approval risk

Wrong addresses, wrong networks, malicious signatures, unlimited approvals,
phishing, malware, lost keys, and fake interfaces can cause permanent loss.
Transactions normally cannot be reversed.

## Third-party risk

NARA depends on systems it does not control, including Base, Ethereum, Uniswap
v4, USDC, RPC providers, wallet software, explorers, hosting, and domain
infrastructure. Outages, exploits, censorship, governance changes, depegging, or
contract changes in those systems can affect NARA.

## Oracle and pricing risk

Onchain prices can be stale, manipulated, unavailable, or inappropriate for a
specific calculation. Low-liquidity prices are especially fragile.

## Interface and indexing risk

A frontend or indexer can display stale or incorrect information even when
contracts work correctly. Users should confirm important state onchain. A
missing deployment manifest must cause the interface to stop, not guess.

## Legal, regulatory, and tax risk

Token classification, offers, trading admission, financial promotions, consumer
rules, sanctions, anti-money-laundering duties, reporting, and taxes vary by
jurisdiction and may change. Availability of code does not mean a product can
lawfully be offered or marketed everywhere.

## Scam and impersonation risk

Anyone can copy a logo, token name, website, or social account. Verify the full
contract address and official domain. No legitimate contributor needs a seed
phrase or private key.

## Documentation risk

Documentation can become outdated. Check its verification date, compare it with
current blockchain state, and treat code and verified manifests as authoritative.

## User responsibility

Do not transact with assets you cannot afford to lose. Understand the exact
action and obtain independent legal, tax, and financial advice appropriate to
your circumstances. No disclaimer can replace accurate disclosure or compliance.
