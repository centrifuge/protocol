// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DisableV2Common} from "./DisableV2Common.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

/// @notice Ethereum-specific spell that disables V2 permissions for both JTRSY_USDC and JAAA_USDC
contract DisableV2Eth is DisableV2Common {
    address public constant V3_JAAA_VAULT = 0x4880799eE5200fC58DA299e965df644fBf46780B;
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    PoolId public constant JAAA_POOL_ID = PoolId.wrap(281474976710663);
    ShareClassId public constant JAAA_SHARE_CLASS_ID = ShareClassId.wrap(0x00010000000000070000000000000001);

    address public constant V2_JTRSY_VAULT_ADDRESS = address(0x36036fFd9B1C6966ab23209E073c68Eb9A992f50);
    address public constant V2_JAAA_VAULT_ADDRESS = address(0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01);

    /// @inheritdoc DisableV2Common
    function getJTRSYVaultV2Address() internal pure override returns (address) {
        return V2_JTRSY_VAULT_ADDRESS;
    }

    function execute() internal override {
        super.execute();

        _disableV2Permissions(JAAA_SHARE_TOKEN, V2_JAAA_VAULT_ADDRESS);
        _setV3Hook(JAAA_SHARE_TOKEN);
        _linkTokenToV3Vault(JAAA_SHARE_TOKEN, V3_JAAA_VAULT, JAAA_POOL_ID, JAAA_SHARE_CLASS_ID);

        _cleanupRootPermissions();
    }
}
