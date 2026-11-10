// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IVaultDeployFactory} from "./interfaces/IVaultDeployFactory.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IVaultFactory} from "../../core/spoke/factories/interfaces/IVaultFactory.sol";

import {Vault} from "../Vault.sol";
import {VaultConfig} from "../interfaces/IAsyncVault.sol";
import {IShareToken} from "../../token/interfaces/IShareToken.sol";

/// @title  Vault Factory
/// @notice Deploys vaults with immutable configuration: changing a vault's plugins is a new
///         deployment, and parallel vaults on one position use distinct variants.
/// @dev    A vault is deployed by anyone, in a transaction of its own, before the hub's `DeployAndLink`
///         registers and links it. Its address commits to its whole configuration, so a vault deployed
///         ahead of time can only be the one the hub links, and one the hub never links is inert.
contract VaultFactory is IVaultDeployFactory {
    address public immutable root;

    ISpoke public immutable spoke;
    ISpokeRegistry public immutable spokeRegistry;

    constructor(address root_, ISpoke spoke_, ISpokeRegistry spokeRegistry_) {
        root = root_;
        spoke = spoke_;
        spokeRegistry = spokeRegistry_;
    }

    /// @inheritdoc IVaultDeployFactory
    function deploy(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, bytes calldata payload)
        external
        returns (address)
    {
        require(tokenId == 0, UnsupportedTokenId());
        address token = address(spokeRegistry.shareToken(poolId, scId));
        require(token != address(0), ISpokeRegistry.ShareTokenDoesNotExist());

        Payload memory p = _decode(payload);
        bytes memory initcode = _initcode(poolId, scId, asset, tokenId, token, p);
        bytes32 salt = _salt(poolId, scId, asset, p.variant);

        address deployed = _address(salt, keccak256(initcode));
        if (deployed.code.length > 0) return deployed;

        // A constructor revert is passed on, so a configuration the vault refuses is named rather than a bare failure.
        Vault vault;
        assembly ("memory-safe") {
            vault := create2(0, add(initcode, 0x20), mload(initcode), salt)
            if and(iszero(vault), gt(returndatasize(), 0)) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        require(address(vault) != address(0), DeploymentFailed());

        // Root alone, for `recoverTokens`: nothing else on a vault is ward-gated.
        vault.rely(root);
        vault.deny(address(this));

        emit VaultDeployed(
            poolId,
            scId,
            asset,
            vault.assetId(),
            address(vault),
            vault.share(),
            vault.escrow(),
            spoke,
            spokeRegistry,
            p,
            vault.foldHorizon()
        );

        return address(vault);
    }

    /// @inheritdoc IVaultFactory
    /// @dev The payload is `abi.encode(Payload)`, as for {deploy}.
    function getVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address token,
        bytes calldata payload
    ) public view returns (address) {
        Payload memory p = _decode(payload);
        bytes32 initcodeHash = keccak256(_initcode(poolId, scId, asset, tokenId, token, p));
        return _address(_salt(poolId, scId, asset, p.variant), initcodeHash);
    }

    /// @inheritdoc IVaultFactory
    /// @dev Deploys nothing: returns the vault {deploy} put at the address, and reverts while there is none,
    ///      which leaves the hub's message failed and retryable.
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address token,
        bytes calldata payload
    ) external view returns (address) {
        address vault = getVault(poolId, scId, asset, tokenId, token, payload);
        require(vault.code.length > 0, VaultNotDeployed());
        return vault;
    }

    /// @dev An empty payload is the likeliest operator mistake, so it gets a named revert.
    function _decode(bytes calldata payload) internal pure returns (Payload memory) {
        require(payload.length != 0, PluginsRequired());
        return abi.decode(payload, (Payload));
    }

    /// @dev Shared by `getVault` and `deploy`, as is `_address`, so the two cannot drift.
    function _initcode(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address token,
        Payload memory p
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(Vault).creationCode,
            abi.encode(
                poolId,
                scId,
                asset,
                spokeRegistry.assetToId(asset, tokenId, true),
                IShareToken(token),
                VaultConfig({
                    spoke: spoke, spokeRegistry: spokeRegistry, plugins: p.plugins, foldHorizon: p.foldHorizon
                })
            )
        );
    }

    /// @dev The CREATE2 salt: the position plus the variant that lets parallel vaults coexist on it.
    function _salt(PoolId poolId, ShareClassId scId, address asset, uint64 variant) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, scId, asset, variant));
    }

    function _address(bytes32 salt, bytes32 initcodeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initcodeHash)))));
    }
}
