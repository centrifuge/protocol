// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

// Src Deps | For cycling of values
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {RestrictedTransfers} from "src/vaults/token/RestrictedTransfers.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import {Properties} from "../properties/Properties.sol";

// @dev A way to separately code and maintain a mocked implementation of `Gateway`
// Based on
// `Gateway.handle(bytes calldata message)`
/**
 * - deployNewTokenPoolAndShare Core function that deploys a Liquidity Pool
 *     - poolManager_registerAsset
 */
abstract contract GatewayMockTargets is BaseTargetFunctions, Properties {
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
            (newShareToken,) = poolManager_addShareClass(POOL_ID, SHARE_ID, name, symbol, 18, address(restrictedTransfers));
        }

        newVault = deployVault(POOL_ID, SHARE_ID, newAssetId);
        asyncRequests.rely(address(newVault));


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
        approvals[0] = address(poolManager);
        approvals[1] = address(vault);
        _finalizeAssetDeployment(_getActors(), approvals, initialMintPerUsers);

        vault = AsyncVault(newVault);
        assetErc20 = ERC20(newToken);
        token = CentrifugeToken(newShareToken);
        restrictedTransfers = RestrictedTransfers(address(token.hook()));

        scId = SHARE_ID;
        poolId = POOL_ID;
        assetId = newAssetId;

        // NOTE: Implicit return
    }

    // Create a Asset
    // Add it to All Pools

    // Step 2
    function poolManager_registerAsset(address assetAddress, uint256 erc6909TokenId) public notGovFuzzing asAdmin returns (uint128 assetId) {
        assetId = poolManager.registerAsset(assetAddress, erc6909TokenId, DEFAULT_DESTINATION_CHAIN);

        // Only if successful
        assetAddressToAssetId[assetAddress] = assetId;
        assetIdToAssetAddress[assetId] = assetAddress;
    }

    // Step 3
    function poolManager_addPool(uint64 poolId) public notGovFuzzing asAdmin {
        poolManager.addPool(poolId);
    }

    // Step 4
    function poolManager_addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public notGovFuzzing asAdmin returns (address, bytes16) {
        address newToken = poolManager.addShareClass(
            poolId, scId, tokenName, tokenSymbol, decimals, keccak256(abi.encodePacked(poolId, scId)), hook
        );

        shareClassTokens.push(newToken);

        return (newToken, scId);
    }

    // Step 5
    function poolManager_deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public returns (address) {
        return poolManager.deployVault(poolId, scId, assetId, address(vaultFactory));
    }

    // Step 6 deploy the pool
    function deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public notGovFuzzing returns (address) {
        address newVault = poolManager.deployVault(poolId, scId, assetId, address(vaultFactory));
        poolManager.linkVault(poolId, scId, assetId, newVault);

        vaults.push(newVault);

        return newVault;
    }

    // Extra 7 - Remove liquidity Pool
    function removeVault(uint64 poolId, bytes16 scId, uint128 assetId) public {
        poolManager.unlinkVault(poolId, scId, assetId, vaults[0]);
    }

    /**
     * NOTE: All of these are implicitly clamped!
     */
    function poolManager_updateMember(uint64 validUntil) public {
        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(_getActor().toBytes32(), validUntil).serialize()
        );
    }

    // TODO: Price is capped at u64 to test overflows
    function poolManager_updateSharePrice(uint64 price, uint64 computedAt) public {
        poolManager.updateSharePrice(poolId, scId, assetId, price, computedAt);
    }

    function poolManager_updateShareMetadata(string memory tokenName, string memory tokenSymbol) public {
        poolManager.updateShareMetadata(poolId, scId, tokenName, tokenSymbol);
    }

    function poolManager_freeze() public {
        poolManager.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionFreeze(_getActor().toBytes32()).serialize());
    }

    function poolManager_unfreeze() public {
        poolManager.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionUnfreeze(_getActor().toBytes32()).serialize());
    }

    // TODO: Rely / Permissions
    // Only after all system is setup
    function root_scheduleRely(address target) public {
        root.scheduleRely(target);
    }

    function root_cancelRely(address target) public {
        root.cancelRely(target);
    }
}

/// 2 Enter Functions
/// 2 Cancel Functions
/// 4 Callback functions
