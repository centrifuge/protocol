// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVManager, INAVHook, NAVAccount} from "./interfaces/INAVManager.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHoldings} from "../../core/hub/interfaces/IHoldings.sol";
import {IValuation} from "../../core/hub/interfaces/IValuation.sol";
import {IHub, AccountKind} from "../../core/hub/interfaces/IHub.sol";
import {ISnapshotHook} from "../../core/hub/interfaces/ISnapshotHook.sol";
import {IAccounting, JournalEntry} from "../../core/hub/interfaces/IAccounting.sol";
import {AccountId, withCentrifugeId, withAssetId} from "../../core/types/AccountId.sol";
import {IManagerCallFromHub, IManagerCallFromSpoke} from "../../core/utils/interfaces/IManagerCall.sol";

/// @dev Assumes all assets in a pool are shared across all share classes, not segregated.
contract NAVManager is INAVManager {
    IHub public immutable hub;
    address public immutable envoy;
    IHoldings public immutable holdings;
    IAccounting public immutable accounting;

    mapping(PoolId => INAVHook) public navHook;
    mapping(PoolId => IValuation) public defaultValuation;
    mapping(PoolId => mapping(uint16 centrifugeId => bool)) public initialized;
    mapping(PoolId => mapping(uint16 centrifugeId => mapping(bytes32 => bool))) public manager;

    constructor(IHub hub_, address envoy_) {
        hub = hub_;
        holdings = hub.holdings();
        accounting = hub.accounting();
        envoy = envoy_;
    }

    //----------------------------------------------------------------------------------------------
    // Manager call
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        ManagerCall kind = ManagerCall(abi.decode(payload, (uint8)));
        if (kind == ManagerCall.SetNavHook) {
            (, address navHook_) = abi.decode(payload, (uint8, address));
            navHook[poolId] = INAVHook(navHook_);
            emit SetNavHook(poolId, navHook_);
        } else if (kind == ManagerCall.InitializeNetwork) {
            (, uint16 centrifugeId) = abi.decode(payload, (uint8, uint16));
            _initializeNetwork(poolId, centrifugeId);
        } else if (kind == ManagerCall.InitializeHolding) {
            (, ShareClassId scId, AssetId assetId) = abi.decode(payload, (uint8, ShareClassId, AssetId));
            _initializeHolding(poolId, scId, assetId);
        } else if (kind == ManagerCall.InitializeLiability) {
            (, ShareClassId scId, AssetId assetId) = abi.decode(payload, (uint8, ShareClassId, AssetId));
            _initializeLiability(poolId, scId, assetId);
        } else if (kind == ManagerCall.UpdateHoldingValuation) {
            (, ShareClassId scId, AssetId assetId, address valuation) =
                abi.decode(payload, (uint8, ShareClassId, AssetId, address));
            _updateHoldingValuation(poolId, scId, assetId, IValuation(valuation));
        } else if (kind == ManagerCall.UpdateManager) {
            (, uint16 centrifugeId, bytes32 who, bool canManage) = abi.decode(payload, (uint8, uint16, bytes32, bool));
            manager[poolId][centrifugeId][who] = canManage;
            emit UpdateManager(poolId, centrifugeId, who, canManage);
        } else if (kind == ManagerCall.SetDefaultValuation) {
            (, address valuation) = abi.decode(payload, (uint8, address));
            defaultValuation[poolId] = IValuation(valuation);
            emit SetDefaultValuation(poolId, IValuation(valuation));
        } else if (kind == ManagerCall.SetAccountMetadata) {
            (, AccountId account, bytes memory metadata) = abi.decode(payload, (uint8, AccountId, bytes));
            hub.setAccountMetadata(poolId, account, metadata);
            emit SetAccountMetadata(poolId, account, metadata);
        } else {
            (, uint16 centrifugeId) = abi.decode(payload, (uint8, uint16));
            _closeGainLoss(poolId, centrifugeId);
        }
    }

    /// @inheritdoc IManagerCallFromSpoke
    /// @dev Spoke-side holding/liability init, reached via the permissionless `spoke.managerCall`, so the
    ///      origin `sender` is checked against the per-pool `manager` allowlist (set hub-side via `fromHub`).
    ///      The target asset must reside on the origin network, so a spoke manager only reaches its own
    ///      network's accounts; cross-network init goes through `fromHub`.
    ///      The downstream `hub.initializeHolding` is still policy-supervised. Other actions stay hub-only.
    function fromSpoke(PoolId poolId, bytes calldata payload, uint16 centrifugeId, bytes32 sender) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());
        require(manager[poolId][centrifugeId][sender], NotManager());

        ManagerCall kind = ManagerCall(abi.decode(payload, (uint8)));
        if (kind == ManagerCall.InitializeHolding) {
            (, ShareClassId scId, AssetId assetId) = abi.decode(payload, (uint8, ShareClassId, AssetId));
            require(assetId.centrifugeId() == centrifugeId, NetworkMismatch());
            _initializeHolding(poolId, scId, assetId);
        } else if (kind == ManagerCall.InitializeLiability) {
            (, ShareClassId scId, AssetId assetId) = abi.decode(payload, (uint8, ShareClassId, AssetId));
            require(assetId.centrifugeId() == centrifugeId, NetworkMismatch());
            _initializeLiability(poolId, scId, assetId);
        } else {
            revert UnsupportedSpokeCall();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    function _initializeNetwork(PoolId poolId, uint16 centrifugeId) internal {
        require(!initialized[poolId][centrifugeId], AlreadyInitialized());

        hub.createAccount(poolId, equityAccount(centrifugeId), false);
        hub.createAccount(poolId, liabilityAccount(centrifugeId), false);
        hub.createAccount(poolId, gainAccount(centrifugeId), false);
        hub.createAccount(poolId, lossAccount(centrifugeId), true);

        initialized[poolId][centrifugeId] = true;

        emit InitializeNetwork(poolId, centrifugeId);
    }

    function _initializeHolding(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        uint16 centrifugeId = assetId.centrifugeId();
        _createHolding(
            poolId,
            scId,
            assetId,
            _accounts(
                assetAccount(assetId), equityAccount(centrifugeId), gainAccount(centrifugeId), lossAccount(centrifugeId)
            )
        );
        emit InitializeHolding(poolId, scId, assetId);
    }

    function _initializeLiability(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        // A liability has no gain/loss, so it reuses its single account for the credit and both value slots.
        AccountId liability = liabilityAccount(assetId.centrifugeId());
        _createHolding(poolId, scId, assetId, _accounts(expenseAccount(assetId), liability, liability, liability));
        emit InitializeLiability(poolId, scId, assetId);
    }

    /// @dev Creates only `accounts[0]`, the per-asset debit account; the other slots are per-network
    ///      accounts already created in `_initializeNetwork` and reused across holdings.
    ///      Keyed by asset alone, so a second share class over the same asset reuses the account instead of
    ///      reverting `AccountExists`, and both holdings debit the one account that keeps pool-wide NAV whole.
    ///      Reuse is gated on debit-normal, so a credit-normal account is never adopted.
    function _createHolding(PoolId poolId, ShareClassId scId, AssetId assetId, AccountId[4] memory accounts) private {
        require(initialized[poolId][assetId.centrifugeId()], NotInitialized());

        IValuation valuation = defaultValuation[poolId];
        require(address(valuation) != address(0), ValuationNotSet());

        if (!accounting.exists(poolId, accounts[0])) {
            hub.createAccount(poolId, accounts[0], true);
        } else {
            (,, bool isDebitNormal,,) = accounting.accounts(poolId, accounts[0]);
            require(isDebitNormal, NotDebitNormalAccount());
        }

        hub.initializeHolding(poolId, scId, assetId, valuation, accounts);
    }

    //----------------------------------------------------------------------------------------------
    // ISnapshotHook updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ISnapshotHook
    function onSync(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external {
        require(msg.sender == address(holdings), NotAuthorized());

        // While the pool-network carries any deficit its NAV misstates the holdings, so skip silently (never
        // reverting) and resume once it clears. The rollup gates, not the share class-network count, because
        // `netAssetValue` reads accounts every share class on the network shares. Only this network's slice is
        // held, not the pool's price: other networks keep publishing. Gate precedes the `navHook` check.
        uint32 networkDeficitCount = holdings.networkDeficitCount(poolId, centrifugeId);
        if (networkDeficitCount != 0) {
            // Both counts, so the skip is attributable: the share class-network count says whether this share
            // class is itself misstated or is only held by a sibling's deficit.
            emit SkipSync(
                poolId, scId, centrifugeId, holdings.deficitCount(poolId, scId, centrifugeId), networkDeficitCount
            );
            return;
        }

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
    ) external {
        require(msg.sender == address(holdings), NotAuthorized());
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

    function _updateHoldingValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation) internal {
        hub.updateHoldingValuation(poolId, scId, assetId, valuation);
        hub.updateHoldingValue(poolId, scId, assetId);
    }

    function _closeGainLoss(PoolId poolId, uint16 centrifugeId) internal {
        require(initialized[poolId][centrifugeId], NotInitialized());

        AccountId equityAccount_ = equityAccount(centrifugeId);
        AccountId gainAccount_ = gainAccount(centrifugeId);
        AccountId lossAccount_ = lossAccount(centrifugeId);

        (bool gainIsPositive, uint128 gainValue) = accounting.accountValue(poolId, gainAccount_);
        (bool lossIsPositive, uint128 lossValue) = accounting.accountValue(poolId, lossAccount_);

        // Gain and loss accounts should never be negative
        require(gainIsPositive && lossIsPositive, InvalidStateOfAccounts());

        uint256 count = (gainValue > 0 ? 1 : 0) + (lossValue > 0 ? 1 : 0);
        if (count == 0) return;

        uint256 index = 0;
        JournalEntry[] memory debits = new JournalEntry[](count);
        JournalEntry[] memory credits = new JournalEntry[](count);

        if (gainValue > 0) {
            debits[index] = JournalEntry({value: gainValue, accountId: gainAccount_});
            credits[index] = JournalEntry({value: gainValue, accountId: equityAccount_});
            index++;
        }

        if (lossValue > 0) {
            debits[index] = JournalEntry({value: lossValue, accountId: equityAccount_});
            credits[index] = JournalEntry({value: lossValue, accountId: lossAccount_});
        }

        hub.updateJournal(poolId, debits, credits);
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

        uint128 totalPositive = 0;
        uint128 totalNegative = 0;

        // Compute NAV = equity + gain - loss - liability

        // Equity: normally positive, if negative flip to negative side
        if (equityIsPositive) totalPositive += equity;
        else totalNegative += equity;

        // Gain: normally positive, if negative flip to negative side
        if (gainIsPositive) totalPositive += gain;
        else totalNegative += gain;

        // Loss: normally negative, if positive flip to positive side
        if (lossIsPositive) totalNegative += loss;
        else totalPositive += loss;

        // Liability: normally negative, if positive flip to positive side
        if (liabilityIsPositive) totalNegative += liability;
        else totalPositive += liability;

        if (totalNegative >= totalPositive) return 0;

        return totalPositive - totalNegative;
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc INAVManager
    function assetAccount(AssetId assetId) public pure returns (AccountId) {
        return withAssetId(assetId, uint16(NAVAccount.Asset));
    }

    /// @inheritdoc INAVManager
    function expenseAccount(AssetId assetId) public pure returns (AccountId) {
        return withAssetId(assetId, uint16(NAVAccount.Expense));
    }

    /// @inheritdoc INAVManager
    function equityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(NAVAccount.Equity));
    }

    /// @inheritdoc INAVManager
    function liabilityAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(NAVAccount.Liability));
    }

    /// @inheritdoc INAVManager
    function gainAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(NAVAccount.Gain));
    }

    /// @inheritdoc INAVManager
    function lossAccount(uint16 centrifugeId) public pure returns (AccountId) {
        return withCentrifugeId(centrifugeId, uint16(NAVAccount.Loss));
    }

    /// @dev Assembles the four settlement slots in AccountKind order (debit, credit, value increase, value decrease).
    function _accounts(AccountId debit, AccountId credit, AccountId valueIncrease, AccountId valueDecrease)
        private
        pure
        returns (AccountId[4] memory accounts)
    {
        accounts[0] = debit;
        accounts[1] = credit;
        accounts[2] = valueIncrease;
        accounts[3] = valueDecrease;
    }
}
