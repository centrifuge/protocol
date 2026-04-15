// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest, SupervisorConfig} from "./interfaces/ISupervisor.sol";

import {IERC7751} from "../../misc/interfaces/IERC7751.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../core/utils/BatchedMulticall.sol";

/// @title  Supervisor
/// @notice Sits between pool managers and the Hub, adding optional per-function timelocks and a
///         manifest hook for custom validation. Sentinels can veto pending timelocked operations.
///
///         The Supervisor is pool-scoped and mostly immutable: Hub, poolId, timelocks, hook config
///         are all set at construction. The one mutable piece is sentinel management: sentinels can
///         be added freely, but removing a sentinel is always timelocked (so the sentinel can veto
///         their own removal).
///
///         Inherits BatchedMulticall so managers can batch multiple execute/submit calls atomically,
///         with cross-chain messages from all inner calls aggregated into a single gateway batch.
contract Supervisor is ISupervisor, BatchedMulticall {
    IHub public immutable hub;
    PoolId public immutable poolId;
    uint48 public immutable delay;
    IManifest public immutable manifest;
    uint48 public immutable expiryWindow;

    uint256 public sentinelCount;
    mapping(bytes4 => bool) public hooked;
    mapping(bytes4 => bool) public timelocked;
    mapping(address => bool) public sentinels;
    mapping(bytes calldata_ => uint48 executeAfter) public pending;

    modifier onlyManager() {
        require(hub.hubRegistry().manager(poolId, msgSender()), NotManager());
        _;
    }

    modifier onlyManagerOrSentinel() {
        if (!sentinels[msgSender()]) {
            require(hub.hubRegistry().manager(poolId, msgSender()), NotManagerOrSentinel());
        }
        _;
    }

    constructor(IHub hub_, PoolId poolId_, SupervisorConfig memory config) BatchedMulticall(hub_.gateway()) {
        hub = hub_;
        poolId = poolId_;
        delay = config.delay;
        expiryWindow = config.expiryWindow;
        manifest = config.manifest;

        for (uint256 i; i < config.timelockSelectors.length; i++) {
            timelocked[config.timelockSelectors[i]] = true;
        }
        for (uint256 i; i < config.hookSelectors.length; i++) {
            hooked[config.hookSelectors[i]] = true;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function execute(bytes calldata data) external payable onlyManager {
        _checkHookAndTimelock(bytes4(data[:4]), data);
        (bool success, bytes memory result) = address(hub).call{value: msgValue()}(data);
        if (!success) revert IERC7751.WrappedError(address(hub), bytes4(data[:4]), result, "");
    }

    /// @inheritdoc ISupervisor
    function submit(bytes calldata data) external onlyManager {
        bytes4 selector = bytes4(data[:4]);
        require(timelocked[selector] || selector == this.removeSentinel.selector, TimelockNotSet());
        require(pending[data] == 0, OperationAlreadyPending());

        // Validate removeSentinel target is currently a sentinel
        if (selector == this.removeSentinel.selector) {
            address target = abi.decode(data[4:], (address));
            require(sentinels[target], NotSentinel());
        }

        uint48 executeAfter = uint48(block.timestamp) + delay;
        pending[data] = executeAfter;

        emit Submit(keccak256(data), selector, executeAfter, data);
    }

    /// @inheritdoc ISupervisor
    function cancel(bytes calldata data) external onlyManagerOrSentinel {
        require(pending[data] != 0, OperationNotPending());

        // A sentinel can only cancel their own removal if they are the sole sentinel
        bytes4 selector = bytes4(data[:4]);
        if (sentinels[msgSender()] && selector == this.removeSentinel.selector) {
            address target = abi.decode(data[4:], (address));
            if (target == msgSender()) {
                require(sentinelCount == 1, CannotSelfCancel());
            }
        }

        delete pending[data];
        emit Cancel(keccak256(data));
    }

    //----------------------------------------------------------------------------------------------
    // Sentinel management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function addSentinel(address sentinel) external onlyManager {
        require(sentinel != address(0), ZeroAddress());
        require(!sentinels[sentinel], AlreadySentinel());

        sentinels[sentinel] = true;
        sentinelCount++;
        emit AddSentinel(sentinel);
    }

    /// @inheritdoc ISupervisor
    function removeSentinel(address sentinel) external onlyManager {
        require(sentinels[sentinel], NotSentinel());
        _checkHookAndTimelock(msg.sig, msg.data);

        sentinels[sentinel] = false;
        sentinelCount--;
        emit RemoveSentinel(sentinel);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _checkHookAndTimelock(bytes4 selector, bytes calldata data) internal {
        uint48 additionalDelay;
        if (address(manifest) != address(0) && hooked[selector]) {
            additionalDelay = manifest.check(poolId, msgSender(), data);
        }

        // removeSentinel is always timelocked regardless of the timelocked mapping
        if (timelocked[selector] || selector == this.removeSentinel.selector) {
            uint48 executeAfter = pending[data] + additionalDelay;
            require(pending[data] != 0, OperationNotPending());
            require(block.timestamp >= executeAfter, TimelockNotReady(executeAfter));
            require(block.timestamp <= executeAfter + expiryWindow, TimelockExpired());

            delete pending[data];
            emit Execute(keccak256(data));
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
    function newSupervisor(PoolId poolId, SupervisorConfig calldata config) external returns (ISupervisor) {
        Supervisor supervisor = new Supervisor(hub, poolId, config);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }
}
