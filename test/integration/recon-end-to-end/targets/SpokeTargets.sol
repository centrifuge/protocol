// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MessageLib} from "src/core/messaging/libraries/MessageLib.sol";
import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {PoolId} from "src/core/types/PoolId.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";

import {Properties} from "../properties/Properties.sol";
import {OpType} from "../BeforeAfter.sol";

// Only for Share
abstract contract SpokeTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using MessageLib for *;

    // NOTE: These introduce many false positives because they're used for cross-chain transfers but our test
    // environment only allows tracking state on one chain so they were removed
    // TODO: Overflow stuff
    // function spoke_handleTransferShares(uint128 amount, uint256 investorEntropy) public updateGhosts asActor {
    //     address investor = _getRandomActor(investorEntropy);
    //     spoke.handleTransferShares(poolId, scId, investor, amount);

    //     // TF-12 mint share class tokens to user, not tracked in escrow

    //     // Track minting for Global-3
    //     incomingTransfers[address(token)] += amount;
    // }

    // function spoke_transferSharesToEVM(uint16 destinationChainId, bytes32 destinationAddress, uint128 amount)
    //     public
    // updateGhosts asActor {
    //     uint256 balB4 = token.balanceOf(_getActor());

    //     // Clamp
    //     if (amount > balB4) {
    //         amount %= uint128(balB4);
    //     }

    //     // Exact approval
    //     token.approve(address(spoke), amount);

    //     spoke.transferShares(destinationChainId, poolId, scId, destinationAddress, amount);
    //     // TF-11 burns share class tokens from user, not tracked in escrow

    //     // Track minting for Global-3
    //     outGoingTransfers[address(token)] += amount;

    //     uint256 balAfterActor = token.balanceOf(_getActor());

    //     t(balAfterActor <= balB4, "PM-3-A");
    //     t(balB4 - balAfterActor == amount, "PM-3-A");
    // }

    // Step 1
    function spoke_registerAsset(
        address assetAddress,
        uint256 erc6909TokenId
    ) public updateGhosts asAdmin returns (uint128 assetId) {
        assetId = spoke
        .registerAsset{value: 0.1 ether}(
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
        spoke.addPool(_getPool());
    }

    // Step 3
    function spoke_addShareClass(
        uint128 scIdAsUint,
        uint8 decimals,
        address hook
    ) public updateGhosts asAdmin returns (address, bytes16) {
        string memory name = "Test ShareClass";
        string memory symbol = "TSC";
        bytes16 scId = bytes16(scIdAsUint);

        spoke.addShareClass(
            _getPool(),
            ShareClassId.wrap(scId),
            name,
            symbol,
            decimals,
            keccak256(abi.encodePacked(_getPool(), scId)),
            hook
        );
        address newToken = address(
            spoke.shareToken(_getPool(), ShareClassId.wrap(scId))
        );

        _addShareClassId(scId);
        _addShareClassToPool(_getPool(), ShareClassId.wrap(scId));
        _addShareToken(newToken);

        return (newToken, scId);
    }

    // Step 4 - deploy the pool
    function spoke_deployVault(
        bool isAsync
    ) public updateGhostsWithType(OpType.ADMIN) asAdmin returns (address) {
        address vault;
        if (isAsync) {
            vault = address(
                vaultRegistry.deployVault(
                    _getPool(),
                    _getShareClassId(),
                    _getAssetId(),
                    asyncVaultFactory
                )
            );
        } else {
            vault = address(
                vaultRegistry.deployVault(
                    _getPool(),
                    _getShareClassId(),
                    _getAssetId(),
                    syncVaultFactory
                )
            );
        }

        _addVault(vault);

        return vault;
    }

    function spoke_deployVault_clamped() public returns (address) {
        return spoke_deployVault(true);
    }

    // Step 5 - set the request manager
    function spoke_setRequestManager(
        address vault
    ) public updateGhosts asAdmin {
        IBaseVault vaultInstance = IBaseVault(vault);
        PoolId poolId = vaultInstance.poolId();

        spoke.setRequestManager(poolId, asyncRequestManager);
    }

    // Step 6- link the vault
    function spoke_linkVault(address vault) public updateGhosts asAdmin {
        IBaseVault vaultInstance = IBaseVault(vault);
        PoolId poolId = vaultInstance.poolId();
        ShareClassId scId = vaultInstance.scId();
        AssetId assetId = _getAssetId();

        vaultRegistry.linkVault(poolId, scId, assetId, IBaseVault(vault));
    }

    function spoke_linkVault_clamped() public {
        spoke_linkVault(address(_getVault()));
    }

    // Extra 7 - remove the vault
    function spoke_unlinkVault() public updateGhosts asAdmin {
        vaultRegistry.unlinkVault(
            _getPool(),
            _getShareClassId(),
            _getAssetId(),
            IBaseVault(_getVault())
        );
    }

    /**
     * NOTE: All of these are implicitly clamped using values set in shortcut_deployNewTokenPoolAndShare
     */
    function spoke_updateMember(uint64 validUntil) public updateGhosts asAdmin {
        spoke.updateRestriction(
            _getPool(),
            _getShareClassId(),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionMember(
                    _getActor().toBytes32(),
                    validUntil
                )
            )
        );
    }

    // NOTE: in e2e tests, these get called as callbacks in notifyAssetPrice and notifySharePrice
    function spoke_updatePricePoolPerShare(
        uint128 price,
        uint64 computedAt
    ) public updateGhostsWithType(OpType.ADMIN) asAdmin {
        PoolId poolId = _getPool();
        ShareClassId scId = _getShareClassId();
        AssetId assetId = _getAssetId();
        spoke.updatePricePoolPerShare(
            poolId,
            scId,
            D18.wrap(price),
            computedAt
        );
        spoke.updatePricePoolPerAsset(
            poolId,
            scId,
            assetId,
            D18.wrap(price),
            computedAt
        );
    }

    function spoke_updateShareMetadata(
        string memory tokenName,
        string memory tokenSymbol
    ) public updateGhosts asAdmin {
        spoke.updateShareMetadata(
            _getPool(),
            _getShareClassId(),
            tokenName,
            tokenSymbol
        );
    }

    function spoke_freeze() public updateGhosts asAdmin {
        spoke.updateRestriction(
            _getPool(),
            _getShareClassId(),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionFreeze(
                    _getActor().toBytes32()
                )
            )
        );
    }

    function spoke_unfreeze() public updateGhosts asAdmin {
        spoke.updateRestriction(
            _getPool(),
            _getShareClassId(),
            UpdateRestrictionMessageLib.serialize(
                UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(
                    _getActor().toBytes32()
                )
            )
        );
    }
}
