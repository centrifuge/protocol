// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICreatePool} from "./interfaces/ICreatePool.sol";
import {IOpsGuardian} from "./interfaces/IOpsGuardian.sol";
import {IBaseGuardian} from "./interfaces/IBaseGuardian.sol";

import {IAuth} from "../misc/interfaces/IAuth.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {ISafe} from "../core/interfaces/ISafe.sol";
import {IAdapter} from "../core/interfaces/IAdapter.sol";
import {IMultiAdapter} from "../core/interfaces/IMultiAdapter.sol";

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
    function wire(address adapter, bytes memory data) external onlySafe {
        uint16 centrifugeId;
        assembly {
            centrifugeId := mload(add(data, 0x20))
        }

        require(!IAdapter(adapter).isWired(centrifugeId), AdapterAlreadyWired());
        IAdapter(adapter).wire(data);
        IAuth(adapter).deny(address(this));
    }

    //----------------------------------------------------------------------------------------------
    // Pool Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOpsGuardian
    function createPool(PoolId poolId, address admin, AssetId currency) external onlySafe {
        hub.createPool(poolId, admin, currency);
    }
}
