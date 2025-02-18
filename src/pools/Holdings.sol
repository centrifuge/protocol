// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {IHoldings} from "src/pools/interfaces/IHoldings.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";

contract Holdings is Auth, IHoldings {
    using MathLib for uint256; // toInt128()

    struct Holding {
        uint128 assetAmount;
        uint128 assetAmountValue;
        IERC7726 valuation; // Used for existance
    }

    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Holding))) public holding;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(uint8 kind => AccountId)))) public accountId;

    IPoolRegistry public poolRegistry;

    constructor(IPoolRegistry poolRegistry_, address deployer) Auth(deployer) {
        poolRegistry = poolRegistry_;
    }

    /// @inheritdoc IHoldings
    function file(bytes32 what, address data) external auth {
        if (what == "poolRegistry") poolRegistry = IPoolRegistry(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @inheritdoc IHoldings
    function create(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation_, AccountId[] memory accounts)
        external
        auth
    {
        require(!scId.isNull(), WrongShareClassId());
        require(address(valuation_) != address(0), WrongValuation());

        holding[poolId][scId][assetId] = Holding(0, 0, valuation_);

        for (uint256 i; i < accounts.length; i++) {
            AccountId accountId_ = accounts[i];
            accountId[poolId][scId][assetId][accountId_.kind()] = accountId_;
        }

        emit Created(poolId, scId, assetId, valuation_);
    }

    /// @inheritdoc IHoldings
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation_, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        amountValue = valuation_.getQuote(amount_, assetId.addr(), poolRegistry.currency(poolId).addr()).toUint128();

        holding_.assetAmount += amount_;
        holding_.assetAmountValue += amountValue;

        emit Increased(poolId, scId, assetId, valuation_, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation_, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        amountValue = valuation_.getQuote(amount_, assetId.addr(), poolRegistry.currency(poolId).addr()).toUint128();

        holding_.assetAmount -= amount_;
        holding_.assetAmountValue -= amountValue;

        emit Decreased(poolId, scId, assetId, valuation_, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function update(PoolId poolId, ShareClassId scId, AssetId assetId) external auth returns (int128 diffValue) {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        uint128 currentAmountValue = holding_.valuation.getQuote(
            holding_.assetAmount, assetId.addr(), poolRegistry.currency(poolId).addr()
        ).toUint128();

        diffValue = currentAmountValue > holding_.assetAmountValue
            ? uint256(currentAmountValue - holding_.assetAmountValue).toInt128()
            : -uint256(holding_.assetAmountValue - currentAmountValue).toInt128();

        holding_.assetAmountValue = currentAmountValue;

        emit Updated(poolId, scId, assetId, diffValue);
    }

    /// @inheritdoc IHoldings
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation_) external auth {
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        holding_.valuation = valuation_;

        emit ValuationUpdated(poolId, scId, assetId, valuation_);
    }

    /// @inheritdoc IHoldings
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, AccountId accountId_) external auth {
        Holding storage holding_ = holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        accountId[poolId][scId][assetId][accountId_.kind()] = accountId_;

        emit AccountIdSet(poolId, scId, assetId, accountId_);
    }

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

    function exists(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        return address(holding[poolId][scId][assetId].valuation) != address(0);
    }
}
