// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

/// @dev Reference for the most expensive message, used to fund test sends and to bound the gas limits.
///      Not enforced anywhere in the protocol, which is why it lives here rather than in src.
///      Sits above UpdateVault DeployAndLink to Monad, the most expensive message on the most expensive
///      chain, which needs ~3.47M once its cold-access surcharge is applied.
uint128 constant MAX_MESSAGE_COST = 4_000_000;
