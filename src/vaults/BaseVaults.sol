// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {EIP712Lib} from "src/misc/libraries/EIP712Lib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SignatureLib} from "src/misc/libraries/SignatureLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";

import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {IERC7575} from "src/vaults/interfaces/IERC7575.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncRedeemVault} from "src/vaults/interfaces/IERC7540.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

abstract contract BaseVault is Auth, Recoverable, IBaseVault {
    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    IRoot public immutable root;
    IBaseInvestmentManager public manager;
    /// @dev NOTE: MUST NOT BE USED EXTERNALLY IN PRODUCTION.
    /// @dev Not backwards compatible with legacy v2 vaults which rely escrow retrieval via asyncRequests.escrow()
    /// @dev To save gas, v3 vaults rely on poolEscrowProvider.escrow(poolId)
    IPoolEscrowProvider internal _poolEscrowProvider;

    /// @inheritdoc IBaseVault
    uint64 public immutable poolId;
    /// @inheritdoc IBaseVault
    bytes16 public immutable trancheId;

    /// @inheritdoc IERC7575
    address public immutable asset;
    /// @dev NOTE: MUST NOT BE USED EXTERNALLY IN PRODUCTION.
    /// @dev Not backwards compatible with legacy v2 vaults. Instead, refer to poolManager.vaultDetails(vault).
    uint256 internal immutable tokenId;

    /// @inheritdoc IERC7575
    address public immutable share;
    uint8 internal immutable _shareDecimals;

    /// --- ERC7741 ---
    bytes32 private immutable nameHash;
    bytes32 private immutable versionHash;
    uint256 public immutable deploymentChainId;
    bytes32 private immutable _DOMAIN_SEPARATOR;
    bytes32 public constant AUTHORIZE_OPERATOR_TYPEHASH =
        keccak256("AuthorizeOperator(address controller,address operator,bool approved,bytes32 nonce,uint256 deadline)");

    /// @inheritdoc IERC7741
    mapping(address controller => mapping(bytes32 nonce => bool used)) public authorizations;

    /// @inheritdoc IERC7540Operator
    mapping(address => mapping(address => bool)) public isOperator;

    // --- Events ---
    event File(bytes32 indexed what, address data);

    constructor(
        uint64 poolId_,
        bytes16 scId_,
        address asset_,
        uint256 tokenId_,
        address token_,
        address root_,
        address manager_,
        IPoolEscrowProvider poolEscrowProvider_
    ) Auth(msg.sender) {
        poolId = poolId_;
        trancheId = scId_;
        asset = asset_;
        tokenId = tokenId_;
        share = token_;
        _shareDecimals = IERC20Metadata(share).decimals();
        root = IRoot(root_);
        // TODO: Redundant due to filing?
        manager = IBaseInvestmentManager(manager_);
        _poolEscrowProvider = poolEscrowProvider_;

        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        deploymentChainId = block.chainid;
        _DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "manager") manager = IBaseInvestmentManager(data);
        /// @dev NOT supported in legacy v2 vaults
        else if (what == "poolEscrowProvider") _poolEscrowProvider = IPoolEscrowProvider(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) public virtual returns (bool success) {
        require(msg.sender != operator, CannotSetSelfAsOperator());
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    /// @inheritdoc IBaseVault
    function setEndorsedOperator(address owner, bool approved) public virtual {
        require(msg.sender != owner, CannotSetSelfAsOperator());
        require(root.endorsed(msg.sender), NotEndorsed());
        isOperator[owner][msg.sender] = approved;
        emit OperatorSet(owner, msg.sender, approved);
    }

    /// @inheritdoc IERC7741
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == deploymentChainId
            ? _DOMAIN_SEPARATOR
            : EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    /// @inheritdoc IERC7741
    function authorizeOperator(
        address controller,
        address operator,
        bool approved,
        bytes32 nonce,
        uint256 deadline,
        bytes memory signature
    ) external returns (bool success) {
        require(controller != operator, CannotSetSelfAsOperator());
        require(block.timestamp <= deadline, ExpiredAuthorization());
        require(!authorizations[controller][nonce], AlreadyUsedAuthorization());

        authorizations[controller][nonce] = true;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(AUTHORIZE_OPERATOR_TYPEHASH, controller, operator, approved, nonce, deadline))
            )
        );

        require(SignatureLib.isValidSignature(controller, digest, signature), InvalidAuthorization());

        isOperator[controller][operator] = approved;
        emit OperatorSet(controller, operator, approved);

        success = true;
    }

    /// @inheritdoc IERC7741
    function invalidateNonce(bytes32 nonce) external {
        authorizations[msg.sender][nonce] = true;
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IERC7540Operator).interfaceId || interfaceId == type(IERC7741).interfaceId
            || interfaceId == type(IERC7714).interfaceId || interfaceId == type(IERC7575).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function totalAssets() external view returns (uint256) {
        return convertToAssets(IERC20Metadata(share).totalSupply());
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        shares = manager.convertToShares(address(this), assets);
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        assets = manager.convertToAssets(address(this), shares);
    }

    // --- Helpers ---
    /// @notice Price of 1 unit of share, quoted in the decimals of the asset.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** _shareDecimals);
    }

    /// @notice Returns timestamp of the last share price update.
    function priceLastUpdated() external view returns (uint64) {
        return manager.priceLastUpdated(address(this));
    }

    /// @inheritdoc IERC7714
    function isPermissioned(address controller) external view returns (bool) {
        return IShareToken(share).checkTransferRestriction(address(0), controller, 0);
    }

    /// @notice Ensures msg.sender can operate on behalf of controller.
    function _validateController(address controller) internal view {
        require(controller == msg.sender || isOperator[controller][msg.sender], InvalidController());
    }
}

