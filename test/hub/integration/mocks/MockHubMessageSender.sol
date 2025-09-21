// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../../src/misc/types/D18.sol";
import {PoolId} from "../../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../../src/common/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../../../src/common/libraries/MessageLib.sol";
import {IHubMessageSender} from "../../../../src/common/interfaces/IGatewaySenders.sol";

contract MockHubMessageSender is IHubMessageSender {
    function localCentrifugeId() external pure returns (uint16) {
        return 1;
    }

    function sendNotifyPool(uint16, PoolId) external pure returns (uint256) {
        return 0;
    }

    function sendNotifyShareClass(uint16, PoolId, ShareClassId, string memory, string memory, uint8, bytes32, bytes32)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function sendNotifyShareMetadata(uint16, PoolId, ShareClassId, string memory, string memory)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function sendUpdateShareHook(uint16, PoolId, ShareClassId, bytes32) external pure returns (uint256) {
        return 0;
    }

    function sendNotifyPricePoolPerShare(uint16, PoolId, ShareClassId, D18) external pure returns (uint256) {
        return 0;
    }

    function sendNotifyPricePoolPerAsset(PoolId, ShareClassId, AssetId, D18) external pure returns (uint256) {
        return 0;
    }

    function sendUpdateRestriction(uint16, PoolId, ShareClassId, bytes calldata, uint128)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function sendUpdateContract(uint16, PoolId, ShareClassId, bytes32, bytes calldata, uint128)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function sendUpdateVault(PoolId, ShareClassId, AssetId, bytes32, VaultUpdateKind, uint128)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function sendSetRequestManager(uint16, PoolId, bytes32) external pure returns (uint256) {
        return 0;
    }

    function sendUpdateBalanceSheetManager(uint16, PoolId, bytes32, bool) external pure returns (uint256) {
        return 0;
    }

    function sendExecuteTransferShares(uint16, uint16, PoolId, ShareClassId, bytes32, uint128, uint128)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function sendMaxAssetPriceAge(PoolId, ShareClassId, AssetId, uint64) external pure returns (uint256) {
        return 0;
    }

    function sendMaxSharePriceAge(uint16, PoolId, ShareClassId, uint64) external pure returns (uint256) {
        return 0;
    }

    function sendSetPoolAdapters(uint16, PoolId, bytes32[] memory, uint8, uint8) external pure returns (uint256) {
        return 0;
    }

    function sendSetGatewayManager(uint16, PoolId, bytes32) external pure returns (uint256) {
        return 0;
    }

    function sendRequestCallback(PoolId, ShareClassId, AssetId, bytes calldata, uint128)
        external
        pure
        returns (uint256 cost)
    {
        return 0; // Mock implementation returns zero cost
    }
}
