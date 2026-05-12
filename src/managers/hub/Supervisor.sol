// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest, TrustedCall} from "./interfaces/ISupervisor.sol";

import {IERC7751} from "../../misc/interfaces/IERC7751.sol";
import {IMulticall} from "../../misc/interfaces/IMulticall.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../core/utils/BatchedMulticall.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  Supervisor
/// @notice Sits between the pool operator and the Hub, providing operator access control and
///         sentinel-based veto capability for timelocked operations. The Hub's manifest handles
///         policy enforcement and timelock determination.
///
///         The Supervisor is pool-scoped and immutable. Hub, poolId, and operator are all set at
///         construction. To change any of these, deploy a new Supervisor.
///
///         Sentinel management (add/remove) is done via Hub's updateContract trusted call,
///         so the Hub's manifest/timelock governs the delay for sentinel changes.
///
///         SECURITY: The Supervisor must be the ONLY address registered as a Hub manager for the
///         pool. Otherwise, the operator (or any other Hub manager) can bypass the Supervisor by
///         calling the Hub directly.
///
///         Inherits BatchedMulticall so the operator can batch multiple execute calls atomically,
///         with cross-chain messages from all inner calls aggregated into a single gateway batch.
contract Supervisor is ISupervisor, ITrustedContractUpdate, BatchedMulticall {
    using BytesLib for bytes;

    IHub public immutable hub;
    PoolId public immutable poolId;
    address public immutable operator;
    address public immutable contractUpdater;
    uint48 public immutable expiryWindow;

    uint256 public sentinelCount;
    mapping(address => bool) public sentinels;

    modifier onlyOperator() {
        require(msgSender() == operator, NotOperator());
        _;
    }

    modifier onlyOperatorOrSentinel() {
        address sender = msgSender();
        require(sender == operator || sentinels[sender], NotOperatorOrSentinel());
        _;
    }

    constructor(IHub hub_, PoolId poolId_, address operator_, address contractUpdater_, uint48 expiryWindow_)
        BatchedMulticall(hub_.gateway())
    {
        hub = hub_;
        poolId = poolId_;
        operator = operator_;
        contractUpdater = contractUpdater_;
        expiryWindow = expiryWindow_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId, ShareClassId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotContractUpdater());

        (TrustedCall kind, address sentinel) = abi.decode(payload, (TrustedCall, address));

        if (kind == TrustedCall.AddSentinel) {
            _addSentinel(sentinel);
        } else if (kind == TrustedCall.RemoveSentinel) {
            _removeSentinel(sentinel);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function execute(bytes calldata data) external payable onlyOperator {
        (bytes4 selector,) = data.decodeCall();
        require(selector != IMulticall.multicall.selector, MulticallForbidden());

        (bool success, bytes memory result) = address(hub).call{value: msgValue()}(data);
        if (!success) revert IERC7751.WrappedError(address(hub), selector, result, "");
    }

    /// @inheritdoc ISupervisor
    function executePending(bytes calldata data) external payable onlyOperatorOrSentinel {
        (uint48 executeAfter,,) = hub.pending(keccak256(data));
        require(block.timestamp <= executeAfter + expiryWindow, TimelockExpired());

        hub.executePending{value: msgValue()}(data);
    }

    /// @inheritdoc ISupervisor
    function cancelPending(bytes32 opId) external onlyOperatorOrSentinel {
        hub.cancel(opId);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _addSentinel(address sentinel) private {
        require(sentinel != address(0), ZeroAddress());
        require(!sentinels[sentinel], AlreadySentinel());

        sentinelCount++;
        sentinels[sentinel] = true;
        emit AddSentinel(sentinel);
    }

    function _removeSentinel(address sentinel) private {
        require(sentinels[sentinel], NotSentinel());

        sentinelCount--;
        sentinels[sentinel] = false;
        emit RemoveSentinel(sentinel);
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
    function newSupervisor(PoolId poolId, address operator, address contractUpdater, uint48 expiryWindow)
        external
        returns (ISupervisor)
    {
        Supervisor supervisor = new Supervisor(hub, poolId, operator, contractUpdater, expiryWindow);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }
}
