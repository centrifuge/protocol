// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {Properties} from "../properties/Properties.sol";
import {OpType} from "../BeforeAfter.sol";


// Only for Share
abstract contract PoolManagerTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using MessageLib for *;

    // NOTE: These introduce many false positives because they're used for cross-chain transfers but our test environment only allows tracking state on one chain so they were removed
    // TODO: Overflow stuff
    // function poolManager_handleTransferShares(uint128 amount, uint256 investorEntropy) public updateGhosts asActor {
    //     address investor = _getRandomActor(investorEntropy);
    //     poolManager.handleTransferShares(poolId, scId, investor, amount);

    //     // TF-12 mint share class tokens to user, not tracked in escrow

    //     // Track minting for Global-3
    //     incomingTransfers[address(token)] += amount;
    // }

    // function poolManager_transferSharesToEVM(uint16 destinationChainId, bytes32 destinationAddress, uint128 amount)
    //     public
    // updateGhosts asActor {
    //     uint256 balB4 = token.balanceOf(_getActor());

    //     // Clamp
    //     if (amount > balB4) {
    //         amount %= uint128(balB4);
    //     }

    //     // Exact approval
    //     token.approve(address(poolManager), amount);

    //     poolManager.transferShares(destinationChainId, poolId, scId, destinationAddress, amount);
    //     // TF-11 burns share class tokens from user, not tracked in escrow

    //     // Track minting for Global-3
    //     outGoingTransfers[address(token)] += amount;

    //     uint256 balAfterActor = token.balanceOf(_getActor());

    //     t(balAfterActor <= balB4, "PM-3-A");
    //     t(balB4 - balAfterActor == amount, "PM-3-A");
    // }

    // Step 1
    function poolManager_registerAsset(address assetAddress, uint256 erc6909TokenId) public  asAdmin returns (uint128 assetId) {
        assetId = poolManager.registerAsset{value: 0.1 ether}(DEFAULT_DESTINATION_CHAIN, assetAddress, erc6909TokenId);

        // Only if successful
        assetAddressToAssetId[assetAddress] = assetId;
        assetIdToAssetAddress[assetId] = assetAddress;
    }

    function poolManager_registerAsset_clamped() public  asAdmin {
        poolManager_registerAsset(_getAsset(), 0);
    }

    // Step 2
    function poolManager_addPool(uint64 poolId) public  asAdmin {
        poolManager.addPool(poolId);
    }

    // Step 3
    function poolManager_addShareClass(
        uint64 poolId,
        bytes16 scId,
        uint8 decimals,
        address hook
    ) public  asAdmin returns (address, bytes16) {
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";

        address newToken = poolManager.addShareClass(
            poolId, scId, name, symbol, decimals, keccak256(abi.encodePacked(poolId, scId)), hook
        );

        shareClassTokens.push(newToken);

        return (newToken, scId);
    }

    // Step 4 - deploy the pool
    function poolManager_deployVault(uint64 poolId, bytes16 scId, uint128 assetId) public asAdmin returns (address) {
        address vault = poolManager.deployVault(poolId, scId, assetId, address(vaultFactory));
        vaults.push(vault);

        return vault;
    }

    function poolManager_deployVault_clamped() public asAdmin returns (address) {
        return poolManager_deployVault(poolId, scId, assetId);
    }

    // Step 5 - link the vault
    function poolManager_linkVault(uint64 poolId, bytes16 scId, uint128 assetId, address vault) public  asAdmin {
        poolManager.linkVault(poolId, scId, assetId, vault);
    }

    function poolManager_linkVault_clamped() public asAdmin {
        poolManager_linkVault(poolId, scId, assetId, address(vault));
    }

    // Extra 6 - remove the vault
    function poolManager_unlinkVault(uint64 poolId, bytes16 scId, uint128 assetId) public asAdmin{
        poolManager.unlinkVault(poolId, scId, assetId, vaults[0]);
    }

    function poolManager_unlinkVault_clamped() public asAdmin{
        // use poolId, scId, assetId deployed in shortcut_deployNewTokenPoolAndShare
        poolManager_unlinkVault(poolId, scId, assetId);
    }

    /**
     * NOTE: All of these are implicitly clamped using values set in shortcut_deployNewTokenPoolAndShare
    */
    function poolManager_updateMember(uint64 validUntil) public asAdmin {
        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(_getActor().toBytes32(), validUntil).serialize()
        );
    }

    // TODO: Price is capped at u64 to test overflows
    function poolManager_updatePricePoolPerShare(uint64 price, uint64 computedAt) public updateGhostsWithType(OpType.ADMIN) asAdmin {
        poolManager.updatePricePoolPerShare(poolId, scId, price, computedAt);
        poolManager.updatePricePoolPerAsset(poolId, scId, assetId, price, computedAt);
    }

    function poolManager_updateShareMetadata(string memory tokenName, string memory tokenSymbol) public asAdmin {
        poolManager.updateShareMetadata(poolId, scId, tokenName, tokenSymbol);
    }

    function poolManager_freeze() public asAdmin {
        poolManager.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionFreeze(_getActor().toBytes32()).serialize());
    }

    function poolManager_unfreeze() public asAdmin {
        poolManager.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionUnfreeze(_getActor().toBytes32()).serialize());
    }
}
