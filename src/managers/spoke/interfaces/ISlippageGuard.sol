// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

struct AssetEntry {
    address asset;
    uint256 tokenId;
}

struct SlippageConfig {
    uint16 maxPeriodLossBps; // Per-period cumulative max in bps (0 = disabled)
    uint32 periodDuration; // Period window in seconds
}

struct PeriodState {
    uint256 cumulativeLoss; // Sum of (loss / totalPreValue) per script, 1e18 precision
    uint48 periodStart;
}

interface ISlippageGuard is ITrustedContractUpdate {
    error SlippageExceeded(uint256 withdrawn, uint256 deposited, uint16 maxBps);
    error PeriodLossExceeded(uint256 accumulated, uint16 maxBps);
    error NotOpen();
    error NotAuthorized();

    event SetConfig(PoolId indexed poolId, ShareClassId indexed scId, uint16 maxPeriodLossBps, uint32 periodDuration);

    //----------------------------------------------------------------------------------------------
    // Functions
    //----------------------------------------------------------------------------------------------

    /// @notice Snapshots holdings for each asset before script execution.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assets The list of assets to snapshot
    function open(PoolId poolId, ShareClassId scId, AssetEntry[] calldata assets) external;

    /// @notice Verifies slippage after script execution by comparing current holdings to snapshots.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param maxSlippageBps Maximum allowed slippage in basis points
    function close(PoolId poolId, ShareClassId scId, uint16 maxSlippageBps) external;

    function contractUpdater() external view returns (address);
    function config(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint16 maxPeriodLossBps, uint32 periodDuration);
    function period(PoolId poolId, ShareClassId scId) external view returns (uint256 cumulativeLoss, uint48 periodStart);
}
