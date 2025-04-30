// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {
    IInvestmentManagerGatewayHandler,
    IPoolManagerGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {ITokenRecoverer} from "src/common/interfaces/ITokenRecoverer.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

contract MockMessageDispatcher {
    using CastLib for *;
    using MathLib for uint256;


    IRoot public root;
    address public gateway;
    address public tokenRecoverer;

    uint16 public localCentrifugeId;

    IHubGatewayHandler public hub;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetGatewayHandler public balanceSheet;

    function file(bytes32 what, address data) external {
        if (what == "hub") hub = IHubGatewayHandler(data);
        else if (what == "poolManager") poolManager = IPoolManagerGatewayHandler(data);
        else if (what == "investmentManager") investmentManager = IInvestmentManagerGatewayHandler(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
    }

    function setLocalCentrifugeId(uint16 _localCentrifugeId) external {
        localCentrifugeId = _localCentrifugeId;
    }

    function sendNotifyPool(uint16 chainId, PoolId poolId) external  {
       poolManager.addPool(poolId);
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
        poolManager.addShareClass(poolId, scId, name, symbol, decimals, salt, hook.toAddress());
    }

    function sendNotifyPricePoolPerShare(uint16 chainId, PoolId poolId, ShareClassId scId, D18 sharePrice)
        external
    {
        uint64 timestamp = block.timestamp.toUint64();
        poolManager.updatePricePoolPerShare(poolId, scId, sharePrice.raw(), timestamp);
    }

    function sendNotifyPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price) external {
        uint64 timestamp = block.timestamp.toUint64();
        poolManager.updatePricePoolPerAsset(poolId, scId, assetId, price.raw(), timestamp);
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external  {
        investmentManager.fulfillDepositRequest(
            poolId, scId, address(bytes20(investor)), assetId, assetAmount, shareAmount
        );
    }

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external  {
        investmentManager.fulfillRedeemRequest(
            poolId, scId, address(bytes20(investor)), assetId, assetAmount, shareAmount
        );
    }

    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external  {
        investmentManager.fulfillCancelDepositRequest(
            poolId, scId, address(bytes20(investor)), assetId, cancelledAmount, cancelledAmount
        );
    }

    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external  {
        investmentManager.fulfillCancelRedeemRequest(
            poolId, scId, address(bytes20(investor)), assetId, cancelledShares
        );
    }

    function sendUpdateRestriction(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes calldata payload)
        external
    {
        poolManager.updateRestriction(poolId, scId, payload);
    }

    function sendUpdateContract(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external  {
    }

    function sendScheduleUpgrade(uint16 chainId, bytes32 target) external  {
    }

    function sendCancelUpgrade(uint16 chainId, bytes32 target) external  {
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
        poolManager.handleTransferShares(PoolId.wrap(poolId), ShareClassId.wrap(scId), address(bytes20(receiver)), amount);
    }

    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
    {
        hub.depositRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount);
    }

    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
    {
        hub.redeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount);
    }

    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external  {
        hub.cancelDepositRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId));
    }

    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external  {
        hub.cancelRedeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId));
    }

    function sendApprovedDeposits(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount, D18 pricePoolPerAsset)
        external
    {
        investmentManager.approvedDeposits(poolId, scId, assetId, assetAmount, pricePoolPerAsset);
    }

    function sendIssuedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external {
        investmentManager.issuedShares(poolId, scId, shareAmount, pricePoolPerShare);
    }

    function sendRevokedShares(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 assetAmount, uint128 shareAmount, D18 pricePoolPerShare) external  {
        investmentManager.revokedShares(poolId, scId, assetId, assetAmount, shareAmount, pricePoolPerShare);
    }

    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease
    ) external  {
        hub.updateHoldingAmount(poolId, scId, assetId, amount, pricePoolPerAsset, isIncrease);
    }

     function sendUpdateShares(PoolId poolId, ShareClassId scId, uint128 shares, bool isIssuance) external {
        if (poolId.centrifugeId() == localCentrifugeId) {
            if (isIssuance) {
                hub.increaseShareIssuance(poolId, scId, shares);
            } else {
                hub.decreaseShareIssuance(poolId, scId, shares);
            }
        } 
    }

    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals) external {
        hub.registerAsset(assetId, decimals);
    }
}
