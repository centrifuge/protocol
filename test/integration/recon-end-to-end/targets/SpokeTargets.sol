// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps

import {D18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {VaultDetails} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {IVaultFactory} from "../../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";
import {MessageLib, VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";

import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {shareClassSalt} from "../../../utils/ShareClassSalt.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {IShareTokenRegistrar} from "../../../../src/token/interfaces/IShareTokenRegistrar.sol";

// Dependencies

// Only for Share
abstract contract SpokeTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using MessageLib for *;

    // NOTE: cross-chain share-transfer handlers are absent: a one-chain harness cannot observe the mint/burn leg

    // Step 1
    /// @dev internal (deploy-only), not a fuzz entry: an arbitrary `assetAddress` is almost never a token, so the
    /// fuzzer spends its budget on `AssetMissingDecimals` reverts. Worse, the literal address a `--repro` test
    /// records is meaningless under Foundry, where the harness deploys to different addresses, so any finding whose
    /// sequence contains this handler is unreplayable. Reach it via `spoke_registerAsset_clamped`.
    function spoke_registerAsset(address assetAddress, uint256 erc6909TokenId)
        internal
        updateGhosts
        asAdmin
        returns (uint128 assetId)
    {
        assetId = spoke.registerAsset{value: 0.1 ether}(
                DEFAULT_DESTINATION_CHAIN,
                assetAddress,
                erc6909TokenId,
                address(this) // refund address
            ).raw();

        // Only if successful
        assetAddressToAssetId[assetAddress] = assetId;
        assetIdToAssetAddress[assetId] = assetAddress;

        _addAssetId(assetId);
    }

    function spoke_registerAsset_clamped() public {
        spoke_registerAsset(_getAsset(), 0);
    }

    // Step 2
    function spoke_addPool() public updateGhosts asAdmin {
        spokeHandler.addPool(_getPool());
    }

    // Step 3
    // Deploy-only, not a fuzz entry: a second share class has no vault and desyncs the vault-tracking ghosts
    function spoke_addShareClass(uint128 scIdAsUint, uint8 decimals)
        internal
        updateGhosts
        asAdmin
        returns (address, bytes16)
    {
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        bytes16 scId = bytes16(scIdAsUint);
        address hook = address(fullRestrictions);

        // Unclamped decimals overflow PricingLib's asset<->share conversion; zero is valid (matches pool decimals)
        decimals = uint8(between(decimals, 0, 18));

        spokeHandler.addShareClass(
            _getPool(),
            ShareClassId.wrap(scId),
            name,
            symbol,
            decimals,
            shareClassSalt(_getPool().raw(), scId),
            shareTokenRegistrar,
            ""
        );
        address newToken = address(spokeRegistry.shareToken(_getPool(), ShareClassId.wrap(scId)));
        shareTokenRegistrar.fromHub(
            _getPool(), abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetHook), scId, hook)
        );

        _addShareClassId(scId);
        _addShareClassToPool(_getPool(), ShareClassId.wrap(scId));
        _addShareToken(newToken);

        return (newToken, scId);
    }

    // Step 4 - deploy and link the vault (via SpokeHandler, which is the only entry point for factory calls)
    function spoke_deployAndLinkVault(bool isAsync)
        public
        updateGhostsWithType(OpType.ADMIN)
        asAdmin
        returns (address)
    {
        address factory = isAsync ? address(asyncVaultFactory) : address(syncVaultFactory);
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();
        (address asset, uint256 tokenId) = spokeRegistry.idToAsset(assetId);
        address token = address(spokeRegistry.shareToken(poolId, scId));

        // Core keeps no tuple -> vault reverse lookup, but IVaultFactory mandates a deterministic
        // pre-deployment address, so the vault is knowable without a DeployVault log scan and therefore
        // without a cheatcode in whichever fuzzer drives the suite.
        address vault = IVaultFactory(factory).getVault(poolId, scId, asset, tokenId, token, bytes(""));

        spokeHandler.updateVault(poolId, scId, assetId, factory, VaultUpdateKind.DeployAndLink, bytes(""));
        t(vault.code.length > 0, "spoke_deployAndLinkVault: factory preview does not match the deployed vault");

        _addVault(vault);

        if (tokenId == 0) {
            shareTokenRegistrar.fromHub(
                poolId, abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetVault), scId.raw(), assetId.raw(), vault)
            );
        }

        return vault;
    }

    function spoke_deployAndLinkVault_clamped() public returns (address) {
        return spoke_deployAndLinkVault(true);
    }

    // Step 5 - set the request manager
    function spoke_setRequestManager(address vault) public updateGhosts asAdmin {
        IBaseVault vaultInstance = IBaseVault(vault);
        PoolId poolId = vaultInstance.poolId();

        spokeHandler.setRequestManager(poolId, asyncRequestManager);
    }

    // Step 6- link the vault
    function spoke_linkVault(address vault) public updateGhosts asAdmin {
        VaultDetails memory vd = spokeRegistry.vaultDetails(vault);

        spokeRegistry.linkVault(vd.poolId, vd.scId, vd.assetId, vault);

        if (vd.tokenId == 0) {
            shareTokenRegistrar.fromHub(
                vd.poolId,
                abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetVault), vd.scId.raw(), vd.assetId.raw(), vault)
            );
        }
    }

    function spoke_linkVault_clamped() public {
        spoke_linkVault(address(_getVault()));
    }

    // Extra 7 - remove the vault
    function spoke_unlinkVault() public updateGhosts asAdmin {
        address vault = address(_getVault());
        VaultDetails memory vd = spokeRegistry.vaultDetails(vault);

        spokeRegistry.unlinkVault(vd.poolId, vd.scId, vd.assetId, vault);

        if (vd.tokenId == 0) {
            shareTokenRegistrar.fromHub(
                vd.poolId,
                abi.encode(
                    uint8(IShareTokenRegistrar.RegistrarCall.SetVault), vd.scId.raw(), vd.assetId.raw(), address(0)
                )
            );
        }
    }

    /**
     * NOTE: All of these are implicitly clamped using values set in shortcut_deployNewTokenPoolAndShare
     */
    function spoke_updateMember(uint64 validUntil) public updateGhosts asAdmin {
        spokeHandler.updateRestriction(
            _getPool(),
            _getShareClassId(),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionMember(_getActor().toBytes32(), validUntil)
            )
        );
    }

    // NOTE: in e2e tests, these get called as callbacks in notifyAssetPrice and notifySharePrice
    function spoke_updatePricePoolPerShare(uint128 price, uint64 computedAt)
        public
        updateGhostsWithType(OpType.ADMIN)
        asAdmin
    {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();
        spokeHandler.updatePricePoolPerShare(poolId, scId, D18.wrap(price), computedAt);
        spokeHandler.updatePricePoolPerAsset(poolId, scId, assetId, D18.wrap(price), computedAt);
    }

    function spoke_updateShareMetadata(string memory tokenName, string memory tokenSymbol) public updateGhosts asAdmin {
        spokeHandler.updateShareMetadata(_getPool(), _getShareClassId(), tokenName, tokenSymbol);
    }

    function spoke_freeze() public updateGhosts asAdmin {
        spokeHandler.updateRestriction(
            _getPool(),
            _getShareClassId(),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionFreeze(_getActor().toBytes32())
            )
        );
    }

    function spoke_unfreeze() public updateGhosts asAdmin {
        spokeHandler.updateRestriction(
            _getPool(),
            _getShareClassId(),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(_getActor().toBytes32())
            )
        );
    }
}
