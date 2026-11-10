// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RequestId} from "../../core/types/RequestId.sol";

/// @title  Vault Request Id Library
/// @notice Vault-namespaced request ids: the high 160 bits carry the owning vault address and the
///         low 96 bits a local id assigned by the request policy. Ids are therefore self-routing:
///         callbacks and sibling forwarding resolve the target vault from the id alone, so several
///         vaults run in parallel on one pool position without request collisions.
library VaultRequestIdLib {
    /// @notice Composes the namespaced request id for a vault and its local id.
    function from(address vault, uint96 localId) internal pure returns (RequestId) {
        return RequestId.wrap(uint256(uint160(vault)) << 96 | localId);
    }

    /// @notice The raw request id of `localId` in the calling vault.
    function ofThis(uint96 localId) internal view returns (uint256) {
        return from(address(this), localId).raw();
    }

    /// @notice The vault that owns a request id.
    function vaultOf(RequestId requestId) internal pure returns (address) {
        return address(uint160(RequestId.unwrap(requestId) >> 96));
    }

    /// @notice The local id within the owning vault.
    function localIdOf(RequestId requestId) internal pure returns (uint96) {
        return uint96(RequestId.unwrap(requestId));
    }
}
