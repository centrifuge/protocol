// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDefaultManifest} from "./interfaces/IDefaultManifest.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";

import {IManifest} from "../interfaces/ISupervisor.sol";

/// @title  Default Manifest
/// @notice Default manifest providing:
///         1. Asymmetric timelocks: granting manager access returns an additional delay,
///            revoking access passes through instantly
///         2. Blocks removing the Supervisor itself as a Hub manager
contract DefaultManifest is IDefaultManifest {
    address public immutable supervisor;
    uint48 public immutable grantManagerDelay;

    constructor(address supervisor_, uint48 grantManagerDelay_) {
        supervisor = supervisor_;
        grantManagerDelay = grantManagerDelay_;
    }

    /// @inheritdoc IManifest
    function check(PoolId, address, bytes calldata data) external view returns (uint48) {
        require(msg.sender == supervisor, NotAuthorized());

        bytes4 selector = bytes4(data[:4]);

        if (selector == IHub.updateHubManager.selector) return _checkHubManager(data);
        if (selector == IHub.updateBalanceSheetManager.selector) return _checkBalanceSheetManager(data);

        return 0;
    }

    function _checkHubManager(bytes calldata data) internal view returns (uint48) {
        (, address who, bool canManage) = abi.decode(data[4:], (PoolId, address, bool));
        require(who != supervisor || canManage, CannotRemoveSupervisor());
        return canManage ? grantManagerDelay : 0;
    }

    function _checkBalanceSheetManager(bytes calldata data) internal view returns (uint48) {
        (,, bytes32 who, bool canManage,) = abi.decode(data[4:], (PoolId, uint16, bytes32, bool, address));
        require(who != bytes32(bytes20(supervisor)) || canManage, CannotRemoveSupervisor());
        return canManage ? grantManagerDelay : 0;
    }
}
