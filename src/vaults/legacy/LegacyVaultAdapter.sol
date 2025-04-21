// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IAsyncRequests, IAsyncVault} from "src/vaults/interfaces/IERC7540.sol";
import {IERC7540Vault} from "src/vaults/legacy/interfaces/IERC7540.sol";
import {IInvestmentManager} from "src/vaults/legacy/interfaces/IInvestmentManager.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";

/// @title  LegacyVaultAdapter
/// @notice An adapter connecting legacy ERC-7540 vaults from Centrifuge V2 to Centrifuge V3.
///
/// @dev This adapter acts as an `IInvestmentManager` for a single legacy `IERC7540` vault from Centrifuge V2. At the
/// same time it acts like a new `IAsyncVault` for the `IAsyncRequests` manager of Centrifuge V3. The adapter needs to
/// be deployed per legacy vault and allows a seamless interaction between Centrifuge V2 vaults and Centrifuge V3
/// infrastructure. Thereby, allowing to migrate existing vaults to the new system.
contract LegacyVaultAdapter is ILegacyVaultAdapter, IInvestmentManager, IAsyncVault {
    u64 public immutable legacyPoolId;
    PoolId public immutable newPoolId;

    bytes16 public immutable legacyTrancheId;
    ShareClassId public immutable newScId;

    IERC7540Vault public immutable legacyVault;
    IAsyncRequests public newInvestmentManager;
    IPoolManager public newPoolManager;

    constructor() {}

    /// @dev Check if the msg.sender is the legacyVault
    modifier legacy() {
        require(msg.sender == address(legacyVault), NotLegacyVault());
        _;
    }

    /// @dev Check if the msg.sender is the newInvestmentManager
    modifier manager() {
        require(msg.sender == address(newInvestmentManager), NotManager());
        _;
    }

    /// @inheritdoc ILegacyVaultAdapter
    function file(bytes32 what, address data) external auth {
        if (what == "investmentManager") newInvestmentManager = IAsyncRequests(data);
        else if (what == "poolManager") newPoolManager = IPoolManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    // --- IInvestmentManager impl ---
    function escrow() public view returns (address) {
        // TODO: query pool manager for perPoolEscrow here
        return address(0);
    }

    /// @inheritdoc IInvestmentManager
    function requestDeposit(address, /* vault */ uint256 assets, address receiver, address owner, address source)
        public
        legacy
        returns (bool)
    {
        return newInvestmentManager.requestDeposit(address(this), assets, receiver, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function requestRedeem(address, /* vault */ uint256 shares, address receiver, address owner, address source)
        public
        legacy
        returns (bool)
    {
        return newInvestmentManager.requestRedeem(address(this), shares, receiver, owner, source);
    }

    /// @inheritdoc IInvestmentManager
    function cancelDepositRequest(address, /* vault */ address owner, address source) public legacy {
        return newInvestmentManager.cancelDepositRequest();
    }

    /// @inheritdoc IInvestmentManager
    function cancelRedeemRequest(address, /* vault */ address owner, address source) public legacy {
        return newInvestmentManager.cancelRedeemRequest(address(this), owner, source);
    }

    // --- IInvestmentManager - View functions ---
    /// @inheritdoc IInvestmentManager
    function convertToShares(address, /* vault */ uint256 _assets) public view returns (uint256 shares) {
        shares = newInvestmentManager.convertToShares(address(this), _assets);
    }

    /// @inheritdoc IInvestmentManager
    function convertToAssets(address, /* vault */ uint256 _shares) public view returns (uint256 assets) {
        assets = newInvestmentManager.convertToAssets(address(this), _assets);
    }

    /// @inheritdoc IInvestmentManager
    function maxDeposit(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = newInvestmentManager.maxDeposit(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function maxMint(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = newInvestmentManager.maxMint(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function maxWithdraw(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = newInvestmentManager.maxWithdraw(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function maxRedeem(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = newInvestmentManager.maxRedeem(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingDepositRequest(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = newInvestmentManager.pendingDepositRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingRedeemRequest(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = newInvestmentManager.pendingRedeemRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelDepositRequest(address, /* vault */ address user) public view returns (bool isPending) {
        isPending = newInvestmentManager.pendingCancelDepositRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function pendingCancelRedeemRequest(address, /* vault */ address user) public view returns (bool isPending) {
        isPending = newInvestmentManager.pendingCancelRedeemRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelDepositRequest(address, /* vault */ address user) public view returns (uint256 assets) {
        assets = newInvestmentManager.claimableCancelDepositRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function claimableCancelRedeemRequest(address, /* vault */ address user) public view returns (uint256 shares) {
        shares = newInvestmentManager.claimableCancelRedeemRequest(address(this), user);
    }

    /// @inheritdoc IInvestmentManager
    function priceLastUpdated(address /* vault */ ) public view returns (uint64 lastUpdated) {
        (, lastUpdated) = newPoolManager.pricePoolPerShare(newPoolId, newScId, false);
    }

    // --- IInvestmentManager - Vault claim functions ---
    /// @inheritdoc IInvestmentManager
    function deposit(address, /* vault */ uint256 assets, address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = newInvestmentManager.deposit(address(this), assets, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function mint(address, /* vault */ uint256 shares, address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = newInvestmentManager.mint(address(this), shares, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function redeem(address, /* vault */ uint256 shares, address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = newInvestmentManager.redeem(address(this), shares, receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function withdraw(address, /* vault */ uint256 assets, address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = newInvestmentManager.withdraw(address(this), receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelDepositRequest(address, /* vault */ address receiver, address owner)
        public
        legacy
        returns (uint256 assets)
    {
        assets = newInvestmentManager.claimableCancelDepositRequest(address(this), receiver, owner);
    }

    /// @inheritdoc IInvestmentManager
    function claimCancelRedeemRequest(address, /* vault */ address receiver, address owner)
        public
        legacy
        returns (uint256 shares)
    {
        shares = newInvestmentManager.claimCancelRedeemRequest(address(this), receiver, owner);
    }

    // --- IAsyncVault impl ---
    /// @notice Callback when a deposit Request becomes claimable
    function onDepositClaimable(address owner, uint256 assets, uint256 shares) public manager {
        legacyVault.onDepositClaimable(owner, assets, shares);
    }

    /// @notice Callback when a claim deposit Request becomes claimable
    function onCancelDepositClaimable(address owner, uint256 assets) public manager {
        legacyVault.onCancelDepositClaimable(owner, assets, shares);
    }

    // --- IAsyncRedeemVault impl ---
    /// @inheritdoc IAsyncRedeemVault
    function onRedeemRequest(address controller, address owner, uint256 shares) public manager {
        legacyVault.onRedeemRequest(controller, owner, shares);
    }

    /// @inheritdoc IAsyncRedeemVault
    function onRedeemClaimable(address owner, uint256 assets, uint256 shares) public manager {
        legacyVault.onRedeemClaimable(owner, assets, shares);
    }

    /// @inheritdoc IAsyncRedeemVault
    function onCancelRedeemClaimable(address owner, uint256 shares) public manager {
        legacyVault.onCancelRedeemClaimable(owner, shares);
    }

    /// @inheritdoc IAsyncRedeemVault
    function asyncRedeemManager() public view returns (IAsyncRedeemManager) {
        return IAsyncRedeemManager(newInvestmentManager);
    }

    // --- IERC7540Redeem impl --
    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256 requestId) {
        // TODO: Or revert() and force going through legacy directly?
        legacyVault.requestRedeem(shares, controller, owner);
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 pendingShares) {
        pendingShares = legacyVault.pendingRedeemRequest(requestId, controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256 requestId, address controller)
        public
        view
        returns (uint256 claimableShares)
    {
        claimableShares = legacyVault.claimableRedeemRequest(requestId, controller);
    }

    // --- IERC7540CancelRedeem impl ---
    /// @inheritdoc IERC7540CancelRedeem
    function cancelRedeemRequest(uint256 requestId, address controller) public {
        // TODO: msg.sender in legacyVault will be off - REMOVE?
        legacyVault.cancelRedeemRequest(requestId, controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function pendingCancelRedeemRequest(uint256 requestId, address controller) public view returns (bool isPending) {
        isPending = legacyVault.pendingCancelRedeemRequest(requestId, controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimableCancelRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares)
    {
        claimableShares = legacyVault.claimableCancelRedeemRequest(requestId, controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimCancelRedeemRequest(uint256 requestId, address receiver, address controller)
        external
        returns (uint256 shares)
    {
        shares = legacyVault.claimCancelRedeemRequest(requestId, receiver, controller);
    }
}
