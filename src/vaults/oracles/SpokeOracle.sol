// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpokeOracle, IVaultOracle} from "./interfaces/IVaultOracle.sol";

import {D18} from "../../misc/types/D18.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @title  Spoke Oracle
/// @notice Default vault oracle: the hub-notified prices from the spoke registry, valid unless the pool
///         paused it or they exceed the optional age and skew bounds. The pool unpauses from the hub only,
///         but its spoke managers can pause on the spoke's chain.
contract SpokeOracle is ISpokeOracle {
    uint64 public immutable maxAge;
    address public immutable envoy;
    uint64 public immutable maxSkew;
    ISpokeRegistry public immutable spokeRegistry;

    mapping(PoolId => bool) public isPaused;

    constructor(ISpokeRegistry spokeRegistry_, uint64 maxAge_, uint64 maxSkew_, address envoy_) {
        spokeRegistry = spokeRegistry_;
        maxAge = maxAge_;
        maxSkew = maxSkew_;
        envoy = envoy_;
        emit OracleConfigured(spokeRegistry_, maxAge_, maxSkew_, envoy_);
    }

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        bool paused_ = abi.decode(payload, (bool));
        if (isPaused[poolId] == paused_) return;
        isPaused[poolId] = paused_;
        emit SetPaused(poolId, paused_, msg.sender);
    }

    /// @inheritdoc ISpokeOracle
    function pause(PoolId poolId) external {
        require(spokeRegistry.manager(poolId, msg.sender), NotManager());

        if (isPaused[poolId]) return;
        isPaused[poolId] = true;
        emit SetPaused(poolId, true, msg.sender);
    }

    /// @inheritdoc IVaultOracle
    function prices(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (D18 pricePoolPerAsset, D18 pricePoolPerShare, bool valid)
    {
        pricePoolPerAsset = spokeRegistry.pricePoolPerAsset(poolId, scId, assetId, false);
        pricePoolPerShare = spokeRegistry.pricePoolPerShare(poolId, scId, false);

        if (isPaused[poolId]) return (pricePoolPerAsset, pricePoolPerShare, false);

        uint64 assetComputedAt = spokeRegistry.pricePoolPerAssetComputedAt(poolId, scId, assetId);
        uint64 shareComputedAt = spokeRegistry.pricePoolPerShareComputedAt(poolId, scId);

        // The prices are read unchecked, so an unset one (zero `computedAt`) is refused here.
        if (assetComputedAt == 0 || shareComputedAt == 0) return (pricePoolPerAsset, pricePoolPerShare, false);

        if (maxAge != 0 && (!_isFresh(assetComputedAt) || !_isFresh(shareComputedAt))) {
            return (pricePoolPerAsset, pricePoolPerShare, false);
        }

        valid = maxSkew == 0 || MathLib.absDiff(assetComputedAt, shareComputedAt) <= maxSkew;
    }

    /// @dev Bounded on both sides, so a `computedAt` in the future is not fresh.
    function _isFresh(uint64 computedAt) internal view returns (bool) {
        return computedAt <= block.timestamp && block.timestamp <= uint256(computedAt) + maxAge;
    }
}
