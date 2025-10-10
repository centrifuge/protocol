// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {D18} from "src/misc/types/D18.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {UserOrder, EpochId} from "src/hub/interfaces/IShareClassManager.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {BaseVault} from "src/vaults/BaseVaults.sol";
import {AsyncInvestmentState} from "src/vaults/interfaces/IVaultManagers.sol";

import {Setup} from "./Setup.sol";

enum OpType {
    GENERIC, // generic operations can be performed by both users and admins
    ADMIN, // admin operations can only be performed by admins
    BATCH, // batch operations that make multiple calls in one transaction
    NOTIFY,
    ADD,
    REMOVE,
    UPDATE,
    REQUEST_DEPOSIT,
    REQUEST_REDEEM
}

abstract contract BeforeAfter is Setup {
    struct PriceVars {
        // See IM_1
        uint256 maxDepositPrice;
        uint256 minDepositPrice;
        // See IM_2
        uint256 maxRedeemPrice;
        uint256 minRedeemPrice;
    }

    struct BeforeAfterVars {
        mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => D18 pricePoolPerAsset))) pricePoolPerAsset;
        mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending))) ghostRedeemRequest;
        mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint128 assetAmountValue))) ghostHolding;
        mapping(PoolId poolId => mapping(ShareClassId scId => D18 pricePoolPerShare)) pricePoolPerShare;
        mapping(PoolId poolId => mapping(AccountId accountId => uint128 accountValue)) ghostAccountValue;
        mapping(ShareClassId scId => mapping(AssetId assetId => EpochId)) ghostEpochId;
        mapping(address vault => mapping(address investor => PriceVars)) investorsGlobals; // global ghost variable only updated as needed
        mapping(address investor => AsyncInvestmentState) investments;
        mapping(address user => uint256 balance) shareTokenBalance;
        mapping(address user => uint256 balance) assetTokenBalance; // uses vault's underyling asset as source of truth instead of _getAsset()
        mapping(address vault => uint256 price) pricePerShare;
        uint256 escrowAssetBalance;
        uint256 escrowShareTokenBalance;
        uint256 poolEscrowAssetBalance;
        uint256 totalAssets;
        uint256 actualAssets;
        uint256 totalShareSupply;
        uint128 ghostDebited;
        uint128 ghostCredited;
        address vault;
    }

    BeforeAfterVars internal _before;
    BeforeAfterVars internal _after;
    OpType internal currentOperation;

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;

        __before();
        _;
        __after();

        if (op == OpType.NOTIFY) {
            __globals();
        }
    }

    function __before() internal {
        // Vault
        _updateInvestmentForAllActors(true);
        _updateValuesIfNonZero(true);

        // if price is zero these both revert so they just get set to 0
        _priceAssetNonZero(true);
        _priceShareNonZero(true);

        // Hub
        _before.ghostDebited = accounting.debited();
        _before.ghostCredited = accounting.credited();
        _before.vault = address(_getVault());

        // if the vault isn't deployed, values below can't be updated
        if (address(_getVault()) == address(0)) return;

        _before.shareTokenBalance[_getActor()] = IShareToken(_getShareToken())
            .balanceOf(_getActor());
        _before.assetTokenBalance[_getActor()] = MockERC20(_getVault().asset())
            .balanceOf(_getActor());

        _updateEpochId(true);
        _updateHolding(true);
        _updateActorRedeemRequests(true);
        _updateAccountValues(true);
    }

    function __after() internal {
        // Vault
        _updateInvestmentForAllActors(false);
        _updateValuesIfNonZero(false);

        // if price is zero these both revert so they just get set to 0
        _priceAssetNonZero(false);
        _priceShareNonZero(false);

        // Hub
        _after.ghostDebited = accounting.debited();
        _after.ghostCredited = accounting.credited();
        _after.vault = address(_getVault());

        // if the vault isn't deployed, values below can't be updated
        if (address(_getVault()) == address(0)) return;

        _after.shareTokenBalance[_getActor()] = IShareToken(_getShareToken())
            .balanceOf(_getActor());
        _after.assetTokenBalance[_getActor()] = MockERC20(_getVault().asset())
            .balanceOf(_getActor());

        _updateEpochId(false);
        _updateHolding(false);
        _updateActorRedeemRequests(false);
        _updateAccountValues(false);
    }

    /// @dev This only needs to be called if the current operation is NOTIFY
    /// @dev This is used for additional checks that don't need to be updated for every operation
    function __globals() internal {
        (
            uint256 depositPrice,
            uint256 redeemPrice
        ) = _getDepositAndRedeemPrice();
        address vault = address(_getVault());
        address actor = _getActor();

        // Conditionally Update max | Always works on zero
        _after.investorsGlobals[vault][actor].maxDepositPrice = depositPrice >
            _after.investorsGlobals[vault][actor].maxDepositPrice
            ? depositPrice
            : _after.investorsGlobals[vault][actor].maxDepositPrice;
        _after.investorsGlobals[vault][actor].maxRedeemPrice = redeemPrice >
            _after.investorsGlobals[vault][actor].maxRedeemPrice
            ? redeemPrice
            : _after.investorsGlobals[vault][actor].maxRedeemPrice;

        // Conditionally Update min
        // On zero we have to update anyway
        if (_after.investorsGlobals[vault][actor].minDepositPrice == 0) {
            _after
            .investorsGlobals[vault][actor].minDepositPrice = depositPrice;
        }
        if (_after.investorsGlobals[vault][actor].minRedeemPrice == 0) {
            _after.investorsGlobals[vault][actor].minRedeemPrice = redeemPrice;
        }

        // Conditional update after zero
        _after.investorsGlobals[vault][actor].minDepositPrice = depositPrice <
            _after.investorsGlobals[vault][actor].minDepositPrice
            ? depositPrice
            : _after.investorsGlobals[vault][actor].minDepositPrice;
        _after.investorsGlobals[vault][actor].minRedeemPrice = redeemPrice <
            _after.investorsGlobals[vault][actor].minRedeemPrice
            ? redeemPrice
            : _after.investorsGlobals[vault][actor].minRedeemPrice;
    }

    function _updateEpochId(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        (
            uint32 depositEpochId,
            uint32 redeemEpochId,
            uint32 issueEpochId,
            uint32 revokeEpochId
        ) = shareClassManager.epochId(scId, assetId);
        _structToUpdate.ghostEpochId[scId][assetId] = EpochId({
            deposit: depositEpochId,
            redeem: redeemEpochId,
            issue: issueEpochId,
            revoke: revokeEpochId
        });
    }

    function _updateHolding(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        (, _structToUpdate.ghostHolding[poolId][scId][assetId], , ) = holdings
            .holding(poolId, scId, assetId);
    }

    function _updateActorRedeemRequests(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        address[] memory _actors = _getActors();
        for (uint256 k = 0; k < _actors.length; k++) {
            bytes32 actor = CastLib.toBytes32(_actors[k]);
            (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager
                .redeemRequest(scId, assetId, actor);
            _structToUpdate.ghostRedeemRequest[scId][assetId][
                actor
            ] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
        }
    }

    function _updateAccountValues(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        for (uint8 kind = 0; kind < 6; kind++) {
            AccountId accountId = holdings.accountId(
                poolId,
                scId,
                assetId,
                kind
            );
            (, , , uint64 lastUpdated, ) = accounting.accounts(
                poolId,
                accountId
            );
            if (lastUpdated != 0) {
                try accounting.accountValue(poolId, accountId) returns (
                    bool,
                    uint128 accountValue
                ) {
                    _structToUpdate.ghostAccountValue[poolId][
                        accountId
                    ] = accountValue;
                } catch {
                    _structToUpdate.ghostAccountValue[poolId][accountId] = 0;
                }
            }
        }
    }

    /// === HELPER FUNCTIONS === ///

    function _getDepositAndRedeemPrice()
        internal
        view
        returns (uint256, uint256)
    {
        (
            ,
            ,
            D18 depositPrice,
            D18 redeemPrice,
            ,
            ,
            ,
            ,
            ,

        ) = asyncRequestManager.investments(
                IBaseVault(address(_getVault())),
                address(_getActor())
            );

        return (depositPrice.raw(), redeemPrice.raw());
    }

    function _updateInvestmentForAllActors(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        address[] memory actors = _getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                D18 depositPrice,
                D18 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = asyncRequestManager.investments(
                    IBaseVault(address(_getVault())),
                    actors[i]
                );

            _structToUpdate.investments[actors[i]] = AsyncInvestmentState(
                maxMint,
                maxWithdraw,
                depositPrice,
                redeemPrice,
                pendingDepositRequest,
                pendingRedeemRequest,
                claimableCancelDepositRequest,
                claimableCancelRedeemRequest,
                pendingCancelDepositRequest,
                pendingCancelRedeemRequest
            );
        }
    }

    function _updateValuesIfNonZero(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        if (_getShareToken() != address(0)) {
            _structToUpdate.escrowShareTokenBalance = MockERC20(
                _getShareToken()
            ).balanceOf(address(globalEscrow));
            _structToUpdate.totalShareSupply = MockERC20(_getShareToken())
                .totalSupply();
        }

        if (address(_getVault()) != address(0)) {
            _structToUpdate.escrowAssetBalance = MockERC20(_getVault().asset())
                .balanceOf(address(globalEscrow));
            _structToUpdate.poolEscrowAssetBalance = MockERC20(
                _getVault().asset()
            ).balanceOf(
                    address(poolEscrowFactory.escrow(_getVault().poolId()))
                );
            _structToUpdate.actualAssets = MockERC20(_getVault().asset())
                .balanceOf(address(_getVault()));
        }
    }

    function _priceAssetNonZero(bool before) internal {
        if (address(_getVault()) == address(0)) {
            return;
        }

        BeforeAfterVars storage _structToUpdate = before ? _before : _after;
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();

        try spoke.pricePoolPerAsset(poolId, scId, assetId, true) returns (
            D18 _priceAsset
        ) {
            _structToUpdate.pricePoolPerAsset[poolId][scId][
                assetId
            ] = _priceAsset;
        } catch (bytes memory reason) {
            bool shareTokenDoesNotExist = checkError(
                reason,
                "ShareTokenDoesNotExist()"
            );
            bool invalidPrice = checkError(reason, "InvalidPrice()");
            if (shareTokenDoesNotExist || invalidPrice) {
                _structToUpdate.totalAssets = 0;
                return;
            } else {
                _structToUpdate.totalAssets = _getVault().totalAssets();
            }
        }
    }

    function _priceShareNonZero(bool before) internal {
        if (address(_getVault()) == address(0)) {
            return;
        }

        BeforeAfterVars storage _structToUpdate = before ? _before : _after;
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        try spoke.pricePoolPerShare(poolId, scId, false) returns (
            D18 _priceShare
        ) {
            _structToUpdate.pricePoolPerShare[poolId][scId] = _priceShare;
        } catch (bytes memory reason) {
            _structToUpdate.pricePoolPerShare[poolId][scId] = D18.wrap(0);
        }

        try BaseVault(address(_getVault())).pricePerShare() returns (
            uint256 _pricePerShare
        ) {
            _structToUpdate.pricePerShare[
                address(_getVault())
            ] = _pricePerShare;
        } catch {
            _structToUpdate.pricePerShare[address(_getVault())] = 0;
        }
    }
}
