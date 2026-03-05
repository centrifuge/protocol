// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISlippageGuard, AssetEntry, SlippageConfig, PeriodState} from "./interfaces/ISlippageGuard.sol";

import {D18} from "../../misc/types/D18.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IERC20Metadata} from "../../misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../misc/interfaces/IERC6909.sol";
import {TransientArrayLib} from "../../misc/libraries/TransientArrayLib.sol";
import {TransientStorageLib} from "../../misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {PricingLib} from "../../core/libraries/PricingLib.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

/// @title  SlippageGuard
/// @notice Standalone bookend contract for Executor scripts. Call `open()` at the start and `close()` at the end
///         of a script to verify that the net value change across all touched assets stays within a slippage bound.
///         Additionally tracks cumulative loss per period to prevent death-by-a-thousand-cuts attacks.
contract SlippageGuard is ISlippageGuard {
    bytes32 internal constant ASSETS_SLOT = keccak256("slippageGuard.assets");
    bytes32 internal constant TOKEN_IDS_SLOT = keccak256("slippageGuard.tokenIds");
    bytes32 internal constant OPENER_SLOT = keccak256("slippageGuard.opener");
    bytes32 internal constant POOL_ID_SLOT = keccak256("slippageGuard.poolId");
    bytes32 internal constant SC_ID_SLOT = keccak256("slippageGuard.scId");
    uint256 internal constant PRE_BASE_SLOT = uint256(keccak256("slippageGuard.pre"));

    ISpoke public immutable spoke;
    IBalanceSheet public immutable balanceSheet;
    address public immutable contractUpdater;

    mapping(PoolId => mapping(ShareClassId => PeriodState)) public period;
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

        (uint128 maxPeriodLoss, uint32 periodDuration) = abi.decode(payload, (uint128, uint32));
        config[poolId][scId] = SlippageConfig(maxPeriodLoss, periodDuration);
        emit SetConfig(poolId, scId, maxPeriodLoss, periodDuration);
    }

    //----------------------------------------------------------------------------------------------
    // Bookend actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISlippageGuard
    function open(PoolId poolId, ShareClassId scId, AssetEntry[] calldata assets) external {
        if (TransientArrayLib.length(ASSETS_SLOT) > 0) {
            TransientArrayLib.clear(ASSETS_SLOT);
            TransientArrayLib.clear(TOKEN_IDS_SLOT);
        }
        TransientStorageLib.tstore(OPENER_SLOT, uint256(uint160(msg.sender)));
        TransientStorageLib.tstore(POOL_ID_SLOT, uint256(poolId.raw()));
        TransientStorageLib.tstore(SC_ID_SLOT, uint256(uint128(ShareClassId.unwrap(scId))));

        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 tokenId = assets[i].tokenId;

            TransientArrayLib.push(ASSETS_SLOT, bytes32(uint256(uint160(asset))));
            TransientArrayLib.push(TOKEN_IDS_SLOT, bytes32(tokenId));

            uint128 balance = balanceSheet.availableBalanceOf(poolId, scId, asset, tokenId);
            TransientStorageLib.tstore(bytes32(PRE_BASE_SLOT + i), uint256(balance));
        }
    }

    /// @inheritdoc ISlippageGuard
    /// @dev Withdrawn amounts are rounded up and deposited amounts rounded down, so a mathematically
    ///      zero-slippage swap may produce a phantom loss of up to 1 wei per asset. Consequently,
    ///      setting `maxSlippageBps = 0` effectively disables all swaps. Use at least 1 bps if any
    ///      balance change is expected.
    function close(PoolId poolId, ShareClassId scId, uint16 maxSlippageBps) external {
        require(TransientArrayLib.length(ASSETS_SLOT) > 0, NotOpen());
        require(msg.sender == address(uint160(TransientStorageLib.tloadUint256(OPENER_SLOT))), NotOpener());
        require(
            poolId.raw() == uint64(TransientStorageLib.tloadUint256(POOL_ID_SLOT))
                && ShareClassId.unwrap(scId) == bytes16(uint128(TransientStorageLib.tloadUint256(SC_ID_SLOT))),
            ContextMismatch()
        );

        uint8 poolDecimals = IERC20Metadata(address(spoke.shareToken(poolId, scId))).decimals();
        (uint256 withdrawn, uint256 deposited) = _computeDeltas(poolId, scId, poolDecimals);
        if (withdrawn > 0) {
            uint256 loss = withdrawn > deposited ? withdrawn - deposited : 0;
            require(loss <= withdrawn * maxSlippageBps / 10_000, SlippageExceeded(withdrawn, deposited, maxSlippageBps));

            if (loss > 0) {
                _trackPeriodLoss(poolId, scId, uint128(loss));
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
        returns (uint256 withdrawn, uint256 deposited)
    {
        bytes32[] memory assets = TransientArrayLib.getBytes32(ASSETS_SLOT);
        bytes32[] memory tokenIds = TransientArrayLib.getBytes32(TOKEN_IDS_SLOT);

        for (uint256 i; i < assets.length; i++) {
            address asset = address(uint160(uint256(assets[i])));
            uint256 tokenId = uint256(tokenIds[i]);

            uint128 pre = uint128(TransientStorageLib.tloadUint256(bytes32(PRE_BASE_SLOT + i)));
            uint128 post = balanceSheet.availableBalanceOf(poolId, scId, asset, tokenId);

            D18 price = spoke.pricePoolPerAsset(poolId, scId, spoke.assetToId(asset, tokenId), true);
            uint8 assetDecimals =
                tokenId == 0 ? IERC20Metadata(asset).decimals() : IERC6909MetadataExt(asset).decimals(tokenId);

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

    /// @dev Tracks absolute loss in pool units.
    function _trackPeriodLoss(PoolId poolId, ShareClassId scId, uint128 loss) internal {
        SlippageConfig storage cfg = config[poolId][scId];
        if (cfg.periodDuration == 0) return;

        PeriodState storage ps = period[poolId][scId];

        if (block.timestamp >= ps.periodStart + cfg.periodDuration) {
            ps.cumulativeLoss = loss;
            ps.periodStart = uint48(block.timestamp);
        } else {
            ps.cumulativeLoss += loss;
        }

        require(ps.cumulativeLoss <= cfg.maxPeriodLoss, PeriodLossExceeded(ps.cumulativeLoss, cfg.maxPeriodLoss));
    }
}
