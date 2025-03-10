// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import "src/pools/SingleShareClass.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";

abstract contract SingleShareClassTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///



    function singleShareClass_addShareClass(PoolId poolId, string memory name, string memory symbol, bytes32 salt, bytes memory data) public asActor {
        singleShareClass.addShareClass(poolId, name, symbol, salt, data);
    }

    function singleShareClass_approveDeposits(PoolId poolId, ShareClassId shareClassId_, uint128 maxApproval, AssetId paymentAssetId, IERC7726 valuation) public asActor {
        singleShareClass.approveDeposits(poolId, shareClassId_, maxApproval, paymentAssetId, valuation);
    }

    function singleShareClass_approveRedeems(PoolId poolId, ShareClassId shareClassId_, uint128 maxApproval, AssetId payoutAssetId) public asActor {
        singleShareClass.approveRedeems(poolId, shareClassId_, maxApproval, payoutAssetId);
    }

    function singleShareClass_cancelDepositRequest(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId) public asActor {
        singleShareClass.cancelDepositRequest(poolId, shareClassId_, investor, depositAssetId);
    }

    function singleShareClass_cancelRedeemRequest(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId) public asActor {
        singleShareClass.cancelRedeemRequest(poolId, shareClassId_, investor, payoutAssetId);
    }

    function singleShareClass_claimDeposit(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId) public asActor {
        singleShareClass.claimDeposit(poolId, shareClassId_, investor, depositAssetId);
    }

    function singleShareClass_claimDepositUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId depositAssetId, uint32 endEpochId) public asActor {
        singleShareClass.claimDepositUntilEpoch(poolId, shareClassId_, investor, depositAssetId, endEpochId);
    }

    function singleShareClass_claimRedeem(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId) public asActor {
        singleShareClass.claimRedeem(poolId, shareClassId_, investor, payoutAssetId);
    }

    function singleShareClass_claimRedeemUntilEpoch(PoolId poolId, ShareClassId shareClassId_, bytes32 investor, AssetId payoutAssetId, uint32 endEpochId) public asActor {
        singleShareClass.claimRedeemUntilEpoch(poolId, shareClassId_, investor, payoutAssetId, endEpochId);
    }

    function singleShareClass_deny(address user) public asActor {
        singleShareClass.deny(user);
    }

    function singleShareClass_file(bytes32 what, address data) public asActor {
        singleShareClass.file(what, data);
    }

    function singleShareClass_issueShares(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, D18 navPerShare) public asActor {
        singleShareClass.issueShares(poolId, shareClassId_, depositAssetId, navPerShare);
    }

    function singleShareClass_issueSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId depositAssetId, D18 navPerShare, uint32 endEpochId) public asActor {
        singleShareClass.issueSharesUntilEpoch(poolId, shareClassId_, depositAssetId, navPerShare, endEpochId);
    }

    function singleShareClass_rely(address user) public asActor {
        singleShareClass.rely(user);
    }

    function singleShareClass_requestDeposit(PoolId poolId, ShareClassId shareClassId_, uint128 amount, bytes32 investor, AssetId depositAssetId) public asActor {
        singleShareClass.requestDeposit(poolId, shareClassId_, amount, investor, depositAssetId);
    }

    function singleShareClass_requestRedeem(PoolId poolId, ShareClassId shareClassId_, uint128 amount, bytes32 investor, AssetId payoutAssetId) public asActor {
        singleShareClass.requestRedeem(poolId, shareClassId_, amount, investor, payoutAssetId);
    }

    function singleShareClass_revokeShares(PoolId poolId, ShareClassId shareClassId_, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) public asActor {
        singleShareClass.revokeShares(poolId, shareClassId_, payoutAssetId, navPerShare, valuation);
    }

    function singleShareClass_revokeSharesUntilEpoch(PoolId poolId, ShareClassId shareClassId_, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation, uint32 endEpochId) public asActor {
        singleShareClass.revokeSharesUntilEpoch(poolId, shareClassId_, payoutAssetId, navPerShare, valuation, endEpochId);
    }

    function singleShareClass_updateMetadata(PoolId poolId, ShareClassId shareClassId_, string memory name, string memory symbol, bytes32 salt, bytes memory data) public asActor {
        singleShareClass.updateMetadata(PoolId(poolId), ShareClassId(shareClassId_), name, symbol, salt, data);
    }
}