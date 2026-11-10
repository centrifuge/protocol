// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IVaultFactory} from "../../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";

/// @dev A vault factory a hostile pool names in `DeployAndLink`: it returns whatever address it was told to, so
///      the registry is asked to register a contract the pool did not build. The core accepts any factory.
contract EvilVaultFactory is IVaultFactory {
    address public result;

    function set(address result_) external {
        result = result_;
    }

    function getVault(PoolId, ShareClassId, address, uint256, address, bytes calldata) external view returns (address) {
        return result;
    }

    function newVault(PoolId, ShareClassId, address, uint256, address, bytes calldata) external view returns (address) {
        return result;
    }
}
