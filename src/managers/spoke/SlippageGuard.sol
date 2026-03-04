// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippageGuard, AssetEntry, SlippageConfig, EpochState} from "./interfaces/ISlippageGuard.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

import {D18} from "../../misc/types/D18.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";
import {TransientArrayLib} from "../../misc/libraries/TransientArrayLib.sol";
import {TransientStorageLib} from "../../misc/libraries/TransientStorageLib.sol";

import {PricingLib} from "../../core/libraries/PricingLib.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "../../core/spoke/interfaces/IBalanceSheet.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";

/// @title  SlippageGuard
/// @notice Standalone bookend contract for Executor scripts. Call `open()` at the start and `close()` at the end
///         of a script to verify that the net value change across all touched assets stays within a slippage bound.
///         Additionally tracks cumulative slippage per epoch to prevent death-by-a-thousand-cuts attacks.
contract SlippageGuard is ISlippageGuard {
    bytes32 internal constant ASSETS_SLOT = keccak256("slippageGuard.assets");
    bytes32 internal constant TOKEN_IDS_SLOT = keccak256("slippageGuard.tokenIds");

    ISpoke public immutable spoke;
    IBalanceSheet public immutable balanceSheet;
    address public immutable contractUpdater;

    mapping(PoolId => mapping(ShareClassId => EpochState)) public epoch;
    mapping(PoolId => mapping(ShareClassId => SlippageConfig)) public config;

    constructor(ISpoke spoke_, IBalanceSheet balanceSheet_, address contractUpdater_) {
        spoke = spoke_;
        balanceSheet = balanceSheet_;
        contractUpdater = contractUpdater_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes memory payload) external {
        require(msg.sender == contractUpdater, NotAuthorized());

        (uint16 maxEpochSlippageBps, uint32 epochDuration) = abi.decode(payload, (uint16, uint32));
        config[poolId][scId] = SlippageConfig(maxEpochSlippageBps, epochDuration);
        emit SetConfig(poolId, scId, maxEpochSlippageBps, epochDuration);
    }

    //----------------------------------------------------------------------------------------------
    // Bookend actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISlippageGuard
    function open(PoolId poolId, ShareClassId scId, AssetEntry[] calldata assets) external {
        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 tokenId = assets[i].tokenId;

            TransientArrayLib.push(ASSETS_SLOT, bytes32(uint256(uint160(asset))));
            TransientArrayLib.push(TOKEN_IDS_SLOT, bytes32(tokenId));

            uint128 balance = balanceSheet.availableBalanceOf(poolId, scId, asset, tokenId);
            bytes32 preSlot = keccak256(abi.encodePacked("slippageGuard.pre", i));
            TransientStorageLib.tstore(preSlot, uint256(balance));
        }
    }

    /// @inheritdoc ISlippageGuard
    function close(PoolId poolId, ShareClassId scId, uint16 maxSlippageBps) external {
        require(TransientArrayLib.length(ASSETS_SLOT) > 0, NotOpen());

        uint8 poolDecimals = IERC20Metadata(address(spoke.shareToken(poolId, scId))).decimals();
        (uint256 withdrawn, uint256 deposited, uint256 totalPreValue) = _computeDeltas(poolId, scId, poolDecimals);
        if (withdrawn > 0) {
            uint256 loss = withdrawn > deposited ? withdrawn - deposited : 0;
            require(loss <= withdrawn * maxSlippageBps / 10_000, SlippageExceeded(withdrawn, deposited, maxSlippageBps));

            if (loss > 0) {
                _accumulateEpoch(poolId, scId, loss, totalPreValue);
            }
        }

        TransientArrayLib.clear(ASSETS_SLOT);
        TransientArrayLib.clear(TOKEN_IDS_SLOT);
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _computeDeltas(PoolId poolId, ShareClassId scId, uint8 poolDecimals)
        internal
        view
        returns (uint256 withdrawn, uint256 deposited, uint256 totalPreValue)
    {
        bytes32[] memory assets = TransientArrayLib.getBytes32(ASSETS_SLOT);
        bytes32[] memory tokenIds = TransientArrayLib.getBytes32(TOKEN_IDS_SLOT);

        for (uint256 i; i < assets.length; i++) {
            address asset = address(uint160(uint256(assets[i])));
            uint256 tokenId = uint256(tokenIds[i]);

            uint128 pre = uint128(TransientStorageLib.tloadUint256(keccak256(abi.encodePacked("slippageGuard.pre", i))));
            uint128 post = balanceSheet.availableBalanceOf(poolId, scId, asset, tokenId);

            D18 price = spoke.pricePoolPerAsset(poolId, scId, spoke.assetToId(asset, tokenId), true);
            uint8 assetDecimals =
                tokenId == 0 ? IERC20Metadata(asset).decimals() : IERC6909MetadataExt(asset).decimals(tokenId);

            totalPreValue += PricingLib.assetToPoolAmount(
                pre, assetDecimals, poolDecimals, price, MathLib.Rounding.Down
            );

            if (post < pre) {
                withdrawn += PricingLib.assetToPoolAmount(
                    pre - post, assetDecimals, poolDecimals, price, MathLib.Rounding.Up
                );
            } else if (post > pre) {
                deposited += PricingLib.assetToPoolAmount(
                    post - pre, assetDecimals, poolDecimals, price, MathLib.Rounding.Down
                );
            }
        }
    }

    function _accumulateEpoch(PoolId poolId, ShareClassId scId, uint256 loss, uint256 totalPreValue) internal {
        SlippageConfig storage cfg = config[poolId][scId];
        if (cfg.epochDuration == 0) return;

        uint256 lossFraction = loss * 1e18 / totalPreValue;
        EpochState storage ep = epoch[poolId][scId];

        if (block.timestamp >= ep.epochStart + cfg.epochDuration) {
            ep.accumulatedSlippage = lossFraction;
            ep.epochStart = uint48(block.timestamp);
        } else {
            ep.accumulatedSlippage += lossFraction;
        }

        require(
            ep.accumulatedSlippage <= uint256(cfg.maxEpochSlippageBps) * 1e18 / 10_000,
            EpochSlippageExceeded(ep.accumulatedSlippage, cfg.maxEpochSlippageBps)
        );
    }
}
