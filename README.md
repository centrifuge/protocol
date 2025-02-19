# Liquidity Pools [![Github Actions][gha-badge]][gha] [![Foundry][foundry-badge]][foundry] [![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/centrifuge/liquidity-pools/blob/main/LICENSE)
[gha]: https://github.com/centrifuge/liquidity-pools/actions
[gha-badge]: https://github.com/centrifuge/liquidity-pools/actions/workflows/ci.yml/badge.svg
[foundry]: https://getfoundry.sh
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

Liquidity Pools enable seamless deployment of Centrifuge pools on any EVM-compatible blockchain. The multi-chain protocol was designed specifically to tokenize RWAs as ERC20 tokens featuring customizable and gas-efficient permissioning. Investors deposit and redeem onchain using the ERC7540 asynchronous tokenized vault standard. Issuers can plug-and-play custom investment features through ERC20 wrapper support and accept multiple stablecoins using ERC7575. The smart contracts are immutable, rigorously audited, and controlled by onchain governance.

## How it works
![Architecture](https://cloudflare-ipfs.com/ipfs/QmW7N8beQ6TF5efwqkMndouxGub2J1jqsEhv5gXDbyqA2K)

Investors can invest in multiple tranches for each RWA pool. Each of these tranches is a separate deployment of an [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) Vault and a Tranche Token.
- [**ERC7540Vault**](https://github.com/centrifuge/liquidity-pools/blob/main/src/ERC7540Vault.sol): An [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) (extension of [ERC-4626](https://ethereum.org/en/developers/docs/standards/tokens/erc-4626/)) compatible contract that enables investors to deposit and withdraw stablecoins to invest in tranches of pools.
- [**Tranche Token**](https://github.com/centrifuge/liquidity-pools/blob/main/src/token/Tranche.sol): An [ERC-20](https://ethereum.org/en/developers/docs/standards/tokens/erc-20/) token for the tranche, linked to a [`RestrictionManager`](https://github.com/centrifuge/liquidity-pools/blob/main/src/token/RestrictionManager.sol) that manages transfer restrictions. Prices for tranche tokens are computed on Centrifuge.

The deployment of these tranches and the management of investments is controlled by the underlying InvestmentManager, PoolManager, Gateway and Adapters.
- [**Investment Manager**](https://github.com/centrifuge/liquidity-pools/blob/main/src/InvestmentManager.sol): The core business logic contract that handles pool creation, tranche deployment, managing investments and sending tokens to the [`Escrow`](https://github.com/centrifuge/liquidity-pools/blob/main/src/Escrow.sol), and more.
- [**Pool Manager**](https://github.com/centrifuge/liquidity-pools/blob/main/src/PoolManager.sol): The second business logic contract that handles asset bookkeeping, and transferring tranche tokens as well as assets.
- [**Gateway**](https://github.com/centrifuge/liquidity-pools/blob/main/src/gateway/Gateway.sol): Multi-Message Aggregation (MMA) implementation, receiving messages from managers, sending these messages as full payload to 1 adapter and a proof to n-1 adapters, and verifying incoming payloads and proofs and sending back to managers.
- [**Adapters**](https://github.com/centrifuge/liquidity-pools/tree/main/src/gateway/adapters): Adapter implementations for messaging layers.

## Developing
#### Getting started
```sh
git clone git@github.com:centrifuge/liquidity-pools.git
cd liquidity-pools
forge update
```

#### Testing
To run all tests locally:
```sh
forge test
```

To run the invariant tests using [echidna](https://github.com/crytic/echidna):
```sh
echidna . --contract CryticTester --config test/vaults/fuzzing/recon-core/echidna.yaml --test-mode assertion
echidna . --contract CryticTester --config test/vaults/fuzzing/recon-core/echidna.yaml --test-mode property
```

To run the invariant tests using [medusa](https://github.com/crytic/medusa/):
```sh
medusa fuzz --config test/vaults/fuzzing/recon-core/medusa-core.json
medusa fuzz --config test/vaults/fuzzing/recon-aggregator/medusa-aggregator.json
```

## Audit reports

| Auditor    | Date    | Engagement                               | Report                                                                                                                                    |
| --- | --- |:------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| [xmxanuel](https://x.com/xmxanuel)  | July 2023  | Security review         |  Internal |
| [Code4rena](https://code4rena.com/)  | Sep 2023  | Competitive audit       | [`Report`](https://code4rena.com/reports/2023-09-centrifuge)                                                        |
| [SRLabs](https://www.srlabs.de/)  | Sep 2023  | Security review               | [`Report`](https://github.com/centrifuge/liquidity-pools/blob/main/audits/2023-09-SRLabs.pdf)                          |
| [Cantina](https://cantina.xyz/)  | Oct 2023  | Security review             | [`Report`](https://github.com/centrifuge/liquidity-pools/blob/main/audits/2023-10-Cantina.pdf) |
| [Alex the Entreprenerd](https://x.com/gallodasballo)  | Mar - Apr 2024  | Invariant test development | [`Part 1`](https://getrecon.substack.com/p/lessons-learned-from-fuzzing-centrifuge) [`Part 2`](https://getrecon.substack.com/p/lessons-learned-from-fuzzing-centrifuge-059)  |
| [xmxanuel](https://x.com/xmxanuel)  | May - June 2024  | Security review | Internal                                                                                                                                               |
| [Spearbit](https://spearbit.com/)  | July 2024  | Security review             | [`Report`](https://github.com/centrifuge/liquidity-pools/blob/main/audits/2024-08-Spearbit.pdf) |

## License
This codebase is licensed under [GNU Lesser General Public License v3.0](https://github.com/centrifuge/liquidity-pools/blob/main/LICENSE).
