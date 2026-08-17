// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {ISpokeRegistry} from "../../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

/// @title  IShareManager
/// @notice Interface for hub-driven share issuance and revocation
/// @dev    All operations are manager calls from the hub arriving through the Envoy, so each one matured
///         through the hub policy.
interface IShareManager is IManagerCallFromHub {
    enum ManagerCall {
        Issue,
        Revoke
    }

    error NotEnvoy();
    error UnexpectedValue();
    error UnknownManagerCall();

    /// @notice The Envoy that routes policy-supervised share operations
    function envoy() external view returns (address);

    /// @notice Manages share token balances, including minting, burning, and escrow transfers
    function spoke() external view returns (ISpoke);

    /// @notice Registry resolving the share token for each pool and share class
    function spokeRegistry() external view returns (ISpokeRegistry);
}
