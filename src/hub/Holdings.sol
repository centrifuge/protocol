// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IHoldings, Holding, HoldingAccount, Snapshot} from "./interfaces/IHoldings.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {AccountId} from "../common/types/AccountId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";
import {ISnapshotHook} from "../common/interfaces/ISnapshotHook.sol";

/// @title  Holdings
/// @notice Bookkeeping of the holdings and its associated accounting IDs for each pool.
/// @dev    Keeps track of whether the current holdings + share issuance in `ShareClassManager` is a snapshot. This is
///         the case when assets and shares are in sync for the given network, and can be used to derive computations
///         that rely on the ratio, such as the price per share.
contract Holdings is Auth, IHoldings {
    using MathLib for uint256;

    IHubRegistry public immutable hubRegistry;

    mapping(PoolId => ISnapshotHook) public snapshotHook;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Holding))) public holding;
    mapping(PoolId => mapping(ShareClassId => mapping(uint16 centrifugeId => Snapshot))) public snapshot;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(uint8 kind => AccountId)))) public accountId;

    constructor(IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Holding creation & updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHoldings
    function initialize(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation_,
        bool isLiability_,
        HoldingAccount[] memory accounts
    ) external auth {
        require(!scId.isNull(), WrongShareClassId());
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) == address(0), AlreadyInitialized());

        holding_.valuation = valuation_;
        holding_.isLiability = isLiability_;

        for (uint256 i; i < accounts.length; i++) {
            accountId[poolId][scId][assetId][accounts[i].kind] = accounts[i].accountId;
        }

        emit Initialize(poolId, scId, assetId, valuation_, isLiability_, accounts);
    }

    /// @inheritdoc IHoldings
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId_)
        external
        auth
    {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        accountId[poolId][scId][assetId][kind] = accountId_;

        emit SetAccountId(poolId, scId, assetId, kind, accountId_);
    }

    /// @inheritdoc IHoldings
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation_) external auth {
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        holding_.valuation = valuation_;

        emit UpdateValuation(poolId, scId, assetId, valuation_);
    }

    /// @inheritdoc IHoldings
    function updateIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability_) external auth {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());
        require(holding_.assetAmount == 0 && holding_.assetAmountValue == 0, HoldingNotZero());

        holding_.isLiability = isLiability_;

        emit UpdateIsLiability(poolId, scId, assetId, isLiability_);
    }

    /// @inheritdoc IHoldings
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external auth {
        snapshotHook[poolId] = hook;

        emit SetSnapshotHook(poolId, hook);
    }

    /// @inheritdoc IHoldings
    function setSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bool isSnapshot, uint64 nonce)
        external
        auth
    {
        Snapshot storage snapshot_ = snapshot[poolId][scId][centrifugeId];
        require(snapshot_.nonce == nonce, InvalidNonce(snapshot_.nonce, nonce));

        snapshot_.isSnapshot = isSnapshot;
        snapshot_.nonce++;

        emit SetSnapshot(poolId, scId, centrifugeId, isSnapshot, nonce);

        if (!isSnapshot) return;

        ISnapshotHook hook = snapshotHook[poolId];
        if (address(hook) != address(0)) hook.onSync(poolId, scId, centrifugeId);
    }

    //----------------------------------------------------------------------------------------------
    // Value updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHoldings
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        Holding storage holding_ = holding[poolId][scId][assetId];

        amountValue = PricingLib.convertWithPrice(
            amount_, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        );

        holding_.assetAmount += amount_;
        holding_.assetAmountValue += amountValue;

        emit Increase(poolId, scId, assetId, pricePoolPerAsset, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        Holding storage holding_ = holding[poolId][scId][assetId];

        amountValue = PricingLib.convertWithPrice(
            amount_, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        );

        holding_.assetAmount -= amount_;
        holding_.assetAmountValue -= amountValue;

        emit Decrease(poolId, scId, assetId, pricePoolPerAsset, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function update(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        auth
        returns (bool isPositive, uint128 diffValue)
    {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        uint128 currentAmountValue =
            holding_.valuation.getQuote(holding_.assetAmount, assetId, hubRegistry.currency(poolId));

        isPositive = currentAmountValue >= holding_.assetAmountValue;
        diffValue =
            isPositive ? currentAmountValue - holding_.assetAmountValue : holding_.assetAmountValue - currentAmountValue;

        holding_.assetAmountValue = currentAmountValue;

        emit Update(poolId, scId, assetId, isPositive, diffValue);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHoldings
    function isInitialized(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        return address(holding[poolId][scId][assetId].valuation) != address(0);
    }

    /// @inheritdoc IHoldings
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value_) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        return holding_.assetAmountValue;
    }

    /// @inheritdoc IHoldings
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount_) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        return holding_.assetAmount;
    }

    /// @inheritdoc IHoldings
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IValuation) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        return holding_.valuation;
    }

    /// @inheritdoc IHoldings
    function isLiability(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        return holding_.isLiability;
    }
}
