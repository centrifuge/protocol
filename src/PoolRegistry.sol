// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;

    uint32 public latestId;

    mapping(PoolId => bytes) public poolMetadata;
    mapping(PoolId => PoolAdmin) public poolAdmins;
    mapping(PoolId => address) public shareClassManagers;
    mapping(PoolId => Currency) public poolCurrencies;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IPoolRegistry
    function registerPool(address admin, Currency currency, address shareClassManager)
        external
        auth
        returns (PoolId poolId)
    {
        uint32 chainId = block.chainid.toUint32();
        poolId = PoolId.wrap((uint64(chainId) << 32) | uint64(latestId++));

        poolAdmins[poolId] = PoolAdmin({account: admin, canManage: true});
        poolCurrencies[poolId] = currency;
        shareClassManagers[poolId] = shareClassManager;

        emit NewPool(poolId, msg.sender);
    }

    /// @inheritdoc IPoolRegistry
    function modifyAdmin(PoolId poolId, address admin, bool canManage) external auth {
        PoolAdmin storage poolAdmin = poolAdmins[poolId];
        require(poolAdmin.account != address(0), NonExistingPool(poolId));
        poolAdmin.account = admin;
        poolAdmin.canManage = canManage;

        emit NewPoolManager(admin);
    }

    /// @inheritdoc IPoolRegistry
    function updateMetadata(PoolId poolId, bytes calldata metadata) external auth {
        require(poolAdmins[poolId].account != address(0), NonExistingPool(poolId));
        poolMetadata[poolId] = metadata;

        emit NewPoolMetadata(poolId, metadata);
    }
}
