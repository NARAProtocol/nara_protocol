# Current State

Last updated: 2026-03-22
This file is the public source of truth for the live NARA deployment.


## Live Base Contracts

| Contract | Address |
| --- | --- |
| NARATokenV3 | `0xE444de61752bD13D1D37Ee59c31ef4e489bd727C` |
| NARARewardReserve | `0xC425F45f3e108cA4E49f86E01C6d256e6c572876` |
| NARAEngineV2 | `0x62250aEE40F37e2eb2cd300E5a429d7096C8868F` |
| NARABondVault | `0xcCe364b9cF815D47B0338aAd960367CdE8E3525D` |
| NARABondDepository | `0x590200d8a81bc8B997314BAD9d1bFC7926d24b93` |
| Uniswap V3 NARA/WETH 0.3% pool | `0x71528CC56F44950aA74C3D656D2bD3502BAD2e91` |

## Verified Snapshot

Verified on Base at block `43,703,057` on 2026-03-22:

- total supply: `1,000,000 NARA`
- reward reserve available: `699,999.752019683961719265 NARA`
- bond vault balance: `250,000 NARA`
- engine token balance: `30,000.102340915383033657 NARA`
- total locked: `30,000 NARA`
- active total weight: `90,000`
- current epoch: `515`
- processed epoch: `514`
- backlog: `1`
- lock fee: `2%` plus `0.0001 ETH`
- claim fee: `5%`
- activation delay: `8 epochs`
- max lock length: `35040 epochs`

## Verified Launch Locks

### Treasury token wallet

- wallet: `0xfe3A8678A9c729438BB11718bD1391E7Ab491E8e`
- one live max-duration position
- `20,000 NARA`
- weight `60,000`
- activation epoch `343`

### Owner signer wallet

- wallet: `0xC019Dc79412c4b20103ac4ce97B2615FF45D490d`
- one live max-duration position
- `10,000 NARA`
- weight `30,000`
- activation epoch `344`

## Bond Status

The bond contracts are deployed but not open.

Verified bond state on 2026-03-22:

- depository `paused = false`
- depository `active = true`
- market open = `false`
- vault market = zero address
- release cap = `0`
- remaining capacity = `0`

Interpretation: the bond stack exists, but there is no live public sale path yet.

## Practical Takeaway

Right now, the live NARA story is:

- fixed supply
- sealed reserves
- a live engine distributing rewards by active weight
- locking live
- bonds closed
- very thin liquid float
- the first public onboarding surface is the lockboard at `/mine`

The important product fact is that the engine is already the shared distribution layer for protocol rewards, and future products can route earnings into that same layer.

## Official Links

[??](https://www.naraprotocol.io) [??](https://www.naraprotocol.io/mine) [?](https://x.com/NARA_protocol) [??](https://warpcast.com/naraprotocol) [??](https://app.uniswap.org/swap?chain=base&outputCurrency=0xE444de61752bD13D1D37Ee59c31ef4e489bd727C)
