// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// @notice Hook interface that is called whenever the accounting system of the Hub, for a given share token on
///         1 network, as in a (poolId, scId, centrifugeId) tuple, is in a synchronous state. This means the assets
///         (deposits/withdrawals of holdings) are updated in alignment with the issuance of shares.
///
///         This can be used to compute higher-level properties such as the NAV and NAV/share, which require
///         assets and shares to be in sync to be accurate.
///
///         NOTE: Only the state for the given centrifugeId is guaranteed to be in sync. This means, if
///         the snapshot hook reads state from the accounting layer, the accounts of holdings and liabilities
///         should be set up per network, to not mingle in sync and out of sync state.
interface ISnapshotHook {
    /// @notice Callback when there is a sync snapshot.
    function onSync(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external;
}
