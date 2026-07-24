// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHub} from "./interfaces/IHub.sol";
import {IHoldings} from "./interfaces/IHoldings.sol";
import {IHubHandler} from "./interfaces/IHubHandler.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";
import {IShareClassManager} from "./interfaces/IShareClassManager.sol";
import {IBridgingHook, BridgeSharesParams, BridgeSharesResult} from "./interfaces/IBridgingHook.sol";

import {Auth} from "../../misc/Auth.sol";

import {IHubMessageSender} from "../messaging/interfaces/IGatewaySenders.sol";
import {IHubGatewayHandler} from "../messaging/interfaces/IGatewayHandlers.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// @title  HubHandler
/// @notice This contract processes incoming cross-chain messages for the Hub, handling asset registration,
///         vault requests, holding amount updates, share issuance/revocation, and cross-chain share
///         transfers while coordinating with the Hub's accounting and holdings systems.
contract HubHandler is Auth, IHubHandler, IHubGatewayHandler {
    IHub public hub;
    IHoldings public holdings;
    IHubMessageSender public sender;
    IShareClassManager public shareClassManager;

    IHubRegistry public immutable hubRegistry;

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

    /// @inheritdoc IHubHandler
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = IHub(data);
        else if (what == "holdings") holdings = IHoldings(data);
        else if (what == "sender") sender = IHubMessageSender(data);
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
    function updateAssets(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) external auth {
        // The delta is valued at the hub-side valuation; the journaled value mirrors the holding
        // mutation exactly, so the accounts stay in sync with the holding.
        uint128 value = isIncrease
            ? holdings.increase(poolId, scId, assetId, centrifugeId, amount)
            : holdings.decrease(poolId, scId, assetId, centrifugeId, amount);

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
        bytes32 sender_,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        IBridgingHook hook = hubRegistry.bridgingHook(poolId);
        if (address(hook) != address(0)) {
            BridgeSharesResult memory result = hook.onBridgeShares(
                BridgeSharesParams({
                    originCentrifugeId: originCentrifugeId,
                    targetCentrifugeId: targetCentrifugeId,
                    poolId: poolId,
                    scId: scId,
                    sender: sender_,
                    receiver: receiver,
                    amount: amount,
                    extraGasLimit: extraGasLimit,
                    refund: refund
                })
            );
            (receiver, amount, extraGasLimit, refund) =
            (result.receiver, result.amount, result.extraGasLimit, result.refund);
        }

        shareClassManager.updateShares(targetCentrifugeId, poolId, scId, amount, true);
        shareClassManager.updateShares(originCentrifugeId, poolId, scId, amount, false);

        holdings.callOnTransferSnapshot(poolId, scId, originCentrifugeId, targetCentrifugeId, amount);

        emit ForwardTransferShares(originCentrifugeId, targetCentrifugeId, poolId, scId, receiver, amount);

        return sender.sendExecuteTransferShares{value: msg.value}(
            originCentrifugeId, targetCentrifugeId, poolId, scId, receiver, amount, extraGasLimit, refund
        );
    }
}
