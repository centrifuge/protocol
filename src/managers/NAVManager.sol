// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVManager, INAVHook} from "./interfaces/INAVManager.sol";
import {INAVManagerFactory} from "./interfaces/INAVManagerFactory.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";
import {ISnapshotHook} from "../common/interfaces/ISnapshotHook.sol";
import {AccountId, withCentrifugeId} from "../common/types/AccountId.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IHoldings} from "../hub/interfaces/IHoldings.sol";
import {IAccounting} from "../hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";

/// @dev Assumes all assets in a pool are shared across all share classes, not segregated.
contract NAVManager is INAVManager {
    PoolId public immutable poolId;

    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;
    IHoldings public immutable holdings;
    IAccounting public immutable accounting;

    INAVHook public navHook;
    mapping(uint16 centrifugeId => uint16) public accountCounter;
    mapping(uint16 centrifugeId => mapping(AssetId => AccountId)) public assetIdToAccountId;
    mapping(address => bool) public manager;

    constructor(PoolId poolId_, IHub hub_) {
        poolId = poolId_;

        hub = hub_;
        hubRegistry = hub_.hubRegistry();
        holdings = hub.holdings();
        accounting = hub.accounting();
    }

    /// @dev Check if the msg.sender is a manager
    modifier onlyManager() {
        require(manager[msg.sender], NotAuthorized());
        _;
    }

    /// @dev Check if the msg.sender is a hub manager
    modifier onlyHubManager() {
        require(hubRegistry.manager(poolId, msg.sender), NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function setNAVHook(INAVHook navHook_) external onlyHubManager {
        navHook = navHook_;
        emit SetNavHook(address(navHook_));
    }

    /// @inheritdoc INAVManager
    function updateManager(address manager_, bool canManage) external onlyHubManager {
        require(manager_ != address(0), EmptyAddress());

        manager[manager_] = canManage;

        emit UpdateManager(manager_, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function initializeNetwork(uint16 centrifugeId) external onlyManager {
        require(accountCounter[centrifugeId] == 0, AlreadyInitialized());

        hub.createAccount(poolId, equityAccount(centrifugeId), false);
        hub.createAccount(poolId, liabilityAccount(centrifugeId), false);
        hub.createAccount(poolId, gainAccount(centrifugeId), false);
        hub.createAccount(poolId, lossAccount(centrifugeId), false);

        accountCounter[centrifugeId] = 5;

        emit InitializeNetwork(centrifugeId);
    }

    /// @inheritdoc INAVManager
    function initializeHolding(ShareClassId scId, AssetId assetId, IValuation valuation) external onlyManager {
        uint16 centrifugeId = assetId.centrifugeId();
        uint16 index = accountCounter[centrifugeId];
        require(index > 0, NotInitialized());
        require(index < type(uint16).max, ExceedsMaxAccounts());

        AccountId assetAccount_ = assetIdToAccountId[centrifugeId][assetId];
        if (assetAccount_.isNull()) {
            assetAccount_ = withCentrifugeId(centrifugeId, index);
            assetIdToAccountId[centrifugeId][assetId] = assetAccount_;
        }

        hub.createAccount(poolId, assetAccount_, true);
        hub.initializeHolding(
            poolId,
            scId,
            assetId,
            valuation,
            assetAccount_,
            equityAccount(centrifugeId),
            gainAccount(centrifugeId),
            lossAccount(centrifugeId)
        );

        accountCounter[centrifugeId] = index + 1;

        emit InitializeHolding(scId, assetId);
    }

    /// @inheritdoc INAVManager
    function initializeLiability(ShareClassId scId, AssetId assetId, IValuation valuation) external onlyManager {
        uint16 centrifugeId = assetId.centrifugeId();
        uint16 index = accountCounter[centrifugeId];
        require(index > 0, NotInitialized());
        require(index < type(uint16).max, ExceedsMaxAccounts());

        AccountId expenseAccount_ = assetIdToAccountId[centrifugeId][assetId];
        if (expenseAccount_.isNull()) {
            expenseAccount_ = withCentrifugeId(centrifugeId, index);
            assetIdToAccountId[centrifugeId][assetId] = expenseAccount_;
        }

        hub.createAccount(poolId, expenseAccount_, true);
        hub.initializeLiability(poolId, scId, assetId, valuation, expenseAccount_, liabilityAccount(centrifugeId));

        accountCounter[centrifugeId] = index + 1;

        emit InitializeLiability(scId, assetId);
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotHook
    function onSync(PoolId poolId_, ShareClassId scId, uint16 centrifugeId) external {
        require(msg.sender == address(holdings), NotAuthorized());
        require(poolId == poolId_, InvalidPoolId());
        _onSync(scId, centrifugeId);
    }

    /// @inheritdoc ISnapshotHook
    function onTransfer(
        PoolId poolId_,
        ShareClassId scId_,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external {
        require(msg.sender == address(hub), NotAuthorized());
        require(poolId == poolId_, InvalidPoolId());
        require(address(navHook) != address(0), InvalidNAVHook());

        navHook.onTransfer(poolId, scId_, fromCentrifugeId, toCentrifugeId, sharesTransferred);

        emit Transfer(scId_, fromCentrifugeId, toCentrifugeId, sharesTransferred);
    }

    /// @inheritdoc INAVManager
    function updateHoldingValue(ShareClassId scId, AssetId assetId) public onlyManager {
        hub.updateHoldingValue(poolId, scId, assetId);
        (bool isSnapshot,) = holdings.snapshot(poolId, scId, assetId.centrifugeId());
        if (isSnapshot) {
            _onSync(scId, assetId.centrifugeId());
        }
    }

    /// @inheritdoc INAVManager
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IValuation valuation) external onlyManager {
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
        updateHoldingValue(scId, assetId);
    }

    /// @inheritdoc INAVManager
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external
        onlyManager
    {
        hub.setHoldingAccountId(poolId, scId, assetId, kind, accountId);
    }

    // TODO: realize gain/loss to move to equity account

    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function netAssetValue(uint16 centrifugeId) public view returns (uint128) {
        // TODO: how to handle when one of the accounts is not positive (or positive for loss account)
        (bool equityIsPositive, uint128 equity) = accounting.accountValue(poolId, equityAccount(centrifugeId));
        (bool gainIsPositive, uint128 gain) = accounting.accountValue(poolId, gainAccount(centrifugeId));
        (bool lossIsPositive, uint128 loss) = accounting.accountValue(poolId, lossAccount(centrifugeId));
        (bool liabilityIsPositive, uint128 liability) = accounting.accountValue(poolId, liabilityAccount(centrifugeId));

        require(equityIsPositive && gainIsPositive && liabilityIsPositive && (!lossIsPositive || loss == 0), "");

        return equity + gain - loss - liability;
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function assetAccount(uint16 centrifugeId, AssetId assetId) public view returns (AccountId) {
        return assetIdToAccountId[centrifugeId][assetId];
    }

    /// @inheritdoc INAVManager
    function expenseAccount(uint16 centrifugeId, AssetId assetId) public view returns (AccountId) {
        return assetAccount(centrifugeId, assetId);
    }

    /// @inheritdoc INAVManager
    function equityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 1);
    }

    /// @inheritdoc INAVManager
    function liabilityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 2);
    }

    /// @inheritdoc INAVManager
    function gainAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 3);
    }

    /// @inheritdoc INAVManager
    function lossAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 4);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    function _onSync(ShareClassId scId, uint16 centrifugeId) internal {
        require(address(navHook) != address(0), InvalidNAVHook());

        uint128 netAssetValue_ = netAssetValue(centrifugeId);
        navHook.onUpdate(poolId, scId, centrifugeId, netAssetValue_);

        emit Sync(scId, centrifugeId, netAssetValue_);
    }
}

contract NAVManagerFactory is INAVManagerFactory {
    IHub public immutable hub;

    constructor(IHub hub_) {
        hub = hub_;
    }

    /// @inheritdoc INAVManagerFactory
    function newManager(PoolId poolId) external returns (INAVManager) {
        require(hub.hubRegistry().exists(poolId), InvalidPoolId());

        NAVManager manager = new NAVManager{salt: bytes32(uint256(poolId.raw()))}(poolId, hub);

        emit DeployNavManager(poolId, address(manager));
        return INAVManager(manager);
    }
}
