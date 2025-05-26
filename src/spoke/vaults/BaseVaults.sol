// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "src/misc/interfaces/IERC7540.sol";
import "src/misc/interfaces/IERC7575.sol";
import {Auth} from "src/misc/Auth.sol";
import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {EIP712Lib} from "src/misc/libraries/EIP712Lib.sol";
import {SignatureLib} from "src/misc/libraries/SignatureLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IBaseVault} from "src/spoke/vaults/interfaces/IBaseVault.sol";
import {IAsyncRedeemVault} from "src/spoke/vaults/interfaces/IAsyncVault.sol";
import {IERC7575} from "src/misc/interfaces/IERC7575.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IAsyncRedeemManager} from "src/spoke/vaults/interfaces/IVaultManagers.sol";
import {ISyncDepositManager} from "src/spoke/vaults/interfaces/IVaultManagers.sol";
import {IBaseRequestManager} from "src/spoke/interfaces/IBaseRequestManager.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {BaseVault} from "src/spoke/BaseVault.sol";

abstract contract BaseAsyncRedeemVault is BaseVault, IAsyncRedeemVault {
    IAsyncRedeemManager public asyncRedeemManager;

    constructor(IAsyncRedeemManager asyncRequestManager_) {
        asyncRedeemManager = asyncRequestManager_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external virtual override auth {
        if (what == "manager") manager = IBaseRequestManager(data);
        else if (what == "asyncRedeemManager") asyncRedeemManager = IAsyncRedeemManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 redeem
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(IShareToken(share).balanceOf(owner) >= shares, InsufficientBalance());

        // If msg.sender is operator of owner, the transfer is executed as if
        // the sender is the owner, to bypass the allowance check
        address sender = isOperator[owner][msg.sender] ? owner : msg.sender;

        require(asyncRedeemManager.requestRedeem(this, shares, controller, owner, sender), RequestRedeemFailed());
        IShareToken(share).authTransferFrom(sender, owner, address(manager.globalEscrow()), shares);

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) public view returns (uint256 pendingShares) {
        pendingShares = asyncRedeemManager.pendingRedeemRequest(this, controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 claimableShares) {
        claimableShares = maxRedeem(controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7887
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7887Redeem
    function cancelRedeemRequest(uint256, address controller) external {
        _validateController(controller);
        asyncRedeemManager.cancelRedeemRequest(this, controller, msg.sender);
        emit CancelRedeemRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7887Redeem
    function pendingCancelRedeemRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = asyncRedeemManager.pendingCancelRedeemRequest(this, controller);
    }

    /// @inheritdoc IERC7887Redeem
    function claimableCancelRedeemRequest(uint256, address controller) public view returns (uint256 claimableShares) {
        claimableShares = asyncRedeemManager.claimableCancelRedeemRequest(this, controller);
    }

    /// @inheritdoc IERC7887Redeem
    function claimCancelRedeemRequest(uint256, address receiver, address controller)
        external
        returns (uint256 shares)
    {
        _validateController(controller);
        shares = asyncRedeemManager.claimCancelRedeemRequest(this, receiver, controller);
        emit CancelRedeemClaim(receiver, controller, REQUEST_ID, msg.sender, shares);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 claim
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem
    function withdraw(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = asyncRedeemManager.withdraw(this, assets, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem.
    ///             When claiming redemption requests using redeem(), there can be some precision loss leading to dust.
    ///             It is recommended to use withdraw() to claim redemption requests instead.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _validateController(controller);
        assets = asyncRedeemManager.redeem(this, shares, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    //----------------------------------------------------------------------------------------------
    // Event emitters
    //----------------------------------------------------------------------------------------------

    function onRedeemRequest(address controller, address owner, uint256 shares) public virtual auth {
        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
    }

    function onRedeemClaimable(address controller, uint256 assets, uint256 shares) public virtual auth {
        emit RedeemClaimable(controller, REQUEST_ID, assets, shares);
    }

    function onCancelRedeemClaimable(address controller, uint256 shares) public virtual auth {
        emit CancelRedeemClaimable(controller, REQUEST_ID, shares);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override(BaseVault, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId) || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7887Redeem).interfaceId;
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) public view returns (uint256 maxAssets) {
        maxAssets = asyncRedeemManager.maxWithdraw(this, controller);
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) public view returns (uint256 maxShares) {
        maxShares = asyncRedeemManager.maxRedeem(this, controller);
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

abstract contract BaseSyncDepositVault is BaseVault {
    ISyncDepositManager public syncDepositManager;

    constructor(ISyncDepositManager syncRequestManager_) {
        syncDepositManager = syncRequestManager_;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-4626
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = syncDepositManager.maxDeposit(this, owner);
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        shares = syncDepositManager.previewDeposit(this, msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = syncDepositManager.deposit(this, assets, receiver, msg.sender);
        // NOTE: For security reasons, transfer must stay at end of call despite the fact that it logically should
        // happen before depositing in the manager
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(manager.poolEscrow(poolId)), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = syncDepositManager.maxMint(this, owner);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = syncDepositManager.previewMint(this, msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = syncDepositManager.mint(this, shares, receiver, msg.sender);
        // NOTE: For security reasons, transfer must stay at end of call
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(manager.poolEscrow(poolId)), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override(BaseVault) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
