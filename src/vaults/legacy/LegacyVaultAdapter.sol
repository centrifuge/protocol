// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {ILegacyVault} from "src/vaults/legacy/interfaces/ILegacyVault.sol";
import {IInvestmentManager} from "src/vaults/legacy/interfaces/IInvestmentManager.sol";
import {ILegacyVaultAdapter} from "src/vaults/legacy/interfaces/ILegacyVaultAdapter.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/investments/IAsyncRequestManager.sol";
import {BaseAsyncRedeemVault, IAsyncRedeemVault} from "src/vaults/BaseVaults.sol";

/// @title  LegacyVaultAdapter
/// @notice An adapter connecting legacy ERC-7540 vaults from Centrifuge V2 to Centrifuge V3.
///
/// @dev    This adapter acts as an `IInvestmentManager` for a single legacy `ILegacyVault` vault from Centrifuge V2.
///         At the same time it acts like a new `IAsyncVault` for the `IAsyncRequestManager` manager of Centrifuge V3.
///         The adapter needs to be deployed per legacy vault and allows a seamless interaction between Centrifuge V2
///         vaults and Centrifuge V3 infrastructure. Thereby, allowing to migrate existing vaults to the new system.
contract LegacyVaultAdapter is AsyncVault, ILegacyVaultAdapter, IInvestmentManager {
    uint64 public immutable legacyPoolId;
    bytes16 public immutable legacyTrancheId;
    ILegacyVault public immutable legacyVault;

    constructor(
        ILegacyVault legacyVault_,
        PoolId poolId,
        uint64 legacyPoolId_,
        ShareClassId scId,
        bytes16 legacyTrancheId_,
        address asset,
        IShareToken token,
        address root,
        IAsyncRequestManager manager
    ) AsyncVault(poolId, scId, asset, token, root, manager) {
        require(legacyVault_.poolId() == legacyPoolId_, NotLegacyPoolId(legacyPoolId_, legacyVault_.poolId()));
        require(
            legacyVault_.trancheId() == legacyTrancheId_, NotLegacyTrancheId(legacyTrancheId_, legacyVault_.trancheId())
        );
        require(legacyVault_.asset() == asset, NotLegacyAsset(asset, legacyVault_.asset()));
        require(legacyVault_.share() == address(token), NotLegacyShare(address(token), legacyVault_.share()));

        legacyPoolId = legacyPoolId_;
        legacyTrancheId = legacyTrancheId_;
        legacyVault = legacyVault_;
    }

    /// @dev Check if the msg.sender is the legacy vault
    modifier legacy() {
        require(msg.sender == address(legacyVault), NotLegacyVault(msg.sender, address(legacyVault)));
        _;
    }

    //----------------------------------------------------------------------------------------------
    // IInvestmentManager handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IInvestmentManager
    function requestDeposit(address, /* vault */ uint256 assets, address receiver, address owner, address source)
        public
        legacy
        returns (bool)
    {
        return asyncManager().requestDeposit(this, assets, receiver, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function requestRedeem(address, /* vault */ uint256 shares, address receiver, address owner, address source)
        public
        legacy
        returns (bool)
    {
        return asyncManager().requestRedeem(this, shares, receiver, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function cancelDepositRequest(address, /* vault */ address owner, address source) public legacy {
        return asyncManager().cancelDepositRequest(this, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function cancelRedeemRequest(address, /* vault */ address owner, address source) public legacy {
        return asyncManager().cancelRedeemRequest(this, owner, source);
    }

    //----------------------------------------------------------------------------------------------
    // IInvestmentManager view methods
    //----------------------------------------------------------------------------------------------

    function escrow() public view returns (address) {
        return address(manager.globalEscrow());
    }

    /// @inheritdoc IInvestmentManager
    function convertToShares(address, /* vault */ uint256 _assets) public view returns (uint256 shares) {
        shares = asyncManager().convertToShares(this, _assets);
    }

    /// @inheritdoc IInvestmentManager
    function convertToAssets(address, /* vault */ uint256 _shares) public view returns (uint256 assets) {
        assets = asyncManager().convertToAssets(this, _shares);
    }

    /// @inheritdoc IInvestmentManager
    function maxDeposit(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().maxDeposit(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function maxMint(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().maxMint(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function maxWithdraw(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().maxWithdraw(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function maxRedeem(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().maxRedeem(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingDepositRequest(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().pendingDepositRequest(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingRedeemRequest(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().pendingRedeemRequest(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelDepositRequest(address, /* vault */ address user) public view returns (bool isPending) {
        isPending = asyncManager().pendingCancelDepositRequest(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelRedeemRequest(address, /* vault */ address user) public view returns (bool isPending) {
        isPending = asyncManager().pendingCancelRedeemRequest(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelDepositRequest(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().claimableCancelDepositRequest(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelRedeemRequest(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().claimableCancelRedeemRequest(this, user);
    }

    /// @inheritdoc IInvestmentManager
    function priceLastUpdated(address /* vault */ ) public view returns (uint64 lastUpdated) {
        lastUpdated = manager.priceLastUpdated(this);
    }

    //----------------------------------------------------------------------------------------------
    // IInvestmentManager vault claim methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IInvestmentManager
    function deposit(address, /* vault */ uint256 assets, address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = asyncManager().deposit(this, assets, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function mint(address, /* vault */ uint256 shares, address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = asyncManager().mint(this, shares, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function redeem(address, /* vault */ uint256 shares, address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = asyncManager().redeem(this, shares, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function withdraw(address, /* vault */ uint256 assets, address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = asyncManager().withdraw(this, assets, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelDepositRequest(address, /* vault */ address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = asyncManager().claimCancelDepositRequest(this, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelRedeemRequest(address, /* vault */ address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = asyncManager().claimCancelRedeemRequest(this, receiver, owner);
    }

    //----------------------------------------------------------------------------------------------
    // Event emitters
    //----------------------------------------------------------------------------------------------

    function onDepositClaimable(address controller, uint256 assets, uint256 shares) public override auth {
        legacyVault.onDepositClaimable(controller, assets, shares);
    }

    function onCancelDepositClaimable(address controller, uint256 assets) public override auth {
        legacyVault.onCancelDepositClaimable(controller, assets);
    }

    function onRedeemRequest(address controller, address owner, uint256 shares)
        public
        override(BaseAsyncRedeemVault, IAsyncRedeemVault)
        auth
    {
        legacyVault.onRedeemRequest(controller, owner, shares);
    }

    function onRedeemClaimable(address controller, uint256 assets, uint256 shares)
        public
        override(BaseAsyncRedeemVault, IAsyncRedeemVault)
        auth
    {
        legacyVault.onRedeemClaimable(controller, assets, shares);
    }

    function onCancelRedeemClaimable(address controller, uint256 shares)
        public
        override(BaseAsyncRedeemVault, IAsyncRedeemVault)
        auth
    {
        legacyVault.onCancelRedeemClaimable(controller, shares);
    }
}
