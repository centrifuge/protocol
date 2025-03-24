// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";

import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {ISyncDepositAsyncRedeemManager} from "src/vaults/interfaces/investments/ISyncDepositAsyncRedeemManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IDepositManager} from "src/vaults/interfaces/investments/IDepositManager.sol";
import {IRedeemManager} from "src/vaults/interfaces/investments/IRedeemManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {PriceConversionLib} from "src/vaults/libraries/PriceConversionLib.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";

/// @title  Sync Investment Manager
/// @notice This is the main contract vaults interact with for
///         both incoming and outgoing investment transactions.
contract SyncDepositAsyncRedeemManager is Auth, ISyncDepositAsyncRedeemManager, IVaultManager {
    using MathLib for uint256;

    address public immutable escrow;

    IGateway public gateway;
    IPoolManager public poolManager;
    IAsyncRedeemManager public asyncRedeemManager;

    mapping(address vaultAddr => uint64) public maxPriceAge;
    mapping(uint64 poolId => mapping(bytes16 trancheId => mapping(uint128 assetId => address vault))) public vault;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = escrow_;
    }

    // --- Administration ---
    /// @inheritdoc IBaseInvestmentManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else revert("SyncDepositAsyncRedeemManager/file-unrecognized-param");
        emit IBaseInvestmentManager.File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId, address to, uint256 amount) external auth {
        if (tokenId == 0) {
            SafeTransferLib.safeTransfer(token, to, amount);
        } else {
            IERC6909(token).transfer(to, tokenId, amount);
        }
    }

    // --- IVaultManager ---
    /// @inheritdoc IVaultManager
    function addVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncDepositAsyncRedeemManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] == address(0), "SyncDepositAsyncRedeemManager/vault-already-exists");

        vault[poolId][trancheId][assetId] = vaultAddr;

        IAuth(token).rely(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), vaultAddr);
        rely(vaultAddr);
    }

    /// @inheritdoc IVaultManager
    function removeVault(uint64 poolId, bytes16 trancheId, address vaultAddr, address asset_, uint128 assetId)
        public
        override
        auth
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        address token = vault_.share();

        require(vault_.asset() == asset_, "SyncDepositAsyncRedeemManager/asset-mismatch");
        require(vault[poolId][trancheId][assetId] != address(0), "SyncDepositAsyncRedeemManager/vault-does-not-exist");

        delete vault[poolId][trancheId][assetId];

        IAuth(token).deny(vaultAddr);
        ITranche(token).updateVault(vault_.asset(), address(0));
        deny(vaultAddr);
    }

    // --- IDepositManager ---
    /// @inheritdoc IDepositManager
    function maxDeposit(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncDepositManager
    function previewDeposit(address vaultAddr, address, /* sender */ uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        shares = PriceConversionLib.calculateShares(assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function deposit(address vaultAddr, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares)
    {
        require(maxDeposit(vaultAddr, owner) >= assets, ExceedsMaxDeposit());
        shares = previewDeposit(vaultAddr, owner, assets);

        ITranche tranche = ITranche(SyncDepositVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    /// @inheritdoc IDepositManager
    function maxMint(address vaultAddr, address /* owner */ ) public view returns (uint256) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        // TODO: implement rate limit
        return type(uint256).max;
    }

    /// @inheritdoc ISyncDepositManager
    function previewMint(address vaultAddr, address, /* sender */ uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddr);
        (uint128 latestPrice, uint64 computedAt) =
            poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        require(block.timestamp - computedAt <= maxPriceAge[vaultAddr], PriceTooOld());

        assets = PriceConversionLib.calculateAssets(shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down);
    }

    /// @inheritdoc IDepositManager
    function mint(address vaultAddr, uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        assets = previewMint(vaultAddr, owner, shares);

        ITranche tranche = ITranche(SyncDepositVault(vaultAddr).share());
        tranche.mint(receiver, shares);

        // TODO: Call CAL.IssueShares + CAL.UpdateHoldings
    }

    // -- IAsyncRedeemManager --
    /// @inheritdoc IAsyncRedeemManager
    function requestRedeem(address vaultAddr, uint256 shares, address receiver, address owner, address source)
        public
        auth
        returns (bool)
    {
        return asyncRedeemManager.requestRedeem(vaultAddr, shares, receiver, owner, source);
    }

    /// @inheritdoc IAsyncRedeemManager
    function cancelRedeemRequest(address vaultAddr, address owner, address source) public auth {
        asyncRedeemManager.cancelRedeemRequest(vaultAddr, owner, source);
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimCancelRedeemRequest(address vaultAddr, address receiver, address owner)
        public
        auth
        returns (uint256 shares)
    {
        return asyncRedeemManager.claimCancelRedeemRequest(vaultAddr, receiver, owner);
    }

    /// @inheritdoc IRedeemManager
    function redeem(address vaultAddr, uint256 shares, address receiver, address controller)
        public
        auth
        returns (uint256 assets)
    {
        return asyncRedeemManager.redeem(vaultAddr, shares, receiver, controller);
    }

    /// @inheritdoc IRedeemManager
    function withdraw(address vaultAddr, uint256 assets, address receiver, address controller)
        public
        auth
        returns (uint256 shares)
    {
        return asyncRedeemManager.withdraw(vaultAddr, assets, receiver, controller);
    }

    // --- View functions ---
    /// @inheritdoc IBaseInvestmentManager
    function convertToShares(address vaultAddr, uint256 _assets) public view returns (uint256 shares) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (uint128 latestPrice,) = poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        shares = uint256(
            PriceConversionLib.calculateShares(_assets.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down)
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function convertToAssets(address vaultAddr, uint256 _shares) public view returns (uint256 assets) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (uint128 latestPrice,) = poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
        assets = uint256(
            PriceConversionLib.calculateAssets(_shares.toUint128(), vaultAddr, latestPrice, MathLib.Rounding.Down)
        );
    }

    /// @inheritdoc IBaseInvestmentManager
    function vaultByAssetId(uint64 poolId, bytes16 trancheId, uint128 assetId) public view returns (address) {
        return vault[poolId][trancheId][assetId];
    }

    /// @inheritdoc IBaseInvestmentManager
    function priceLastUpdated(address vaultAddr) public view returns (uint64 lastUpdated) {
        SyncDepositVault vault_ = SyncDepositVault(vaultAddr);
        VaultDetails memory vaultDetails = poolManager.vaultDetails(address(vault_));
        (, lastUpdated) = poolManager.tranchePrice(vault_.poolId(), vault_.trancheId(), vaultDetails.assetId);
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        asyncRedeemManager.pendingRedeemRequest(vaultAddr, user);
    }

    /// @inheritdoc IAsyncRedeemManager
    function pendingCancelRedeemRequest(address vaultAddr, address user) public view returns (bool isPending) {
        asyncRedeemManager.pendingCancelRedeemRequest(vaultAddr, user);
    }

    /// @inheritdoc IAsyncRedeemManager
    function claimableCancelRedeemRequest(address vaultAddr, address user) public view returns (uint256 shares) {
        asyncRedeemManager.claimableCancelRedeemRequest(vaultAddr, user);
    }

    /// @inheritdoc IRedeemManager
    function maxRedeem(address vaultAddr, address user) public view returns (uint256 shares) {
        return asyncRedeemManager.maxRedeem(vaultAddr, user);
    }

    /// @inheritdoc IRedeemManager
    function maxWithdraw(address vaultAddr, address user) public view returns (uint256 assets) {
        return asyncRedeemManager.maxWithdraw(vaultAddr, user);
    }

    // --- Admin actions ---
    /// @inheritdoc IMessageHandler
    function handle(uint32 chainId, bytes calldata message) public auth {
        // TODO: updateMaxPriceAge handler
    }
}
