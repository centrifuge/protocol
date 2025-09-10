// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";

import {INAVManagerFactory} from "./interfaces/INAVManagerFactory.sol";
import {INAVManager, INAVHook} from "./interfaces/INAVManager.sol";
import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";
import {ISnapshotHook} from "../common/interfaces/ISnapshotHook.sol";
import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";
import {AccountId, withCentrifugeId} from "../common/types/AccountId.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IAccounting} from "../hub/interfaces/IAccounting.sol";

/// @dev Assumes all assets in a pool are shared across all share classes, not segregated.
contract NAVManager is Auth, INAVManager {
    PoolId public immutable poolId;

    IHub public immutable hub;
    address public immutable holdings;
    IAccounting public immutable accounting;

    INAVHook public navHook;
    mapping(uint16 centrifugeId => uint16) public accountCounter;
    mapping(uint16 centrifugeId => mapping(AssetId => AccountId)) public assetIdToAccountId;
    mapping(address => bool) public manager;

    constructor(PoolId poolId_, IHub hub_, address deployer) Auth(deployer) {
        poolId = poolId_;

        hub = hub_;
        holdings = address(hub.holdings());
        accounting = hub.accounting();
    }

    /// @dev Check if the msg.sender is ward or a manager
    modifier onlyManager() {
        require(wards[msg.sender] == 1 || manager[msg.sender], NotAuthorized());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function setNAVHook(INAVHook navHook_) external auth {
        navHook = navHook_;
        emit SetNavHook(address(navHook_));
    }

    /// @inheritdoc INAVManager
    function updateManager(address manager_, bool canManage) external auth {
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
        console2.log("NAVManager onSync");
        require(msg.sender == holdings, NotAuthorized());
        require(poolId == poolId_, InvalidPoolId());
        require(address(navHook) != address(0), InvalidNAVHook());

        uint128 netAssetValue_ = netAssetValue(centrifugeId);
        console2.log("NAV", netAssetValue_);
        navHook.onUpdate(poolId, scId, centrifugeId, netAssetValue_);
        console2.log("NAVManager onSync done");

        emit Sync(scId, centrifugeId, netAssetValue_);
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
    function updateHoldingValue(ShareClassId scId, AssetId assetId) external onlyManager {
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    /// @inheritdoc INAVManager
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IValuation valuation) external onlyManager {
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
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
        // TODO: how to handle when one of the accounts is not positive
        (, uint128 equity) = accounting.accountValue(poolId, equityAccount(centrifugeId));
        (, uint128 gain) = accounting.accountValue(poolId, gainAccount(centrifugeId));
        (, uint128 loss) = accounting.accountValue(poolId, lossAccount(centrifugeId));
        (, uint128 liability) = accounting.accountValue(poolId, liabilityAccount(centrifugeId));

        console2.log("Equity", equity);
        console2.log("Gain", gain);
        console2.log("Loss", loss);
        console2.log("Liability", liability);
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
}

contract NavManagerFactory is INAVManagerFactory {
    address public immutable contractUpdater;
    IHub public immutable hub;

    constructor(address contractUpdater_, IHub hub_) {
        contractUpdater = contractUpdater_;
        hub = hub_;
    }

    /// @inheritdoc INAVManagerFactory
    function newManager(PoolId poolId) external returns (INAVManager) {
        require(hub.hubRegistry().exists(poolId), InvalidPoolId());

        NAVManager manager = new NAVManager{salt: bytes32(uint256(poolId.raw()))}(poolId, hub, contractUpdater);

        emit DeployNavManager(poolId, address(manager));
        return INAVManager(manager);
    }
}
