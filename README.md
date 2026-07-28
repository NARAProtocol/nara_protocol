# NARA Protocol

Beginner-first public documentation for NARA v4 on Base.

> **Important:** NARA is experimental crypto software. Crypto assets can lose all
> of their value. Smart-contract bugs, wallet mistakes, scams, market volatility,
> and unavailable liquidity can cause permanent losses. Nothing in this repository
> is legal, tax, or financial advice, and nothing here asks you to buy or sell NARA.

## Start here

NARA is a fixed-supply ERC-20 token and an experimental protocol being built on
[Base](https://base.org/), an Ethereum layer-2 network.

If you are new to crypto, read these pages in order:

1. [Beginner guide](docs/User_Guide.md)
2. [What is live now](docs/CURRENT_STATE.md)
3. [Token and allocation](docs/TOKEN_AND_ALLOCATION.md)
4. [Risks](docs/Risk_Assessment.md)
5. [Glossary](docs/GLOSSARY.md)

## Current status

Last verified: **2026-07-28**

| Component | Status |
|---|---|
| NARA v4 token | Deployed on Base |
| Fixed supply | 1,000,000 NARA |
| Reward reserve | Deployed and sealed with 650,000 NARA |
| NARA/USDC pool | Registered but not initialized |
| Official liquidity | **Not added** |
| Public buying or selling through the official pool | **Not available** |
| Baskets application | Preview only; fail-closed until deployment manifests exist |
| Public locks and rewards | Not activated |
| Bonds | Deferred |
| Lockboard | Deferred |
| Lotto and Arena | Retired |

The current NARA token address on Base is:

```text
0x65E247AA3aa9C0131b2984b894c3D24c41341D7A
```

Always compare a contract address character by character. A ticker or token name
is not enough because anyone can create another token called NARA.

## What `$NARA` means

`NARA` is the token's onchain symbol. `$NARA` is a common display convention used
in writing and social posts. The dollar sign does not create a different token.

## Repository purpose

This repository is the public documentation portal. The active v4 engineering
source is maintained in
[NARAProtocol/nara_protocol_v4](https://github.com/NARAProtocol/nara_protocol_v4).
Generated v4 artifacts, ABIs, deployment manifests, and verified blockchain state
are the technical sources of truth.

Old v3 contracts, mining, jackpot, lotto, and auto-miner designs are not part of
the active protocol. Historical files remain available through Git history, not
in the current documentation tree.

## Documentation

The complete reading map is in [docs/README.md](docs/README.md).

## Official channels

- Website: [naraprotocol.pro](https://naraprotocol.pro)
- X: [@NARA_protocol](https://x.com/NARA_protocol)
- Security reports: [security@naraprotocol.pro](mailto:security@naraprotocol.pro)

Treat unsolicited direct messages, support offers, token links, and requests for
a seed phrase or private key as scams. NARA contributors will never need those
secrets.

## Legal note

This repository describes software and observable blockchain state. It is not a
crypto-asset white paper, offering document, prospectus, approval, registration,
or authorization in any jurisdiction. Laws differ by location and can change.
The project must obtain qualified legal advice before an offer, admission to
trading, financial promotion, or consumer-facing launch in any jurisdiction.

## License

Code and documentation are available under the [MIT License](LICENSE). The
license permits software use; it does not grant permission to use NARA names,
logos, or other branding, and it is not a regulatory approval.
