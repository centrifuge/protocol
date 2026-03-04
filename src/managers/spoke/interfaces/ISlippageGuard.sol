// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

struct AssetEntry {
    address asset;
    uint256 tokenId;
}

struct SlippageConfig {
    uint16 maxEpochSlippageBps; // Per-epoch cumulative max in bps (0 = disabled)
    uint32 epochDuration; // Epoch window in seconds
}

struct EpochState {
    uint256 accumulatedSlippage; // Sum of (loss / totalPreValue) per script, 1e18 precision
    uint48 epochStart;
}

interface ISlippageGuard is ITrustedContractUpdate {
    error SlippageExceeded(uint256 withdrawn, uint256 deposited, uint16 maxBps);
    error EpochSlippageExceeded(uint256 accumulated, uint16 maxBps);
    error NotOpen();
    error NotAuthorized();

    event SetConfig(PoolId indexed poolId, ShareClassId indexed scId, uint16 maxEpochSlippageBps, uint32 epochDuration);

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
        returns (uint16 maxEpochSlippageBps, uint32 epochDuration);
    function epoch(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint256 accumulatedSlippage, uint48 epochStart);
}
