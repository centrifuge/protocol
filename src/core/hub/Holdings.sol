// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IValuation} from "./interfaces/IValuation.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {ISnapshotHook} from "./interfaces/ISnapshotHook.sol";
import {IHoldings, Holding, Snapshot} from "./interfaces/IHoldings.sol";

import {Auth} from "../../misc/Auth.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {AccountId} from "../types/AccountId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// @title  Holdings
/// @notice Bookkeeping of the holdings and its associated accounting IDs for each pool.
/// @dev    Keeps track of whether the current holdings + share issuance in `ShareClassManager` is a snapshot. This is
///         the case when assets and shares are in sync for the given network, and can be used to derive computations
///         that rely on the ratio, such as the price per share.
contract Holdings is Auth, IHoldings {
    using MathLib for uint256;

    IHubRegistry public immutable hubRegistry;

    mapping(PoolId => ISnapshotHook) public snapshotHook;
    mapping(PoolId => mapping(uint16 centrifugeId => uint32)) public networkDeficitCount;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => Holding))) internal _holding;
    mapping(PoolId => mapping(ShareClassId => mapping(uint16 centrifugeId => uint32))) public deficitCount;
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
        AccountId[4] memory accounts
    ) external auth {
        require(!scId.isNull(), WrongShareClassId());
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = _holding[poolId][scId][assetId];
        require(address(holding_.valuation) == address(0), AlreadyInitialized());

        holding_.valuation = valuation_;

        for (uint256 i; i < 4; i++) {
            accountId[poolId][scId][assetId][uint8(i)] = accounts[i];
        }

        emit Initialize(poolId, scId, assetId, valuation_, accounts);
    }

    /// @inheritdoc IHoldings
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId_)
        external
        auth
    {
        Holding storage holding_ = _holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        accountId[poolId][scId][assetId][kind] = accountId_;

        emit SetAccountId(poolId, scId, assetId, kind, accountId_);
    }

    /// @inheritdoc IHoldings
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation_) external auth {
        require(address(valuation_) != address(0), WrongValuation());

        Holding storage holding_ = _holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        holding_.valuation = valuation_;

        emit UpdateValuation(poolId, scId, assetId, valuation_);
    }

    /// @inheritdoc IHoldings
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external auth {
        require(hubRegistry.exists(poolId), NonExistingPool());

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

        _callOnSync(poolId, scId, centrifugeId, snapshot_);
    }

    /// @inheritdoc IHoldings
    function callOnSyncSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external auth {
        Snapshot memory snapshot_ = snapshot[poolId][scId][centrifugeId];
        _callOnSync(poolId, scId, centrifugeId, snapshot_);
    }

    /// @inheritdoc IHoldings
    function callOnTransferSnapshot(
        PoolId poolId,
        ShareClassId scId,
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        uint128 amount_
    ) external auth {
        ISnapshotHook hook = snapshotHook[poolId];
        if (address(hook) != address(0)) {
            hook.onTransfer(poolId, scId, originCentrifugeId, targetCentrifugeId, amount_);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Value updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHoldings
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, uint16 centrifugeId, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        Holding storage holding_ = _holding[poolId][scId][assetId];

        bool wasDeficit = holding_.decreasedAmount > holding_.increasedAmount;
        uint128 oldAmount = _amount(holding_);
        holding_.increasedAmount += amount_;
        uint128 realized = _amount(holding_) - oldAmount;

        // Value only the realized increase (a preceding over-decrease is netted off first) at the hub-side
        // valuation. Uninitialized holdings track amount only; their value is established at initialization.
        amountValue = realized != 0 && address(holding_.valuation) != address(0)
            ? holding_.valuation.getQuote(poolId, scId, assetId, realized)
            : 0;

        holding_.assetAmountValue += amountValue;
        _updateDeficit(poolId, scId, centrifugeId, wasDeficit, holding_.decreasedAmount > holding_.increasedAmount);

        emit Increase(poolId, scId, assetId, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, uint16 centrifugeId, uint128 amount_)
        external
        auth
        returns (uint128 amountValue)
    {
        Holding storage holding_ = _holding[poolId][scId][assetId];

        bool wasDeficit = holding_.decreasedAmount > holding_.increasedAmount;
        uint128 oldAmount = _amount(holding_);
        holding_.decreasedAmount += amount_;
        uint128 removedAmount = oldAmount - _amount(holding_);

        // Remove carrying value pro-rata to the realized decrease (an over-decrease is capped at the current
        // amount and its excess carried on `decreasedAmount`), so the returned value always mirrors the
        // storage mutation and can never over-journal. Deliberately NOT a live oracle quote like increase():
        // pro-rata preserves `amount == 0 => value == 0`, which a live quote would break when the price has
        // moved since the last update() (a full drain would leave residual value behind).
        amountValue = oldAmount == 0 ? 0 : (uint256(holding_.assetAmountValue) * removedAmount / oldAmount).toUint128();

        holding_.assetAmountValue -= amountValue;
        _updateDeficit(poolId, scId, centrifugeId, wasDeficit, holding_.decreasedAmount > holding_.increasedAmount);

        emit Decrease(poolId, scId, assetId, amount_, amountValue);
    }

    /// @inheritdoc IHoldings
    function update(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        auth
        returns (bool isPositive, uint128 diffValue)
    {
        Holding storage holding_ = _holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        uint128 currentAmountValue = holding_.valuation.getQuote(poolId, scId, assetId, _amount(holding_));

        isPositive = currentAmountValue >= holding_.assetAmountValue;
        diffValue = isPositive ? currentAmountValue - holding_.assetAmountValue : holding_.assetAmountValue - currentAmountValue; // forgefmt: disable-line

        holding_.assetAmountValue = currentAmountValue;

        emit Update(poolId, scId, assetId, isPositive, diffValue);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHoldings
    function isInitialized(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool) {
        return address(_holding[poolId][scId][assetId].valuation) != address(0);
    }

    /// @inheritdoc IHoldings
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value_) {
        Holding storage holding_ = _holding[poolId][scId][assetId];
        return holding_.assetAmountValue;
    }

    /// @inheritdoc IHoldings
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount_) {
        return _amount(_holding[poolId][scId][assetId]);
    }

    /// @inheritdoc IHoldings
    function holdingAmounts(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 increasedAmount, uint128 decreasedAmount)
    {
        Holding storage holding_ = _holding[poolId][scId][assetId];
        return (holding_.increasedAmount, holding_.decreasedAmount);
    }

    /// @inheritdoc IHoldings
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IValuation) {
        Holding storage holding_ = _holding[poolId][scId][assetId];
        require(address(holding_.valuation) != address(0), HoldingNotFound());

        return holding_.valuation;
    }

    /// @inheritdoc IHoldings
    function holding(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 assetAmount, uint128 assetAmountValue, IValuation valuation_)
    {
        Holding storage holding_ = _holding[poolId][scId][assetId];
        return (_amount(holding_), holding_.assetAmountValue, holding_.valuation);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _callOnSync(PoolId poolId, ShareClassId scId, uint16 centrifugeId, Snapshot memory snapshot_) internal {
        if (!snapshot_.isSnapshot) return;

        ISnapshotHook hook = snapshotHook[poolId];
        if (address(hook) != address(0)) hook.onSync(poolId, scId, centrifugeId);
    }

    /// @dev Moves both deficit counters on a deficit-state crossing; no-op otherwise. The share class-network
    ///      counter reports which share class is in deficit; the pool-network rollup is what a snapshot hook
    ///      gates on, because the NAV it publishes is pooled across share classes.
    function _updateDeficit(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bool wasDeficit, bool isDeficit)
        internal
    {
        if (wasDeficit == isDeficit) return;

        uint32 count =
            isDeficit ? ++deficitCount[poolId][scId][centrifugeId] : --deficitCount[poolId][scId][centrifugeId];
        uint32 networkCount =
            isDeficit ? ++networkDeficitCount[poolId][centrifugeId] : --networkDeficitCount[poolId][centrifugeId];
        emit UpdateDeficitCount(poolId, scId, centrifugeId, count, networkCount);
    }

    /// @dev Current amount, derived from the cumulative counters and floored at zero.
    function _amount(Holding storage holding_) internal view returns (uint128) {
        return
            holding_.increasedAmount >= holding_.decreasedAmount
                ? holding_.increasedAmount - holding_.decreasedAmount
                : 0;
    }
}
