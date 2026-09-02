// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC165} from "../../../../src/misc/interfaces/IERC7575.sol";
import {IERC7540Deposit, IERC7887Deposit} from "../../../../src/misc/interfaces/IERC7540.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

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

    function getRandomPoolId(uint64[] memory createdPools, uint64 poolEntropy) internal pure returns (PoolId) {
        return PoolId.wrap(createdPools[poolEntropy % createdPools.length]);
    }

    function getRandomShareClassIdForPool(IShareClassManager shareClassManager, PoolId poolId, uint32 scEntropy)
        internal
        view
        returns (ShareClassId)
    {
        uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
        uint32 randomIndex = scEntropy % (shareClassCount + 1);
        if (randomIndex == 0) {
            // the first share class is never assigned
            randomIndex = 1;
        }

        ShareClassId scId = shareClassManager.previewShareClassId(poolId, randomIndex);
        return scId;
    }

    function getRandomAccountId(
        IHoldings holdings,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint8 accountEntropy
    ) internal view returns (AccountId) {
        uint8 accountType = accountEntropy % 6;
        return holdings.accountId(poolId, scId, assetId, accountType);
    }

    function getRandomAccountId(AccountId[] memory createdAccountIds, uint8 accountEntropy)
        internal
        pure
        returns (AccountId)
    {
        return createdAccountIds[accountEntropy % createdAccountIds.length];
    }

    /// @dev Picks an account distinct from the one `firstEntropy` selects. A holding that binds the same
    ///      AccountId to a settlement slot and its counterpart nets every journal entry to zero, which
    ///      makes the accounting-vs-holdings invariants trivially false without any misconfiguration a
    ///      pool would plausibly create.
    function getDistinctAccountId(AccountId[] memory createdAccountIds, uint8 firstEntropy, uint8 secondEntropy)
        internal
        pure
        returns (AccountId)
    {
        uint256 length = createdAccountIds.length;
        uint256 spread = length > 1 ? length - 1 : 1;
        uint256 index = (firstEntropy % length + 1 + secondEntropy % spread) % length;

        return createdAccountIds[index];
    }

    /// @dev performs the same check as SCM::_updateQueued
    function canMutate(uint32 lastUpdate, uint128 pending, uint128 latestApproval) internal pure returns (bool) {
        return latestApproval == 0 || pending == 0 || lastUpdate > latestApproval;
    }

    function isAsyncVault(address vault) internal view returns (bool) {
        return IERC165(vault).supportsInterface(type(IERC7540Deposit).interfaceId)
            || IERC165(vault).supportsInterface(type(IERC7887Deposit).interfaceId);
    }
}
