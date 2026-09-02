// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";

import {AccountId} from "../../../src/core/types/AccountId.sol";

import {MAX_MESSAGE_COST} from "../../utils/GasConstants.sol";

/// @title IntegrationConstants
/// @notice Centralized constants for integration tests
library IntegrationConstants {
    // ======== Network IDs ========
    uint16 constant CENTRIFUGE_ID_A = 1;
    uint16 constant CENTRIFUGE_ID_B = 2;
    uint16 constant CENTRIFUGE_ID_C = 3;
    uint16 constant LOCAL_CENTRIFUGE_ID = 4;

    // ======== Amounts ========
    uint128 constant DEFAULT_USDC_AMOUNT = 1e12; // 1M USDC

    // ======== Account IDs ========
    AccountId constant ASSET_ACCOUNT = AccountId.wrap(0x01);
    AccountId constant EQUITY_ACCOUNT = AccountId.wrap(0x02);
    AccountId constant LOSS_ACCOUNT = AccountId.wrap(0x03);
    AccountId constant GAIN_ACCOUNT = AccountId.wrap(0x04);

    // ======== Decimals ========
    uint8 constant USDC_DECIMALS = 6;
    uint8 constant POOL_DECIMALS = 18;

    // ======== Gas Values ========
    uint128 constant GAS = MAX_MESSAGE_COST;
    uint256 constant DEFAULT_SUBSIDY = 0.1 ether;
    uint256 constant INTEGRATION_DEFAULT_SUBSIDY = 1 ether;
    uint128 constant HOOK_GAS = 0 ether;
    uint128 constant EXTRA_GAS = 0;
    /// @dev Extra gas shipped with ShareManager revoke manager calls, whose pull + approve + burn
    ///      sequence exceeds the light fromHub targets the ManagerCallFromHub estimate started from.
    uint128 constant SHARE_REVOKE_EXTRA_GAS = 300_000;

    // ======== Misc Constants ========
    uint256 constant PLACEHOLDER_REQUEST_ID = 0;

    // ======== Price Retrieval Functions ========
    function zeroPrice() internal pure returns (D18) {
        return d18(0);
    }

    function identityPrice() internal pure returns (D18) {
        return d18(1, 1);
    }

    function assetPrice() internal pure returns (D18) {
        return d18(1, 2);
    }

    function sharePrice() internal pure returns (D18) {
        return d18(4, 1);
    }
}
