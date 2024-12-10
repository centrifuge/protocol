    // SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IFiatCurrencyRegistry} from "src/FiatCurrencyRegistry.sol";
import {AddressLib} from "src/libraries/AddressLib.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;
    using AddressLib for address;

    uint32 public latestId;

    IFiatCurrencyRegistry fiatRegistry;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => Currency) public poolCurrencies;
    mapping(PoolId => address) public shareClassManagers;
    mapping(PoolId => mapping(address => bool)) public poolAdmins;

    constructor(address deployer, address fiatRegistry_) Auth(deployer) {
        fiatRegistry = IFiatCurrencyRegistry(fiatRegistry_); // update through file pattern
    }

    /// @inheritdoc IPoolRegistry
    function registerPool(address admin, address currency, address shareClassManager)
        external
        auth
        returns (PoolId poolId)
    {
        require(admin != address(0), EmptyAdmin());
        require(shareClassManager != address(0), EmptyShareClassManager());

        // TODO: Make this part of the library. Something like PoolId.generate();
        poolId = PoolId.wrap((uint64(block.chainid.toUint32()) << 32) | uint64(++latestId));

        poolAdmins[poolId][admin] = true;
        poolCurrencies[poolId] = _assignCurrency(poolId, currency);
        shareClassManagers[poolId] = shareClassManager;

        emit NewPool(poolId, admin, shareClassManager, currency);
    }

    /// @inheritdoc IPoolRegistry
    function updateAdmin(PoolId poolId, address admin, bool canManage) external auth {
        require(admin != address(0), EmptyAdmin());
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));

        poolAdmins[poolId][admin] = canManage;

        emit UpdatedPoolAdmin(poolId, admin);
    }

    /// @inheritdoc IPoolRegistry
    function updateMetadata(PoolId poolId, bytes calldata metadata_) external auth {
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));

        metadata[poolId] = metadata_;

        emit UpdatedPoolMetadata(poolId, metadata_);
    }

    /// @inheritdoc IPoolRegistry
    function updateShareClassManager(PoolId poolId, address shareClassManager) external auth {
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));
        require(shareClassManager != address(0), EmptyShareClassManager());

        shareClassManagers[poolId] = shareClassManager;

        emit UpdatedShareClassManager(poolId, shareClassManager);
    }

    /// @inheritdoc IPoolRegistry
    function updateCurrency(PoolId poolId, address currency) external auth {
        // TODO: Make sure the address that is passed is actually a token
        // One idea is to check if `decimals()` can be called but might not work with Special Address
        // defined in the ERC-7726 for traditional currencies.
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));

        poolCurrencies[poolId] = _assignCurrency(poolId, currency);

        emit UpdatedPoolCurrency(poolId, currency);
    }

    function _assignCurrency(PoolId poolId, address target) internal returns (Currency memory currency) {
        require(!target.isNull(), EmptyCurrency());

        if (target.isContract()) {
            currency = target.asCurrency();
        } else {
            (address addr, uint8 decimals, string memory name, string memory symbol) = fiatRegistry.currencies(target);
            return Currency(addr, decimals, name, symbol);
        }
    }
}
