// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, TrustedCall} from "./interfaces/ISupervisor.sol";

import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  Supervisor
/// @notice Pool-scoped sentinel registry and veto layer for the authorize flow. It holds no positive
///         power of its own; its sole job is to let the sentinels held here veto a pending
///         authorization during the manifest delay window.
///
///         The Supervisor is a registered Hub manager for the pool only so that it can reach the
///         manifest's {IHubRegistry.cancelAuthorization} on behalf of sentinels (which are not Hub
///         managers). The hub, pool, and contract updater are immutable; the sentinel set is managed
///         via {trustedCall}.
contract Supervisor is ISupervisor, ITrustedContractUpdate {
    using BytesLib for bytes;

    IHub public immutable hub;
    PoolId public immutable poolId;
    address public immutable contractUpdater;

    uint256 public sentinelCount;
    mapping(address => bool) public sentinels;

    constructor(IHub hub_, PoolId poolId_, address contractUpdater_) {
        hub = hub_;
        poolId = poolId_;
        contractUpdater = contractUpdater_;
    }

    modifier onlySentinel() {
        require(sentinels[msg.sender], NotSentinel());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId_, ShareClassId, bytes calldata payload) external {
        require(poolId_ == poolId, NotPool());
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
    function cancelAuthorization(bytes calldata data) external onlySentinel {
        if (sentinelCount > 1) {
            _checkNotSelfRemoval(data, msg.sender);
        }
        hub.hubRegistry().cancelAuthorization(poolId, data);
    }

    /// @dev Reverts if `data` is a Hub updateContract call whose payload removes `sender` as sentinel.
    ///      Anything that isn't a well-formed (RemoveSentinel, sender) inner payload cannot be a
    ///      self-removal, so it must not block the veto. The inner payload is read field-by-field
    ///      rather than `abi.decode(_, (TrustedCall, address))`, which would revert on a malformed or
    ///      out-of-range payload, which a compromised operator could otherwise shape to freeze vetoes.
    function _checkNotSelfRemoval(bytes calldata data, address sender) private pure {
        (bytes4 selector, bytes calldata args) = data.decodeCall();
        if (selector != IHub.updateContract.selector) return;
        (,,,, bytes memory payload,,) =
            abi.decode(args, (PoolId, ShareClassId, uint16, bytes32, bytes, uint128, address));
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
    function newSupervisor(PoolId poolId, address contractUpdater) external returns (ISupervisor) {
        Supervisor supervisor = new Supervisor{salt: _salt(hub, poolId, contractUpdater)}(hub, poolId, contractUpdater);

        emit DeploySupervisor(poolId, address(supervisor));
        return ISupervisor(address(supervisor));
    }

    /// @inheritdoc ISupervisorFactory
    function previewSupervisor(PoolId poolId, address contractUpdater) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt(hub, poolId, contractUpdater),
                keccak256(abi.encodePacked(type(Supervisor).creationCode, abi.encode(hub, poolId, contractUpdater)))
            )
        );
        return address(uint160(uint256(hash)));
    }

    /// @dev Deterministic CREATE2 salt so a (hub, contractUpdater) config for a pool maps to a fixed,
    ///      previewable address. `hub` is included so a redeployment against a migrated hub yields a
    ///      fresh address rather than colliding with the prior deployment.
    function _salt(IHub hub_, PoolId poolId, address contractUpdater) internal pure returns (bytes32) {
        return keccak256(abi.encode(hub_, poolId, contractUpdater));
    }
}
