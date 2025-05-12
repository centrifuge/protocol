# Centrifuge Protocol V3 [![Github Actions][gha-badge]][gha] [![Foundry][foundry-badge]][foundry]
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

## Project structure
```
.
├── deployments
├── docs
│  └── audits
├── script
├── src
│  ├── misc
│  ├── common
│  ├── hub
│  └── vaults
├── test
├── foundry.toml
└── README.json
```
- `deployments` contains the deployment information of the supported chains
- `docs` documentation, diagrams and security audit reports
- `script` deployment scripts used to deploy a part or the full system, along with adapters.
- `src` main source containing all the contrats. Look for the interfaces and libraries inside of each module.
  - `misc` generic contracts
  - `common` common code to `hub` and `vaults`
  - `hub` code related to Centrifuge Hub
  - `vaults` code related to Centrifuge Vaults
- `test` cotains all tests: unitary test, integration test per module, and end-to-end integration tests


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
| [Code4rena](https://code4rena.com/)                  | Sep 2023        | Competitive audit          | [`Report`](https://code4rena.com/reports/2023-09-centrifuge)                                                                                                                |
| [SRLabs](https://www.srlabs.de/)                     | Sep 2023        | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2023-09-SRLabs.pdf)                                                                              |
| [Cantina](https://cantina.xyz/)                      | Oct 2023        | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2023-10-Cantina.pdf)                                                                             |
| [Alex the Entreprenerd](https://x.com/gallodasballo) | Mar - Apr 2024  | Review + invariant testing | [`Part 1`](https://getrecon.substack.com/p/lessons-learned-from-fuzzing-centrifuge) [`Part 2`](https://getrecon.substack.com/p/lessons-learned-from-fuzzing-centrifuge-059) |
| [Spearbit](https://spearbit.com/)                    | July 2024       | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2024-08-Spearbit.pdf)                                                                            |
| [Recon](https://getrecon.xyz/) | Jan 2025  | Invariant testing | [`Report`](https://getrecon.substack.com/p/never-stop-improving-your-invariant) |
| [Cantina](https://cantina.xyz/)                      | Feb 2025        | Security review            | [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2025-02-Cantina.pdf)                                                                             |
| [xmxanuel](https://x.com/xmxanuel)                   | Mar 2025       | Security review            |  [`Report`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2025-03-xmxanuel.pdf)                                                                                                                                                                    |
| [burraSec](https://www.burrasec.com/)                      | Apr 2025        | Security review            | [`Part 1`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2025-04-burraSec-1.pdf) [`Part 2`](https://github.com/centrifuge/protocol-v3/blob/main/docs/audits/2025-04-burraSec-2.pdf)                                                                             |
| [Alex the Entreprenerd](https://x.com/gallodasballo)                     | Apr 2025        | Review + invariant testing            | [`Report`](https://github.com/Recon-Fuzz/audits/blob/main/Centrifuge_Protocol_V3.MD)                                                                             |

## License
This codebase is licensed under [Business Source License 1.1](https://github.com/centrifuge/protocol-v3/blob/main/LICENSE).
