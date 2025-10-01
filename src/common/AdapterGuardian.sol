// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IAdapterGuardian} from "./interfaces/IAdapterGuardian.sol";
import {IMultiAdapter} from "./interfaces/IMultiAdapter.sol";
import {IHubMessageSender} from "./interfaces/IGatewaySenders.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

contract AdapterGuardian is IAdapterGuardian {
    using CastLib for address;

    ISafe public safe;
    IGateway public gateway;
    IMultiAdapter public multiAdapter;
    IHubMessageSender public sender;

    constructor(ISafe safe_, IGateway gateway_, IMultiAdapter multiAdapter_, IHubMessageSender sender_) {
        safe = safe_;
        gateway = gateway_;
        multiAdapter = multiAdapter_;
        sender = sender_;
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), NotTheAuthorizedSafe());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Adapter Management
    //----------------------------------------------------------------------------------------------

/// @inheritdoc IAdapterGuardian
    function setAdapters(
        uint16 centrifugeId,
        IAdapter[] calldata adapters,
        uint8 threshold,
        uint8 recoveryIndex,
        address refund
    ) external payable onlySafe {
        multiAdapter.setAdapters(centrifugeId, PoolId.wrap(0), adapters, threshold, recoveryIndex);

        bytes32[] memory adapterBytes = new bytes32[](adapters.length);
        for (uint256 i = 0; i < adapters.length; i++) {
            // NOTE: Adapter addresses are deterministic on all networks due to CREATE-3 deployments
            adapterBytes[i] = address(adapters[i]).toBytes32();
        }

        sender.sendSetPoolAdapters{value: msg.value}(
            centrifugeId, PoolId.wrap(0), adapterBytes, threshold, recoveryIndex, refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // Local Emergency Controls
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterGuardian
    function updateGatewayManager(address who, bool canManage) external onlySafe {
        gateway.updateManager(PoolId.wrap(0), who, canManage);
    }

    /// @inheritdoc IAdapterGuardian
    function blockOutgoing(uint16 centrifugeId, bool isBlocked) external onlySafe {
        gateway.blockOutgoing(centrifugeId, PoolId.wrap(0), isBlocked);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "sender") sender = IHubMessageSender(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }
}
