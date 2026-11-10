// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FlowTargets} from "./FlowTargets.sol";

import {OpType} from "../BeforeAfter.sol";

/// @dev The NAV pool's reports, as the spokes of two networks would send them: asset deltas and share issuance, each
///      message numbered per network, a snapshot flag ending a batch. The ghosts keep each network's assets and
///      shares as the messages state them, so the NAV the contracts compute is checked against a sum made apart
///      from them: assets scaled to the pool currency, less the liability, signed per network.
abstract contract NavTargets is FlowTargets {
    function nav_updateAssets(uint256 assetSeed, uint256 amount, bool isIncrease, bool isSnapshot)
        public
        updateGhosts(OpType.MANAGER)
    {
        uint256 i = assetSeed % 4;
        uint16 net = navAssets[i].centrifugeId();
        uint128 delta;
        if (isIncrease) {
            delta = uint128(between(amount, 1, 1e9 * 10 ** navDecimals[i]));
        } else {
            if (ghostNavAmount[i] == 0) return;
            delta = uint128(between(amount, 1, ghostNavAmount[i]));
        }

        hubHandler.updateAssets(net, poolN, scN, navAssets[i], delta, isIncrease, isSnapshot, ghostNavNonce[net]++);
        ghostNavAmount[i] = isIncrease ? ghostNavAmount[i] + delta : ghostNavAmount[i] - delta;
        if (isSnapshot) _navSynced(net);
        _ok("nav_updateAssets");
    }

    function nav_updateShares(uint256 netSeed, uint256 amount, bool isIssuance, bool isSnapshot)
        public
        updateGhosts(OpType.MANAGER)
    {
        uint16 net = netSeed % 2 == 0 ? NAV_NET_A : NAV_NET_B;
        uint128 delta;
        if (isIssuance) {
            delta = uint128(between(amount, 1, 1e30));
        } else {
            if (ghostNavShares[net] == 0) return;
            delta = uint128(between(amount, 1, ghostNavShares[net]));
        }

        hubHandler.updateShares(net, poolN, scN, delta, isIssuance, isSnapshot, ghostNavNonce[net]++);
        ghostNavShares[net] = isIssuance ? ghostNavShares[net] + delta : ghostNavShares[net] - delta;
        if (isSnapshot) _navSynced(net);
        _ok("nav_updateShares");
    }

    function _navSynced(uint16 net) internal {
        ghostNavSynced[net] = true;
        ghostNavSyncedNav[net] = _ghostNav(net);
        ghostNavSyncedShares[net] = ghostNavShares[net];
    }
}
