// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareManager} from "./interfaces/IShareManager.sol";

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @title  ShareManager
/// @notice Balance sheet manager for hub-driven share issuance and revocation, for holdings tracked
///         outside the protocol (e.g. investments on chains where the protocol is not live).
///         Every operation is a manager call from the hub, so it matures through the hub policy before
///         execution; no local wallet holds any permission.
contract ShareManager is IShareManager {
    using CastLib for *;

    ISpoke public immutable spoke;
    address public immutable envoy;
    ISpokeRegistry public immutable spokeRegistry;

    constructor(address envoy_, ISpoke spoke_, ISpokeRegistry spokeRegistry_) {
        envoy = envoy_;
        spoke = spoke_;
        spokeRegistry = spokeRegistry_;
    }

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (uint8 kindValue, ShareClassId scId, bytes32 accountAddress, uint128 shares) =
            abi.decode(payload, (uint8, ShareClassId, bytes32, uint128));
        require(kindValue <= uint8(type(ManagerCall).max), UnknownManagerCall());
        require(shares != 0, EmptyAmount());
        address account = accountAddress.toAddress();

        ManagerCall kind = ManagerCall(kindValue);
        if (kind == ManagerCall.Issue) {
            spoke.issue(poolId, scId, account, shares);

            emit Issue(poolId, scId, account, shares);
        } else if (kind == ManagerCall.Revoke) {
            address token = address(spokeRegistry.shareToken(poolId, scId));

            spoke.transferSharesFrom(poolId, scId, account, account, address(this), shares);
            SafeTransferLib.safeApprove(token, address(spoke), shares);
            spoke.revoke(poolId, scId, shares);

            emit Revoke(poolId, scId, account, shares);
        }
    }
}
