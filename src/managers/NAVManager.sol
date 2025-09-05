// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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
    error AlreadyInitialized();
    error NotInitialized();
    error ExceedsMaxAccounts();
    error InvalidNAVHook();

    PoolId public immutable poolId;

    IHub public immutable hub;
    address public immutable holdings;
    IAccounting public immutable accounting;

    INAVHook public navHook;
    mapping(uint16 centrifugeId => uint16) public accountCounter;
    mapping(uint16 centrifugeId => mapping(AssetId => AccountId)) public assetIdToAccountId;

    constructor(PoolId poolId_, IHub hub_, address deployer) Auth(deployer) {
        poolId = poolId_;

        hub = hub_;
        holdings = address(hub.holdings());
        accounting = hub.accounting();
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function setNAVHook(INAVHook navHook_) external auth {
        navHook = navHook_;
    }

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    function initializeNetwork(uint16 centrifugeId) external {
        // TODO AUTH
        // require(hubRegistry.manager(poolId, msg.sender), NotHubManager());

        require(accountCounter[centrifugeId] == 0, AlreadyInitialized());

        hub.createAccount(poolId, equityAccount(centrifugeId), false);
        hub.createAccount(poolId, liabilityAccount(centrifugeId), false);
        hub.createAccount(poolId, gainAccount(centrifugeId), false);
        hub.createAccount(poolId, lossAccount(centrifugeId), false);

        accountCounter[centrifugeId] = 5;
    }

    function initializeHolding(ShareClassId scId, AssetId assetId, IValuation valuation) external {
        // TODO AUTH
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
    }

    function initializeLiability(ShareClassId scId, AssetId assetId, IValuation valuation) external {
        // TODO AUTH
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
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotHook
    function onSync(PoolId poolId_, ShareClassId scId, uint16 centrifugeId) external {
        require(poolId == poolId_);
        require(msg.sender == holdings, NotAuthorized());
        require(address(navHook) != address(0), InvalidNAVHook());

        D18 netAssetValue_ = netAssetValue(centrifugeId);
        navHook.onUpdate(poolId, scId, centrifugeId, netAssetValue_);
    }

    function onTransfer(PoolId poolId_, ShareClassId scId_, uint16 fromCentrifugeId, uint16 toCentrifugeId) external {
        // TODO
    }

    function updateHoldingValue(ShareClassId scId, AssetId assetId) external {
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    // TODO: setHoldingAccountId, updateHoldingValuation
    // TODO: realize gain/loss to move to equity account

    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @dev NAV = equity + gain - loss - liability
    function netAssetValue(uint16 centrifugeId) public view returns (D18) {
        // TODO: how to handle when one of the accounts is not positive
        (, uint128 equity) = accounting.accountValue(poolId, equityAccount(centrifugeId));
        (, uint128 gain) = accounting.accountValue(poolId, gainAccount(centrifugeId));
        (, uint128 loss) = accounting.accountValue(poolId, lossAccount(centrifugeId));
        (, uint128 liability) = accounting.accountValue(poolId, liabilityAccount(centrifugeId));
        return d18(equity) + d18(gain) - d18(loss) - d18(liability);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function assetAccount(uint16 centrifugeId, AssetId assetId) public view returns (AccountId) {
        return assetIdToAccountId[centrifugeId][assetId];
    }

    function expenseAccount(uint16 centrifugeId, AssetId assetId) public view returns (AccountId) {
        return assetAccount(centrifugeId, assetId);
    }

    function equityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 1);
    }

    function liabilityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 2);
    }

    function gainAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, 3);
    }

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
