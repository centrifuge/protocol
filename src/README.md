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

- `misc` generic contracts
- `common` common code to `hub` and `spoke`
- `hub` code related to Centrifuge Hub
- `spoke` code related to Centrifuge Spoke
- `managers` extension of Centrifuge, for custom hub and balance sheet managers
- `vaults` extension of Centrifuge Spoke, for ERC-4626 and ERC-7540 vaults
- `hooks` extension of Centrifuge Spoke, for implementing transfer hooks
- `valuations` extension of Centrifuge Hub, for custom valuation logic

