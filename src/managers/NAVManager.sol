// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId, withCentrifugeId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {ISnapshotHook} from "src/common/interfaces/ISnapshotHook.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

struct NetworkMetrics {
    D18 netAssetValue;
    uint128 issuance;
}

contract NAVManager is Auth, ISnapshotHook {
    error InvalidShareClassCount();
    error AlreadyInitialized();
    error NotInitialized();
    error ExceedsMaxAccounts();

    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    IHub public immutable hub;
    address public immutable holdings;
    IAccounting public immutable accounting;
    IShareClassManager public immutable shareClassManager;

    uint128 public globalIssuance;
    D18 public globalNetAssetValue;
    mapping(uint16 centrifugeId => uint16) public accountCounter;
    mapping(uint16 centrifugeId => NetworkMetrics) public metrics;

    constructor(PoolId poolId_, ShareClassId scId_, IHub hub_, address holdings_, address deployer) Auth(deployer) {
        require(hub.shareClassManager().shareClassCount(poolId_) == 1, InvalidShareClassCount());

        poolId = poolId_;
        scId = scId_;
        hub = hub_;
        holdings = holdings_;
        accounting = hub.accounting();
        shareClassManager = hub.shareClassManager();
    }

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    function initializeNetwork(uint16 centrifugeId) external auth {
        require(accountCounter[centrifugeId] == 0, AlreadyInitialized());

        hub.createAccount(poolId, equityAccount(centrifugeId), false);
        hub.createAccount(poolId, liabilityAccount(centrifugeId), false);
        hub.createAccount(poolId, gainAccount(centrifugeId), false);
        hub.createAccount(poolId, lossAccount(centrifugeId), false);

        accountCounter[centrifugeId] = 5;
    }

    function initializeHolding(AssetId assetId, IValuation valuation) external auth {
        uint16 centrifugeId = assetId.centrifugeId();
        uint16 index = accountCounter[centrifugeId];
        require(index > 0, NotInitialized());
        require(index < type(uint16).max, ExceedsMaxAccounts());

        AccountId assetAccount = withCentrifugeId(centrifugeId, index);
        hub.createAccount(poolId, assetAccount, true);
        hub.initializeHolding(
            poolId,
            scId,
            assetId,
            valuation,
            assetAccount,
            equityAccount(centrifugeId),
            gainAccount(centrifugeId),
            lossAccount(centrifugeId)
        );

        accountCounter[centrifugeId] = index + 1;
    }

    function initializeLiability(AssetId assetId, IValuation valuation) external auth {
        uint16 centrifugeId = assetId.centrifugeId();
        uint16 index = accountCounter[centrifugeId];
        require(index > 0, NotInitialized());
        require(index < type(uint16).max, ExceedsMaxAccounts());

        AccountId expenseAccount = withCentrifugeId(centrifugeId, index);
        hub.createAccount(poolId, expenseAccount, true);
        hub.initializeLiability(poolId, scId, assetId, valuation, expenseAccount, liabilityAccount(centrifugeId));

        accountCounter[centrifugeId] = index + 1;
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotHook
    function onSync(PoolId poolId_, ShareClassId scId_, uint16 centrifugeId) external {
        require(poolId == poolId_ && scId == scId_);
        require(msg.sender == holdings, NotAuthorized());

        NetworkMetrics storage networkMetrics = metrics[centrifugeId];
        D18 netAssetValue_ = netAssetValue(centrifugeId);
        uint128 issuance = shareClassManager.issuance(scId, centrifugeId);

        globalIssuance = globalIssuance + issuance - networkMetrics.issuance;
        globalNetAssetValue = globalNetAssetValue + netAssetValue_ - networkMetrics.netAssetValue;
        D18 price = globalNetAssetValue / d18(globalIssuance);

        networkMetrics.netAssetValue = netAssetValue_;
        networkMetrics.issuance = issuance;

        hub.updateSharePrice(poolId, scId, price);
    }

    function updateHoldingValue(AssetId assetId) external {
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

    function navPoolPerShare() public view returns (D18) {
        return globalNetAssetValue / d18(globalIssuance);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function equityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return equityAccount(centrifugeId);
    }

    function liabilityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return liabilityAccount(centrifugeId);
    }

    function gainAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return gainAccount(centrifugeId);
    }

    function lossAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return lossAccount(centrifugeId);
    }
}
