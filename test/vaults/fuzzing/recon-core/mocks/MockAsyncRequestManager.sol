// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockAsyncRequestManager {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of addVault
    function addVault(uint64 poolId, bytes16 scId, address vault_, address asset_, uint128 assetId) public {}

    // Mock implementation of approvedDeposits
    function approvedDeposits(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assetAmount,
        uint128 pricePoolPerAsset
    ) public {}

    // Mock implementation of cancelDepositRequest
    function cancelDepositRequest(address vault_, address controller, address arg2) public {}

    // Mock implementation of cancelRedeemRequest
    function cancelRedeemRequest(address vault_, address controller, address arg2) public {}

    // Mock implementation of deny
    function deny(address user) public {}

    // Mock implementation of file
    function file(bytes32 what, address data) public {}

    // Mock implementation of fulfillCancelDepositRequest
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public {}

    // Mock implementation of fulfillCancelRedeemRequest
    function fulfillCancelRedeemRequest(uint64 poolId, bytes16 scId, address user, uint128 assetId, uint128 shares)
        public
    {}

    // Mock implementation of fulfillDepositRequest
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {}

    // Mock implementation of fulfillRedeemRequest
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {}

    // Mock implementation of issuedShares
    function issuedShares(uint64 poolId, bytes16 scId, uint128 shareAmount, uint128 pricePoolPerShare) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {}

    // Mock implementation of rely
    function rely(address user) public {}

    // Mock implementation of removeVault
    function removeVault(uint64 poolId, bytes16 scId, address vault_, address asset_, uint128 assetId) public {}

    // Mock implementation of revokedShares
    function revokedShares(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        uint128 pricePoolPerShare
    ) public {}

    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for balanceSheet
    function setBalanceSheetReturn(address _value0) public {
        _balanceSheetReturn_0 = _value0;
    }

    // Function to set return values for claimCancelDepositRequest
    function setClaimCancelDepositRequestReturn(uint256 _value0) public {
        _claimCancelDepositRequestReturn_0 = _value0;
    }

    // Function to set return values for claimCancelRedeemRequest
    function setClaimCancelRedeemRequestReturn(uint256 _value0) public {
        _claimCancelRedeemRequestReturn_0 = _value0;
    }

    // Function to set return values for claimableCancelDepositRequest
    function setClaimableCancelDepositRequestReturn(uint256 _value0) public {
        _claimableCancelDepositRequestReturn_0 = _value0;
    }

    // Function to set return values for claimableCancelRedeemRequest
    function setClaimableCancelRedeemRequestReturn(uint256 _value0) public {
        _claimableCancelRedeemRequestReturn_0 = _value0;
    }

    // Function to set return values for convertToAssets
    function setConvertToAssetsReturn(uint256 _value0) public {
        _convertToAssetsReturn_0 = _value0;
    }

    // Function to set return values for convertToShares
    function setConvertToSharesReturn(uint256 _value0) public {
        _convertToSharesReturn_0 = _value0;
    }

    // Function to set return values for deposit
    function setDepositReturn(uint256 _value0) public {
        _depositReturn_0 = _value0;
    }

    // Function to set return values for globalEscrow
    function setGlobalEscrowReturn(address _value0) public {
        _globalEscrowReturn_0 = _value0;
    }

    // Function to set return values for investments
    function setInvestmentsReturn(
        uint128 _value0,
        uint128 _value1,
        uint256 _value2,
        uint256 _value3,
        uint128 _value4,
        uint128 _value5,
        uint128 _value6,
        uint128 _value7,
        bool _value8,
        bool _value9
    ) public {
        _investmentsReturn_0 = _value0;
        _investmentsReturn_1 = _value1;
        _investmentsReturn_2 = _value2;
        _investmentsReturn_3 = _value3;
        _investmentsReturn_4 = _value4;
        _investmentsReturn_5 = _value5;
        _investmentsReturn_6 = _value6;
        _investmentsReturn_7 = _value7;
        _investmentsReturn_8 = _value8;
        _investmentsReturn_9 = _value9;
    }

    // Function to set return values for maxDeposit
    function setMaxDepositReturn(uint256 _value0) public {
        _maxDepositReturn_0 = _value0;
    }

    // Function to set return values for maxMint
    function setMaxMintReturn(uint256 _value0) public {
        _maxMintReturn_0 = _value0;
    }

    // Function to set return values for maxRedeem
    function setMaxRedeemReturn(uint256 _value0) public {
        _maxRedeemReturn_0 = _value0;
    }

    // Function to set return values for maxWithdraw
    function setMaxWithdrawReturn(uint256 _value0) public {
        _maxWithdrawReturn_0 = _value0;
    }

    // Function to set return values for mint
    function setMintReturn(uint256 _value0) public {
        _mintReturn_0 = _value0;
    }

    // Function to set return values for pendingCancelDepositRequest
    function setPendingCancelDepositRequestReturn(bool _value0) public {
        _pendingCancelDepositRequestReturn_0 = _value0;
    }

    // Function to set return values for pendingCancelRedeemRequest
    function setPendingCancelRedeemRequestReturn(bool _value0) public {
        _pendingCancelRedeemRequestReturn_0 = _value0;
    }

    // Function to set return values for pendingDepositRequest
    function setPendingDepositRequestReturn(uint256 _value0) public {
        _pendingDepositRequestReturn_0 = _value0;
    }

    // Function to set return values for pendingRedeemRequest
    function setPendingRedeemRequestReturn(uint256 _value0) public {
        _pendingRedeemRequestReturn_0 = _value0;
    }

    // Function to set return values for poolEscrow
    function setPoolEscrowReturn(address _value0) public {
        _poolEscrowReturn_0 = _value0;
    }

    // Function to set return values for poolEscrowProvider
    function setPoolEscrowProviderReturn(address _value0) public {
        _poolEscrowProviderReturn_0 = _value0;
    }

    // Function to set return values for spoke
    function setPoolManagerReturn(address _value0) public {
        _poolManagerReturn_0 = _value0;
    }

    // Function to set return values for priceLastUpdated
    function setPriceLastUpdatedReturn(uint64 _value0) public {
        _priceLastUpdatedReturn_0 = _value0;
    }

    // Function to set return values for redeem
    function setRedeemReturn(uint256 _value0) public {
        _redeemReturn_0 = _value0;
    }

    // Function to set return values for requestDeposit
    function setRequestDepositReturn(bool _value0) public {
        _requestDepositReturn_0 = _value0;
    }

    // Function to set return values for requestRedeem
    function setRequestRedeemReturn(bool _value0) public {
        _requestRedeemReturn_0 = _value0;
    }

    // Function to set return values for root
    function setRootReturn(address _value0) public {
        _rootReturn_0 = _value0;
    }

    // Function to set return values for sender
    function setSenderReturn(address _value0) public {
        _senderReturn_0 = _value0;
    }

    // Function to set return values for vault
    function setVaultReturn(address _value0) public {
        _vaultReturn_0 = _value0;
    }

    // Function to set return values for vaultByAssetId
    function setVaultByAssetIdReturn(address _value0) public {
        _vaultByAssetIdReturn_0 = _value0;
    }

    // Function to set return values for vaultKind
    function setVaultKindReturn(uint8 _value0, address _value1) public {
        _vaultKindReturn_0 = _value0;
        _vaultKindReturn_1 = _value1;
    }

    // Function to set return values for wards
    function setWardsReturn(uint256 _value0) public {
        _wardsReturn_0 = _value0;
    }

    // Function to set return values for withdraw
    function setWithdrawReturn(uint256 _value0) public {
        _withdrawReturn_0 = _value0;
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

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  EVENTS DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>
    event Deny(address user);
    event File(bytes32 what, address data);
    event Rely(address user);
    event TriggerRedeemRequest(
        uint64 poolId, bytes16 scId, address user, address asset, uint256 tokenId, uint128 shares
    );

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    address private _balanceSheetReturn_0;
    uint256 private _claimCancelDepositRequestReturn_0;
    uint256 private _claimCancelRedeemRequestReturn_0;
    uint256 private _claimableCancelDepositRequestReturn_0;
    uint256 private _claimableCancelRedeemRequestReturn_0;
    uint256 private _convertToAssetsReturn_0;
    uint256 private _convertToSharesReturn_0;
    uint256 private _depositReturn_0;
    address private _globalEscrowReturn_0;
    uint128 private _investmentsReturn_0;
    uint128 private _investmentsReturn_1;
    uint256 private _investmentsReturn_2;
    uint256 private _investmentsReturn_3;
    uint128 private _investmentsReturn_4;
    uint128 private _investmentsReturn_5;
    uint128 private _investmentsReturn_6;
    uint128 private _investmentsReturn_7;
    bool private _investmentsReturn_8;
    bool private _investmentsReturn_9;
    uint256 private _maxDepositReturn_0;
    uint256 private _maxMintReturn_0;
    uint256 private _maxRedeemReturn_0;
    uint256 private _maxWithdrawReturn_0;
    uint256 private _mintReturn_0;
    bool private _pendingCancelDepositRequestReturn_0;
    bool private _pendingCancelRedeemRequestReturn_0;
    uint256 private _pendingDepositRequestReturn_0;
    uint256 private _pendingRedeemRequestReturn_0;
    address private _poolEscrowReturn_0;
    address private _poolEscrowProviderReturn_0;
    address private _poolManagerReturn_0;
    uint64 private _priceLastUpdatedReturn_0;
    uint256 private _redeemReturn_0;
    bool private _requestDepositReturn_0;
    bool private _requestRedeemReturn_0;
    address private _rootReturn_0;
    address private _senderReturn_0;
    address private _vaultReturn_0;
    address private _vaultByAssetIdReturn_0;
    uint8 private _vaultKindReturn_0;
    address private _vaultKindReturn_1;
    uint256 private _wardsReturn_0;
    uint256 private _withdrawReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of balanceSheet
    function balanceSheet() public view returns (address) {
        return _balanceSheetReturn_0;
    }

    // Mock implementation of claimCancelDepositRequest
    function claimCancelDepositRequest(address vault_, address receiver, address controller)
        public
        view
        returns (uint256)
    {
        return _claimCancelDepositRequestReturn_0;
    }

    // Mock implementation of claimCancelRedeemRequest
    function claimCancelRedeemRequest(address vault_, address receiver, address controller)
        public
        view
        returns (uint256)
    {
        return _claimCancelRedeemRequestReturn_0;
    }

    // Mock implementation of claimableCancelDepositRequest
    function claimableCancelDepositRequest(address vault_, address user) public view returns (uint256) {
        return _claimableCancelDepositRequestReturn_0;
    }

    // Mock implementation of claimableCancelRedeemRequest
    function claimableCancelRedeemRequest(address vault_, address user) public view returns (uint256) {
        return _claimableCancelRedeemRequestReturn_0;
    }

    // Mock implementation of convertToAssets
    function convertToAssets(address vault_, uint256 shares) public view returns (uint256) {
        return _convertToAssetsReturn_0;
    }

    // Mock implementation of convertToShares
    function convertToShares(address vault_, uint256 assets) public view returns (uint256) {
        return _convertToSharesReturn_0;
    }

    // Mock implementation of deposit
    function deposit(address vault_, uint256 assets, address receiver, address controller)
        public
        view
        returns (uint256)
    {
        return _depositReturn_0;
    }

    // Mock implementation of globalEscrow
    function globalEscrow() public view returns (address) {
        return _globalEscrowReturn_0;
    }

    // Mock implementation of investments
    function investments(address vault, address investor)
        public
        view
        returns (uint128, uint128, uint256, uint256, uint128, uint128, uint128, uint128, bool, bool)
    {
        return (
            _investmentsReturn_0,
            _investmentsReturn_1,
            _investmentsReturn_2,
            _investmentsReturn_3,
            _investmentsReturn_4,
            _investmentsReturn_5,
            _investmentsReturn_6,
            _investmentsReturn_7,
            _investmentsReturn_8,
            _investmentsReturn_9
        );
    }

    // Mock implementation of maxDeposit
    function maxDeposit(address vault_, address user) public view returns (uint256) {
        return _maxDepositReturn_0;
    }

    // Mock implementation of maxMint
    function maxMint(address vault_, address user) public view returns (uint256) {
        return _maxMintReturn_0;
    }

    // Mock implementation of maxRedeem
    function maxRedeem(address vault_, address user) public view returns (uint256) {
        return _maxRedeemReturn_0;
    }

    // Mock implementation of maxWithdraw
    function maxWithdraw(address vault_, address user) public view returns (uint256) {
        return _maxWithdrawReturn_0;
    }

    // Mock implementation of mint
    function mint(address vault_, uint256 shares, address receiver, address controller) public view returns (uint256) {
        return _mintReturn_0;
    }

    // Mock implementation of pendingCancelDepositRequest
    function pendingCancelDepositRequest(address vault_, address user) public view returns (bool) {
        return _pendingCancelDepositRequestReturn_0;
    }

    // Mock implementation of pendingCancelRedeemRequest
    function pendingCancelRedeemRequest(address vault_, address user) public view returns (bool) {
        return _pendingCancelRedeemRequestReturn_0;
    }

    // Mock implementation of pendingDepositRequest
    function pendingDepositRequest(address vault_, address user) public view returns (uint256) {
        return _pendingDepositRequestReturn_0;
    }

    // Mock implementation of pendingRedeemRequest
    function pendingRedeemRequest(address vault_, address user) public view returns (uint256) {
        return _pendingRedeemRequestReturn_0;
    }

    // Mock implementation of poolEscrow
    function poolEscrow(uint64 poolId) public view returns (address) {
        return _poolEscrowReturn_0;
    }

    // Mock implementation of poolEscrowProvider
    function poolEscrowProvider() public view returns (address) {
        return _poolEscrowProviderReturn_0;
    }

    // Mock implementation of spoke
    function spoke() public view returns (address) {
        return _poolManagerReturn_0;
    }

    // Mock implementation of priceLastUpdated
    function priceLastUpdated(address vault_) public view returns (uint64) {
        return _priceLastUpdatedReturn_0;
    }

    // Mock implementation of redeem
    function redeem(address vault_, uint256 shares, address receiver, address controller)
        public
        view
        returns (uint256)
    {
        return _redeemReturn_0;
    }

    // Mock implementation of requestDeposit
    function requestDeposit(address vault_, uint256 assets, address controller, address arg3, address arg4)
        public
        view
        returns (bool)
    {
        return _requestDepositReturn_0;
    }

    // Mock implementation of requestRedeem
    function requestRedeem(address vault_, uint256 shares, address controller, address owner, address arg4)
        public
        view
        returns (bool)
    {
        return _requestRedeemReturn_0;
    }

    // Mock implementation of root
    function root() public view returns (address) {
        return _rootReturn_0;
    }

    // Mock implementation of sender
    function sender() public view returns (address) {
        return _senderReturn_0;
    }

    // Mock implementation of vault
    function vault(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (address) {
        return _vaultReturn_0;
    }

    // Mock implementation of vaultByAssetId
    function vaultByAssetId(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (address) {
        return _vaultByAssetIdReturn_0;
    }

    // Mock implementation of vaultKind
    function vaultKind(address arg0) public view returns (uint8, address) {
        return (_vaultKindReturn_0, _vaultKindReturn_1);
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }

    // Mock implementation of withdraw
    function withdraw(address vault_, uint256 assets, address receiver, address controller)
        public
        view
        returns (uint256)
    {
        return _withdrawReturn_0;
    }
}
