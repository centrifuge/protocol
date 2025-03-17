// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC20, IERC20Permit, IERC20Wrapper} from "src/misc/interfaces/IERC20.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";

import {IERC7540Vault} from "src/vaults/interfaces/IERC7540.sol";
import {IVaultRouter} from "src/vaults/interfaces/IVaultRouter.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";

/// @title  VaultRouter
/// @notice This is a helper contract, designed to be the entrypoint for EOAs.
///         It removes the need to know about all other contracts and simplifies the way to interact with the protocol.
///         It also adds the need to fully pay for each step of the transaction execution. VaultRouter allows
///         the caller to execute multiple function into a single transaction by taking advantage of
///         the multicall functionality which batches message calls into a single one.
/// @dev    It is critical to ensure that at the end of any transaction, no funds remain in the
///         VaultRouter. Any funds that do remain are at risk of being taken by other users.
contract VaultRouter is Auth, Multicall, IVaultRouter {
    using CastLib for address;

    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 private constant REQUEST_ID = 0;

    IEscrow public immutable escrow;
    IGateway public immutable gateway;
    IPoolManager public immutable poolManager;

    /// @inheritdoc IVaultRouter
    mapping(address controller => mapping(address vault => uint256 amount)) public lockedRequests;

    constructor(address escrow_, address gateway_, address poolManager_) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
        gateway = IGateway(gateway_);
        poolManager = IPoolManager(poolManager_);
    }

    // --- Administration ---
    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all message sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override(Multicall, IMulticall) {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatch();
        }

        super.multicall(data);

        if (!wasBatching) {
            gateway.topUp{value: msg.value}();
            gateway.endBatch();
        }
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Enable interactions with the vault ---
    function enable(address vault) public payable protected {
        IERC7540Vault(vault).setEndorsedOperator(msg.sender, true);
    }

    function disable(address vault) external payable protected {
        IERC7540Vault(vault).setEndorsedOperator(msg.sender, false);
    }

    // --- Deposit ---
    /// @inheritdoc IVaultRouter
    function requestDeposit(address vault, uint256 amount, address controller, address owner)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), "VaultRouter/invalid-owner");

        (address asset,) = poolManager.getVaultAsset(vault);
        if (owner == address(this)) {
            _approveMax(asset, vault);
        }

        IERC7540Vault(vault).requestDeposit(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function lockDepositRequest(address vault, uint256 amount, address controller, address owner)
        public
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), "VaultRouter/invalid-owner");

        lockedRequests[controller][vault] += amount;
        (address asset,) = poolManager.getVaultAsset(vault);
        SafeTransferLib.safeTransferFrom(asset, owner, address(escrow), amount);

        emit LockDepositRequest(vault, controller, owner, msg.sender, amount);
    }

    /// @inheritdoc IVaultRouter
    function enableLockDepositRequest(address vault, uint256 amount) external payable protected {
        enable(vault);

        (address asset, bool isWrapper) = poolManager.getVaultAsset(vault);
        uint256 assetBalance = IERC20(asset).balanceOf(msg.sender);
        if (isWrapper && assetBalance < amount) {
            wrap(asset, amount, address(this), msg.sender);
            lockDepositRequest(vault, amount, msg.sender, address(this));
        } else {
            lockDepositRequest(vault, amount, msg.sender, msg.sender);
        }
    }

    /// @inheritdoc IVaultRouter
    function unlockDepositRequest(address vault, address receiver) external payable protected {
        uint256 lockedRequest = lockedRequests[msg.sender][vault];
        require(lockedRequest != 0, "VaultRouter/no-locked-balance");
        lockedRequests[msg.sender][vault] = 0;

        (address asset,) = poolManager.getVaultAsset(vault);
        escrow.approveMax(asset, address(this));
        SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, lockedRequest);

        emit UnlockDepositRequest(vault, msg.sender, receiver);
    }

    /// @inheritdoc IVaultRouter
    function executeLockedDepositRequest(address vault, address controller) external payable protected {
        uint256 lockedRequest = lockedRequests[controller][vault];
        require(lockedRequest != 0, "VaultRouter/no-locked-request");
        lockedRequests[controller][vault] = 0;

        (address asset,) = poolManager.getVaultAsset(vault);

        escrow.approveMax(asset, address(this));
        SafeTransferLib.safeTransferFrom(asset, address(escrow), address(this), lockedRequest);

        _approveMax(asset, vault);
        IERC7540Vault(vault).requestDeposit(lockedRequest, controller, address(this));
        emit ExecuteLockedDepositRequest(vault, controller, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimDeposit(address vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxMint = IERC7540Vault(vault).maxMint(controller);
        IERC7540Vault(vault).mint(maxMint, receiver, controller);
    }

    /// @inheritdoc IVaultRouter
    function cancelDepositRequest(address vault) external payable protected {
        IERC7540Vault(vault).cancelDepositRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimCancelDepositRequest(address vault, address receiver, address controller)
        external
        payable
        protected
    {
        _canClaim(vault, receiver, controller);
        IERC7540Vault(vault).claimCancelDepositRequest(REQUEST_ID, receiver, controller);
    }

    // --- Redeem ---
    /// @inheritdoc IVaultRouter
    function requestRedeem(address vault, uint256 amount, address controller, address owner)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), "VaultRouter/invalid-owner");
        IERC7540Vault(vault).requestRedeem(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function claimRedeem(address vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxWithdraw = IERC7540Vault(vault).maxWithdraw(controller);

        (address asset, bool isWrapper) = poolManager.getVaultAsset(vault);
        if (isWrapper && controller != msg.sender) {
            // Auto-unwrap if permissionlessly claiming for another controller
            IERC7540Vault(vault).withdraw(maxWithdraw, address(this), controller);
            unwrap(asset, maxWithdraw, receiver);
        } else {
            IERC7540Vault(vault).withdraw(maxWithdraw, receiver, controller);
        }
    }

    /// @inheritdoc IVaultRouter
    function cancelRedeemRequest(address vault) external payable protected {
        IERC7540Vault(vault).cancelRedeemRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimCancelRedeemRequest(address vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        IERC7540Vault(vault).claimCancelRedeemRequest(REQUEST_ID, receiver, controller);
    }

    // --- Transfer ---
    /// @inheritdoc IVaultRouter
    function transferTrancheTokens(address vault, uint32 chainId, bytes32 recipient, uint128 amount)
        public
        payable
        protected
    {
        SafeTransferLib.safeTransferFrom(IERC7540Vault(vault).share(), msg.sender, address(this), amount);
        _approveMax(IERC7540Vault(vault).share(), address(poolManager));
        IPoolManager(poolManager).transferTrancheTokens(
            IERC7540Vault(vault).poolId(), IERC7540Vault(vault).trancheId(), chainId, recipient, amount
        );
    }

    /// @inheritdoc IVaultRouter
    function transferTrancheTokens(address vault, uint32 chainId, address recipient, uint128 amount)
        external
        payable
        protected
    {
        transferTrancheTokens(vault, chainId, recipient.toBytes32(), amount);
    }

    // --- ERC20 permits ---
    /// @inheritdoc IVaultRouter
    function permit(address asset, address spender, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        protected
    {
        try IERC20Permit(asset).permit(msg.sender, spender, assets, deadline, v, r, s) {} catch {}
    }

    // --- ERC20 wrapping ---
    function wrap(address wrapper, uint256 amount, address receiver, address owner) public payable protected {
        require(owner == msg.sender || owner == address(this), "VaultRouter/invalid-owner");
        address underlying = IERC20Wrapper(wrapper).underlying();

        amount = MathLib.min(amount, IERC20(underlying).balanceOf(owner));
        require(amount != 0, "VaultRouter/zero-balance");
        SafeTransferLib.safeTransferFrom(underlying, owner, address(this), amount);

        _approveMax(underlying, wrapper);
        require(IERC20Wrapper(wrapper).depositFor(receiver, amount), "VaultRouter/wrap-failed");
    }

    function unwrap(address wrapper, uint256 amount, address receiver) public payable protected {
        amount = MathLib.min(amount, IERC20(wrapper).balanceOf(address(this)));
        require(amount != 0, "VaultRouter/zero-balance");

        require(IERC20Wrapper(wrapper).withdrawTo(receiver, amount), "VaultRouter/unwrap-failed");
    }

    // --- View Methods ---
    /// @inheritdoc IVaultRouter
    function getVault(uint64 poolId, bytes16 trancheId, address asset) external view returns (address) {
        return ITranche(IPoolManager(poolManager).getTranche(poolId, trancheId)).vault(asset);
    }

    /// @inheritdoc IVaultRouter
    function estimate(uint32 chainId, bytes calldata payload) external view returns (uint256 amount) {
        (, amount) = IGateway(gateway).estimate(chainId, payload);
    }

    /// @inheritdoc IVaultRouter
    function hasPermissions(address vault, address controller) external view returns (bool) {
        return IERC7540Vault(vault).isPermissioned(controller);
    }

    /// @inheritdoc IVaultRouter
    function isEnabled(address vault, address controller) public view returns (bool) {
        return IERC7540Vault(vault).isOperator(controller, address(this));
    }

    /// @notice Gives the max approval to `to` to spend the given `asset` if not already approved.
    /// @dev    Assumes that `type(uint256).max` is large enough to never have to increase the allowance again.
    function _approveMax(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(token, spender, type(uint256).max);
        }
    }

    /// @notice Ensures msg.sender is either the controller, or can permissionlessly claim
    ///         on behalf of the controller.
    function _canClaim(address vault, address receiver, address controller) internal view {
        require(
            controller == msg.sender || (controller == receiver && isEnabled(vault, controller)),
            "VaultRouter/invalid-sender"
        );
    }
}
