// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {IValuation} from "src/common/interfaces/IValuation.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

contract MinSubordination is Auth {
    error InvalidJuniorRatio(D18 newRatio, D18 minRatio);

    IHub public immutable hub;
    IHoldings public immutable holdings;
    IShareClassManager public immutable scm;

    PoolId public immutable poolId;
    ShareClassId public immutable seniorScId;
    ShareClassId public immutable juniorScId;

    D18 public minJuniorRatio;

    constructor(
        IHub hub_,
        IHoldings holdings_,
        IShareClassManager scm_,
        PoolId poolId_,
        ShareClassId seniorScId_,
        ShareClassId juniorScId_
    ) Auth(msg.sender) {
        hub = hub_;
        holdings = holdings_;
        scm = scm_;

        poolId = poolId_;
        seniorScId = seniorScId_;
        juniorScId = juniorScId_;
    }

    // --- Administration ---
    function setMinJuniorRatio(D18 newRatio) external auth {
        minJuniorRatio = newRatio;
        _checkRatio();
    }

    // --- Pool management ---
    function fulfill(
        AssetId assetId,
        uint128 seniorDeposit,
        uint128 seniorRedeem,
        D18 seniorNavPerShare,
        uint128 juniorDeposit,
        uint128 juniorRedeem,
        D18 juniorNavPerShare
    ) external auth {
        IValuation valuation = holdings.valuation(poolId, seniorScId, assetId);

        hub.updateSharePrice(poolId, seniorScId, seniorNavPerShare);
        hub.updateSharePrice(poolId, juniorScId, juniorNavPerShare);

        hub.approveDeposits(poolId, seniorScId, assetId, scm.nowDepositEpoch(seniorScId, assetId), seniorDeposit);
        hub.issueShares(poolId, seniorScId, assetId, scm.nowIssueEpoch(seniorScId, assetId), seniorNavPerShare);

        hub.approveRedeems(poolId, seniorScId, assetId, scm.nowRedeemEpoch(seniorScId, assetId), seniorRedeem);
        hub.revokeShares(poolId, seniorScId, assetId, scm.nowRevokeEpoch(seniorScId, assetId), seniorNavPerShare);

        hub.approveDeposits(poolId, juniorScId, assetId, scm.nowDepositEpoch(juniorScId, assetId), juniorDeposit);
        hub.issueShares(poolId, juniorScId, assetId, scm.nowIssueEpoch(juniorScId, assetId), juniorNavPerShare);

        hub.approveRedeems(poolId, juniorScId, assetId, scm.nowRedeemEpoch(juniorScId, assetId), juniorRedeem);
        hub.revokeShares(poolId, juniorScId, assetId, scm.nowRevokeEpoch(juniorScId, assetId), juniorNavPerShare);

        _checkRatio();
    }

    // --- Validation ---
    function _checkRatio() internal view {
        (uint128 seniorIssuance, D18 seniorPrice) = scm.metrics(seniorScId);
        (uint128 juniorIssuance, D18 juniorPrice) = scm.metrics(juniorScId);

        D18 seniorValue = d18(seniorIssuance) * seniorPrice;
        D18 juniorValue = d18(juniorIssuance) * juniorPrice;

        D18 juniorRatio = juniorValue / (seniorValue + juniorValue);
        require(juniorRatio >= minJuniorRatio, InvalidJuniorRatio(juniorRatio, minJuniorRatio));
    }
}
