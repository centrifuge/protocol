// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";


// Src Deps | For cycling of values
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {ERC20} from "src/misc/ERC20.sol";
import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

import {Properties} from "../properties/Properties.sol";
import {OpType} from "../BeforeAfter.sol";
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
            (newShareToken,) = poolManager_addShareClass(POOL_ID, SHARE_ID, name, symbol, 18, address(fullRestrictions));
        }

        newVault = deployVault(POOL_ID, SHARE_ID, newAssetId);
        asyncRequestManager.rely(address(newVault));

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
    function poolManager_registerAsset(address assetAddress, uint256 erc6909TokenId) public notGovFuzzing asAdmin returns (uint128 assetId) {
        assetId = poolManager.registerAsset{value: 0.1 ether}(DEFAULT_DESTINATION_CHAIN, assetAddress, erc6909TokenId).raw();

        // Only if successful
        assetAddressToAssetId[assetAddress] = assetId;
        assetIdToAssetAddress[assetId] = assetAddress;
    }

    // Step 3
    function poolManager_addPool(uint64 poolId) public notGovFuzzing asAdmin {
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
    ) public notGovFuzzing asAdmin returns (address, bytes16) {
        poolManager.addShareClass(
            PoolId.wrap(poolId), ShareClassId.wrap(scId), tokenName, tokenSymbol, decimals, keccak256(abi.encodePacked(poolId, scId)), hook
        );

        address newToken = address(poolManager.shareToken(PoolId.wrap(poolId), ShareClassId.wrap(scId)));

        shareClassTokens.push(newToken);

        return (newToken, scId);
    }

    // Step 5
    function poolManager_deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public asAdmin returns (address) {
        return address(poolManager.deployVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), vaultFactory));
    }

    // Step 6 deploy the pool
    function deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public notGovFuzzing asAdmin returns (address) {
        address newVault = address(poolManager.deployVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), vaultFactory));
        poolManager.linkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), IBaseVault(newVault));

        vaults.push(newVault);

        return newVault;
    }

    // Extra 7 - Remove liquidity Pool
    function removeVault(uint64 poolId, bytes16 scId, uint128 assetId) public asAdmin{
        poolManager.unlinkVault(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), IBaseVault(vaults[0]));
    }

    function removeVault_clamped() public asAdmin{
        // use poolId, scId, assetId deployed in deployNewTokenPoolAndShare
        removeVault(poolId, scId, assetId);
    }

    /**
     * NOTE: All of these are implicitly clamped!
     */
    function poolManager_updateMember(uint64 validUntil) public asAdmin {
        poolManager.updateRestriction(
            PoolId.wrap(poolId), ShareClassId.wrap(scId), MessageLib.UpdateRestrictionMember(_getActor().toBytes32(), validUntil).serialize()
        );
    }

    // TODO: Price is capped at u64 to test overflows
    function poolManager_updatePricePoolPerShare(uint64 price, uint64 computedAt) public updateGhostsWithType(OpType.ADMIN) asAdmin {
        poolManager.updatePricePoolPerShare(PoolId.wrap(poolId), ShareClassId.wrap(scId), price, computedAt);
        poolManager.updatePricePoolPerAsset(PoolId.wrap(poolId), ShareClassId.wrap(scId), AssetId.wrap(assetId), price, computedAt);
    }

    function poolManager_updateShareMetadata(string memory tokenName, string memory tokenSymbol) public asAdmin {
        poolManager.updateShareMetadata(PoolId.wrap(poolId), ShareClassId.wrap(scId), tokenName, tokenSymbol);
    }

    function poolManager_freeze() public asAdmin {
        poolManager.updateRestriction(PoolId.wrap(poolId), ShareClassId.wrap(scId), MessageLib.UpdateRestrictionFreeze(_getActor().toBytes32()).serialize());
    }

    function poolManager_unfreeze() public asAdmin {
        poolManager.updateRestriction(PoolId.wrap(poolId), ShareClassId.wrap(scId), MessageLib.UpdateRestrictionUnfreeze(_getActor().toBytes32()).serialize());
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
