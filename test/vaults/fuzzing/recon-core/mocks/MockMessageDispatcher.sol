// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAsyncRequestManager} from "src/vaults/interfaces/investments/IAsyncRequestManager.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

contract MockMessageDispatcher {
    PoolManager public poolManager;
    IAsyncRequestManager public asyncRequestManager;
    IRoot public root;

    uint16 public localCentrifugeId;

    function setLocalCentrifugeId(uint16 _localCentrifugeId) external {
        localCentrifugeId = _localCentrifugeId;
    }

    function sendNotifyPool(uint16 chainId, PoolId poolId) external  {
       
    }

    function sendNotifyShareClass(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external  {
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external  {
        if (assetId.centrifugeId() == localCentrifugeId) {
            asyncRequestManager.fulfillDepositRequest(
                poolId, scId, address(bytes20(investor)), assetId, assetAmount, shareAmount
            );
        } else {
            
        }
    }

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external  {
        if (assetId.centrifugeId() == localCentrifugeId) {
            asyncRequestManager.fulfillRedeemRequest(
                poolId, scId, address(bytes20(investor)), assetId, assetAmount, shareAmount
            );
        } else {
        }
    }

    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external  {
        if (assetId.centrifugeId() == localCentrifugeId) {
            asyncRequestManager.fulfillCancelDepositRequest(
                poolId, scId, address(bytes20(investor)), assetId, cancelledAmount, cancelledAmount
            );
        } else {
        }
    }

    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external  {
        if (assetId.centrifugeId() == localCentrifugeId) {
            asyncRequestManager.fulfillCancelRedeemRequest(
                poolId, scId, address(bytes20(investor)), assetId, cancelledShares
            );
        } else {
        }
    }

    function sendUpdateContract(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external  {
        if (chainId == localCentrifugeId) {
            poolManager.updateContract(poolId, scId, address(bytes20(target)), payload);
        } else {
        }
    }

    function sendScheduleUpgrade(uint16 chainId, bytes32 target) external  {
        if (chainId == localCentrifugeId) {
            root.scheduleRely(address(bytes20(target)));
        } else {
        }
    }

    function sendCancelUpgrade(uint16 chainId, bytes32 target) external  {
        if (chainId == localCentrifugeId) {
            root.cancelRely(address(bytes20(target)));
        } else {
        }
    }

    function sendInitiateMessageRecovery(uint16 chainId, uint16 adapterChainId, bytes32 adapter, bytes32 hash)
        external
    {
    }

    function sendDisputeMessageRecovery(uint16 chainId, uint16 adapterChainId, bytes32 adapter, bytes32 hash)
        external
    {
    }

    function sendTransferShares(uint16 chainId, uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount)
        external
    {
        if (chainId == localCentrifugeId) {
            poolManager.handleTransferShares(PoolId.wrap(poolId), ShareClassId.wrap(scId), address(bytes20(receiver)), amount);
        }
    }

    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
    {
    }

    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
    {
    }

    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external  {
        
    }

    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external  {
       
    }

    function sendApprovedDeposits(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount)
        external
    {}

    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        bool isIncrease
    ) external  {
    }

    function sendUpdateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePerUnit)
        external
    {
    }

    function sendUpdateShares(
        PoolId poolId,
        ShareClassId scId,
        address receiver,
        D18 pricePerShare,
        uint128 shares,
        bool isIssuance
    ) external  {
    }

    function sendJournalEntry(PoolId poolId, JournalEntry[] calldata debits, JournalEntry[] calldata credits)
        external
    {
    }

    function sendRegisterAsset( uint16 centrifugeId, uint128 assetId, uint8 decimals) external  {
    }

    function sendRevokedShares(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount) external  {
    }
}
