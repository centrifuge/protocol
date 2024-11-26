// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;

    uint32 public latestId;

    mapping(PoolId => bytes) public poolMetadata;
    mapping(PoolId => address) public poolManagers;
    mapping(PoolId => address) public shareClassManagers;
    mapping(PoolId => CurrencyId) public poolCurrencies;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IPoolRegistry
    function registerPool(CurrencyId poolCurrency, address shareClassManager)
        external
        payable
        returns (PoolId poolId)
    {
        uint32 chainId = block.chainid.toUint32();
        poolId = PoolId.wrap((uint64(chainId) << 32) | uint64(latestId++));

        poolManagers[poolId] = msg.sender;
        poolCurrencies[poolId] = poolCurrency;
        shareClassManagers[poolId] = shareClassManager;

        emit NewPool(poolId, msg.sender);
    }

    /// @inheritdoc IPoolRegistry
    function changeManager(PoolId poolId, address manager) external {
        require(poolManagers[poolId] == manager, NotManagerOrNonExistingPool());
        poolManagers[poolId] = manager;

        emit NewPoolManager(manager);
    }

    /// @inheritdoc IPoolRegistry
    function updateMetadata(PoolId poolId, bytes calldata metadata) external {
        require(poolManagers[poolId] == msg.sender, NotManagerOrNonExistingPool());
        poolMetadata[poolId] = metadata;

        emit NewPoolMetadata(poolId, metadata);
    }
}
