---
paths:
  - "src/core/**"
  - "src/misc/**"
  - "src/admin/GasService.sol"
  - "src/admin/interfaces/IAdapterGasService.sol"
  - "src/admin/interfaces/ICreatePool.sol"
  - "src/admin/interfaces/IGasService.sol"
  - "src/token/ShareToken.sol"
  - "src/token/interfaces/IShareToken.sol"
  - "src/token/interfaces/ITransferHook.sol"
  - "src/vaults/**"
  - "src/hooks/**"
  - "src/valuations/**"
  - "src/policies/**"
  - "src/adapters/**"
  - "src/admin/Root.sol"
  - "src/token/ShareTokenRegistrar.sol"
---

# Formal verification

The Certora proofs in the `certora/` submodule cover the core as it was at commit `74e16461`, and nothing re-runs them on a change. They stay trustworthy only while every PR states what it did to the code they rely on, so the team can schedule re-verification.

## Verified code

The proofs compile every contract in `src/core` except `PricingLib` and `Envoy`, plus the `src/misc`, `GasService` and `ShareToken` code those contracts import. A change to the logic of any of it ends the PR description with `FV: needs re-verification of <contracts>`, naming each verified contract it changed. A change limited to whitespace, comments, or code no verified contract calls gets `FV: no effect on verified code` with the reason.

## Contracts the proofs stand in for

Request managers, vault factories, hooks, valuations, policies, adapters, `Envoy`, `Root` and `ShareTokenRegistrar` are not verified. The core proofs replace each with a stand-in in `certora/specs/shared/models/` that changes nothing in core. A change that makes one of them call back into a core contract while core is calling it takes that path outside the proofs: add `FV: <contract> now calls back into <core contract>` to the PR description.
