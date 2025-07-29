[![Github Actions][gha-badge]][gha] [![Foundry][foundry-badge]][foundry] [![Docs][docs-badge]][docs]

[gha]: https://github.com/centrifuge/protocol-v3/actions
[gha-badge]: https://github.com/centrifuge/protocol-v3/actions/workflows/ci.yml/badge.svg
[foundry]: https://getfoundry.sh
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[docs]: https://docs.centrifuge.io/developer/protocol/overview/
[docs-badge]: https://img.shields.io/badge/Docs-docs.centrifuge.io-6EDFFB.svg

# Centrifuge Protocol V3

Centrifuge V3 is an open, decentralized protocol for onchain asset management. Built on immutable smart contracts, it enables permissionless deployment of customizable tokenization products.

Build a wide range of use cases, from permissioned funds to onchain loans, while enabling fast, secure deployment. ERC-4626 and ERC-7540 vaults allow seamless integration into DeFi.

Using protocol-level chain abstraction, tokenization issuers access liquidity across any network, all managed from one Hub chain of their choice.

## Protocol

Centrifuge V3 operates on a [hub-and-spoke model](https://docs.centrifuge.io/developer/protocol/chain-abstraction/). Each pool chooses a single hub chain, and can tokenize and manage liquidity on many spoke chains.

![](https://docs.centrifuge.io/assets/images/overview-6f95e12a2317402da85bcd8d953f2115.png)

### Centrifuge Hub
* Manage and control your tokens from a single chain of your choice
* Consolidate accounting of all your vaults in a single place
* Control price oracles across all networks
* Manage investment requests from all investors

### Centrifuge Spoke
* Tokenize ownership using ERC-20 - customizable with modules of your choice
* Distribute to DeFi with ERC-4626 and ERC-7540 vaults
* Multiple vaults supported for pooled liquidity from different assets
* Support 1:1 token transfers between chains using burn-and-mint process

## Project structure
```
.
├── deployments
├── docs
│  └── audits
├── script
├── src
├── test
├── foundry.toml
└── README.json
```

- [`docs`](./docs) documentation, diagrams and security audit reports
- [`env`](./env) contains the deployment information of the supported chains
- [`script`](./script) deployment scripts used to deploy a part or the full system, along with adapters.
- [`src`](./src) main source containing all the contrats. Look for the interfaces and libraries inside of each module.
- [`test`](./test) contains all tests: unit tests, integration test per module, and end-to-end integration tests


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

## Security

Reports from security reviews can be found in the [documentation](https://docs.centrifuge.io/developer/protocol/security/).

## License
The primary license is the [Business Source License 1.1](https://github.com/centrifuge/protocol-v3/blob/main/LICENSE). However, all files in the [`src/misc`](./src/misc) folder, [`src/managers/MerkleProofManager.sol`](./src/managers/MerkleProofManager.sol), and any interface file can also be licensed under `GPL-2.0-or-later` (as indicated in their SPDX headers).
