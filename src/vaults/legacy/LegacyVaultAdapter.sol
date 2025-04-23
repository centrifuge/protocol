// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {ILegacyVault} from "src/vaults/legacy/interfaces/ILegacyVault.sol";
import {IInvestmentManager} from "src/vaults/legacy/interfaces/IInvestmentManager.sol";
import {ILegacyVaultAdapter} from "src/vaults/legacy/interfaces/ILegacyVaultAdapter.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";

/// @title  LegacyVaultAdapter
/// @notice An adapter connecting legacy ERC-7540 vaults from Centrifuge V2 to Centrifuge V3.
///
/// @dev This adapter acts as an `IInvestmentManager` for a single legacy `ILegacyVault` vault from Centrifuge V2. At
/// the
/// same time it acts like a new `IAsyncVault` for the `IAsyncRequests` manager of Centrifuge V3. The adapter needs to
/// be deployed per legacy vault and allows a seamless interaction between Centrifuge V2 vaults and Centrifuge V3
/// infrastructure. Thereby, allowing to migrate existing vaults to the new system.
contract LegacyVaultAdapter is AsyncVault, ILegacyVaultAdapter, IInvestmentManager {
    // No TokenId in legacy
    uint256 constant LEGACY_TOKEN_ID = 0;

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
        IAsyncRedeemManager manager,
        IPoolEscrowProvider poolEscrowProvider
    ) AsyncVault(poolId, scId, asset, LEGACY_TOKEN_ID, token, root, manager, poolEscrowProvider) {
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

    /// @dev Check if the msg.sende_r is the legacyVault
    modifier legacy() {
        require(msg.sender == address(legacyVault), NotLegacyVault(msg.sender, address(legacyVault)));
        _;
    }

    // --- IInvestmentManager impl ---
    function escrow() public view returns (address) {
        return address(_poolEscrowProvider.escrow(poolId));
    }

    /// @inheritdoc IInvestmentManager
    function requestDeposit(address, /* vault */ uint256 assets, address receiver, address owner, address source)
        public
        legacy
        returns (bool)
    {
        return asyncManager().requestDeposit(address(this), assets, receiver, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function requestRedeem(address, /* vault */ uint256 shares, address receiver, address owner, address source)
        public
        legacy
        returns (bool)
    {
        return asyncManager().requestRedeem(address(this), shares, receiver, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function cancelDepositRequest(address, /* vault */ address owner, address source) public legacy {
        return asyncManager().cancelDepositRequest(address(this), owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function cancelRedeemRequest(address, /* vault */ address owner, address source) public legacy {
        return asyncManager().cancelRedeemRequest(address(this), owner, source);
    }

    // --- IInvestmentManager - View functions ---
    /// @inheritdoc IInvestmentManager
    function convertToShares(address, /* vault */ uint256 _assets) public view returns (uint256 shares) {
        shares = manager.convertToShares(address(this), _assets);
    }

    /// @inheritdoc IInvestmentManager
    function convertToAssets(address, /* vault */ uint256 _shares) public view returns (uint256 assets) {
        assets = manager.convertToAssets(address(this), _shares);
    }

    /// @inheritdoc IInvestmentManager
    function maxDeposit(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().maxDeposit(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function maxMint(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().maxMint(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function maxWithdraw(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().maxWithdraw(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function maxRedeem(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().maxRedeem(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingDepositRequest(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().pendingDepositRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingRedeemRequest(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().pendingRedeemRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelDepositRequest(address, /* vault */ address user) public view returns (bool isPending) {
        isPending = asyncManager().pendingCancelDepositRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelRedeemRequest(address, /* vault */ address user) public view returns (bool isPending) {
        isPending = asyncManager().pendingCancelRedeemRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelDepositRequest(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = asyncManager().claimableCancelDepositRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelRedeemRequest(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = asyncManager().claimableCancelRedeemRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function priceLastUpdated(address /* vault */ ) public view returns (uint64 lastUpdated) {
        lastUpdated = manager.priceLastUpdated(address(this));
    }

    // --- IInvestmentManager - Vault claim functions ---
    /// @inheritdoc IInvestmentManager
    function deposit(address, /* vault */ uint256 assets, address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = asyncManager().deposit(address(this), assets, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function mint(address, /* vault */ uint256 shares, address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = asyncManager().mint(address(this), shares, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function redeem(address, /* vault */ uint256 shares, address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = asyncManager().redeem(address(this), shares, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function withdraw(address, /* vault */ uint256 assets, address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = asyncManager().withdraw(address(this), assets, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelDepositRequest(address, /* vault */ address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = asyncManager().claimCancelDepositRequest(address(this), receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelRedeemRequest(address, /* vault */ address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = asyncManager().claimCancelRedeemRequest(address(this), receiver, owner);
    }
}
