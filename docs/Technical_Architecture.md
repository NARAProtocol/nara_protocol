# Technical Architecture

This document explains the current live NARA architecture at a high level.

## Live Contracts

| Contract | Role |
| --- | --- |
| `NARATokenV3` | fixed-supply ERC20 asset |
| `NARARewardReserve` | sealed reward reserve |
| `NARAEngineV2` | lock, activation, reward, claim, and earnings distribution engine |
| `NARABondVault` | sealed bond inventory vault |
| `NARABondDepository` | future bond market contract |

For the live addresses, see `CURRENT_STATE.md`.

## Core System View

The live protocol is easiest to understand as four layers:

- token layer
- reserve layer
- engine layer
- surface layer

The engine layer is the important one. It is the common distribution layer that turns committed positions into a fair share of protocol rewards.

## Token Layer

`NARATokenV3` is the asset layer.

- fixed supply
- transferable
- no post-deploy minting

## Reserve Layer

Two sealed reserves matter:

- `NARARewardReserve` for locker rewards
- `NARABondVault` for future controlled bond distribution

These are not arbitrary team wallets. They are part of the protocol architecture.

## Engine Layer

`NARAEngineV2` is the core live contract.

It handles:

- lock creation
- activation timing
- active weight accounting
- NARA reward distribution
- ETH reward distribution
- claims and unlocks

This is the contract that makes NARA more than a simple token lock. It is designed to be the fair accounting and settlement layer for protocol earnings.

## Revenue Routing

The engine is designed so that current and future products can route ETH into one common reward layer.

That matters because it keeps the protocol coherent:

- one position system
- one weight system
- one earnings distribution engine
- many possible product surfaces on top

## Bond Layer

`NARABondVault` and `NARABondDepository` are deployed but not currently open for public bond sales.

The vault holds sealed inventory.
The depository is the future market surface when conditions justify opening it.

## Surface Layer

The live protocol also depends on:

- epoch advancement infrastructure
- the public lockboard at `/mine`
- monitoring, analytics, and future dashboard layers

These are important surfaces, but they are not the core protocol rules.

## Design Principle

The system is meant to work as a durable base layer:

- hard supply rules in the core
- live economic state visible onchain
- a shared engine for fair reward distribution
- more experimental UX and composability layers built on top over time

## Official Links

[??](https://www.naraprotocol.io) [??](https://www.naraprotocol.io/mine) [?](https://x.com/NARA_protocol) [??](https://warpcast.com/naraprotocol) [??](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)
