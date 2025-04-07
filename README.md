# Centrifuge Protocol V3 [![Github Actions][gha-badge]][gha] [![Foundry][foundry-badge]][foundry] [![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://github.com/centrifuge/protocol-v3/blob/main/LICENSE)
[gha]: https://github.com/centrifuge/protocol-v3/actions
[gha-badge]: https://github.com/centrifuge/protocol-v3/actions/workflows/ci.yml/badge.svg
[foundry]: https://getfoundry.sh
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

Centrifuge V3 is an open, decentralized protocol for onchain asset management. Built on immutable smart contracts, it enables permissionless deployment of customizable tokenization products.

Build a wide range of use cases—from permissioned funds to onchain loans—while enabling fast, secure deployment. ERC-4626 and ERC-7540 vaults allow seamless integration into DeFi. 

Using protocol-level chain abstraction, tokenization issuers access liquidity across any network, all managed from one Hub chain of their choice.

### Centrifuge Vaults

* Tokenize ownership using ERC-20 — customizable with modules of your choice
* Distribute to DeFi with ERC-4626 and ERC-7540 vaults
* Support 1:1 token transfers between chains using burn-and-mint process

### Centrifuge Hub

* Manage and control your vaults from a single chain of your choice
* Consolidate accounting of all your vaults in a single place
* Manage both RWAs & DeFi-native assets

## Contributing
#### Getting started
```sh
git clone git@github.com:centrifuge/protocol-v3.git
cd protocol-v3
```

#### Testing
To build and run all tests locally:
```sh
forge test
```

## Audit reports

| Auditor                                              | Date            | Engagement                 | Report                                                                                                                                                                      |
| ---------------------------------------------------- | --------------- | :------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [xmxanuel](https://x.com/xmxanuel)                   | July 2023       | Security review            | Internal                                                                                                                                                                    |
| [Code4rena](https://code4rena.com/)                  | Sep 2023        | Competitive audit          | [`Report`](https://code4rena.com/reports/2023-09-centrifuge)                                                                                                                |
| [SRLabs](https://www.srlabs.de/)                     | Sep 2023        | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2023-09-SRLabs.pdf)                                                                              |
| [Cantina](https://cantina.xyz/)                      | Oct 2023        | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2023-10-Cantina.pdf)                                                                             |
| [Alex the Entreprenerd](https://x.com/gallodasballo) | Mar - Apr 2024  | Invariant test development | [`Part 1`](https://getrecon.substack.com/p/lessons-learned-from-fuzzing-centrifuge) [`Part 2`](https://getrecon.substack.com/p/lessons-learned-from-fuzzing-centrifuge-059) |
| [xmxanuel](https://x.com/xmxanuel)                   | May - June 2024 | Security review            | Internal                                                                                                                                                                    |
| [Spearbit](https://spearbit.com/)                    | July 2024       | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2024-08-Spearbit.pdf)                                                                            |
| [Cantina](https://cantina.xyz/)                      | Feb 2025        | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2025-02-Cantina.pdf)                                                                             |

## License
This codebase is licensed under [Business Source License 1.1](https://github.com/centrifuge/protocol-v3/blob/main/LICENSE).
