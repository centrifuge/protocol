// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockHub {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of addShareClass
    function addShareClass(uint64 poolId, string memory name, string memory symbol, bytes32 salt) public {}

    // Mock implementation of cancelDepositRequest
    function cancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 depositAssetId) public {}

    // Mock implementation of cancelRedeemRequest
    function cancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 payoutAssetId) public {}

    // Mock implementation of createAccount
    function createAccount(uint64 poolId, uint32 account, bool isDebitNormal) public {}

    // Mock implementation of createHolding
    function createHolding(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address valuation,
        uint32 assetAccount,
        uint32 equityAccount,
        uint32 lossAccount,
        uint32 gainAccount
    ) public {}

    // Mock implementation of createLiability
    function createLiability(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address valuation,
        uint32 expenseAccount,
        uint32 liabilityAccount
    ) public {}

    // Mock implementation of createPool
    function createPool(uint64 poolId, address admin, uint128 currency) public {}

    // Mock implementation of decreaseShareIssuance
    function decreaseShareIssuance(uint64 poolId, bytes16 scId, uint128 amount) public {}

    // Mock implementation of deny
    function deny(address user) public {}

    // Mock implementation of depositRequest
    function depositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 depositAssetId, uint128 amount)
        public
    {}

    // Mock implementation of file
    function file(bytes32 what, address data) public {}

    // Mock implementation of increaseShareIssuance
    function increaseShareIssuance(uint64 poolId, bytes16 scId, uint128 amount) public {}

    // Mock implementation of multicall
    function multicall(bytes[] memory data) public {}

    // Mock implementation of notifyAssetPrice
    function notifyAssetPrice(uint64 poolId, bytes16 scId, uint128 assetId) public {}

    // Mock implementation of notifyDeposit
    function notifyDeposit(uint64 poolId, bytes16 scId, uint128 assetId, bytes32 investor, uint32 maxClaims) public {}

    // Mock implementation of notifyPool
    function notifyPool(uint64 poolId, uint16 centrifugeId) public {}

    // Mock implementation of notifyRedeem
    function notifyRedeem(uint64 poolId, bytes16 scId, uint128 assetId, bytes32 investor, uint32 maxClaims) public {}

    // Mock implementation of notifyShareClass
    function notifyShareClass(uint64 poolId, bytes16 scId, uint16 centrifugeId, bytes32 hook) public {}

    // Mock implementation of notifyShareMetadata
    function notifyShareMetadata(uint64 poolId, bytes16 scId, uint16 centrifugeId) public {}

    // Mock implementation of notifySharePrice
    function notifySharePrice(uint64 poolId, bytes16 scId, uint16 centrifugeId) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {}

    // Mock implementation of redeemRequest
    function redeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 payoutAssetId, uint128 amount)
        public
    {}

    // Mock implementation of registerAsset
    function registerAsset(uint128 assetId, uint8 decimals) public {}

    // Mock implementation of rely
    function rely(address user) public {}

    // Mock implementation of setAccountMetadata
    function setAccountMetadata(uint64 poolId, uint32 account, bytes memory metadata) public {}

    // Mock implementation of setHoldingAccountId
    function setHoldingAccountId(uint64 poolId, bytes16 scId, uint128 assetId, uint8 kind, uint32 accountId) public {}

    // Mock implementation of setPoolMetadata
    function setPoolMetadata(uint64 poolId, bytes memory metadata) public {}

    // Mock implementation of setQueue
    function setQueue(uint16 centrifugeId, uint64 poolId, bytes16 scId, bool enabled) public {}

    // Mock implementation of triggerIssueShares
    function triggerIssueShares(uint16 centrifugeId, uint64 poolId, bytes16 scId, address who, uint128 shares) public {}

    // Mock implementation of triggerSubmitQueuedAssets
    function triggerSubmitQueuedAssets(uint64 poolId, bytes16 scId, uint128 assetId) public {}

    // Mock implementation of triggerSubmitQueuedShares
    function triggerSubmitQueuedShares(uint16 centrifugeId, uint64 poolId, bytes16 scId) public {}

    // Mock implementation of updateContract
    function updateContract(uint64 poolId, bytes16 scId, uint16 centrifugeId, bytes32 target, bytes memory payload)
        public
    {}

    // Mock implementation of updateHoldingAmount
    function updateHoldingAmount(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 amount,
        uint128 pricePoolPerAsset,
        bool isIncrease
    ) public {}

    // Mock implementation of updateHoldingValuation
    function updateHoldingValuation(uint64 poolId, bytes16 scId, uint128 assetId, address valuation) public {}

    // Mock implementation of updateHoldingValue
    function updateHoldingValue(uint64 poolId, bytes16 scId, uint128 assetId) public {}

    // Mock implementation of updateJournal
    function updateJournal(uint64 poolId, JournalEntry[] memory debits, JournalEntry[] memory credits) public {}

    // Mock implementation of updateManager
    function updateManager(uint64 poolId, address who, bool canManage) public {}

    // Mock implementation of updatePricePerShare
    function updatePricePerShare(uint64 poolId, bytes16 scId, uint128 navPoolPerShare) public {}

    // Mock implementation of updateRestriction
    function updateRestriction(uint64 poolId, bytes16 scId, uint16 centrifugeId, bytes memory payload) public {}

    // Mock implementation of updateShareClassMetadata
    function updateShareClassMetadata(uint64 poolId, bytes16 scId, string memory name, string memory symbol) public {}

    // Mock implementation of updateShareHook
    function updateShareHook(uint64 poolId, bytes16 scId, uint16 centrifugeId, bytes32 hook) public {}

    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for accounting
    function setAccountingReturn(address _value0) public {
        _accountingReturn_0 = _value0;
    }

    // Function to set return values for approveDeposits
    function setApproveDepositsReturn(uint128 _value0, uint128 _value1) public {
        _approveDepositsReturn_0 = _value0;
        _approveDepositsReturn_1 = _value1;
    }

    // Function to set return values for approveRedeems
    function setApproveRedeemsReturn(uint128 _value0) public {
        _approveRedeemsReturn_0 = _value0;
    }

    // Function to set return values for gateway
    function setGatewayReturn(address _value0) public {
        _gatewayReturn_0 = _value0;
    }

    // Function to set return values for holdings
    function setHoldingsReturn(address _value0) public {
        _holdingsReturn_0 = _value0;
    }

    // Function to set return values for hubRegistry
    function setHubRegistryReturn(address _value0) public {
        _hubRegistryReturn_0 = _value0;
    }

    // Function to set return values for issueShares
    function setIssueSharesReturn(uint128 _value0, uint128 _value1, uint128 _value2) public {
        _issueSharesReturn_0 = _value0;
        _issueSharesReturn_1 = _value1;
        _issueSharesReturn_2 = _value2;
    }

    // Function to set return values for revokeShares
    function setRevokeSharesReturn(uint128 _value0, uint128 _value1, uint128 _value2) public {
        _revokeSharesReturn_0 = _value0;
        _revokeSharesReturn_1 = _value1;
        _revokeSharesReturn_2 = _value2;
    }

    // Function to set return values for sender
    function setSenderReturn(address _value0) public {
        _senderReturn_0 = _value0;
    }

    // Function to set return values for shareClassManager
    function setShareClassManagerReturn(address _value0) public {
        _shareClassManagerReturn_0 = _value0;
    }

    // Function to set return values for wards
    function setWardsReturn(uint256 _value0) public {
        _wardsReturn_0 = _value0;
    }

    /**
     *
     *   ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️  *
     * -----------------------------------------------------------------*
     *      Generally you only need to modify the sections above.      *
     *          The code below handles system operations.              *
     *
     */

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  STRUCT DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>
    // Struct definition for JournalEntry
    struct JournalEntry {
        uint128 value;
        uint32 accountId;
    }

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  EVENTS DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>
    event Deny(address user);
    event File(bytes32 what, address addr);
    event NotifyAssetPrice(
        uint16 centrifugeId, uint64 poolId, bytes16 scId, uint128 assetId, uint128 pricePoolPerAsset
    );
    event NotifyPool(uint16 centrifugeId, uint64 poolId);
    event NotifyShareClass(uint16 centrifugeId, uint64 poolId, bytes16 scId);
    event NotifySharePrice(uint16 centrifugeId, uint64 poolId, bytes16 scId, string name, string symbol);
    event NotifySharePrice(uint16 centrifugeId, uint64 poolId, bytes16 scId, uint128 poolPerShare);
    event Rely(address user);
    event UpdateContract(uint16 centrifugeId, uint64 poolId, bytes16 scId, bytes32 target, bytes payload);
    event UpdateRestriction(uint16 centrifugeId, uint64 poolId, bytes16 scId, bytes payload);
    event UpdateShareHook(uint16 centrifugeId, uint64 poolId, bytes16 scId, bytes32 hook);

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    address private _accountingReturn_0;
    uint128 private _approveDepositsReturn_0;
    uint128 private _approveDepositsReturn_1;
    uint128 private _approveRedeemsReturn_0;
    address private _gatewayReturn_0;
    address private _holdingsReturn_0;
    address private _hubRegistryReturn_0;
    uint128 private _issueSharesReturn_0;
    uint128 private _issueSharesReturn_1;
    uint128 private _issueSharesReturn_2;
    uint128 private _revokeSharesReturn_0;
    uint128 private _revokeSharesReturn_1;
    uint128 private _revokeSharesReturn_2;
    address private _senderReturn_0;
    address private _shareClassManagerReturn_0;
    uint256 private _wardsReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of accounting
    function accounting() public view returns (address) {
        return _accountingReturn_0;
    }

    // Mock implementation of approveDeposits
    function approveDeposits(
        uint64 poolId,
        bytes16 scId,
        uint128 depositAssetId,
        uint32 nowDepositEpochId,
        uint128 approvedAssetAmount
    ) public view returns (uint128, uint128) {
        return (_approveDepositsReturn_0, _approveDepositsReturn_1);
    }

    // Mock implementation of approveRedeems
    function approveRedeems(
        uint64 poolId,
        bytes16 scId,
        uint128 payoutAssetId,
        uint32 nowRedeemEpochId,
        uint128 approvedShareAmount
    ) public view returns (uint128) {
        return _approveRedeemsReturn_0;
    }

    // Mock implementation of gateway
    function gateway() public view returns (address) {
        return _gatewayReturn_0;
    }

    // Mock implementation of holdings
    function holdings() public view returns (address) {
        return _holdingsReturn_0;
    }

    // Mock implementation of hubRegistry
    function hubRegistry() public view returns (address) {
        return _hubRegistryReturn_0;
    }

    // Mock implementation of issueShares
    function issueShares(
        uint64 poolId,
        bytes16 scId,
        uint128 depositAssetId,
        uint32 nowIssueEpochId,
        uint128 navPoolPerShare
    ) public view returns (uint128, uint128, uint128) {
        return (_issueSharesReturn_0, _issueSharesReturn_1, _issueSharesReturn_2);
    }

    // Mock implementation of revokeShares
    function revokeShares(
        uint64 poolId,
        bytes16 scId,
        uint128 payoutAssetId,
        uint32 nowRevokeEpochId,
        uint128 navPoolPerShare
    ) public view returns (uint128, uint128, uint128) {
        return (_revokeSharesReturn_0, _revokeSharesReturn_1, _revokeSharesReturn_2);
    }

    // Mock implementation of sender
    function sender() public view returns (address) {
        return _senderReturn_0;
    }

    // Mock implementation of shareClassManager
    function shareClassManager() public view returns (address) {
        return _shareClassManagerReturn_0;
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }
}
