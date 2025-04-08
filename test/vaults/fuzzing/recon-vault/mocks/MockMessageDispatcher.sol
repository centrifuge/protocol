// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {JournalEntry, Meta} from "src/common/libraries/JournalEntryLib.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

contract MockMessageDispatcher {
    PoolManager public poolManager;
    IAsyncRequests public asyncRequests;
    IRoot public root;

    uint16 public localCentrifugeId;

    constructor(
        PoolManager _poolManager, 
        IAsyncRequests _asyncRequests, 
        IRoot _root, 
        uint16 _localCentrifugeId
    ) {
        poolManager = _poolManager;
        asyncRequests = _asyncRequests;
        root = _root;
        localCentrifugeId = _localCentrifugeId;
    }

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
        if (chainId == localCentrifugeId) {
            poolManager.addShareClass(poolId.raw(), scId.raw(), name, symbol, decimals, salt, address(bytes20(hook)));
        } else {
            
        }
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
            asyncRequests.fulfillDepositRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), assetAmount, shareAmount
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
            asyncRequests.fulfillRedeemRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), assetAmount, shareAmount
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
            asyncRequests.fulfillCancelDepositRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), cancelledAmount, cancelledAmount
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
            asyncRequests.fulfillCancelRedeemRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), cancelledShares
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
            poolManager.updateContract(poolId.raw(), scId.raw(), address(bytes20(target)), payload);
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
            poolManager.handleTransferShares(poolId, scId, address(bytes20(receiver)), amount);
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

    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        bool isIncrease,
        Meta calldata meta
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

    function sendRegisterAsset(
        uint16 chainId,
        uint128 assetId,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external  {
    }
}
