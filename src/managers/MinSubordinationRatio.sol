// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18, divD8} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

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
    IShareClassManager public immutable shareClassManager;

    PoolId public immutable poolId;
    ShareClassId public immutable seniorScId;
    ShareClassId public immutable juniorScId;

    D18 public minJuniorRatio;

    constructor(
        IHub hub_,
        IHoldings holdings_,
        IShareClassManager shareClassManager_,
        PoolId poolId_,
        ShareClassId seniorScId_,
        ShareClassId juniorScId_
    ) Auth(msg.sender) {
        hub = hub_;
        holdings = holdings_;
        shareClassManager = shareClassManager_;

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
        IERC7726 valuation = holdings.valuation(poolId, seniorScId, assetId);

        hub.updatePricePoolPerShare(poolId, seniorScId, seniorNavPerShare, bytes(""));
        hub.updatePricePoolPerShare(poolId, juniorScId, juniorNavPerShare, bytes(""));

        hub.approveDeposits(poolId, seniorScId, assetId, seniorDeposit, valuation);
        hub.issueShares(poolId, seniorScId, assetId, seniorNavPerShare);

        hub.approveRedeems(poolId, seniorScId, assetId, seniorRedeem);
        hub.revokeShares(poolId, seniorScId, assetId, seniorNavPerShare, valuation);

        hub.approveDeposits(poolId, juniorScId, assetId, juniorDeposit, valuation);
        hub.issueShares(poolId, juniorScId, assetId, juniorNavPerShare);

        hub.approveRedeems(poolId, juniorScId, assetId, juniorRedeem);
        hub.revokeShares(poolId, juniorScId, assetId, juniorNavPerShare, valuation);

        _checkRatio();
    }

    // --- Validation ---
    function _checkRatio() internal view {
        (uint128 seniorIssuance,) = shareClassManager.shareClassPrice(poolId, seniorScId);
        (uint128 juniorIssuance,) = shareClassManager.shareClassPrice(poolId, juniorScId);

        D18 juniorRatio = d18(juniorIssuance) / (d18(seniorIssuance) + d18(juniorIssuance));
        require(juniorRatio >= minJuniorRatio, InvalidJuniorRatio(juniorRatio, minJuniorRatio));
    }
}
