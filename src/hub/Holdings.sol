// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ConversionLib} from "src/misc/libraries/ConversionLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IHoldings, Holding, HoldingAccount} from "src/hub/interfaces/IHoldings.sol";

contract Holdings is Auth, IHoldings {
    using MathLib for uint256; // toInt128()

    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Holding))) public holding;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(uint8 kind => AccountId)))) public accountId;

    IHubRegistry public hubRegistry;

    constructor(IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hubRegistry = hubRegistry_;
    }

    /// @inheritdoc IHoldings
    function file(bytes32 what, address data) external auth {
        if (what == "hubRegistry") hubRegistry = IHubRegistry(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @inheritdoc IHoldings
    function create(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bool isLiability_,
        HoldingAccount[] memory accounts
    ) external auth {
        require(!scId.isNull(), WrongShareClassId());

        holding[poolId][scId][assetId] = Holding(0, 0, isLiability_, true);

        for (uint256 i; i < accounts.length; i++) {
            accountId[poolId][scId][assetId][accounts[i].kind] = accounts[i].accountId;
        }

        emit Create(poolId, scId, assetId, isLiability_, accounts);
    }

    /// @inheritdoc IHoldings
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        amountValue = ConversionLib.convertWithPrice(
            amount_, hubRegistry.decimals(assetId.raw()), hubRegistry.decimals(poolId), price
        ).toUint128();

        holding_.assetAmount += amount_;
        holding_.assetAmountValue += amountValue;

        emit Increase(poolId, scId, assetId, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        amountValue = ConversionLib.convertWithPrice(
            amount_, hubRegistry.decimals(assetId.raw()), hubRegistry.decimals(poolId), price
        ).toUint128();

        holding_.assetAmount -= amount_;
        holding_.assetAmountValue -= amountValue;

        emit Decrease(poolId, scId, assetId, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function update(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price)
        external
        auth
        returns (bool isPositive, uint128 diffValue)
    {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        uint128 currentAmountValue = ConversionLib.convertWithPrice(
            holding_.assetAmount, hubRegistry.decimals(assetId.raw()), hubRegistry.decimals(poolId), price
        ).toUint128();

        isPositive = currentAmountValue >= holding_.assetAmountValue;
        diffValue =
            isPositive ? currentAmountValue - holding_.assetAmountValue : holding_.assetAmountValue - currentAmountValue;

        holding_.assetAmountValue = currentAmountValue;

        emit Update(poolId, scId, assetId, isPositive, diffValue);
    }

    /// @inheritdoc IHoldings
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId_)
        external
        auth
    {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        accountId[poolId][scId][assetId][kind] = accountId_;

        emit SetAccountId(poolId, scId, assetId, kind, accountId_);
    }

    /// @inheritdoc IHoldings
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value_) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        return holding_.assetAmountValue;
    }

    /// @inheritdoc IHoldings
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount_) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        return holding_.assetAmount;
    }

    /// @inheritdoc IHoldings
    function isLiability(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(holding_.existence, HoldingNotFound());

        return holding_.isLiability;
    }

    function exists(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        return holding[poolId][scId][assetId].existence;
    }
}
