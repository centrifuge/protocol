// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest, SupervisorConfig} from "./interfaces/ISupervisor.sol";

import {IERC7751} from "../../misc/interfaces/IERC7751.sol";
import {IMulticall} from "../../misc/interfaces/IMulticall.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../core/utils/BatchedMulticall.sol";

/// @title  Supervisor
/// @notice Sits between the pool operator and the Hub, adding manifest-driven timelocks and
///         custom validation. Sentinels can veto pending timelocked operations.
///
///         The Supervisor is pool-scoped and immutable. Hub, poolId, operator, hook config,
///         and manifest are all set at construction. To change any of these, deploy a new
///         Supervisor. The only mutable state is the sentinel set, and both adding and
///         removing sentinels are timelocked.
///
///         For hooked selectors, the manifest determines the timelock: returning 0 means
///         immediate execution, returning > 0 requires a submit→wait→execute flow.
///         Sentinel management uses a fixed sentinelTimelock independent of the manifest.
///
///         SECURITY: The Supervisor must be the ONLY address registered as a Hub manager for the
///         pool. Otherwise, the operator (or any other Hub manager) can bypass the Supervisor by
///         calling the Hub directly.
///
///         Inherits BatchedMulticall so the operator can batch multiple execute/submit calls
///         atomically, with cross-chain messages from all inner calls aggregated into a single
///         gateway batch.
contract Supervisor is ISupervisor, BatchedMulticall {
    using BytesLib for bytes;

    IHub public immutable hub;
    PoolId public immutable poolId;
    address public immutable operator;
    uint48 public immutable sentinelTimelock;
    uint48 public immutable expiryWindow;
    IManifest public immutable manifest;

    uint256 public sentinelCount;
    mapping(bytes4 => bool) public hooked;
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
        hub = hub_;
        poolId = poolId_;
        operator = operator_;
        manifest = config.manifest;
        expiryWindow = config.expiryWindow;
        sentinelTimelock = config.sentinelTimelock;

        for (uint256 i; i < config.hookSelectors.length; i++) hooked[config.hookSelectors[i]] = true;
    }

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function execute(bytes calldata data) external payable onlyOperator {
        (bytes4 selector,) = data.decodeCall();
        require(selector != IMulticall.multicall.selector, MulticallForbidden());

        if (pending[data] != 0) {
            _consumeTimelock(data);
        } else if (hooked[selector]) {
            require(address(manifest) != address(0), ManifestRequired());
            uint48 timelock = manifest.check(poolId, msgSender(), data);
            require(timelock == 0, TimelockNotReady(uint48(block.timestamp) + timelock));
        }

        (bool success, bytes memory result) = address(hub).call{value: msgValue()}(data);
        if (!success) revert IERC7751.WrappedError(address(hub), selector, result, "");
    }

    /// @inheritdoc ISupervisor
    function submit(bytes calldata data) external onlyOperator {
        (bytes4 selector, bytes calldata payload) = data.decodeCall();
        require(selector != IMulticall.multicall.selector, MulticallForbidden());
        require(pending[data] == 0, OperationAlreadyPending());

        uint48 timelock;
        if (selector == this.addSentinel.selector || selector == this.removeSentinel.selector) {
            timelock = sentinelTimelock;
            // Validate removeSentinel target is currently a sentinel
            if (selector == this.removeSentinel.selector) {
                require(sentinels[abi.decode(payload, (address))], NotSentinel());
            }
        } else {
            require(hooked[selector], NotHooked());
            require(address(manifest) != address(0), ManifestRequired());
            timelock = manifest.check(poolId, msgSender(), data);
        }

        uint48 executeAfter = uint48(block.timestamp) + timelock;
        pending[data] = executeAfter;
        emit Submit(keccak256(data), selector, executeAfter, data);
    }

    /// @inheritdoc ISupervisor
    function cancel(bytes calldata data) external onlyOperatorOrSentinel {
        require(pending[data] != 0, OperationNotPending());

        if (msgSender() != operator) {
            (bytes4 selector, bytes calldata payload) = data.decodeCall();
            require(
                selector != this.removeSentinel.selector // not a removal
                    || abi.decode(payload, (address)) != msgSender() // not removing self
                    || sentinelCount == 1, // last sentinel
                CannotSelfCancel()
            );
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
        _consumeTimelock(msg.data);

        sentinelCount++;
        sentinels[sentinel] = true;
        emit AddSentinel(sentinel);
    }

    /// @inheritdoc ISupervisor
    function removeSentinel(address sentinel) external onlyOperator {
        require(sentinels[sentinel], NotSentinel());
        _consumeTimelock(msg.data);

        sentinelCount--;
        sentinels[sentinel] = false;
        emit RemoveSentinel(sentinel);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _consumeTimelock(bytes calldata data) internal {
        uint48 executeAfter = pending[data];
        require(executeAfter != 0, OperationNotPending());
        require(block.timestamp >= executeAfter, TimelockNotReady(executeAfter));
        require(block.timestamp <= executeAfter + expiryWindow, TimelockExpired());

        delete pending[data];
        emit Execute(keccak256(data));
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
