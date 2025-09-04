// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Src Deps | For cycling of values
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {BaseSyncDepositVault} from "src/vaults/BaseVaults.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/IVaultManagers.sol";

import {Properties} from "../properties/Properties.sol";
import {OpType} from "../BeforeAfter.sol";
// @dev A way to separately code and maintain a mocked implementation of `Gateway`
// Based on
// `Gateway.handle(bytes calldata message)`
/**
 * - deployNewTokenPoolAndShare Core function that deploys a Liquidity Pool
 *     - spoke_registerAsset
 */

abstract contract GatewayMockTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using MessageLib for *;

    // Deploy new Asset
    // Add Asset to Pool -> Also deploy Share Class

    bool hasDoneADeploy;

    // Basically the real complete setup
    function deployNewTokenPoolAndShare(uint8 decimals, uint256 initialMintPerUsers)
        public
        notGovFuzzing
        returns (address newToken, address newShareToken, address newVault, uint128 newAssetId, bytes16 scId)
    {
        // NOTE: TEMPORARY
        require(!hasDoneADeploy); // This bricks the function for this one for Medusa
        // Meaning we only deploy one token, one Pool, one share class

        if (RECON_USE_SINGLE_DEPLOY) {
            hasDoneADeploy = true;
        }

        if (RECON_USE_HARDCODED_DECIMALS) {
            decimals = 18;
        }

        initialMintPerUsers = 1_000_000e18;
        // NOTE END TEMPORARY

        decimals = decimals % RECON_MODULO_DECIMALS;
        /// @audit NOTE: This works because we only deploy once!!

        newToken = _newAsset(decimals);
        {
            ASSET_ID_COUNTER += 1;
            newAssetId = spoke_registerAsset(address(newToken), 0);
        }

        {
            POOL_ID += 1;
            spoke_addPool(POOL_ID);
        }

        {
            // TODO: QA: Custom Names
            string memory name = "Share";
            string memory symbol = "T1";

            // TODO: Ask if we should customize decimals and permissions here
            (newShareToken,) = spoke_addShareClass(POOL_ID, SHARE_ID, name, symbol, 18, address(fullRestrictions));
        }

        // Set AsyncRequestManager as the request manager for this asset BEFORE linking vault
        // This allows AsyncRequestManager to call spoke.request()
        spoke.setRequestManager(
            PoolId.wrap(POOL_ID), ShareClassId.wrap(SHARE_ID), AssetId.wrap(newAssetId), address(asyncRequestManager)
        );

        newVault = deployVault(POOL_ID, SHARE_ID, newAssetId);
        asyncRequestManager.rely(address(newVault));

        // Set max reserve for sync vaults (if it's a sync vault)
        // Check if the vault is a sync vault by checking if it has a syncDepositManager
        try BaseSyncDepositVault(newVault).syncDepositManager() returns (ISyncDepositManager syncDepositManager) {
            if (address(syncDepositManager) != address(0)) {
                // This is a sync vault, set max reserve to maximum value
                (address asset, uint256 tokenId) = spoke.idToAsset(AssetId.wrap(newAssetId));
                syncManager.setMaxReserve(
                    PoolId.wrap(POOL_ID), ShareClassId.wrap(SHARE_ID), asset, tokenId, type(uint128).max
                );
            }
        } catch {
            // If the vault doesn't have syncDepositManager, it's not a sync vault
        }

        // NOTE: Add to storage! So this will be called by other functions
        // NOTE: This sets the actors
        // We will cycle them through other means
        // NOTE: These are all tightly coupled
        // First step of uncoupling is to simply store all of them as a setting
        // So we can have multi deploys
        // And do parallel checks

        // O(n)
        // Basically switch on new deploy
        // And track all historical

        // O(n*m)
        // Second Step is to store permutations
        // Which means we have to switch on all permutations on all checks

        // approve and mint initial amount to all actors
        address[] memory approvals = new address[](2);
        approvals[0] = address(spoke);
        approvals[1] = address(vault);
        _finalizeAssetDeployment(_getActors(), approvals, initialMintPerUsers);

        vault = AsyncVault(newVault);
        token = ShareToken(newShareToken);
        fullRestrictions = FullRestrictions(address(token.hook()));

        scId = SHARE_ID;
        poolId = POOL_ID;
        assetId = newAssetId;

        // NOTE: Implicit return
    }

    // Create a Asset
    // Add it to All Pools

    // Step 2
    function spoke_registerAsset(address assetAddress, uint256 erc6909TokenId)
        public
        notGovFuzzing
        asAdmin
        returns (uint128 assetId)
    {
        assetId = spoke.registerAsset{value: 0.1 ether}(DEFAULT_DESTINATION_CHAIN, assetAddress, erc6909TokenId).raw();

        // Only if successful
        assetAddressToAssetId[assetAddress] = assetId;
        assetIdToAssetAddress[assetId] = assetAddress;
    }

    // Step 3
    function spoke_addPool(uint64 poolId) public notGovFuzzing asAdmin {
        spoke.addPool(PoolId.wrap(poolId));
    }

    // Step 4
    function spoke_addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public notGovFuzzing asAdmin returns (address, bytes16) {
        spoke.addShareClass(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            tokenName,
            tokenSymbol,
            decimals,
            keccak256(abi.encodePacked(poolId, scId)),
            hook
        );

        address newToken = address(spoke.shareToken(PoolId.wrap(poolId), ShareClassId.wrap(scId)));

        shareClassTokens.push(newToken);

        return (newToken, scId);
    }

    // Step 5
    function spoke_deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public asAdmin returns (address) {
        return address(
            spoke.deployVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), vaultFactory)
        );
    }

    // Step 6 deploy the pool
    function deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public notGovFuzzing asAdmin returns (address) {
        address newVault = address(
            spoke.deployVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), vaultFactory)
        );
        spoke.linkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), IBaseVault(newVault));

        vaults.push(newVault);

        return newVault;
    }

    // Extra 7 - Remove liquidity Pool
    function removeVault(uint64 poolId, bytes16 scId, uint128 assetId) public asAdmin {
        spoke.unlinkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), IBaseVault(vaults[0]));
    }

    function removeVault_clamped() public asAdmin {
        // use poolId, scId, assetId deployed in deployNewTokenPoolAndShare
        removeVault(poolId, scId, assetId);
    }

    /**
     * NOTE: All of these are implicitly clamped!
     */
    function spoke_updateMember(uint64 validUntil) public asAdmin {
        spoke.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionMember(_getActor().toBytes32(), validUntil)
            )
        );
    }

    // TODO: Price is capped at u64 to test overflows
    function spoke_updatePricePoolPerShare(uint64 price, uint64 computedAt)
        public
        updateGhostsWithType(OpType.ADMIN)
        asAdmin
    {
        spoke.updatePricePoolPerShare(PoolId.wrap(poolId), ShareClassId.wrap(scId), price, computedAt);
        spoke.updatePricePoolPerAsset(
            PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), price, computedAt
        );
    }

    function spoke_updateShareMetadata(string memory tokenName, string memory tokenSymbol) public asAdmin {
        spoke.updateShareMetadata(PoolId.wrap(poolId), ShareClassId.wrap(scId), tokenName, tokenSymbol);
    }

    function spoke_freeze() public asAdmin {
        spoke.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionFreeze(_getActor().toBytes32())
            )
        );
    }

    function spoke_unfreeze() public asAdmin {
        spoke.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(_getActor().toBytes32())
            )
        );
    }

    // TODO: Rely / Permissions
    // Only after all system is setup
    function root_scheduleRely(address target) public asAdmin {
        root.scheduleRely(target);
    }

    function root_cancelRely(address target) public asAdmin {
        root.cancelRely(target);
    }
}

/// 2 Enter Functions
/// 2 Cancel Functions
/// 4 Callback functions
