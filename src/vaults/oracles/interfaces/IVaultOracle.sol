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
    /// @notice What a `fromHub` payload sets, its first word.
    enum ConfigKind {
        /// @dev `abi.encode(SetPaused, bool paused)`: the pool's pause flag.
        SetPaused,
        /// @dev `abi.encode(SetPauser, address pauser, bool allowed)`: who may `pause` the pool on this chain.
        SetPauser
    }

    /// @notice The oracle was deployed with its price source, bounds and configuring Envoy.
    event OracleConfigured(ISpokeRegistry indexed spokeRegistry, uint64 maxAge, uint64 maxSkew, address indexed envoy);

    /// @notice A pool's pause flag changed to `paused`, by `by`: the envoy for the hub, or the local pauser that
    ///         paused. Not emitted when a call leaves it as it was.
    event SetPaused(PoolId indexed poolId, bool paused, address indexed by);

    /// @notice The pool allowed or disallowed `pauser` to pause it on this chain.
    event SetPauser(PoolId indexed poolId, address indexed pauser, bool allowed);

    /// @notice Only the Envoy may configure the oracle from the hub.
    error NotEnvoy();

    /// @notice The caller is not a pauser of the pool it tried to pause.
    error NotPauser();

    /// @notice Configuring the oracle takes no native value.
    error UnexpectedValue();

    /// @notice A `fromHub` payload names a configuration kind this contract does not handle.
    error UnknownConfigKind();

    /// @notice Pauses a pool's checked reads from the spoke's chain, without waiting on a hub message.
    /// @dev    Open to the pool's pausers (`ConfigKind.SetPauser`), a role of its own rather than the spoke manager
    ///         role, so a key that can only stop the lane need not be able to move the escrow. Pausing only:
    ///         unpausing stays with the pool, through `fromHub`.
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
    /// @dev    Set through the Envoy (`fromHub`, `ConfigKind.SetPaused`), or set by `pause`. Closes the instant lane
    ///         and the previews of a caller in instant mode; async settlement, claims and a claimant's previews are
    ///         untouched, since they price from the ledger.
    function isPaused(PoolId poolId) external view returns (bool);

    /// @notice Whether `who` may `pause` the pool on this chain.
    function isPauser(PoolId poolId, address who) external view returns (bool);
}
