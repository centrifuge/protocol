// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

interface IPoolRegistry {
    /// Events
    event NewPool(
        PoolId poolId,
        address indexed admin,
        IShareClassManager indexed shareClassManager,
        IERC20Metadata indexed currency
    );
    event UpdatedPoolAdmin(PoolId indexed poolId, address indexed admin);
    event UpdatedPoolMetadata(PoolId indexed poolId, bytes metadata);
    event UpdatedShareClassManager(PoolId indexed poolId, IShareClassManager indexed shareClassManager);
    event UpdatedPoolCurrency(PoolId indexed poolId, IERC20Metadata currency);
    event UpdatedAddressFor(PoolId indexed poolId, bytes32 key, address addr);

    /// Errors
    error NonExistingPool(PoolId id);
    error EmptyAdmin();
    error EmptyCurrency();
    error EmptyShareClassManager();

    /// Functions

    /// Getters
    /// @notice TODO
    function metadata(PoolId poolId) external returns (bytes memory);
    /// @notice TODO
    function currency(PoolId poolId) external returns (IERC20Metadata);
    /// @notice TODO
    function shareClassManager(PoolId poolId) external returns (IShareClassManager);
    /// @notice TODO
    function isAdmin(PoolId poolId, address admin) external returns (bool);
    /// @notice TODO
    function addressFor(PoolId poolId, bytes32 key) external returns (address);

    /// @notice TODO
    function registerPool(address admin, IERC20Metadata currency, IShareClassManager shareClassManager)
        external
        returns (PoolId);
    /// @notice TODO
    function updateAdmin(PoolId poolId, address newAdmin, bool canManage) external;
    /// @notice TODO
    function updateMetadata(PoolId poolId, bytes calldata metadata) external;
    /// @notice TODO
    function updateShareClassManager(PoolId poolId, IShareClassManager shareClassManager) external;
    /// @notice TODO
    function updateCurrency(PoolId poolId, IERC20Metadata currency) external;
    /// @notice TODO
    function setAddressFor(PoolId poolid, bytes32 key, address addr) external;
}
