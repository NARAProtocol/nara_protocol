# Technical Architecture

This document explains the current live NARA architecture at a high level.

## Official Links

[??](https://www.naraprotocol.io) [??](https://www.naraprotocol.io/mine) [?](https://x.com/NARA_protocol) [??](https://warpcast.com/naraprotocol) [??](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)


## Live Contracts

| Contract | Role |
| --- | --- |
| `NARATokenV3` | fixed-supply ERC20 asset |
| `NARARewardReserve` | sealed reward reserve |
| `NARAEngineV2` | lock, activation, reward, and claim engine |
| `NARABondVault` | sealed bond inventory vault |
| `NARABondDepository` | future bond market contract |

For the live addresses, see `CURRENT_STATE.md`.

## Core Flow

### Token Layer

`NARATokenV3` is the asset layer.

- fixed supply
- transferable
- no post-deploy minting

### Reserve Layer

`NARARewardReserve` holds the NARA allocated for rewards.

- the reserve is sealed by code
- the engine pulls from it as rewards are distributed
- the reserve is not a discretionary treasury pool

### Engine Layer

`NARAEngineV2` is the core live contract.

It handles:

- lock creation
- activation timing
- active weight accounting
- NARA reward distribution
- ETH reward distribution
- claims and unlocks

### Bond Layer

`NARABondVault` and `NARABondDepository` are deployed but not currently open for public bond sales.

The vault holds sealed inventory.
The depository is the future market surface when conditions justify opening it.

## Non-Contract Infrastructure

The live protocol also depends on:

- epoch advancement infrastructure
- the public lockboard at `/mine`
- monitoring, analytics, and future dashboard layers

These are important surfaces, but they are not the core protocol rules.

## Design Principle

The system is meant to work as a durable base layer:

- hard supply rules in the core
- live economic state visible onchain
- more experimental UX and composability layers built on top over time
