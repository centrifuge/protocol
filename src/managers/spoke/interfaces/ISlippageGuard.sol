// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

struct AssetEntry {
    address asset;
    uint256 tokenId;
}

interface ISlippageGuard {
    error SlippageExceeded(uint256 withdrawn, uint256 deposited, uint16 maxBps);
    error NotOpen();

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
}
