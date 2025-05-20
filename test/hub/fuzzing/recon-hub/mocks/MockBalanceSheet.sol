// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockBalanceSheet {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of deny
    function deny(address user) public {
        
    }

    // Mock implementation of deposit
    function deposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address owner, uint128 amount) public {
        
    }

    // Mock implementation of file
    function file(bytes32 what, address data) public {
        
    }

    // Mock implementation of issue
    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares) public {
        
    }

    // Mock implementation of noteDeposit
    function noteDeposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address owner, uint128 amount) public {
        
    }

    // Mock implementation of noteRevoke
    function noteRevoke(uint64 poolId, bytes16 scId, address from, uint128 shares) public {
        
    }

    // Mock implementation of overridePricePoolPerAsset
    function overridePricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, uint128 value) public {
        
    }

    // Mock implementation of overridePricePoolPerShare
    function overridePricePoolPerShare(uint64 poolId, bytes16 scId, uint128 value) public {
        
    }

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {
        
    }

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {
        
    }

    // Mock implementation of rely
    function rely(address user) public {
        
    }

    // Mock implementation of revoke
    function revoke(uint64 poolId, bytes16 scId, address from, uint128 shares) public {
        
    }

    // Mock implementation of setQueue
    function setQueue(uint64 poolId, bytes16 scId, bool enabled) public {
        
    }

    // Mock implementation of submitQueuedAssets
    function submitQueuedAssets(uint64 poolId, bytes16 scId, uint128 assetId) public {
        
    }

    // Mock implementation of submitQueuedShares
    function submitQueuedShares(uint64 poolId, bytes16 scId) public {
        
    }

    // Mock implementation of transferSharesFrom
    function transferSharesFrom(uint64 poolId, bytes16 scId, address from, address to, uint256 amount) public {
        
    }

    // Mock implementation of triggerDeposit
    function triggerDeposit(uint64 poolId, bytes16 scId, uint128 assetId, address owner, uint128 amount) public {
        
    }

    // Mock implementation of triggerIssueShares
    function triggerIssueShares(uint64 poolId, bytes16 scId, address receiver, uint128 shares) public {
        
    }

    // Mock implementation of triggerWithdraw
    function triggerWithdraw(uint64 poolId, bytes16 scId, uint128 assetId, address receiver, uint128 amount) public {
        
    }

    // Mock implementation of update
    function update(uint64 poolId, bytes16 arg1, bytes memory payload) public {
        
    }

    // Mock implementation of withdraw
    function withdraw(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address receiver, uint128 amount) public {
        
    }


    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for gateway
    function setGatewayReturn(address _value0) public {
        _gatewayReturn_0 = _value0;
    }

    // Function to set return values for manager
    function setManagerReturn(bool _value0) public {
        _managerReturn_0 = _value0;
    }

    // Function to set return values for poolEscrowProvider
    function setPoolEscrowProviderReturn(address _value0) public {
        _poolEscrowProviderReturn_0 = _value0;
    }

    // Function to set return values for spoke
    function setPoolManagerReturn(address _value0) public {
        _poolManagerReturn_0 = _value0;
    }

    // Function to set return values for queueEnabled
    function setQueueEnabledReturn(bool _value0) public {
        _queueEnabledReturn_0 = _value0;
    }

    // Function to set return values for queuedAssets
    function setQueuedAssetsReturn(uint128 _value0, uint128 _value1) public {
        _queuedAssetsReturn_0 = _value0;
        _queuedAssetsReturn_1 = _value1;
    }

    // Function to set return values for queuedShares
    function setQueuedSharesReturn(uint128 _value0, uint128 _value1) public {
        _queuedSharesReturn_0 = _value0;
        _queuedSharesReturn_1 = _value1;
    }

    // Function to set return values for root
    function setRootReturn(address _value0) public {
        _rootReturn_0 = _value0;
    }

    // Function to set return values for sender
    function setSenderReturn(address _value0) public {
        _senderReturn_0 = _value0;
    }

    // Function to set return values for wards
    function setWardsReturn(uint256 _value0) public {
        _wardsReturn_0 = _value0;
    }


    /*******************************************************************
     *   ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️ WARNING ⚠️  *
     *-----------------------------------------------------------------*
     *      Generally you only need to modify the sections above.      *
     *          The code below handles system operations.              *
     *******************************************************************/

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
    event Deposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address provider, uint128 amount, uint128 pricePoolPerAsset);
    event File(bytes32 what, address data);
    event Issue(uint64 poolId, bytes16 scId, address to, uint128 pricePoolPerShare, uint128 shares);
    event Rely(address user);
    event Revoke(uint64 poolId, bytes16 scId, address from, uint128 pricePoolPerShare, uint128 shares);
    event UpdateManager(uint64 poolId, address who, bool canManage);
    event Withdraw(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address receiver, uint128 amount, uint128 pricePoolPerAsset);

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    address private _gatewayReturn_0;
    bool private _managerReturn_0;
    address private _poolEscrowProviderReturn_0;
    address private _poolManagerReturn_0;
    bool private _queueEnabledReturn_0;
    uint128 private _queuedAssetsReturn_0;
    uint128 private _queuedAssetsReturn_1;
    uint128 private _queuedSharesReturn_0;
    uint128 private _queuedSharesReturn_1;
    address private _rootReturn_0;
    address private _senderReturn_0;
    uint256 private _wardsReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of gateway
    function gateway() public view returns (address) {
        return _gatewayReturn_0;
    }

    // Mock implementation of manager
    function manager(uint64 arg0, address arg1) public view returns (bool) {
        return _managerReturn_0;
    }

    // Mock implementation of poolEscrowProvider
    function poolEscrowProvider() public view returns (address) {
        return _poolEscrowProviderReturn_0;
    }

    // Mock implementation of spoke
    function spoke() public view returns (address) {
        return _poolManagerReturn_0;
    }

    // Mock implementation of queueEnabled
    function queueEnabled(uint64 poolId, bytes16 scId) public view returns (bool) {
        return _queueEnabledReturn_0;
    }

    // Mock implementation of queuedAssets
    function queuedAssets(uint64 poolId, bytes16 scId, uint128 assetId) public view returns (uint128, uint128) {
        return (_queuedAssetsReturn_0, _queuedAssetsReturn_1);
    }

    // Mock implementation of queuedShares
    function queuedShares(uint64 poolId, bytes16 scId) public view returns (uint128, uint128) {
        return (_queuedSharesReturn_0, _queuedSharesReturn_1);
    }

    // Mock implementation of root
    function root() public view returns (address) {
        return _rootReturn_0;
    }

    // Mock implementation of sender
    function sender() public view returns (address) {
        return _senderReturn_0;
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }

}