abstract contract AsyncRedeemVault is BaseVault, IAsyncRedeemVault {
    IAsyncRedeemManager public asyncRedeemManager;

    constructor(address asyncRequests_) {
        asyncRedeemManager = IAsyncRedeemManager(asyncRequests_);
    }

    // --- ERC-7540 methods ---
    /// @inheritdoc IERC7540Redeem
    function requestRedeem(uint256 shares, address controller, address owner) public returns (uint256) {
        require(IShareToken(share).balanceOf(owner) >= shares, InsufficientBalance());

        // If msg.sender is operator of owner, the transfer is executed as if
        // the sender is the owner, to bypass the allowance check
        address sender = isOperator[owner][msg.sender] ? owner : msg.sender;

        require(
            asyncRedeemManager.requestRedeem(address(this), shares, controller, owner, sender), RequestRedeemFailed()
        );

        address escrow = address(_poolEscrowProvider.escrow(poolId));
        try IShareToken(share).authTransferFrom(sender, owner, escrow, shares) returns (bool) {}
        catch {
            // Support share class tokens that block authTransferFrom. In this case ERC20 approval needs to be set
            require(IShareToken(share).transferFrom(owner, escrow, shares), TransferFromFailed());
        }

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256, address controller) public view returns (uint256 pendingShares) {
        pendingShares = asyncRedeemManager.pendingRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 claimableShares) {
        claimableShares = maxRedeem(controller);
    }

    // --- Asynchronous cancellation methods ---
    /// @inheritdoc IERC7540CancelRedeem
    function cancelRedeemRequest(uint256, address controller) external {
        _validateController(controller);
        asyncRedeemManager.cancelRedeemRequest(address(this), controller, msg.sender);
        emit CancelRedeemRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function pendingCancelRedeemRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = asyncRedeemManager.pendingCancelRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimableCancelRedeemRequest(uint256, address controller) public view returns (uint256 claimableShares) {
        claimableShares = asyncRedeemManager.claimableCancelRedeemRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelRedeem
    function claimCancelRedeemRequest(uint256, address receiver, address controller)
        external
        returns (uint256 shares)
    {
        _validateController(controller);
        shares = asyncRedeemManager.claimCancelRedeemRequest(address(this), receiver, controller);
        emit CancelRedeemClaim(receiver, controller, REQUEST_ID, msg.sender, shares);
    }

    // --- Synchronous redeem methods ---
    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem
    function withdraw(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = asyncRedeemManager.withdraw(address(this), assets, receiver, controller);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    /// @notice     DOES NOT support controller != msg.sender since shares are already transferred on requestRedeem.
    ///             When claiming redemption requests using redeem(), there can be some precision loss leading to dust.
    ///             It is recommended to use withdraw() to claim redemption requests instead.
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _validateController(controller);
        assets = asyncRedeemManager.redeem(address(this), shares, receiver, controller);
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
        return super.supportsInterface(interfaceId) || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540CancelRedeem).interfaceId;
    }

    /// @inheritdoc IERC7575
    function maxWithdraw(address controller) public view returns (uint256 maxAssets) {
        maxAssets = asyncRedeemManager.maxWithdraw(address(this), controller);
    }

    /// @inheritdoc IERC7575
    function maxRedeem(address controller) public view returns (uint256 maxShares) {
        maxShares = asyncRedeemManager.maxRedeem(address(this), controller);
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

    constructor(address syncRequests_) {
        syncDepositManager = ISyncDepositManager(syncRequests_);
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = syncDepositManager.maxDeposit(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        shares = syncDepositManager.previewDeposit(address(this), msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = syncDepositManager.deposit(address(this), assets, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = syncDepositManager.maxMint(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = syncDepositManager.previewMint(address(this), msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = syncDepositManager.mint(address(this), shares, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override(BaseVault) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
