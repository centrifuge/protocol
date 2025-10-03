// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Interfaces
import {UserOrder} from "src/hub/interfaces/IShareClassManager.sol";
import {AccountId} from "src/hub/interfaces/IAccounting.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";

// Types
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {EpochId} from "src/hub/interfaces/IShareClassManager.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// Recon Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {Setup} from "./Setup.sol";

enum OpType {
    GENERIC,
    DEPOSIT,
    REDEEM,
    BATCH // batch operations that make multiple calls in one transaction

}

// ghost variables for tracking state variable values before and after function calls
abstract contract BeforeAfter is Setup {
    struct Vars {
        uint128 ghostDebited;
        uint128 ghostCredited;
        mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
            ghostRedeemRequest;
        mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint128 assetAmountValue)))
            ghostHolding;
        mapping(PoolId poolId => mapping(AccountId accountId => uint128 accountValue)) ghostAccountValue;
        mapping(ShareClassId scId => mapping(AssetId assetId => EpochId)) ghostEpochId;
    }

    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;
        __before();
        _;
        __after();
    }

    function __before() internal {
        _before.ghostDebited = accounting.debited();
        _before.ghostCredited = accounting.credited();

        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            // loop through all share classes for the pool
            for (uint32 j = 0; j < shareClassManager.shareClassCount(poolId); j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 depositEpochId, uint32 redeemEpochId, uint32 issueEpochId, uint32 revokeEpochId) =
                    shareClassManager.epochId(scId, assetId);
                _before.ghostEpochId[scId][assetId] = EpochId({
                    deposit: depositEpochId,
                    redeem: redeemEpochId,
                    issue: issueEpochId,
                    revoke: revokeEpochId
                });

                (, _before.ghostHolding[poolId][scId][assetId],,) = holdings.holding(poolId, scId, assetId);
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = CastLib.toBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, actor);
                    _before.ghostRedeemRequest[scId][assetId][actor] =
                        UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }

                // loop over all account types defined in IHub::AccountType
                for (uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (,,, uint64 lastUpdated,) = accounting.accounts(poolId, accountId);
                    // accountValue is only set if the account has been updated
                    if (lastUpdated != 0) {
                        (bool isPositive, uint128 accountValue) = accounting.accountValue(poolId, accountId);
                        _before.ghostAccountValue[poolId][accountId] = accountValue;
                    }
                }
            }
        }
    }

    function __after() internal {
        _after.ghostDebited = accounting.debited();
        _after.ghostCredited = accounting.credited();

        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];

            // loop through all share classes for the pool
            for (uint32 j = 0; j < shareClassManager.shareClassCount(poolId); j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (uint32 depositEpochId, uint32 redeemEpochId, uint32 issueEpochId, uint32 revokeEpochId) =
                    shareClassManager.epochId(scId, assetId);
                _after.ghostEpochId[scId][assetId] = EpochId({
                    deposit: depositEpochId,
                    redeem: redeemEpochId,
                    issue: issueEpochId,
                    revoke: revokeEpochId
                });
                (, _after.ghostHolding[poolId][scId][assetId],,) = holdings.holding(poolId, scId, assetId);
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = CastLib.toBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, actor);
                    _after.ghostRedeemRequest[scId][assetId][actor] =
                        UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }

                // loop over all account types defined in IHub::AccountType
                for (uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (,,, uint64 lastUpdated,) = accounting.accounts(poolId, accountId);
                    // accountValue is only set if the account has been updated
                    if (lastUpdated != 0) {
                        (bool isPositive, uint128 accountValue) = accounting.accountValue(poolId, accountId);
                        _after.ghostAccountValue[poolId][accountId] = accountValue;
                    }
                }
            }
        }
    }
}
