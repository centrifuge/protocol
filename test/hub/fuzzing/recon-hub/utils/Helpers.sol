// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

library Helpers {
    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return bytes32 bytes32 representation of the address.
     */
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /// === Helpers === ///
    function getRandomPoolId(PoolId[] memory createdPools, uint64 poolEntropy) internal pure returns (PoolId) {
        return createdPools[poolEntropy % createdPools.length];
    }

    function getRandomShareClassIdForPool(IShareClassManager shareClassManager, PoolId poolId, uint32 scEntropy) internal view returns (ShareClassId) {
        uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
        uint32 randomIndex = scEntropy % (shareClassCount + 1);
        if(randomIndex == 0) {
            // the first share class is never assigned
            randomIndex = 1;
        }

        ShareClassId scId = shareClassManager.previewShareClassId(poolId, randomIndex);
        return scId;
    }

    function getRandomAccountId(IHoldings holdings, PoolId poolId, ShareClassId scId, AssetId assetId, uint8 accountEntropy) internal view returns (AccountId) {
        uint8 accountType = accountEntropy % 6;
        return holdings.accountId(poolId, scId, assetId, accountType);
    }

    function getRandomAccountId(AccountId[] memory createdAccountIds, uint8 accountEntropy) internal pure returns (AccountId) {
        return createdAccountIds[accountEntropy % createdAccountIds.length];
    }

    function getRandomAssetId(AssetId[] memory createdAssetIds, uint128 assetEntropy) internal pure returns (AssetId) {
        uint128 randomIndex = assetEntropy % createdAssetIds.length;
        return createdAssetIds[randomIndex];
    }

    /// @dev performs the same check as SCM::_updateQueued
    function canMutate(uint32 lastUpdate, uint128 pending, uint128 latestApproval) internal pure returns (bool) {
        return lastUpdate > latestApproval || pending == 0 || latestApproval == 0;
    }
}
