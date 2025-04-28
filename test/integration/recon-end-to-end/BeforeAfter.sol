// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {MockERC20} from "@recon/MockERC20.sol";

import {D18} from "src/misc/types/D18.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {EpochPointers, UserOrder} from "src/hub/interfaces/IShareClassManager.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import {AsyncInvestmentState} from "src/vaults/interfaces/investments/IAsyncRequests.sol";

import {Ghosts} from "./helpers/Ghosts.sol";
import {Setup} from "./Setup.sol";

enum OpType {
    GENERIC, // generic operations can be performed by both users and admins
    ADMIN, // admin operations can only be performed by admins
    DEPOSIT,
    REDEEM,
    BATCH // batch operations that make multiple calls in one transaction
}


abstract contract BeforeAfter is Ghosts {

    struct BeforeAfterVars {
        uint256 escrowTokenBalance;
        uint256 escrowTrancheTokenBalance;
        uint256 totalAssets;
        uint256 actualAssets;
        uint256 pricePerShare;
        uint256 totalShareSupply;
        uint128 ghostDebited;
        uint128 ghostCredited;
        uint32 ghostLatestRedeemApproval;

        mapping(address investor => AsyncInvestmentState) investments;
        mapping(PoolId poolId => uint32) ghostEpochId;
        mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
            ghostRedeemRequest;
        mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint128 assetAmountValue))) ghostHolding;
        mapping(PoolId poolId => mapping(AccountId accountId => int128 accountValue)) ghostAccountValue;
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
        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            _before.ghostEpochId[poolId] = shareClassManager.epochId(poolId);
            // loop through all share classes for the pool
            for (uint32 j = 0; j < shareClassManager.shareClassCount(poolId); j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);

                (,_before.ghostLatestRedeemApproval,,) = shareClassManager.epochPointers(scId, assetId);
                (, _before.ghostHolding[poolId][scId][assetId],,) = holdings.holding(poolId, scId, assetId);
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = CastLib.toBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, actor);
                    _before.ghostRedeemRequest[scId][assetId][actor] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }

                // loop over all account types defined in IHub::AccountType
                for(uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (,,,uint64 lastUpdated,) = accounting.accounts(poolId, accountId);
                    // accountValue is only set if the account has been updated
                    if(lastUpdated != 0) {
                        _before.ghostAccountValue[poolId][accountId] = accounting.accountValue(poolId, accountId);
                    }
                }
            }
        }
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
        for (uint256 i = 0; i < createdPools.length; i++) {
            address[] memory _actors = _getActors();
            PoolId poolId = createdPools[i];
            _after.ghostEpochId[poolId] = shareClassManager.epochId(poolId);
            // loop through all share classes for the pool
            for (uint32 j = 0; j < shareClassManager.shareClassCount(poolId); j++) {
                ShareClassId scId = shareClassManager.previewShareClassId(poolId, j);
                AssetId assetId = hubRegistry.currency(poolId);
                
                (,_after.ghostLatestRedeemApproval,,) = shareClassManager.epochPointers(scId, assetId);
                (, _after.ghostHolding[poolId][scId][assetId],,) = holdings.holding(poolId, scId, assetId);
                // loop over all actors
                for (uint256 k = 0; k < _actors.length; k++) {
                    bytes32 actor = CastLib.toBytes32(_actors[k]);
                    (uint128 pendingRedeem, uint32 lastUpdate) = shareClassManager.redeemRequest(scId, assetId, actor);
                    _after.ghostRedeemRequest[scId][assetId][actor] = UserOrder({pending: pendingRedeem, lastUpdate: lastUpdate});
                }

                // loop over all account types defined in IHub::AccountType
                for(uint8 kind = 0; kind < 6; kind++) {
                    AccountId accountId = holdings.accountId(poolId, scId, assetId, kind);
                    (,,,uint64 lastUpdated,) = accounting.accounts(poolId, accountId);
                    // accountValue is only set if the account has been updated
                    if(lastUpdated != 0) {
                        _after.ghostAccountValue[poolId][accountId] = accounting.accountValue(poolId, accountId);
                    }
                }
            }
        }
    }

    function _updateInvestmentForAllActors(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        address[] memory actors = _getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            (
                uint128 maxMint,
                uint128 maxWithdraw,
                uint256 depositPrice,
                uint256 redeemPrice,
                uint128 pendingDepositRequest,
                uint128 pendingRedeemRequest,
                uint128 claimableCancelDepositRequest,
                uint128 claimableCancelRedeemRequest,
                bool pendingCancelDepositRequest,
                bool pendingCancelRedeemRequest
            ) = asyncRequests.investments(address(vault), actors[i]);
            
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

        if(address(token) != address(0)) {
            _structToUpdate.escrowTrancheTokenBalance = token.balanceOf(address(escrow));
            _structToUpdate.totalShareSupply = token.totalSupply();
        }

        if (address(vault) != address(0)) {
            _structToUpdate.escrowTokenBalance = MockERC20(vault.asset()).balanceOf(address(escrow));
            _structToUpdate.actualAssets = MockERC20(vault.asset()).balanceOf(address(vault));
        }
    }

    function _priceAssetNonZero(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        D18 priceAsset;
        try poolManager.pricePoolPerAsset(poolId, scId, assetId, false) returns (D18 _priceAsset, uint64) {
            priceAsset = _priceAsset;
        } catch (bytes memory reason) {
            bool expected = checkError(reason, "ShareTokenDoesNotExist()");
            if(expected) {
                _structToUpdate.totalAssets = 0;
                return;
            }
        }
        
        if (priceAsset.raw() != 0) {
            _structToUpdate.totalAssets = vault.totalAssets();
        } else {
            _structToUpdate.totalAssets = 0;
        }
    }

    function _priceShareNonZero(bool before) internal {
        BeforeAfterVars storage _structToUpdate = before ? _before : _after;

        D18 priceShare;
        try poolManager.pricePoolPerShare(poolId, scId, false) returns (D18 _priceShare, uint64) {
            priceShare = _priceShare;
        } catch (bytes memory reason) {
            bool expected = checkError(reason, "ShareTokenDoesNotExist()");
            if(expected) {
                _structToUpdate.pricePerShare = 0;
                return;
            }
        }
        
        if (priceShare.raw() != 0) {
            _structToUpdate.pricePerShare = vault.pricePerShare();
        } else {
            _structToUpdate.pricePerShare = 0;
        }
    }
}
