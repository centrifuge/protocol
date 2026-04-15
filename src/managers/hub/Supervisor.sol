// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest, SupervisorConfig} from "./interfaces/ISupervisor.sol";

import {IERC7751} from "../../misc/interfaces/IERC7751.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../core/utils/BatchedMulticall.sol";

/// @title  Supervisor
/// @notice Sits between the pool operator and the Hub, adding optional per-function timelocks and a
///         manifest hook for custom validation. Sentinels can veto pending timelocked operations.
///
///         The Supervisor is pool-scoped and immutable. Hub, poolId, operator, timelocks, hook
///         config, delay, and manifest are all set at construction. To change any of these, deploy
///         a new Supervisor. The only mutable state is the sentinel set, and both adding and
///         removing sentinels are timelocked.
///
///         SECURITY: The Supervisor must be the ONLY address registered as a Hub manager for the
///         pool. Otherwise, the operator (or any other Hub manager) can bypass the Supervisor by
///         calling the Hub directly.
///
///         The operator should be a multisig or other secure address, since it has sole authority
///         to submit/execute/cancel operations. Compromising the operator gives the attacker the
///         ability to execute any non-timelocked Hub call immediately, and any timelocked Hub call
///         after the delay (unless blocked by sentinel veto or the manifest).
///
///         Inherits BatchedMulticall so the operator can batch multiple execute/submit calls
///         atomically, with cross-chain messages from all inner calls aggregated into a single
///         gateway batch.
contract Supervisor is ISupervisor, BatchedMulticall {
    IHub public immutable hub;
    PoolId public immutable poolId;
    address public immutable operator;
    uint48 public immutable delay;
    IManifest public immutable manifest;
    uint48 public immutable expiryWindow;

    uint256 public sentinelCount;
    mapping(bytes4 => bool) public hooked;
    mapping(bytes4 => bool) public timelocked;
    mapping(address => bool) public sentinels;
    mapping(bytes calldata_ => uint48 executeAfter) public pending;

    modifier onlyOperator() {
        require(msgSender() == operator, NotOperator());
        _;
    }

    modifier onlyOperatorOrSentinel() {
        address sender = msgSender();
        require(sender == operator || sentinels[sender], NotOperatorOrSentinel());
        _;
    }

    constructor(IHub hub_, PoolId poolId_, address operator_, SupervisorConfig memory config)
        BatchedMulticall(hub_.gateway())
    {
        require(operator_ != address(0), ZeroAddress());
        hub = hub_;
        poolId = poolId_;
        operator = operator_;
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
    function execute(bytes calldata data) external payable onlyOperator {
        _checkHookAndTimelock(bytes4(data[:4]), data);
        (bool success, bytes memory result) = address(hub).call{value: msgValue()}(data);
        if (!success) revert IERC7751.WrappedError(address(hub), bytes4(data[:4]), result, "");
    }

    /// @inheritdoc ISupervisor
    function submit(bytes calldata data) external onlyOperator {
        bytes4 selector = bytes4(data[:4]);
        require(
            timelocked[selector] || selector == this.addSentinel.selector || selector == this.removeSentinel.selector,
            TimelockNotSet()
        );
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
    function cancel(bytes calldata data) external onlyOperatorOrSentinel {
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
    function addSentinel(address sentinel) external onlyOperator {
        require(sentinel != address(0), ZeroAddress());
        require(!sentinels[sentinel], AlreadySentinel());
        _checkHookAndTimelock(msg.sig, msg.data);

        sentinels[sentinel] = true;
        sentinelCount++;
        emit AddSentinel(sentinel);
    }

    /// @inheritdoc ISupervisor
    function removeSentinel(address sentinel) external onlyOperator {
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

        // addSentinel and removeSentinel are always timelocked regardless of the timelocked mapping
        if (
            timelocked[selector] || selector == this.addSentinel.selector || selector == this.removeSentinel.selector
        ) {
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
    function newSupervisor(PoolId poolId, address operator, SupervisorConfig calldata config)
        external
        returns (ISupervisor)
    {
        Supervisor supervisor = new Supervisor(hub, poolId, operator, config);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }
}
