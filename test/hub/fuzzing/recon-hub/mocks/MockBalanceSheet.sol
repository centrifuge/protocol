// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {D18} from "src/misc/types/D18.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {ISpokeMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IPoolEscrowProvider} from "src/common/factories/interfaces/IPoolEscrowFactory.sol";
import {IPoolEscrow} from "src/common/interfaces/IPoolEscrow.sol";

contract MockBalanceSheet {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of deny
    function deny(address user) public {}

    // Mock implementation of deposit
    function deposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, uint128 amount) public {}

    // Mock implementation of file
    function file(bytes32 what, address data) public {}

    // Mock implementation of issue
    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares) public {}

    // Mock implementation of noteDeposit
    function noteDeposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, uint128 amount) public {}

    // Mock implementation of noteRevoke
    function noteRevoke(uint64 poolId, bytes16 scId, address from, uint128 shares) public {}

    // Mock implementation of overridePricePoolPerAsset
    function overridePricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, D18 value) public {}

    // Mock implementation of overridePricePoolPerShare
    function overridePricePoolPerShare(uint64 poolId, bytes16 scId, D18 value) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {}

    // Mock implementation of rely
    function rely(address user) public {}

    // Mock implementation of reserve
    function reserve(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, uint128 amount) public {}

    // Mock implementation of resetPricePoolPerAsset
    function resetPricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId) public {}

    // Mock implementation of resetPricePoolPerShare
    function resetPricePoolPerShare(uint64 poolId, bytes16 scId) public {}

    // Mock implementation of revoke
    function revoke(uint64 poolId, bytes16 scId, uint128 shares) public {}

    // Mock implementation of setQueue
    function setQueue(uint64 poolId, bytes16 scId, bool enabled) public {}

    // Mock implementation of submitQueuedAssets
    function submitQueuedAssets(uint64 poolId, bytes16 scId, uint128 assetId, uint128 extraGasLimit) public {}

    // Mock implementation of submitQueuedShares
    function submitQueuedShares(uint64 poolId, bytes16 scId, uint128 extraGasLimit) public {}

    // Mock implementation of transferSharesFrom
    function transferSharesFrom(uint64 poolId, bytes16 scId, address sender, address from, address to, uint256 amount)
        public
    {}

    // Mock implementation of triggerDeposit
    function triggerDeposit(uint64 poolId, bytes16 scId, uint128 assetId, address owner, uint128 amount) public {}

    // Mock implementation of triggerIssueShares
    function triggerIssueShares(uint64 poolId, bytes16 scId, address receiver, uint128 shares) public {}

    // Mock implementation of triggerWithdraw
    function triggerWithdraw(uint64 poolId, bytes16 scId, uint128 assetId, address receiver, uint128 amount) public {}

    // Mock implementation of unreserve
    function unreserve(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, uint128 amount) public {}

    // Mock implementation of update
    function update(uint64 poolId, bytes16 scId, bytes memory payload) public {}

    // Mock implementation of withdraw
    function withdraw(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address receiver, uint128 amount)
        public
    {}

    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for availableBalanceOf
    function setAvailableBalanceOfReturn(uint128 _value0) public {
        _availableBalanceOfReturn_0 = _value0;
    }

    // Function to set return values for escrow
    function setEscrowReturn(address _value0) public {
        _escrowReturn_0 = _value0;
    }

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
    function setQueuedSharesReturn(uint128 _value0, bool _value1, uint32 _value2, uint64 _value3) public {
        _queuedSharesReturn_0 = _value0;
        _queuedSharesReturn_1 = _value1;
        _queuedSharesReturn_2 = _value2;
        _queuedSharesReturn_3 = _value3;
    }

    // Function to set return values for root
    function setRootReturn(address _value0) public {
        _rootReturn_0 = _value0;
    }

    // Function to set return values for sender
    function setSenderReturn(address _value0) public {
        _senderReturn_0 = _value0;
    }

    // Function to set return values for spoke
    function setSpokeReturn(address _value0) public {
        _spokeReturn_0 = _value0;
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

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  EVENTS DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>
    event Deny(address user);
    event Deposit(uint64 poolId, bytes16 shareClassId, address asset, uint256 tokenId, uint128 amount);
    event NoteDeposit(
        uint64 poolId, bytes16 shareClassId, address asset, uint256 tokenId, uint128 amount, D18 pricePoolPerAsset
    );
    event File(bytes32 what, address data);
    event Issue(uint64 poolId, bytes16 shareClassId, address to, D18 pricePoolPerShare, uint128 shares);
    event Rely(address user);
    event Revoke(uint64 poolId, bytes16 shareClassId, address from, D18 pricePoolPerShare, uint128 shares);
    event SubmitQueuedAssets(
        uint64 poolId,
        bytes16 shareClassId,
        AssetId assetId,
        uint128 deposits,
        uint128 withdrawals,
        D18 pricePoolPerAsset,
        bool isSnapshot,
        uint64 nonce
    );
    event SubmitQueuedShares(
        uint64 poolId, bytes16 shareClassId, uint128 shares, bool isIssuance, bool isSnapshot, uint64 nonce
    );
    event TransferSharesFrom(
        uint64 poolId, bytes16 shareClassId, address sender, address from, address to, uint256 amount
    );
    event UpdateManager(uint64 poolId, address who, bool canManage);
    event Withdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    );

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    uint128 private _availableBalanceOfReturn_0;
    address private _escrowReturn_0;
    address private _gatewayReturn_0;
    bool private _managerReturn_0;
    address private _poolEscrowProviderReturn_0;
    address private _poolManagerReturn_0;
    bool private _queueEnabledReturn_0;
    uint128 private _queuedAssetsReturn_0;
    uint128 private _queuedAssetsReturn_1;
    uint128 private _queuedSharesReturn_0;
    bool private _queuedSharesReturn_1;
    uint32 private _queuedSharesReturn_2;
    uint64 private _queuedSharesReturn_3;
    address private _rootReturn_0;
    address private _senderReturn_0;
    address private _spokeReturn_0;
    uint256 private _wardsReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of availableBalanceOf
    function availableBalanceOf(uint64 poolId, bytes16 scId, address asset, uint256 tokenId)
        public
        view
        returns (uint128)
    {
        return _availableBalanceOfReturn_0;
    }

    // Mock implementation of escrow
    function escrow(uint64 poolId) public view returns (address) {
        return _escrowReturn_0;
    }

    // Mock implementation of gateway
    function gateway() public view returns (address) {
        return _gatewayReturn_0;
    }

    // Mock implementation of manager
    function manager(uint64 poolId, address manager) public view returns (bool) {
        return _managerReturn_0;
    }

    // Mock implementation of poolEscrowProvider
    function poolEscrowProvider() public view returns (address) {
        return _poolEscrowProviderReturn_0;
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
    function queuedShares(uint64 poolId, bytes16 scId) public view returns (uint128, bool, uint32, uint64) {
        return (_queuedSharesReturn_0, _queuedSharesReturn_1, _queuedSharesReturn_2, _queuedSharesReturn_3);
    }

    // Mock implementation of root
    function root() public view returns (address) {
        return _rootReturn_0;
    }

    // Mock implementation of sender
    function sender() public view returns (address) {
        return _senderReturn_0;
    }

    // Mock implementation of spoke
    function spoke() public view returns (address) {
        return _spokeReturn_0;
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }
}
