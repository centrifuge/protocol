// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC20, IERC20Permit, IERC20Wrapper} from "src/misc/interfaces/IERC20.sol";
import {IERC7540Deposit} from "src/misc/interfaces/IERC7540.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMessageDispatcher} from "src/common/interfaces/IMessageDispatcher.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IAsyncVault, IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {IVaultRouter} from "src/vaults/interfaces/IVaultRouter.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {BaseSyncDepositVault} from "src/vaults/BaseVaults.sol";

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

    IEscrow public immutable escrow;
    IGateway public immutable gateway;
    IPoolManager public immutable poolManager;
    IMessageDispatcher public immutable messageDispatcher;

    /// @inheritdoc IVaultRouter
    mapping(address controller => mapping(IBaseVault vault => uint256 amount)) public lockedRequests;

    constructor(
        address escrow_,
        IGateway gateway_,
        IPoolManager poolManager_,
        IMessageDispatcher messageDispatcher_,
        address deployer
    ) Auth(deployer) {
        escrow = IEscrow(escrow_);
        gateway = gateway_;
        poolManager = poolManager_;
        messageDispatcher = messageDispatcher_;
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
            gateway.payTransaction{value: msg.value}(msg.sender);
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.endBatching();
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
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        if (owner == address(this)) {
            _approveMax(vaultDetails.asset, address(vault));
        }

        _pay();
        vault.requestDeposit(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function deposit(BaseSyncDepositVault vault, uint256 assets, address receiver, address owner)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        require(!vault.supportsInterface(type(IERC7540Deposit).interfaceId), NonSyncDepositVault());

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        SafeTransferLib.safeTransferFrom(vaultDetails.asset, owner, address(this), assets);
        _approveMax(vaultDetails.asset, address(vault));

        _pay();
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

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        SafeTransferLib.safeTransferFrom(vaultDetails.asset, owner, address(escrow), amount);

        emit LockDepositRequest(vault, controller, owner, msg.sender, amount);
    }

    /// @inheritdoc IVaultRouter
    function enableLockDepositRequest(IBaseVault vault, uint256 amount) external payable protected {
        enable(vault);

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);

        uint256 assetBalance;
        assetBalance = IERC20(vaultDetails.asset).balanceOf(msg.sender);

        if (vaultDetails.isWrapper && assetBalance < amount) {
            wrap(vaultDetails.asset, amount, address(this), msg.sender);
            lockDepositRequest(vault, amount, msg.sender, address(this));
        } else {
            lockDepositRequest(vault, amount, msg.sender, msg.sender);
        }
    }

    /// @inheritdoc IVaultRouter
    function unlockDepositRequest(IBaseVault vault, address receiver) external payable protected {
        uint256 lockedRequest = lockedRequests[msg.sender][vault];
        require(lockedRequest != 0, NoLockedBalance());
        lockedRequests[msg.sender][vault] = 0;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        escrow.authTransferTo(vaultDetails.asset, receiver, lockedRequest);

        emit UnlockDepositRequest(vault, msg.sender, receiver);
    }

    /// @inheritdoc IVaultRouter
    function executeLockedDepositRequest(IAsyncVault vault, address controller) external payable protected {
        uint256 lockedRequest = lockedRequests[controller][vault];
        require(lockedRequest != 0, NoLockedRequest());
        lockedRequests[controller][vault] = 0;

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        escrow.authTransferTo(vaultDetails.asset, address(this), lockedRequest);

        _pay();
        _approveMax(vaultDetails.asset, address(vault));
        vault.requestDeposit(lockedRequest, controller, address(this));
        emit ExecuteLockedDepositRequest(vault, controller, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimDeposit(IAsyncVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxMint = vault.maxMint(controller);
        vault.mint(maxMint, receiver, controller);
    }

    /// @inheritdoc IVaultRouter
    function cancelDepositRequest(IAsyncVault vault) external payable protected {
        _pay();
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
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        _pay();
        vault.requestRedeem(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function claimRedeem(IBaseVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxWithdraw = vault.maxWithdraw(controller);

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);
        if (vaultDetails.isWrapper && controller != msg.sender) {
            // Auto-unwrap if permissionlessly claiming for another controller
            vault.withdraw(maxWithdraw, address(this), controller);
            unwrap(vaultDetails.asset, maxWithdraw, receiver);
        } else {
            vault.withdraw(maxWithdraw, receiver, controller);
        }
    }

    /// @inheritdoc IVaultRouter
    function cancelRedeemRequest(IAsyncVault vault) external payable protected {
        _pay();
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
    // ERC-20 permits & wrapping
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function permit(address asset, address spender, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        protected
    {
        try IERC20Permit(asset).permit(msg.sender, spender, assets, deadline, v, r, s) {} catch {}
    }

    function wrap(address wrapper, uint256 amount, address receiver, address owner) public payable protected {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        address underlying = IERC20Wrapper(wrapper).underlying();

        amount = MathLib.min(amount, IERC20(underlying).balanceOf(owner));
        require(amount != 0, ZeroBalance());
        SafeTransferLib.safeTransferFrom(underlying, owner, address(this), amount);

        _approveMax(underlying, wrapper);
        require(IERC20Wrapper(wrapper).depositFor(receiver, amount), WrapFailed());
    }

    function unwrap(address wrapper, uint256 amount, address receiver) public payable protected {
        amount = MathLib.min(amount, IERC20(wrapper).balanceOf(address(this)));
        require(amount != 0, ZeroBalance());

        require(IERC20Wrapper(wrapper).withdrawTo(receiver, amount), UnwrapFailed());
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function getVault(PoolId poolId, ShareClassId scId, address asset) external view returns (address) {
        return IPoolManager(poolManager).shareToken(poolId, scId).vault(asset);
    }

    /// @inheritdoc IVaultRouter
    function estimate(uint16 centrifugeId, bytes calldata payload) external view returns (uint256) {
        return messageDispatcher.estimate(centrifugeId, payload);
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

    /// @notice Send native tokens to the gateway for transaction payment if it's not in a multicall.
    function _pay() internal {
        if (!gateway.isBatching()) {
            gateway.payTransaction{value: msg.value}(msg.sender);
        }
    }

    /// @notice Ensures msg.sender is either the controller, or can permissionlessly claim
    ///         on behalf of the controller.
    function _canClaim(IBaseVault vault, address receiver, address controller) internal view {
        require(controller == msg.sender || (controller == receiver && isEnabled(vault, controller)), InvalidSender());
    }
}
