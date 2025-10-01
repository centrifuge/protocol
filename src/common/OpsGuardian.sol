// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {IOpsGuardian} from "./interfaces/IOpsGuardian.sol";
import {IMultiAdapter} from "./interfaces/IMultiAdapter.sol";
import {IHubGuardianActions} from "./interfaces/IGuardianActions.sol";

contract OpsGuardian is IOpsGuardian {
    PoolId public constant GLOBAL_POOL = PoolId.wrap(0);

    ISafe public safe;
    IHubGuardianActions public hub;
    IMultiAdapter public multiAdapter;

    constructor(ISafe safe_, IHubGuardianActions hub_, IMultiAdapter multiAdapter_) {
        safe = safe_;
        hub = hub_;
        multiAdapter = multiAdapter_;
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), NotTheAuthorizedSafe());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "hub") hub = IHubGuardianActions(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Adapter Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function initAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold, uint8 recoveryIndex)
        external
        onlySafe
    {
        require(multiAdapter.quorum(centrifugeId, GLOBAL_POOL) == 0, AdaptersAlreadyInitialized());
        multiAdapter.setAdapters(centrifugeId, GLOBAL_POOL, adapters, threshold, recoveryIndex);
    }

    //----------------------------------------------------------------------------------------------
    // Pool Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function createPool(PoolId poolId, address admin, AssetId currency) external onlySafe {
        hub.createPool(poolId, admin, currency);
    }
}
