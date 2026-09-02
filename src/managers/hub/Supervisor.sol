// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, TrustedCall} from "./interfaces/ISupervisor.sol";

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @title  Supervisor
/// @notice Pool-scoped sentinel registry and veto layer for the authorize flow. It holds no positive
///         power of its own; its sole job is to let the sentinels held here veto a pending
///         authorization during the policy delay window.
///
///         The Supervisor is a registered Hub manager for the pool only so that it can reach
///         {IHub.cancelAuthorization} on behalf of sentinels (which are not Hub managers). The hub,
///         pool, and contract updater are immutable; the sentinel set is managed via {IHub.managerCall}.
contract Supervisor is ISupervisor, IManagerCallFromHub {
    using BytesLib for bytes;
    using CastLib for bytes32;

    IHub public immutable hub;
    PoolId public immutable poolId;
    address public immutable envoy;

    uint256 public sentinelCount;
    mapping(address => bool) public sentinels;

    constructor(IHub hub_, PoolId poolId_, address envoy_) {
        hub = hub_;
        poolId = poolId_;
        envoy = envoy_;
    }

    modifier onlySentinel() {
        require(sentinels[msg.sender], NotSentinel());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Hub actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId_, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(poolId_ == poolId, NotPool());
        require(msg.value == 0, UnexpectedValue());

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
    function cancelAuthorization(bytes calldata data) external onlySentinel {
        if (sentinelCount > 1) {
            _checkNotSelfRemoval(data, msg.sender);
        }
        hub.cancelAuthorization(poolId, data);
    }

    /// @dev Reverts if `data` is a `Hub.managerCall` targeting this Supervisor that removes `sender` as a
    ///      sentinel. Non-matching payloads pass through to preserve the veto, `AddSentinel` included.
    function _checkNotSelfRemoval(bytes calldata data, address sender) private view {
        (bytes4 selector, bytes calldata args) = data.decodeCall();
        if (selector != IHub.managerCall.selector) return;
        // 224 = 7 x 32, the managerCall tuple's minimum ABI encoding; a shorter blob would revert the
        // decode and freeze this veto. Shares shape and threshold with {StdHubPolicy._checkManagerCall};
        // if the managerCall tuple changes, update both together.
        if (args.length < 224) return;
        (,, bytes32 target, bytes memory payload,,,) =
            abi.decode(args, (PoolId, uint16, bytes32, bytes, uint128, uint256, address));
        if (target.toAddress() != address(this)) return;
        if (payload.length < 64) return;
        if (payload.toUint256(0) != uint256(uint8(TrustedCall.RemoveSentinel))) return;
        require(payload.toAddress(44) != sender, CannotSelfCancel());
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
    function newSupervisor(PoolId poolId, address envoy) external returns (ISupervisor) {
        Supervisor supervisor = new Supervisor{salt: _salt(poolId, envoy)}(hub, poolId, envoy);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }

    /// @inheritdoc ISupervisorFactory
    function previewSupervisor(PoolId poolId, address envoy) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _salt(poolId, envoy), _initCodeHash(poolId, envoy))
        );
        return address(uint160(uint256(hash)));
    }

    function _initCodeHash(PoolId poolId, address envoy) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(type(Supervisor).creationCode, abi.encode(hub, poolId, envoy)));
    }

    /// @dev Deterministic CREATE2 salt so a (hub, poolId, envoy) config maps to a fixed, previewable
    ///      address. `hub` is a factory immutable, so it need not enter the salt.
    function _salt(PoolId poolId, address envoy) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, envoy));
    }
}
