// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {d18, D18} from "src/misc/types/D18.sol";

import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {IHoldings, Holding} from "src/hub/interfaces/IHoldings.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IHoldings, Holding, HoldingAccount} from "src/hub/interfaces/IHoldings.sol";

/// @title  Holdings
/// @notice Bookkeeping of the holdings and its associated accounting IDs for each pool.
contract Holdings is Auth, IHoldings {
    using MathLib for uint256;

    IHubRegistry public immutable hubRegistry;

    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Holding))) public holding;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(uint8 kind => AccountId)))) public accountId;

    constructor(IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Holding creation & updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHoldings
    function create(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IERC7726 valuation_,
        bool isLiability_,
        HoldingAccount[] memory accounts
    ) external auth {
        require(!scId.isNull(), WrongShareClassId());
        require(address(valuation_) != address(0), WrongValuation());

        holding[poolId][scId][assetId] = Holding(0, 0, valuation_, isLiability_);

        for (uint256 i; i < accounts.length; i++) {
            accountId[poolId][scId][assetId][accounts[i].kind] = accounts[i].accountId;
        }

        emit Create(poolId, scId, assetId, valuation_, isLiability_, accounts);
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
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation_) external auth {
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        holding_.valuation = valuation_;

        emit UpdateValuation(poolId, scId, assetId, valuation_);
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
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        amountValue = PricingLib.convertWithPrice(
            amount_, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        ).toUint128();

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
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        amountValue = PricingLib.convertWithPrice(
            amount_, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), pricePoolPerAsset
        ).toUint128();

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

        uint128 currentAmountValue = holding_.valuation.getQuote(
            holding_.assetAmount, assetId.addr(), hubRegistry.currency(poolId).addr()
        ).toUint128();

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
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value_) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        return holding_.assetAmountValue;
    }

    /// @inheritdoc IHoldings
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount_) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        return holding_.assetAmount;
    }

    /// @inheritdoc IHoldings
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IERC7726) {
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

    /// @inheritdoc IHoldings
    function exists(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        return address(holding[poolId][scId][assetId].valuation) != address(0);
    }
}
