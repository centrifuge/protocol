// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {D18} from "src/misc/types/D18.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IVault} from "src/spoke/interfaces/IVault.sol";
import {IVaultFactory} from "src/spoke/factories/interfaces/IVaultFactory.sol";

contract MockSpoke {
    //<>=============================================================<>
    //||                                                             ||
    //||                    NON-VIEW FUNCTIONS                       ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of addPool
    function addPool(uint64 poolId) public {}

    // Mock implementation of addShareClass
    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public {}

    // Mock implementation of deny
    function deny(address user) public {}

    // Mock implementation of file
    function file(bytes32 what, address factory, bool status) public {}

    // Mock implementation of file
    function file(bytes32 what, address data) public {}

    // Mock implementation of handleTransferShares
    function handleTransferShares(uint64 poolId, bytes16 scId, address destinationAddress, uint128 amount) public {}

    // Mock implementation of linkToken
    function linkToken(uint64 poolId, bytes16 scId, address shareToken) public {}

    // Mock implementation of linkVault
    function linkVault(uint64 poolId, bytes16 scId, uint128 assetId, address vault) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, address receiver, uint256 amount) public {}

    // Mock implementation of recoverTokens
    function recoverTokens(address token, uint256 tokenId, address receiver, uint256 amount) public {}

    // Mock implementation of registerAsset
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId) public payable returns (uint128) {
        return _registerAssetReturn_0;
    }

    // Mock implementation of registerVault
    function registerVault(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address asset,
        uint256 tokenId,
        address factory,
        address vault
    ) public {}

    // Mock implementation of rely
    function rely(address user) public {}

    // Mock implementation of request
    function request(uint64 poolId, bytes16 scId, uint128 assetId, bytes memory payload) public {}

    function requestCallback(uint64 poolId, bytes16 scId, uint128 assetId, bytes memory payload) public {
        // TODO: Call to requestManager?
    }

    // Mock implementation of transferShares
    function transferShares(uint16 centrifugeId, uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount)
        public
        payable
    {}

    // Mock implementation of unlinkVault
    function unlinkVault(uint64 poolId, bytes16 scId, uint128 assetId, address vault) public {}

    // Mock implementation of update
    function update(uint64 poolId, bytes16 scId, bytes memory payload) public {}

    // Mock implementation of updateContract
    function updateContract(uint64 poolId, bytes16 scId, address target, bytes memory update_) public {}

    // Mock implementation of updatePricePoolPerAsset
    function updatePricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, D18 poolPerAsset_, uint64 computedAt)
        public
    {}

    // Mock implementation of updatePricePoolPerShare
    function updatePricePoolPerShare(uint64 poolId, bytes16 scId, D18 price, uint64 computedAt) public {}

    // Mock implementation of updateRestriction
    function updateRestriction(uint64 poolId, bytes16 scId, bytes memory update_) public {}

    // Mock implementation of updateShareHook
    function updateShareHook(uint64 poolId, bytes16 scId, address hook) public {}

    // Mock implementation of updateShareMetadata
    function updateShareMetadata(uint64 poolId, bytes16 scId, string memory name, string memory symbol) public {}

    //<>=============================================================<>
    //||                                                             ||
    //||                    SETTER FUNCTIONS                         ||
    //||                                                             ||
    //<>=============================================================<>
    // Function to set return values for assetToId
    function setAssetToIdReturn(uint128 _value0) public {
        _assetToIdReturn_0 = _value0;
    }

    // Function to set return values for balanceSheet
    function setBalanceSheetReturn(address _value0) public {
        _balanceSheetReturn_0 = _value0;
    }

    // Function to set return values for deployVault
    function setDeployVaultReturn(address _value0) public {
        _deployVaultReturn_0 = _value0;
    }

    // Function to set return values for gateway
    function setGatewayReturn(address _value0) public {
        _gatewayReturn_0 = _value0;
    }

    // Function to set return values for idToAsset
    function setIdToAssetReturn(address _value0, uint256 _value1) public {
        _idToAssetReturn_0 = _value0;
        _idToAssetReturn_1 = _value1;
    }

    // Function to set return values for isLinked
    function setIsLinkedReturn(bool _value0) public {
        _isLinkedReturn_0 = _value0;
    }

    // Function to set return values for isPoolActive
    function setIsPoolActiveReturn(bool _value0) public {
        _isPoolActiveReturn_0 = _value0;
    }

    // Function to set return values for markersPricePoolPerAsset
    function setMarkersPricePoolPerAssetReturn(uint64 _value0, uint64 _value1, uint64 _value2) public {
        _markersPricePoolPerAssetReturn_0 = _value0;
        _markersPricePoolPerAssetReturn_1 = _value1;
        _markersPricePoolPerAssetReturn_2 = _value2;
    }

    // Function to set return values for markersPricePoolPerShare
    function setMarkersPricePoolPerShareReturn(uint64 _value0, uint64 _value1, uint64 _value2) public {
        _markersPricePoolPerShareReturn_0 = _value0;
        _markersPricePoolPerShareReturn_1 = _value1;
        _markersPricePoolPerShareReturn_2 = _value2;
    }

    // Function to set return values for poolEscrowFactory
    function setPoolEscrowFactoryReturn(address _value0) public {
        _poolEscrowFactoryReturn_0 = _value0;
    }

    // Function to set return values for pools
    function setPoolsReturn(uint256 _value0) public {
        _poolsReturn_0 = _value0;
    }

    // Function to set return values for priceAssetPerShare
    function setPriceAssetPerShareReturn(D18 _value0) public {
        _priceAssetPerShareReturn_0 = _value0;
    }

    // Function to set return values for pricePoolPerAsset
    function setPricePoolPerAssetReturn(D18 _value0) public {
        _pricePoolPerAssetReturn_0 = _value0;
    }

    // Function to set return values for pricePoolPerShare
    function setPricePoolPerShareReturn(D18 _value0) public {
        _pricePoolPerShareReturn_0 = _value0;
    }

    // Function to set return values for pricesPoolPer
    function setPricesPoolPerReturn(D18 _value0, D18 _value1) public {
        _pricesPoolPerReturn_0 = _value0;
        _pricesPoolPerReturn_1 = _value1;
    }

    // Function to set return values for registerAsset
    function setRegisterAssetReturn(uint128 _value0) public {
        _registerAssetReturn_0 = _value0;
    }

    // Function to set return values for sender
    function setSenderReturn(address _value0) public {
        _senderReturn_0 = _value0;
    }

    // Function to set return values for shareToken
    function setShareTokenReturn(address _value0) public {
        _shareTokenReturn_0 = _value0;
    }

    // Function to set return values for tokenFactory
    function setTokenFactoryReturn(address _value0) public {
        _tokenFactoryReturn_0 = _value0;
    }

    // Function to set return values for vaultDetails
    function setVaultDetailsReturn(VaultDetails memory _value0) public {
        _vaultDetailsReturn_0 = _value0;
    }

    // Function to set return values for vaultFactory
    function setVaultFactoryReturn(bool _value0) public {
        _vaultFactoryReturn_0 = _value0;
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
    // Struct definition for VaultDetails
    struct VaultDetails {
        uint128 assetId;
        address asset;
        uint256 tokenId;
        bool isLinked;
    }

    //<>=============================================================<>
    //||                                                             ||
    //||        ⚠️  EVENTS DEFINITIONS - DO NOT MODIFY  ⚠️          ||
    //||                                                             ||
    //<>=============================================================<>
    event AddPool(uint64 poolId);
    event AddShareClass(uint64 poolId, bytes16 scId, address token);
    event Deny(address user);
    event DeployVault(
        uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address factory, address vault, uint8 kind
    );
    event File(bytes32 what, address data);
    event File(bytes32 what, address factory, bool status);
    event LinkVault(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address vault);
    event RegisterAsset(
        uint128 assetId,
        address asset,
        uint256 tokenId,
        string name,
        string symbol,
        uint8 decimals,
        bool isInitialization
    );
    event Rely(address user);
    event TransferShares(
        uint16 centrifugeId, uint64 poolId, bytes16 scId, address sender, bytes32 destinationAddress, uint128 amount
    );
    event UnlinkVault(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address vault);
    event UpdateContract(uint64 poolId, bytes16 scId, address target, bytes payload);
    event UpdateMaxAssetPriceAge(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, uint64 maxPriceAge);
    event UpdateMaxSharePriceAge(uint64 poolId, bytes16 scId, uint64 maxPriceAge);

    //<>=============================================================<>
    //||                                                             ||
    //||         ⚠️  INTERNAL STORAGE - DO NOT MODIFY  ⚠️           ||
    //||                                                             ||
    //<>=============================================================<>
    uint128 private _assetToIdReturn_0;
    address private _balanceSheetReturn_0;
    address private _deployVaultReturn_0;
    address private _gatewayReturn_0;
    address private _idToAssetReturn_0;
    uint256 private _idToAssetReturn_1;
    bool private _isLinkedReturn_0;
    bool private _isPoolActiveReturn_0;
    uint64 private _markersPricePoolPerAssetReturn_0;
    uint64 private _markersPricePoolPerAssetReturn_1;
    uint64 private _markersPricePoolPerAssetReturn_2;
    uint64 private _markersPricePoolPerShareReturn_0;
    uint64 private _markersPricePoolPerShareReturn_1;
    uint64 private _markersPricePoolPerShareReturn_2;
    address private _poolEscrowFactoryReturn_0;
    uint256 private _poolsReturn_0;
    D18 private _priceAssetPerShareReturn_0;
    D18 private _pricePoolPerAssetReturn_0;
    D18 private _pricePoolPerShareReturn_0;
    D18 private _pricesPoolPerReturn_0;
    D18 private _pricesPoolPerReturn_1;
    uint128 private _registerAssetReturn_0;
    address private _senderReturn_0;
    address private _shareTokenReturn_0;
    address private _tokenFactoryReturn_0;
    VaultDetails private _vaultDetailsReturn_0;
    bool private _vaultFactoryReturn_0;
    uint256 private _wardsReturn_0;

    //<>=============================================================<>
    //||                                                             ||
    //||          ⚠️  VIEW FUNCTIONS - DO NOT MODIFY  ⚠️            ||
    //||                                                             ||
    //<>=============================================================<>
    // Mock implementation of assetToId
    function assetToId(address asset, uint256 tokenId) public view returns (uint128) {
        return _assetToIdReturn_0;
    }

    // Mock implementation of balanceSheet
    function balanceSheet() public view returns (address) {
        return _balanceSheetReturn_0;
    }

    // Mock implementation of deployVault
    function deployVault(uint64 poolId, bytes16 scId, uint128 assetId, address factory) public returns (address) {
        return _deployVaultReturn_0;
    }

    // Mock implementation of gateway
    function gateway() public view returns (address) {
        return _gatewayReturn_0;
    }

    // Mock implementation of idToAsset
    function idToAsset(uint128 assetId) public view returns (address, uint256) {
        return (_idToAssetReturn_0, _idToAssetReturn_1);
    }

    // Mock implementation of isLinked
    function isLinked(address vault) public view returns (bool) {
        return _isLinkedReturn_0;
    }

    // Mock implementation of isPoolActive
    function isPoolActive(uint64 poolId) public view returns (bool) {
        return _isPoolActiveReturn_0;
    }

    // Mock implementation of markersPricePoolPerShare
    function markersPricePoolPerShare(uint64 poolId, bytes16 scId) public view returns (uint64, uint64, uint64) {
        return (_markersPricePoolPerShareReturn_0, _markersPricePoolPerShareReturn_1, _markersPricePoolPerShareReturn_2);
    }

    // Mock implementation of markersPricePoolPerAsset
    function markersPricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId)
        public
        view
        returns (uint64, uint64, uint64)
    {
        return (_markersPricePoolPerAssetReturn_0, _markersPricePoolPerAssetReturn_1, _markersPricePoolPerAssetReturn_2);
    }

    // Mock implementation of poolEscrowFactory
    function poolEscrowFactory() public view returns (address) {
        return _poolEscrowFactoryReturn_0;
    }

    // Mock implementation of pools
    function pools(uint64 poolId) public view returns (uint256) {
        return _poolsReturn_0;
    }

    // Mock implementation of pricePoolPerAsset
    function pricePoolPerAsset(uint64 poolId, bytes16 scId, uint128 assetId, bool checkValidity)
        public
        view
        returns (D18)
    {
        return _pricePoolPerAssetReturn_0;
    }

    // Mock implementation of pricePoolPerShare
    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool checkValidity) public view returns (D18) {
        return _pricePoolPerShareReturn_0;
    }

    // Mock implementation of pricesPoolPer
    function pricesPoolPer(uint64 poolId, bytes16 scId, uint128 assetId, bool checkValidity)
        public
        view
        returns (D18, D18)
    {
        return (_pricesPoolPerReturn_0, _pricesPoolPerReturn_1);
    }

    // Mock implementation of sender
    function sender() public view returns (address) {
        return _senderReturn_0;
    }

    // Mock implementation of shareToken
    function shareToken(uint64 poolId, bytes16 scId) public view returns (address) {
        return _shareTokenReturn_0;
    }

    // Mock implementation of tokenFactory
    function tokenFactory() public view returns (address) {
        return _tokenFactoryReturn_0;
    }

    // Mock implementation of vaultDetails
    function vaultDetails(address vault) public view returns (VaultDetails memory) {
        return _vaultDetailsReturn_0;
    }

    // Mock implementation of vaultFactory
    function vaultFactory(address factory) public view returns (bool) {
        return _vaultFactoryReturn_0;
    }

    // Mock implementation of wards
    function wards(address arg0) public view returns (uint256) {
        return _wardsReturn_0;
    }
}
