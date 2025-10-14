// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "./interfaces/ISafe.sol";
import {ICreatePool} from "./interfaces/ICreatePool.sol";
import {IOpsGuardian} from "./interfaces/IOpsGuardian.sol";
import {IBaseGuardian} from "./interfaces/IBaseGuardian.sol";
import {IAdapterWiring} from "./interfaces/IAdapterWiring.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {IAdapter} from "../core/messaging/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../core/messaging/interfaces/IMultiAdapter.sol";

/// @title  OpsGuardian
/// @notice This contract manages operational aspects of the protocol including adapter initialization,
///         network wiring, and pool creation.
contract OpsGuardian is IOpsGuardian {
    PoolId public constant GLOBAL_POOL = PoolId.wrap(0);

    ISafe public opsSafe;
    ICreatePool public hub;
    IMultiAdapter public multiAdapter;

    constructor(ISafe opsSafe_, ICreatePool hub_, IMultiAdapter multiAdapter_) {
        opsSafe = opsSafe_;
        hub = hub_;
        multiAdapter = multiAdapter_;
    }

    modifier onlySafe() {
        require(msg.sender == address(opsSafe), NotTheAuthorizedSafe());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "opsSafe") opsSafe = ISafe(data);
        else if (what == "hub") hub = ICreatePool(data);
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

    /// @inheritdoc IBaseGuardian
    function wire(address adapter, uint16 centrifugeId, bytes memory data) external onlySafe {
        require(!IAdapterWiring(adapter).isWired(centrifugeId), AdapterAlreadyWired());
        IAdapterWiring(adapter).wire(centrifugeId, data);
    }

    //----------------------------------------------------------------------------------------------
    // Pool Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function createPool(PoolId poolId, address admin, AssetId currency) external onlySafe {
        hub.createPool(poolId, admin, currency);
    }
}
