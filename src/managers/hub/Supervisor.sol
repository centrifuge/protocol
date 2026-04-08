// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifestHook} from "./interfaces/ISupervisor.sol";

import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {PoolId} from "../../core/types/PoolId.sol";
import {IERC7751} from "../../misc/interfaces/IERC7751.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";

/// @title  Supervisor
/// @notice Sits between pool managers and the Hub, adding optional per-function timelocks and a
///         manifest hook for custom validation. Guardians can veto pending timelocked operations.
///
///         The Supervisor is pool-scoped and mostly immutable: Hub, poolId, timelocks, hook config
///         are all set at construction. The one mutable piece is guardian management: guardians can
///         be added freely, but removing a guardian is always timelocked (so the guardian can veto
///         their own removal).
contract Supervisor is ISupervisor {
    IHub public immutable hub;
    PoolId public immutable poolId;
    uint48 public immutable delay;
    uint48 public immutable expiryWindow;
    IManifestHook public immutable manifestHook;

    mapping(bytes4 => bool) public hooked;
    mapping(bytes4 => bool) public timelocked;
    mapping(address => bool) public guardians;
    mapping(bytes32 => uint48) public pending;

    modifier onlyManager() {
        require(hub.hubRegistry().manager(poolId, msg.sender), NotManager());
        _;
    }

    modifier onlyManagerOrGuardian() {
        if (!guardians[msg.sender]) {
            require(hub.hubRegistry().manager(poolId, msg.sender), NotManagerOrGuardian());
        }
        _;
    }

    constructor(
        IHub hub_,
        PoolId poolId_,
        bytes4[] memory timelockSelectors,
        bytes4[] memory hookSelectors,
        uint48 delay_,
        uint48 expiryWindow_,
        IManifestHook manifestHook_
    ) {
        hub = hub_;
        poolId = poolId_;
        delay = delay_;
        expiryWindow = expiryWindow_;
        manifestHook = manifestHook_;

        for (uint256 i; i < timelockSelectors.length; i++) {
            timelocked[timelockSelectors[i]] = true;
        }
        for (uint256 i; i < hookSelectors.length; i++) {
            hooked[hookSelectors[i]] = true;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function execute(bytes calldata data) external payable onlyManager {
        _checkHookAndTimelock(bytes4(data[:4]), data);
        _forward(data);
    }

    /// @inheritdoc ISupervisor
    function submit(bytes calldata data) external onlyManager returns (bytes32 operationId) {
        bytes4 selector = bytes4(data[:4]);
        require(timelocked[selector] || selector == this.removeGuardian.selector, TimelockNotSet());

        operationId = keccak256(data);
        require(pending[operationId] == 0, OperationAlreadyPending());

        uint48 executeAfter = uint48(block.timestamp) + delay;
        pending[operationId] = executeAfter;

        emit Submit(operationId, selector, executeAfter);
    }

    /// @inheritdoc ISupervisor
    function cancel(bytes32 operationId) external onlyManagerOrGuardian {
        require(pending[operationId] != 0, OperationNotPending());

        delete pending[operationId];
        emit Cancel(operationId);
    }

    //----------------------------------------------------------------------------------------------
    // Guardian management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function addGuardian(address guardian) external onlyManager {
        require(guardian != address(0), ZeroAddress());
        require(!guardians[guardian], AlreadyGuardian());

        guardians[guardian] = true;
        emit AddGuardian(guardian);
    }

    /// @inheritdoc ISupervisor
    function removeGuardian(address guardian) external onlyManager {
        require(guardians[guardian], NotGuardian());
        _checkHookAndTimelock(msg.sig, msg.data);

        guardians[guardian] = false;
        emit RemoveGuardian(guardian);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _checkHookAndTimelock(bytes4 selector, bytes calldata data) internal {
        require(
            address(manifestHook) == address(0) || !hooked[selector] || manifestHook.check(poolId, msg.sender, data),
            ManifestCheckFailed()
        );

        // removeGuardian is always timelocked regardless of the timelocked mapping
        if (timelocked[selector] || selector == this.removeGuardian.selector) {
            bytes32 operationId = keccak256(data);
            uint48 executeAfter = pending[operationId];
            require(executeAfter != 0, OperationNotPending());
            require(block.timestamp >= executeAfter, TimelockNotReady(executeAfter));
            require(block.timestamp <= executeAfter + expiryWindow, TimelockExpired());

            delete pending[operationId];
            emit Execute(operationId);
        }
    }

    function _forward(bytes calldata data) internal {
        (bool success, bytes memory result) = address(hub).call{value: msg.value}(data);
        if (!success) {
            revert IERC7751.WrappedError(address(hub), bytes4(data[:4]), result, "");
        }
    }

}

/// @title  Supervisor Factory
/// @notice Deploys pool-specific Supervisor instances.
contract SupervisorFactory is ISupervisorFactory {
    IHub public immutable hub;

    constructor(IHub hub_) {
        hub = hub_;
    }

    /// @inheritdoc ISupervisorFactory
    function newSupervisor(
        PoolId poolId,
        bytes4[] calldata timelockSelectors,
        bytes4[] calldata hookSelectors,
        uint48 delay,
        uint48 expiryWindow,
        IManifestHook hook
    ) external returns (ISupervisor) {
        Supervisor supervisor =
            new Supervisor(hub, poolId, timelockSelectors, hookSelectors, delay, expiryWindow, hook);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }
}
