// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

/// @title  IShareManager
/// @notice Interface for hub-driven share issuance and revocation
/// @dev    All operations are manager calls from the hub arriving through the Envoy, so each one matured
///         through the hub policy.
///
///         Revocation pulls shares from any holder of the share class, without touching the holder's own
///         books. A pool holding another pool's share token as an asset therefore trusts that pool's
///         manager not to revoke it from under its escrow, since such a revocation leaves the holding
///         pool's booked amount overstated until it is revalued.
///
///         The contract holds no balance between calls and has no way to return one: `fromHub` carries only
///         a `poolId`, so it cannot tell which pool an arbitrary token belongs to, and it deliberately
///         carries neither `Auth` nor `Recoverable`. Anything transferred to it is therefore stuck until
///         Root recovers it, so treat transfers to this address as requiring administrative recovery.
interface IShareManager is IManagerCallFromHub {
    enum ManagerCall {
        Issue,
        Revoke
    }

    event Issue(PoolId indexed poolId, ShareClassId indexed scId, address indexed account, uint128 shares);
    event Revoke(PoolId indexed poolId, ShareClassId indexed scId, address indexed account, uint128 shares);

    error NotEnvoy();
    error UnexpectedValue();
    error UnknownManagerCall();
    error EmptyAmount();

    /// @notice The Envoy that routes policy-supervised share operations
    function envoy() external view returns (address);

    /// @notice Manages share token balances, including minting, burning, and escrow transfers
    function spoke() external view returns (ISpoke);

    /// @notice Registry resolving the share token for each pool and share class
    function spokeRegistry() external view returns (ISpokeRegistry);
}
