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
/// @notice Pool-scoped proxy between the operator and the Hub. Restricts who can call the Hub
///         (operator only), who can execute or cancel timelocked operations (operator + sentinels),
///         and enforces an expiry window on pending operations. All configuration is immutable.
///         To change operator or expiryWindow, deploy a new Supervisor.
///
///         SECURITY: The Supervisor must be the ONLY Hub manager for the pool. Otherwise the
///         operator can bypass it by calling the Hub directly.
contract Supervisor is ISupervisor, ITrustedContractUpdate, BatchedMulticall {
    using BytesLib for bytes;

    IHub public immutable hub;
    PoolId public immutable poolId;
    address public immutable operator;
    address public immutable contractUpdater;
    uint48 public immutable expiryWindow;

    uint256 public sentinelCount;
    mapping(address => bool) public sentinels;

    constructor(IHub hub_, PoolId poolId_, address operator_, address contractUpdater_, uint48 expiryWindow_)
        BatchedMulticall(hub_.gateway())
    {
        hub = hub_;
        poolId = poolId_;
        operator = operator_;
        contractUpdater = contractUpdater_;
        expiryWindow = expiryWindow_;
    }

    modifier onlyOperator() {
        require(msgSender() == operator, NotOperator());
        _;
    }

    modifier onlyOperatorOrSentinel() {
        address sender = msgSender();
        require(sender == operator || sentinels[sender], NotOperatorOrSentinel());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId, ShareClassId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotContractUpdater());

        (TrustedCall kind, address sentinel) = abi.decode(payload, (TrustedCall, address));

        if (kind == TrustedCall.AddSentinel) {
            require(sentinel != address(0), ZeroAddress());
            require(!sentinels[sentinel], AlreadySentinel());

            sentinelCount++;
            sentinels[sentinel] = true;
            emit AddSentinel(sentinel);
        } else {
            require(sentinels[sentinel], NotSentinel());
            require(sentinelCount > 1, LastSentinel());

            sentinelCount--;
            sentinels[sentinel] = false;
            emit RemoveSentinel(sentinel);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Execution
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISupervisor
    function forward(bytes calldata data) external payable onlyOperator {
        (bytes4 selector,) = data.decodeCall();
        require(selector != IMulticall.multicall.selector, MulticallForbidden());

        (bool success, bytes memory result) = address(hub).call{value: msgValue()}(data);
        if (!success) revert IERC7751.WrappedError(address(hub), selector, result, "");
    }

    /// @inheritdoc ISupervisor
    function execute(bytes calldata data) external payable onlyOperatorOrSentinel {
        (uint48 executeAfter,) = hub.pending(keccak256(data));
        require(block.timestamp <= executeAfter + expiryWindow, TimelockExpired());

        hub.execute{value: msgValue()}(data);
    }

    /// @inheritdoc ISupervisor
    function cancel(bytes calldata data) external onlyOperatorOrSentinel {
        address sender = msgSender();
        if (sentinels[sender] && sentinelCount > 1) {
            _checkNotSelfRemoval(data, sender);
        }
        hub.cancel(data);
    }

    /// @dev Reverts if `data` is a Hub updateContract call whose payload removes `sender` as sentinel.
    function _checkNotSelfRemoval(bytes calldata data, address sender) private pure {
        (bytes4 selector, bytes calldata args) = data.decodeCall();
        if (selector != IHub.updateContract.selector) return;
        (,,,, bytes memory payload,,) = abi.decode(args, (PoolId, ShareClassId, uint16, bytes32, bytes, uint128, address));
        (TrustedCall kind, address sentinel) = abi.decode(payload, (TrustedCall, address));
        require(!(kind == TrustedCall.RemoveSentinel && sentinel == sender), CannotSelfCancel());
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
