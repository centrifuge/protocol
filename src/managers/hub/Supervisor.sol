// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest} from "./interfaces/ISupervisor.sol";

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
    IManifest public immutable manifest;

    mapping(bytes4 => bool) public hooked;
    mapping(bytes4 => bool) public timelocked;
    mapping(address => bool) public guardians;
    uint256 public guardianCount;

    /// @dev Calldata-as-key timelock storage (Morpho pattern). The pending calldata IS the key.
    mapping(bytes calldata_ => uint48 executeAfter) public pending;

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
        IManifest manifest_
    ) {
        hub = hub_;
        poolId = poolId_;
        delay = delay_;
        expiryWindow = expiryWindow_;
        manifest = manifest_;

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
    function submit(bytes calldata data) external onlyManager {
        bytes4 selector = bytes4(data[:4]);
        require(timelocked[selector] || selector == this.removeGuardian.selector, TimelockNotSet());
        require(pending[data] == 0, OperationAlreadyPending());

        uint48 executeAfter = uint48(block.timestamp) + delay;
        pending[data] = executeAfter;

        emit Submit(keccak256(data), selector, executeAfter, data);
    }

    /// @inheritdoc ISupervisor
    function cancel(bytes calldata data) external onlyManagerOrGuardian {
        require(pending[data] != 0, OperationNotPending());

        // A guardian can only cancel their own removal if they are the sole guardian
        bytes4 selector = bytes4(data[:4]);
        if (guardians[msg.sender] && selector == this.removeGuardian.selector) {
            address target = abi.decode(data[4:], (address));
            if (target == msg.sender) {
                require(guardianCount == 1, CannotSelfCancel());
            }
        }

        delete pending[data];
        emit Cancel(keccak256(data));
    }

    //----------------------------------------------------------------------------------------------
    // Guardian management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function addGuardian(address guardian) external onlyManager {
        require(guardian != address(0), ZeroAddress());
        require(!guardians[guardian], AlreadyGuardian());

        guardians[guardian] = true;
        guardianCount++;
        emit AddGuardian(guardian);
    }

    /// @inheritdoc ISupervisor
    function removeGuardian(address guardian) external onlyManager {
        require(guardians[guardian], NotGuardian());
        _checkHookAndTimelock(msg.sig, msg.data);

        guardians[guardian] = false;
        guardianCount--;
        emit RemoveGuardian(guardian);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _checkHookAndTimelock(bytes4 selector, bytes calldata data) internal {
        uint48 additionalDelay;
        if (address(manifest) != address(0) && hooked[selector]) {
            additionalDelay = manifest.check(poolId, msg.sender, data);
        }

        // removeGuardian is always timelocked regardless of the timelocked mapping
        if (timelocked[selector] || selector == this.removeGuardian.selector) {
            uint48 executeAfter = pending[data] + additionalDelay;
            require(pending[data] != 0, OperationNotPending());
            require(block.timestamp >= executeAfter, TimelockNotReady(executeAfter));
            require(block.timestamp <= executeAfter + expiryWindow, TimelockExpired());

            delete pending[data];
            emit Execute(keccak256(data));
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
        IManifest hook
    ) external returns (ISupervisor) {
        Supervisor supervisor =
            new Supervisor(hub, poolId, timelockSelectors, hookSelectors, delay, expiryWindow, hook);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }
}
