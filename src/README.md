# Project structure
```
.
├── src
├── misc
├── common
├── hub
├── spoke
├── managers
├── vaults
├── hooks
└── valuations
```

- [`misc`](./msic) generic contracts
- [`common`](./common) common code to `hub` and `spoke`
- [`hub`](./hub) code related to Centrifuge Hub
- [`spoke`](./spoke) code related to Centrifuge Spoke
- [`managers`](./managers) extension of Centrifuge, for custom hub and balance sheet managers
- [`vaults`](./vaults) extension of Centrifuge Spoke, for ERC-4626 and ERC-7540 vaults
- [`hooks`](./hooks) extension of Centrifuge Spoke, for implementing transfer hooks
- [`valuations`](./valuations) extension of Centrifuge Hub, for custom valuation logic

