// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/vaults/libraries/SafeTransferLib.sol";
import {CastLib} from "src/vaults/libraries/CastLib.sol";
import {IERC20, IERC20Permit, IERC20Wrapper} from "src/misc/interfaces/IERC20.sol";
import {IERC7540Vault} from "src/vaults/interfaces/IERC7540.sol";
import {ICentrifugeRouter} from "src/vaults/interfaces/ICentrifugeRouter.sol";
import {IPoolManager, Domain} from "src/vaults/interfaces/IPoolManager.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IGateway} from "src/vaults/interfaces/gateway/IGateway.sol";
import {TransientStorage} from "src/vaults/libraries/TransientStorage.sol";
import {IRecoverable} from "src/vaults/interfaces/IRoot.sol";
import {ITransferProxy} from "src/vaults/interfaces/factories/ITransferProxy.sol";

/// @title  CentrifugeRouter
/// @notice This is a helper contract, designed to be the entrypoint for EOAs.
///         It removes the need to know about all other contracts and simplifies the way to interact with the protocol.
///         It also adds the need to fully pay for each step of the transaction execution. CentrifugeRouter allows
///         the caller to execute multiple function into a single transaction by taking advantage of
///         the multicall functionality which batches message calls into a single one.
/// @dev    It is critical to ensure that at the end of any transaction, no funds remain in the
///         CentrifugeRouter. Any funds that do remain are at risk of being taken by other users.
contract CentrifugeRouter is Auth, ICentrifugeRouter {
    using CastLib for address;
    using TransientStorage for bytes32;

    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 private constant REQUEST_ID = 0;

    bytes32 public constant INITIATOR_SLOT = bytes32(uint256(keccak256("Centrifuge/initiator")) - 1);

    IEscrow public immutable escrow;
    IGateway public immutable gateway;
    IPoolManager public immutable poolManager;

    /// @inheritdoc ICentrifugeRouter
    mapping(address controller => mapping(address vault => uint256 amount)) public lockedRequests;

    constructor(address escrow_, address gateway_, address poolManager_) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
        gateway = IGateway(gateway_);
        poolManager = IPoolManager(poolManager_);
    }

    modifier protected() {
        address currentInitiator = INITIATOR_SLOT.tloadAddress();
        if (currentInitiator == address(0)) {
            // Single call re-entrancy lock
            INITIATOR_SLOT.tstore(msg.sender);
            _;
            INITIATOR_SLOT.tstore(0);
        } else {
            // Multicall re-entrancy lock
            require(msg.sender == currentInitiator, "CentrifugeRouter/unauthorized-sender");
            _;
        }
    }

    // --- Administration ---
    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // --- Enable interactions with the vault ---
    function enable(address vault) public protected {
        IERC7540Vault(vault).setEndorsedOperator(msg.sender, true);
    }

    function disable(address vault) external protected {
        IERC7540Vault(vault).setEndorsedOperator(msg.sender, false);
    }

    // --- Deposit ---
    /// @inheritdoc ICentrifugeRouter
    function requestDeposit(address vault, uint256 amount, address controller, address owner, uint256 topUpAmount)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), "CentrifugeRouter/invalid-owner");

        (address asset,) = poolManager.getVaultAsset(vault);
        if (owner == address(this)) {
            _approveMax(asset, vault);
        }

        _pay(topUpAmount);
        IERC7540Vault(vault).requestDeposit(amount, controller, owner);
    }

    /// @inheritdoc ICentrifugeRouter
    function lockDepositRequest(address vault, uint256 amount, address controller, address owner)
        public
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), "CentrifugeRouter/invalid-owner");

        lockedRequests[controller][vault] += amount;
        (address asset,) = poolManager.getVaultAsset(vault);
        SafeTransferLib.safeTransferFrom(asset, owner, address(escrow), amount);

        emit LockDepositRequest(vault, controller, owner, msg.sender, amount);
    }

    /// @inheritdoc ICentrifugeRouter
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

    /// @inheritdoc ICentrifugeRouter
    function unlockDepositRequest(address vault, address receiver) external payable protected {
        uint256 lockedRequest = lockedRequests[msg.sender][vault];
        require(lockedRequest != 0, "CentrifugeRouter/no-locked-balance");
        lockedRequests[msg.sender][vault] = 0;

        (address asset,) = poolManager.getVaultAsset(vault);
        escrow.approveMax(asset, address(this));
        SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, lockedRequest);

        emit UnlockDepositRequest(vault, msg.sender, receiver);
    }

    /// @inheritdoc ICentrifugeRouter
    function executeLockedDepositRequest(address vault, address controller, uint256 topUpAmount)
        external
        payable
        protected
    {
        uint256 lockedRequest = lockedRequests[controller][vault];
        require(lockedRequest != 0, "CentrifugeRouter/no-locked-request");
        lockedRequests[controller][vault] = 0;

        (address asset,) = poolManager.getVaultAsset(vault);

        escrow.approveMax(asset, address(this));
        SafeTransferLib.safeTransferFrom(asset, address(escrow), address(this), lockedRequest);

        _pay(topUpAmount);
        _approveMax(asset, vault);
        IERC7540Vault(vault).requestDeposit(lockedRequest, controller, address(this));
        emit ExecuteLockedDepositRequest(vault, controller, msg.sender);
    }

    /// @inheritdoc ICentrifugeRouter
    function claimDeposit(address vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxMint = IERC7540Vault(vault).maxMint(controller);
        IERC7540Vault(vault).mint(maxMint, receiver, controller);
    }

    /// @inheritdoc ICentrifugeRouter
    function cancelDepositRequest(address vault, uint256 topUpAmount) external payable protected {
        _pay(topUpAmount);
        IERC7540Vault(vault).cancelDepositRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc ICentrifugeRouter
    function claimCancelDepositRequest(address vault, address receiver, address controller)
        external
        payable
        protected
    {
        _canClaim(vault, receiver, controller);
        IERC7540Vault(vault).claimCancelDepositRequest(REQUEST_ID, receiver, controller);
    }

    // --- Redeem ---
    /// @inheritdoc ICentrifugeRouter
    function requestRedeem(address vault, uint256 amount, address controller, address owner, uint256 topUpAmount)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), "CentrifugeRouter/invalid-owner");
        _pay(topUpAmount);
        IERC7540Vault(vault).requestRedeem(amount, controller, owner);
    }

    /// @inheritdoc ICentrifugeRouter
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

    /// @inheritdoc ICentrifugeRouter
    function cancelRedeemRequest(address vault, uint256 topUpAmount) external payable protected {
        _pay(topUpAmount);
        IERC7540Vault(vault).cancelRedeemRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc ICentrifugeRouter
    function claimCancelRedeemRequest(address vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        IERC7540Vault(vault).claimCancelRedeemRequest(REQUEST_ID, receiver, controller);
    }

    // --- Transfer ---
    /// @inheritdoc ICentrifugeRouter
    function transferAssets(address asset, bytes32 recipient, uint128 amount, uint256 topUpAmount)
        public
        payable
        protected
    {
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amount);
        _approveMax(asset, address(poolManager));
        _pay(topUpAmount);
        poolManager.transferAssets(asset, recipient, amount);
    }

    /// @inheritdoc ICentrifugeRouter
    function transferAssets(address asset, address recipient, uint128 amount, uint256 topUpAmount)
        external
        payable
        protected
    {
        transferAssets(asset, recipient.toBytes32(), amount, topUpAmount);
    }

    /// @inheritdoc ICentrifugeRouter
    function transferAssetsFromProxy(address transferProxy, address asset, uint256 topUpAmount)
        external
        payable
        protected
    {
        _pay(topUpAmount);
        ITransferProxy(transferProxy).transfer(asset);
    }

    /// @inheritdoc ICentrifugeRouter
    function transferTrancheTokens(
        address vault,
        Domain domain,
        uint64 chainId,
        bytes32 recipient,
        uint128 amount,
        uint256 topUpAmount
    ) public payable protected {
        SafeTransferLib.safeTransferFrom(IERC7540Vault(vault).share(), msg.sender, address(this), amount);
        _approveMax(IERC7540Vault(vault).share(), address(poolManager));
        _pay(topUpAmount);
        IPoolManager(poolManager).transferTrancheTokens(
            IERC7540Vault(vault).poolId(), IERC7540Vault(vault).trancheId(), domain, chainId, recipient, amount
        );
    }

    /// @inheritdoc ICentrifugeRouter
    function transferTrancheTokens(
        address vault,
        Domain domain,
        uint64 chainId,
        address recipient,
        uint128 amount,
        uint256 topUpAmount
    ) external payable protected {
        transferTrancheTokens(vault, domain, chainId, recipient.toBytes32(), amount, topUpAmount);
    }

    // --- ERC20 permits ---
    /// @inheritdoc ICentrifugeRouter
    function permit(address asset, address spender, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        protected
    {
        try IERC20Permit(asset).permit(msg.sender, spender, assets, deadline, v, r, s) {} catch {}
    }

    // --- ERC20 wrapping ---
    function wrap(address wrapper, uint256 amount, address receiver, address owner) public payable protected {
        require(owner == msg.sender || owner == address(this), "CentrifugeRouter/invalid-owner");
        address underlying = IERC20Wrapper(wrapper).underlying();

        amount = MathLib.min(amount, IERC20(underlying).balanceOf(owner));
        require(amount != 0, "CentrifugeRouter/zero-balance");
        SafeTransferLib.safeTransferFrom(underlying, owner, address(this), amount);

        _approveMax(underlying, wrapper);
        require(IERC20Wrapper(wrapper).depositFor(receiver, amount), "CentrifugeRouter/wrap-failed");
    }

    function unwrap(address wrapper, uint256 amount, address receiver) public payable protected {
        amount = MathLib.min(amount, IERC20(wrapper).balanceOf(address(this)));
        require(amount != 0, "CentrifugeRouter/zero-balance");

        require(IERC20Wrapper(wrapper).withdrawTo(receiver, amount), "CentrifugeRouter/unwrap-failed");
    }

    // --- Batching ---
    /// @inheritdoc ICentrifugeRouter
    function multicall(bytes[] memory data) external payable {
        require(INITIATOR_SLOT.tloadAddress() == address(0), "CentrifugeRouter/already-initiated");

        INITIATOR_SLOT.tstore(msg.sender);
        uint256 totalBytes = data.length;
        for (uint256 i; i < totalBytes; ++i) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                uint256 length = returnData.length;
                require(length != 0, "CentrifugeRouter/call-failed");

                assembly ("memory-safe") {
                    revert(add(32, returnData), length)
                }
            }
        }
        INITIATOR_SLOT.tstore(0);
    }

    // --- View Methods ---
    /// @inheritdoc ICentrifugeRouter
    function getVault(uint64 poolId, bytes16 trancheId, address asset) external view returns (address) {
        return ITranche(IPoolManager(poolManager).getTranche(poolId, trancheId)).vault(asset);
    }

    /// @inheritdoc ICentrifugeRouter
    function estimate(bytes calldata payload) external view returns (uint256 amount) {
        (, amount) = IGateway(gateway).estimate(payload);
    }

    /// @inheritdoc ICentrifugeRouter
    function hasPermissions(address vault, address controller) external view returns (bool) {
        return IERC7540Vault(vault).isPermissioned(controller);
    }

    /// @inheritdoc ICentrifugeRouter
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

    /// @notice Send native tokens to the gateway for transaction payment.
    function _pay(uint256 amount) internal {
        require(amount <= address(this).balance, "CentrifugeRouter/insufficient-funds");
        gateway.topUp{value: amount}();
    }

    /// @notice Ensures msg.sender is either the controller, or can permissionlessly claim
    ///         on behalf of the controller.
    function _canClaim(address vault, address receiver, address controller) internal view {
        require(
            controller == msg.sender || (controller == receiver && isEnabled(vault, controller)),
            "CentrifugeRouter/invalid-sender"
        );
    }
}
