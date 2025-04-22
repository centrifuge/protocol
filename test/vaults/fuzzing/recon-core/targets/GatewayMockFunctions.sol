// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

// Src Deps | For cycling of values
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {RestrictedTransfers} from "src/hooks/RestrictedTransfers.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

// @dev A way to separately code and maintain a mocked implementation of `Gateway`
// Based on
// `Gateway.handle(bytes calldata message)`
/**
 * - deployNewTokenPoolAndShare Core function that deploys a Liquidity Pool
 *     - poolManager_registerAsset
 */
abstract contract GatewayMockFunctions is BaseTargetFunctions, Properties {
    using CastLib for *;
    using MessageLib for *;

    // Deploy new Asset
    // Add Asset to Pool -> Also deploy Share Class

    bool hasDoneADeploy;

    // Pool ID = Pool ID
    // Asset ID
    // Share ID

    // Basically the real complete setup
    function deployNewTokenPoolAndShare(uint8 decimals, uint256 initialMintPerUsers)
        public
        returns (address newToken, address newVault, uint128 newAssetId)
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

        newToken = addToken(decimals, initialMintPerUsers);
        {
            ASSET_ID_COUNTER += 1;
            newAssetId = poolManager_registerAsset(address(newToken), 0);
        }

        {
            POOL_ID += 1;
            poolManager_addPool(POOL_ID);
        }

        {
            // TODO: QA: Custom Names
            string memory name = "Share";
            string memory symbol = "T1";

            // TODO: Ask if we should customize decimals and permissions here
            poolManager_addShareClass(POOL_ID, SHARE_ID, name, symbol, 18, address(restrictedTransfers));
        }

        newVault = poolManager_deployVault(POOL_ID, SHARE_ID, newAssetId);

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

        vault = AsyncVault(newVault);
        assetErc20 = ERC20(newToken);
        restrictedTransfers = RestrictedTransfers(address(token.hook()));

        scId = SHARE_ID;
        poolId = POOL_ID;
        assetId = newAssetId;

        // NOTE: Iplicit return
    }

    // Create a Asset
    // Add it to All Pools

    // Step 2
    function poolManager_registerAsset(address assetAddress, uint256 erc6909TokenId) public returns (uint128 assetId) {
        assetId = poolManager.registerAsset{value: 0.1 ether}(DEFAULT_DESTINATION_CHAIN, assetAddress, erc6909TokenId);

        // Only if successful
        assetAddressToAssetId[assetAddress] = assetId;
        assetIdToAssetAddress[assetId] = assetAddress;
    }

    // Step 3
    function poolManager_addPool(uint64 poolId) public {
        poolManager.addPool(PoolId.wrap(poolId));
    }

    // Step 4
    function poolManager_addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public {
        poolManager.addShareClass(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            tokenName,
            tokenSymbol,
            decimals,
            keccak256(abi.encodePacked(poolId, scId)),
            hook
        );
    }

    // Step 5
    function poolManager_deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public returns (address) {
        return poolManager.deployVault(poolId, scId, assetId, address(vaultFactory));
    }

    /**
     * NOTE: All of these are implicitly clamped!
     */
    function poolManager_updateMember(uint64 validUntil) public {
        poolManager.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            MessageLib.UpdateRestrictionMember(actor.toBytes32(), validUntil).serialize()
        );
    }

    // TODO: Price is capped at u64 to test overflows
    function poolManager_updatePricePoolPerShare(uint64 price, uint64 computedAt) public {
        poolManager.updatePricePoolPerShare(PoolId.wrap(poolId), ShareClassId.wrap(scId), price, computedAt);
        poolManager.updatePricePoolPerAsset(
            PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), price, computedAt
        );
    }

    function poolManager_updateShareMetadata(string memory tokenName, string memory tokenSymbol) public {
        poolManager.updateShareMetadata(PoolId.wrap(poolId), ShareClassId.wrap(scId), tokenName, tokenSymbol);
    }

    function poolManager_freeze() public {
        poolManager.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            MessageLib.UpdateRestrictionFreeze(actor.toBytes32()).serialize()
        );
    }

    function poolManager_unfreeze() public {
        poolManager.updateRestriction(
            PoolId.wrap(poolId),
            ShareClassId.wrap(scId),
            MessageLib.UpdateRestrictionUnfreeze(actor.toBytes32()).serialize()
        );
    }

    // TODO: Rely / Permissions
    // Only after all system is setup
    function root_scheduleRely(address target) public {
        root.scheduleRely(target);
    }

    function root_cancelRely(address target) public {
        root.cancelRely(target);
    }

    function addToken(uint8 decimals, uint256 initialMintPerUsers) public returns (address) {
        ERC20 newToken = new ERC20(decimals % RECON_MODULO_DECIMALS); // NOTE: we revert on <1 and >18

        allTokens.push(newToken);

        // TODO: If you have multi actors add them here
        newToken.mint(actor, initialMintPerUsers);

        return address(newToken);
    }

    function getMoreToken(uint8 tokenIndex, uint256 newTokenAmount) public {
        // Token Id
        ERC20 newToken = allTokens[tokenIndex % allTokens.length];

        // TODO: Consider minting to actors
        newToken.mint(address(this), newTokenAmount);
    }

    // Step 2 = poolManager_registerAsset - GatewayMockFunctions
    // Step 3 = poolManager_addPool - GatewayMockFunctions
    // Step 4 = poolManager_addShareClass - GatewayMockFunctions
    // Step 5 = poolManager_deployVault - GatewayMockFunctions

    // A pool can belong to a share class
    // A Vault can belong to a share class and a currency

    // Step 6 deploy the pool
    function deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public {
        address newVault = poolManager.deployVault(poolId, scId, assetId, address(vaultFactory));
        poolManager.linkVault(poolId, scId, assetId, newVault);

        vaults.push(newVault);
    }

    // Extra 7 - Remove liquidity Pool
    function removeVault(uint64 poolId, bytes16 scId, uint128 assetId) public {
        poolManager.unlinkVault(poolId, scId, assetId, vaults[0]);
    }
}

/// 2 Enter Functions
/// 2 Cancel Functions
/// 4 Callback functions
