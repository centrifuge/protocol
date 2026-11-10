// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

/// @notice The prices a vault converts at, and whether they are fit to trade on.
interface IVaultOracle {
    /// @notice The prices used for all vault conversions, and whether they may be traded on.
    /// @dev    MUST NOT revert, and returns the prices even when not `valid`, since `convertTo*` and
    ///         `totalAssets` must keep answering. An oracle that cannot decide returns false.
    /// @param  poolId The pool identifier
    /// @param  scId The share class identifier
    /// @param  assetId The asset identifier
    /// @return pricePoolPerAsset The price of 1 asset unit in pool currency
    /// @return pricePoolPerShare The price of 1 share unit in pool currency
    /// @return valid Whether the pair may be traded on right now
    function prices(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (D18 pricePoolPerAsset, D18 pricePoolPerShare, bool valid);
}

/// @notice The default oracle: hub-notified prices, with optional age and skew bounds and a per-pool
///         pause. Registry validity alone only means a price was notified once.
interface ISpokeOracle is IVaultOracle, IManagerCallFromHub {
    event OracleConfigured(ISpokeRegistry indexed spokeRegistry, uint64 maxAge, uint64 maxSkew, address indexed envoy);

    /// @notice A pool's pause flag changed to `paused`, by `by`: the envoy for the hub, or the local manager that
    ///         paused. Not emitted when a call leaves it as it was.
    event SetPaused(PoolId indexed poolId, bool paused, address indexed by);

    /// @notice Only the Envoy may set the pause flag from the hub.
    error NotEnvoy();

    /// @notice The caller is not a spoke manager of the pool it tried to pause.
    error NotManager();

    /// @notice Setting the pause flag takes no native value.
    error UnexpectedValue();

    /// @notice Pauses a pool's checked reads from the spoke's chain, without waiting on a hub message.
    /// @dev    Open to the pool's spoke managers. Pausing only: unpausing stays with the pool, through `fromHub`.
    function pause(PoolId poolId) external;

    /// @notice The spoke registry the prices are read from.
    function spokeRegistry() external view returns (ISpokeRegistry);

    /// @notice Maximum age, in seconds, of a price `prices` reports valid. Zero disables the bound.
    function maxAge() external view returns (uint64);

    /// @notice Maximum gap, in seconds, between the asset and share prices' notification times.
    /// @dev    The prices arrive in separate messages, so each can be fresh while the pair is
    ///         incoherent. Zero disables the bound.
    function maxSkew() external view returns (uint64);

    /// @notice Whether a pool's checked reads are refused.
    /// @dev    Set through the Envoy (`fromHub`, payload `(bool)`), or set by `pause`. Closes the instant lane and the
    ///         previews; async settlement and claims are untouched, since they price from the ledger.
    function isPaused(PoolId poolId) external view returns (bool);
}
