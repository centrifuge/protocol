// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault} from "src/vaults/BaseVault.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IAsyncRedeemVault} from "src/vaults/interfaces/IERC7540.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";

import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

abstract contract AsyncRedeemVault is BaseVault, IAsyncRedeemVault {
    IAsyncRedeemManager public asyncManager;

    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address baseManager_,
        address asyncManager_
    ) BaseVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, baseManager_) {
        asyncManager = IAsyncRedeemManager(asyncManager_);
    }

    // --- ERC-7540 methods ---
    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(ITranche(share).balanceOf(owner) >= shares, "ERC7540Vault/insufficient-balance");

        // If msg.sender is operator of owner, the transfer is executed as if
        // the sender is the owner, to bypass the allowance check
        address sender = isOperator[owner][msg.sender] ? owner : msg.sender;

        require(
            asyncManager.requestRedeem(address(this), shares, controller, owner, sender),
            "ERC7540Vault/request-redeem-failed"
        );

        address escrow = asyncManager.escrow();
        try ITranche(share).authTransferFrom(sender, owner, escrow, shares) returns (bool) {}
        catch {
            // Support tranche tokens that block authTransferFrom. In this case ERC20 approval needs to be set
            require(ITranche(share).transferFrom(owner, escrow, shares), "ERC7540Vault/transfer-from-failed");
        }

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) public view returns (uint256 pendingShares) {
        pendingShares = asyncManager.pendingRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 claimableShares) {
        claimableShares = maxRedeem(controller);
    }

    // --- Asynchronous cancellation methods ---
    /// @inheritdoc IERC7540CancelRedeem
    function cancelRedeemRequest(uint256, address controller) external {
        _validateController(controller);
        asyncManager.cancelRedeemRequest(address(this), controller, msg.sender);
        emit CancelRedeemRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function pendingCancelRedeemRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = asyncManager.pendingCancelRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimableCancelRedeemRequest(uint256, address controller) public view returns (uint256 claimableShares) {
        claimableShares = asyncManager.claimableCancelRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimCancelRedeemRequest(uint256, address receiver, address controller)
        external
        returns (uint256 shares)
    {
        _validateController(controller);
        shares = asyncManager.claimCancelRedeemRequest(address(this), receiver, controller);
        emit CancelRedeemClaim(receiver, controller, REQUEST_ID, msg.sender, shares);
    }

    // --- Synchronous redeem methods ---
    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem
    function withdraw(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = asyncManager.withdraw(address(this), assets, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem.
    ///             When claiming redemption requests using redeem(), there can be some precision loss leading to dust.
    ///             It is recommended to use withdraw() to claim redemption requests instead.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _validateController(controller);
        assets = asyncManager.redeem(address(this), shares, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    // --- Event emitters ---
    function onRedeemRequest(address controller, address owner, uint256 shares) public auth {
        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
    }

    function onRedeemClaimable(address controller, uint256 assets, uint256 shares) public auth {
        emit RedeemClaimable(controller, REQUEST_ID, assets, shares);
    }

    function onCancelRedeemClaimable(address controller, uint256 shares) public auth {
        emit CancelRedeemClaimable(controller, REQUEST_ID, shares);
    }

    // --- View methods ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override(BaseVault, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId) || interfaceId == type(IAsyncRedeemVault).interfaceId;
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) public view returns (uint256 maxAssets) {
        maxAssets = asyncManager.maxWithdraw(address(this), controller);
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) public view returns (uint256 maxShares) {
        maxShares = asyncManager.maxRedeem(address(this), controller);
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert();
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewRedeem(uint256) external pure returns (uint256) {
        revert();
    }
}
