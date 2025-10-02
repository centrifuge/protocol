// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVManager, INAVHook} from "./interfaces/INAVManager.sol";

import {Auth} from "../../misc/Auth.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IValuation} from "../../core/hub/interfaces/IValuation.sol";
import {IHoldings} from "../../core/hub/interfaces/IHoldings.sol";
import {IHub, AccountType} from "../../core/hub/interfaces/IHub.sol";
import {IAccounting} from "../../core/hub/interfaces/IAccounting.sol";
import {ISnapshotHook} from "../../core/hub/interfaces/ISnapshotHook.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";
import {AccountId, withCentrifugeId, withAssetId} from "../../core/types/AccountId.sol";

/// @dev Assumes all assets in a pool are shared across all share classes, not segregated.
contract NAVManager is INAVManager, Auth {
    IHub public immutable hub;
    IHoldings public immutable holdings;
    IAccounting public immutable accounting;
    IHubRegistry public immutable hubRegistry;

    mapping(PoolId => INAVHook) public navHook;
    mapping(PoolId poolId => mapping(address => bool)) public manager;
    mapping(PoolId poolId => mapping(uint16 centrifugeId => bool)) public initialized;

    constructor(IHub hub_, address deployer) Auth(deployer) {
        hub = hub_;
        hubRegistry = hub_.hubRegistry();
        holdings = hub.holdings();
        accounting = hub.accounting();
    }

    modifier onlyManager(PoolId poolId) {
        require(manager[poolId][msg.sender], NotAuthorized());
        _;
    }

    modifier onlyHubManager(PoolId poolId) {
        require(hubRegistry.manager(poolId, msg.sender), NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function setNAVHook(PoolId poolId, INAVHook navHook_) external onlyHubManager(poolId) {
        navHook[poolId] = navHook_;
        emit SetNavHook(poolId, address(navHook_));
    }

    /// @inheritdoc INAVManager
    function updateManager(PoolId poolId, address manager_, bool canManage) external onlyHubManager(poolId) {
        manager[poolId][manager_] = canManage;
        emit UpdateManager(poolId, manager_, canManage);
    }

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function initializeNetwork(PoolId poolId, uint16 centrifugeId) external onlyManager(poolId) {
        require(!initialized[poolId][centrifugeId], AlreadyInitialized());

        hub.createAccount(poolId, equityAccount(centrifugeId), false);
        hub.createAccount(poolId, liabilityAccount(centrifugeId), false);
        hub.createAccount(poolId, gainAccount(centrifugeId), false);
        hub.createAccount(poolId, lossAccount(centrifugeId), false);

        initialized[poolId][centrifugeId] = true;

        emit InitializeNetwork(poolId, centrifugeId);
    }

    /// @inheritdoc INAVManager
    function initializeHolding(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        onlyManager(poolId)
    {
        uint16 centrifugeId = assetId.centrifugeId();
        require(initialized[poolId][centrifugeId], NotInitialized());

        AccountId assetAccount_ = assetAccount(assetId);

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

        emit InitializeHolding(poolId, scId, assetId);
    }

    /// @inheritdoc INAVManager
    function initializeLiability(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        onlyManager(poolId)
    {
        uint16 centrifugeId = assetId.centrifugeId();
        require(initialized[poolId][centrifugeId], NotInitialized());

        AccountId expenseAccount_ = expenseAccount(assetId);

        hub.createAccount(poolId, expenseAccount_, true);
        hub.initializeLiability(poolId, scId, assetId, valuation, expenseAccount_, liabilityAccount(centrifugeId));

        emit InitializeLiability(poolId, scId, assetId);
    }

    //----------------------------------------------------------------------------------------------
    // ISnapshotHook updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotHook
    function onSync(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external auth {
        require(address(navHook[poolId]) != address(0), InvalidNAVHook());

        uint128 netAssetValue_ = netAssetValue(poolId, centrifugeId);
        navHook[poolId].onUpdate(poolId, scId, centrifugeId, netAssetValue_);

        emit Sync(poolId, scId, centrifugeId, netAssetValue_);
    }

    /// @inheritdoc ISnapshotHook
    function onTransfer(
        PoolId poolId,
        ShareClassId scId,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external auth {
        require(address(navHook[poolId]) != address(0), InvalidNAVHook());

        navHook[poolId].onTransfer(poolId, scId, fromCentrifugeId, toCentrifugeId, sharesTransferred);
        emit Transfer(poolId, scId, fromCentrifugeId, toCentrifugeId, sharesTransferred);
    }

    //----------------------------------------------------------------------------------------------
    // Holding updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external {
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    /// @inheritdoc INAVManager
    function updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation)
        external
        onlyManager(poolId)
    {
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    /// @inheritdoc INAVManager
    function closeGainLoss(PoolId poolId, uint16 centrifugeId) external onlyManager(poolId) {
        require(initialized[poolId][centrifugeId], NotInitialized());

        AccountId equityAccount_ = equityAccount(centrifugeId);
        AccountId gainAccount_ = gainAccount(centrifugeId);
        AccountId lossAccount_ = lossAccount(centrifugeId);

        (bool gainIsPositive, uint128 gainValue) = accounting.accountValue(poolId, gainAccount_);
        (bool lossIsPositive, uint128 lossValue) = accounting.accountValue(poolId, lossAccount_);

        accounting.unlock(poolId);

        // Because we're crediting the gain account for gains and debiting the loss account for losses (and loss is
        // credit-normal), gain should never be negative, and loss should never be positive.
        // Still, double-check here.
        if (gainIsPositive && gainValue > 0) {
            accounting.addDebit(gainAccount_, gainValue);
            accounting.addCredit(equityAccount_, gainValue);
        }

        if (!lossIsPositive && lossValue > 0) {
            accounting.addCredit(lossAccount_, lossValue);
            accounting.addDebit(equityAccount_, lossValue);
        }

        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function netAssetValue(PoolId poolId, uint16 centrifugeId) public view returns (uint128) {
        (bool equityIsPositive, uint128 equity) = accounting.accountValue(poolId, equityAccount(centrifugeId));
        (bool gainIsPositive, uint128 gain) = accounting.accountValue(poolId, gainAccount(centrifugeId));
        (bool lossIsPositive, uint128 loss) = accounting.accountValue(poolId, lossAccount(centrifugeId));
        (bool liabilityIsPositive, uint128 liability) = accounting.accountValue(poolId, liabilityAccount(centrifugeId));

        require(
            equityIsPositive && gainIsPositive && liabilityIsPositive && (!lossIsPositive || loss == 0), InvalidNAV()
        );

        return equity + gain - loss - liability;
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function assetAccount(AssetId assetId) public pure returns (AccountId) {
        return withAssetId(assetId, uint16(AccountType.Asset));
    }

    /// @inheritdoc INAVManager
    function expenseAccount(AssetId assetId) public pure returns (AccountId) {
        return withAssetId(assetId, uint16(AccountType.Expense));
    }

    /// @inheritdoc INAVManager
    function equityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(AccountType.Equity));
    }

    /// @inheritdoc INAVManager
    function liabilityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(AccountType.Liability));
    }

    /// @inheritdoc INAVManager
    function gainAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(AccountType.Gain));
    }

    /// @inheritdoc INAVManager
    function lossAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(AccountType.Loss));
    }
}
