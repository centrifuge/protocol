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

        (bytes[] memory cs, uint256 c) = (new bytes[](10), 0);
        cs[c++] = abi.encodeWithSelector(hub.updatePricePoolPerShare.selector, seniorScId, seniorNavPerShare, bytes(""));
        cs[c++] = abi.encodeWithSelector(hub.updatePricePoolPerShare.selector, juniorScId, juniorNavPerShare, bytes(""));
        cs[c++] = abi.encodeWithSelector(hub.approveDeposits.selector, seniorScId, assetId, seniorDeposit, valuation);
        cs[c++] = abi.encodeWithSelector(hub.issueShares.selector, seniorScId, assetId, seniorNavPerShare);
        cs[c++] = abi.encodeWithSelector(hub.approveRedeems.selector, seniorScId, assetId, seniorRedeem);
        cs[c++] = abi.encodeWithSelector(hub.revokeShares.selector, seniorScId, assetId, seniorNavPerShare, valuation);
        cs[c++] = abi.encodeWithSelector(hub.approveDeposits.selector, juniorScId, assetId, juniorDeposit, valuation);
        cs[c++] = abi.encodeWithSelector(hub.issueShares.selector, juniorScId, assetId, juniorNavPerShare);
        cs[c++] = abi.encodeWithSelector(hub.approveRedeems.selector, juniorScId, assetId, juniorRedeem);
        cs[c++] = abi.encodeWithSelector(hub.revokeShares.selector, assetId, juniorNavPerShare, valuation);

        hub.execute(poolId, cs);

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
