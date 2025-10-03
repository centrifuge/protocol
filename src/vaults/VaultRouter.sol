// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseSyncDepositVault} from "./BaseVaults.sol";
import {IBaseVault} from "./interfaces/IBaseVault.sol";
import {IAsyncVault} from "./interfaces/IAsyncVault.sol";
import {IVaultRouter} from "./interfaces/IVaultRouter.sol";

import {Auth} from "../misc/Auth.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {IEscrow} from "../misc/interfaces/IEscrow.sol";
import {Multicall, IMulticall} from "../misc/Multicall.sol";
import {IERC7540Deposit} from "../misc/interfaces/IERC7540.sol";
import {IERC20, IERC20Permit} from "../misc/interfaces/IERC20.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {IGateway} from "../common/interfaces/IGateway.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {ISpoke, VaultDetails} from "../spoke/interfaces/ISpoke.sol";

/// @title  VaultRouter
/// @notice This is a helper contract, designed to be the entrypoint for EOAs.
///         It removes the need to know about all other contracts and simplifies the way to interact with the protocol.
///         It also adds the need to fully pay for each step of the transaction execution. VaultRouter allows
///         the caller to execute multiple function into a single transaction by taking advantage of
///         the multicall functionality which batches message calls into a single one.
/// @dev    It is critical to ensure that at the end of any transaction, no funds remain in the
///         VaultRouter. Any funds that do remain are at risk of being taken by other users.
contract VaultRouter is Auth, Multicall, Recoverable, IVaultRouter {
    using CastLib for address;

    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 private constant REQUEST_ID = 0;

    ISpoke public immutable spoke;
    IEscrow public immutable escrow;
    IGateway public immutable gateway;

    /// @inheritdoc IVaultRouter
    mapping(address controller => mapping(IBaseVault vault => uint256 amount)) public lockedRequests;

    constructor(address escrow_, IGateway gateway_, ISpoke spoke_, address deployer) Auth(deployer) {
        escrow = IEscrow(escrow_);
        gateway = gateway_;
        spoke = spoke_;
    }

    modifier payTransaction() {
        if (!gateway.isBatching()) {
            gateway.startTransactionPayment{value: msg.value}(msg.sender);
        }
        _;
        if (!gateway.isBatching()) {
            gateway.endTransactionPayment();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all message sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override(Multicall, IMulticall) {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatching();
            gateway.startTransactionPayment{value: msg.value}(msg.sender);
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.endBatching();
            gateway.endTransactionPayment();
        }
    }

    //----------------------------------------------------------------------------------------------
    // Enable interactions
    //----------------------------------------------------------------------------------------------

    function enable(IBaseVault vault) public payable protected {
        vault.setEndorsedOperator(msg.sender, true);
    }

    function disable(IBaseVault vault) external payable protected {
        vault.setEndorsedOperator(msg.sender, false);
    }

    //----------------------------------------------------------------------------------------------
    // Deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function requestDeposit(IAsyncVault vault, uint256 amount, address controller, address owner)
        external
        payable
        payTransaction
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
        if (owner == address(this)) {
            _approveMax(vaultDetails.asset, address(vault));
        }

        vault.requestDeposit(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function deposit(BaseSyncDepositVault vault, uint256 assets, address receiver, address owner)
        external
        payable
        payTransaction
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        require(!vault.supportsInterface(type(IERC7540Deposit).interfaceId), NonSyncDepositVault());

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
        if (owner != address(this)) SafeTransferLib.safeTransferFrom(vaultDetails.asset, owner, address(this), assets);
        _approveMax(vaultDetails.asset, address(vault));

        vault.deposit(assets, receiver);
    }

    /// @inheritdoc IVaultRouter
    function lockDepositRequest(IBaseVault vault, uint256 amount, address controller, address owner)
        public
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        require(vault.supportsInterface(type(IERC7540Deposit).interfaceId), NonAsyncVault());

        lockedRequests[controller][vault] += amount;

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
        SafeTransferLib.safeTransferFrom(vaultDetails.asset, owner, address(escrow), amount);

        emit LockDepositRequest(vault, controller, owner, msg.sender, amount);
    }

    /// @inheritdoc IVaultRouter
    function enableLockDepositRequest(IBaseVault vault, uint256 amount) external payable protected {
        enable(vault);
        lockDepositRequest(vault, amount, msg.sender, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function unlockDepositRequest(IBaseVault vault, address receiver) external payable protected {
        uint256 lockedRequest = lockedRequests[msg.sender][vault];
        require(lockedRequest != 0, NoLockedBalance());
        lockedRequests[msg.sender][vault] = 0;

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
        escrow.authTransferTo(vaultDetails.asset, 0, receiver, lockedRequest);

        emit UnlockDepositRequest(vault, msg.sender, receiver);
    }

    /// @inheritdoc IVaultRouter
    function executeLockedDepositRequest(IAsyncVault vault, address controller)
        external
        payable
        payTransaction
        protected
    {
        uint256 lockedRequest = lockedRequests[controller][vault];
        require(lockedRequest != 0, NoLockedRequest());
        lockedRequests[controller][vault] = 0;

        VaultDetails memory vaultDetails = spoke.vaultDetails(vault);
        escrow.authTransferTo(vaultDetails.asset, 0, address(this), lockedRequest);

        _approveMax(vaultDetails.asset, address(vault));
        vault.requestDeposit(lockedRequest, controller, address(this));
        emit ExecuteLockedDepositRequest(vault, controller, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimDeposit(IAsyncVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxMint = vault.maxMint(controller);

        spoke.vaultDetails(vault); // Ensure vault is valid
        vault.mint(maxMint, receiver, controller);
    }

    /// @inheritdoc IVaultRouter
    function cancelDepositRequest(IAsyncVault vault) external payable payTransaction protected {
        vault.cancelDepositRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimCancelDepositRequest(IAsyncVault vault, address receiver, address controller)
        external
        payable
        protected
    {
        _canClaim(vault, receiver, controller);
        vault.claimCancelDepositRequest(REQUEST_ID, receiver, controller);
    }

    //----------------------------------------------------------------------------------------------
    // Redeem
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function requestRedeem(IAsyncVault vault, uint256 amount, address controller, address owner)
        external
        payable
        payTransaction
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        vault.requestRedeem(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function claimRedeem(IBaseVault vault, address receiver, address controller)
        external
        payable
        payTransaction
        protected
    {
        _canClaim(vault, receiver, controller);
        uint256 maxWithdraw = vault.maxWithdraw(controller);

        spoke.vaultDetails(vault); // Ensure vault is valid
        vault.withdraw(maxWithdraw, receiver, controller);
    }

    /// @inheritdoc IVaultRouter
    function cancelRedeemRequest(IAsyncVault vault) external payable payTransaction protected {
        vault.cancelRedeemRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimCancelRedeemRequest(IAsyncVault vault, address receiver, address controller)
        external
        payable
        protected
    {
        _canClaim(vault, receiver, controller);
        vault.claimCancelRedeemRequest(REQUEST_ID, receiver, controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-20 permits
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function permit(address asset, address spender, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        protected
    {
        try IERC20Permit(asset).permit(msg.sender, spender, assets, deadline, v, r, s) {} catch {}
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function getVault(PoolId poolId, ShareClassId scId, address asset) external view returns (address) {
        return ISpoke(spoke).shareToken(poolId, scId).vault(asset);
    }

    /// @inheritdoc IVaultRouter
    function hasPermissions(IBaseVault vault, address controller) external view returns (bool) {
        return vault.isPermissioned(controller);
    }

    /// @inheritdoc IVaultRouter
    function isEnabled(IBaseVault vault, address controller) public view returns (bool) {
        return vault.isOperator(controller, address(this));
    }

    /// @notice Gives the max approval to `to` for spending the given `asset` if not already approved.
    /// @dev    Assumes that `type(uint256).max` is large enough to never have to increase the allowance again.
    function _approveMax(address asset, address spender) internal {
        if (IERC20(asset).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(asset, spender, type(uint256).max);
        }
    }

    /// @notice Ensures msg.sender is either the controller, or can permissionlessly claim
    ///         on behalf of the controller.
    function _canClaim(IBaseVault vault, address receiver, address controller) internal view {
        require(controller == msg.sender || (controller == receiver && isEnabled(vault, controller)), InvalidSender());
    }
}
