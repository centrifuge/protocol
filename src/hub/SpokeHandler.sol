// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHub} from "./interfaces/IHub.sol";
import {IHoldings} from "./interfaces/IHoldings.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {ISpokeHandler} from "./interfaces/ISpokeHandler.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";
import {IShareClassManager} from "./interfaces/IShareClassManager.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {ISnapshotHook} from "../common/interfaces/ISnapshotHook.sol";
import {IHubMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {IHubGatewayHandler} from "../common/interfaces/IGatewayHandlers.sol";

contract SpokeHandler is Auth, ISpokeHandler, IHubGatewayHandler {
    IHub public hub;
    IHoldings public holdings;
    IHubRegistry public hubRegistry;
    IHubMessageSender public sender;
    IShareClassManager public shareClassManager;

    constructor(
        IHub hub_,
        IHoldings holdings_,
        IHubRegistry hubRegistry_,
        IShareClassManager shareClassManager_,
        address deployer
    ) Auth(deployer) {
        hub = hub_;
        holdings = holdings_;
        hubRegistry = hubRegistry_;
        shareClassManager = shareClassManager_;
    }

    //----------------------------------------------------------------------------------------------
    // System methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISpokeHandler
    function file(bytes32 what, address data) external auth {
        if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "shareClassManager") shareClassManager = IShareClassManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Gateway owner methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubGatewayHandler
    function registerAsset(AssetId assetId, uint8 decimals) external auth {
        hubRegistry.registerAsset(assetId, decimals);
    }

    /// @inheritdoc IHubGatewayHandler
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external auth {
        IHubRequestManager manager = hubRegistry.hubRequestManager(poolId, assetId.centrifugeId());
        require(address(manager) != address(0), InvalidRequestManager());

        IHubRequestManager(manager).request(poolId, scId, assetId, payload);
    }

    /// @inheritdoc IHubGatewayHandler
    function updateHoldingAmount(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) external auth {
        uint128 value = isIncrease
            ? holdings.increase(poolId, scId, assetId, pricePoolPerAsset, amount)
            : holdings.decrease(poolId, scId, assetId, pricePoolPerAsset, amount);

        if (holdings.isInitialized(poolId, scId, assetId)) {
            hub.updateAccountingAmount(poolId, scId, assetId, isIncrease, value);
        }

        holdings.setSnapshot(poolId, scId, centrifugeId, isSnapshot, nonce);
    }

    /// @inheritdoc IHubGatewayHandler
    function updateShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        uint128 amount,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce
    ) external auth {
        shareClassManager.updateShares(centrifugeId, poolId, scId, amount, isIssuance);

        holdings.setSnapshot(poolId, scId, centrifugeId, isSnapshot, nonce);
    }

    /// @inheritdoc IHubGatewayHandler
    function initiateTransferShares(
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        shareClassManager.updateShares(originCentrifugeId, poolId, scId, amount, false);
        shareClassManager.updateShares(targetCentrifugeId, poolId, scId, amount, true);

        ISnapshotHook hook = holdings.snapshotHook(poolId);
        if (address(hook) != address(0)) hook.onTransfer(poolId, scId, originCentrifugeId, targetCentrifugeId, amount);

        emit ForwardTransferShares(originCentrifugeId, targetCentrifugeId, poolId, scId, receiver, amount);

        return sender.sendExecuteTransferShares(
            originCentrifugeId, targetCentrifugeId, poolId, scId, receiver, amount, extraGasLimit
        );
    }
}
