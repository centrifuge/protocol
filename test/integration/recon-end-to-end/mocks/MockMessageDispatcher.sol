// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {
    ISpokeGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IUpdateContractGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/IVaultManagers.sol";
import {ITokenRecoverer} from "src/common/interfaces/ITokenRecoverer.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
import {RequestMessageLib} from "src/common/libraries/RequestMessageLib.sol";
import {RequestCallbackMessageLib} from "src/common/libraries/RequestCallbackMessageLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

contract MockMessageDispatcher {
    using CastLib for *;
    using MathLib for uint256;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    IRoot public root;
    IGateway public gateway;
    ITokenRecoverer public tokenRecoverer;

    uint16 public localCentrifugeId;

    IHubGatewayHandler public hub;
    ISpokeGatewayHandler public spoke;
    IAsyncRequestManager public requestManager;
    IBalanceSheetGatewayHandler public balanceSheet;
    IUpdateContractGatewayHandler public contractUpdater;

    function file(bytes32 what, address data) external {
        if (what == "hub") hub = IHubGatewayHandler(data);
        else if (what == "spoke") spoke = ISpokeGatewayHandler(data);
        else if (what == "requestManager") requestManager = IAsyncRequestManager(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
    }

    function sendNotifyPool(uint16 centrifugeId, PoolId poolId) external {
        spoke.addPool(poolId);
    }

    function sendNotifyShareClass(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external {
        spoke.addShareClass(poolId, scId, name, symbol, decimals, salt, hook.toAddress());
    }

    function sendNotifyShareMetadata(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol
    ) external {
        spoke.updateShareMetadata(poolId, scId, name, symbol);
    }

    function sendUpdateShareHook(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 hook) external {
        spoke.updateShareHook(poolId, scId, hook.toAddress());
    }

    function sendNotifyPricePoolPerShare(uint16 centrifugeId, PoolId poolId, ShareClassId scId, D18 sharePrice)
        external
    {
        uint64 timestamp = block.timestamp.toUint64();
        spoke.updatePricePoolPerShare(poolId, scId, sharePrice.raw(), timestamp);
    }

    function sendNotifyPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price) external {
        uint64 timestamp = block.timestamp.toUint64();
        spoke.updatePricePoolPerAsset(poolId, scId, assetId, price.raw(), timestamp);
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) external {
        bytes memory payload = RequestCallbackMessageLib.FulfilledDepositRequest(
            investor, fulfilledAssetAmount, fulfilledShareAmount, cancelledAssetAmount
        ).serialize();
        spoke.requestCallback(poolId, scId, assetId, payload);
    }

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) external {
        bytes memory payload = RequestCallbackMessageLib.FulfilledRedeemRequest(
            investor, fulfilledAssetAmount, fulfilledShareAmount, cancelledShareAmount
        ).serialize();
        spoke.requestCallback(poolId, scId, assetId, payload);
    }

    function sendUpdateRestriction(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes calldata payload)
        external
    {
        spoke.updateRestriction(poolId, scId, payload);
    }

    function sendUpdateContract(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external {
        contractUpdater.execute(poolId, scId, target.toAddress(), payload);
    }

    function sendUpdateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind
    ) external {
        spoke.updateVault(poolId, scId, assetId, vaultOrFactory.toAddress(), kind);
    }

    function sendUpdateBalanceSheetManager(uint16 centrifugeId, PoolId poolId, bytes32 who, bool canManage) external {
        balanceSheet.updateManager(poolId, who.toAddress(), canManage);
    }

    function sendApprovedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) external {
        bytes memory payload =
            RequestCallbackMessageLib.ApprovedDeposits(assetAmount, pricePoolPerAsset.raw()).serialize();
        spoke.requestCallback(poolId, scId, assetId, payload);
    }

    function sendIssuedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external {
        bytes memory payload = RequestCallbackMessageLib.IssuedShares(shareAmount, pricePoolPerShare.raw()).serialize();
        spoke.requestCallback(poolId, scId, assetId, payload);
    }

    function sendRevokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external {
        bytes memory payload =
            RequestCallbackMessageLib.RevokedShares(assetAmount, shareAmount, pricePoolPerShare.raw()).serialize();
        spoke.requestCallback(poolId, scId, assetId, payload);
    }

    function sendMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external {
        spoke.setMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
    }

    function sendMaxSharePriceAge(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external {
        spoke.setMaxSharePriceAge(poolId, scId, maxPriceAge);
    }

    function sendScheduleUpgrade(uint16 centrifugeId, bytes32 target) external {
        root.scheduleRely(target.toAddress());
    }

    function sendCancelUpgrade(uint16 centrifugeId, bytes32 target) external {
        root.cancelRely(target.toAddress());
    }

    function sendRecoverTokens(
        uint16 centrifugeId,
        bytes32 target,
        bytes32 token,
        uint256 tokenId,
        bytes32 to,
        uint256 amount
    ) external {}

    function sendInitiateTransferShares(
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    ) external {
        hub.initiateTransferShares(targetCentrifugeId, poolId, scId, receiver, amount, 0);
    }

    function sendExecuteTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    ) external {
        spoke.executeTransferShares(poolId, scId, receiver, amount);
    }

    function sendDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId, uint128 amount)
        external
    {
        bytes memory payload = RequestMessageLib.DepositRequest(investor, amount).serialize();
        hub.request(poolId, scId, assetId, payload);
    }

    function sendRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId, uint128 amount)
        external
    {
        bytes memory payload = RequestMessageLib.RedeemRequest(investor, amount).serialize();
        hub.request(poolId, scId, assetId, payload);
    }

    function sendCancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId) external {
        bytes memory payload = RequestMessageLib.CancelDepositRequest(investor).serialize();
        hub.request(poolId, scId, assetId, payload);
    }

    function sendCancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId) external {
        bytes memory payload = RequestMessageLib.CancelRedeemRequest(investor).serialize();
        hub.request(poolId, scId, assetId, payload);
    }

    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) external {
        hub.updateHoldingAmount(
            localCentrifugeId, poolId, scId, assetId, amount, pricePoolPerAsset, isIncrease, isSnapshot, nonce
        );
    }

    function sendUpdateShares(
        PoolId poolId,
        ShareClassId scId,
        uint128 shares,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce
    ) external {
        hub.updateShares(localCentrifugeId, poolId, scId, shares, isIssuance, isSnapshot, nonce);
    }

    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals) external {
        hub.registerAsset(assetId, decimals);
    }

    function sendRequestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external {
        spoke.requestCallback(poolId, scId, assetId, payload);
    }

    function sendRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external {
        hub.request(poolId, scId, assetId, payload);
    }
}
