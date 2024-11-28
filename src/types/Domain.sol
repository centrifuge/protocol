// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type PoolId is uint64;

type AssetId is address;

type ShareClassId is bytes16;

type PoolAmount is uint256;

// TODO: Check whether downgrade to uint128 is feasible due to CV messages using uint128 as inheritance from Rust
type ShareClassAmount is uint256;

// TODO: Check whether downgrade to uint128 is feasible due to CV messages using uint128 as inheritance from Rust
type AssetAmount is uint256;

// NOTE: Only used temporarily
type Ratio is uint128;

// @dev: Suffices for ~135 years of advancing an epoch each second
type EpochId is uint32;
