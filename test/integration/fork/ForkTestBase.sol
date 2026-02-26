// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC7575Share, IERC165} from "../../../src/misc/interfaces/IERC7575.sol";

import {Hub} from "../../../src/core/hub/Hub.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {VaultRegistry} from "../../../src/core/spoke/VaultRegistry.sol";
import {IRequestManager} from "../../../src/core/interfaces/IRequestManager.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";

/// @title ForkTestBase
/// @notice Base contract for all fork tests, providing common setup and utilities
contract ForkTestBase is Test {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 constant GAS = IntegrationConstants.GAS;
    uint128 constant HOOK_GAS = IntegrationConstants.HOOK_GAS;

    address immutable ANY = makeAddr("ANY");

    EnvConfig config;

    function setUp() public virtual {
        config = Env.load(_network());
        vm.createSelectFork(_rpcEndpoint());
        vm.deal(_poolAdmin(), 10 ether);
    }

    function _network() internal view virtual returns (string memory) {
        return vm.envOr("NETWORK", string("ethereum"));
    }

    function _rpcEndpoint() internal view virtual returns (string memory) {
        return IntegrationConstants.RPC_ETHEREUM;
    }

    function _poolAdmin() internal view virtual returns (address) {
        return IntegrationConstants.ETH_DEFAULT_POOL_ADMIN;
    }

    /// @notice Get the pool admin (hub manager) for a specific pool
    /// @dev Base implementation uses default pool admin. Child contracts can override for pool-specific lookup.
    ///      ForkTestInvestmentValidation provides GraphQL-based implementation.
    function _getPoolAdmin(
        PoolId /* poolId */
    )
        internal
        view
        virtual
        returns (address)
    {
        return _poolAdmin(); // Use default pool admin as fallback
    }

    /// @notice Create restriction member update message
    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: addr.toBytes32(), validUntil: type(uint64).max
            }).serialize();
    }

    /// @notice Add a pool member with transfer permissions
    function _addPoolMember(IBaseVault vault, address user) internal virtual {
        _addPoolMemberRaw(vault.poolId(), vault.scId(), user);
    }

    /// @notice Add a user as pool member using raw pool/shareClass IDs
    function _addPoolMemberRaw(PoolId poolId, ShareClassId scId, address user) internal virtual {
        vm.startPrank(_getPoolAdmin(poolId));
        Hub(config.contracts.hub).updateRestriction{value: GAS}(
            poolId, scId, config.network.centrifugeId, _updateRestrictionMemberMsg(user), HOOK_GAS, address(this)
        );
        vm.stopPrank();
    }

    /// @notice Configure prices for a pool (fork-specific version that skips valuation.setPrice())
    function _baseConfigurePrices(PoolId poolId, ShareClassId shareClassId, AssetId assetId, address poolManager)
        internal
        virtual
    {
        vm.startPrank(poolManager);
        Hub(config.contracts.hub)
            .updateSharePrice(poolId, shareClassId, IntegrationConstants.identityPrice(), uint64(block.timestamp));
        Hub(config.contracts.hub).notifySharePrice{value: GAS}(
            poolId, shareClassId, config.network.centrifugeId, address(this)
        );
        Hub(config.contracts.hub).notifyAssetPrice{value: GAS}(poolId, shareClassId, assetId, address(this));
        vm.stopPrank();
    }

    function _isShareToken(address token) internal view returns (bool) {
        try IERC165(token).supportsInterface(type(IERC7575Share).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    function _getAsyncVault(PoolId poolId, ShareClassId shareClassId, AssetId assetId)
        internal
        view
        returns (address vaultAddr)
    {
        return address(
            VaultRegistry(config.contracts.vaultRegistry)
                .vault(poolId, shareClassId, assetId, IRequestManager(config.contracts.asyncRequestManager))
        );
    }
}
