// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBaseVault} from "./interfaces/IBaseVault.sol";
import {IAsyncRedeemVault} from "./interfaces/IAsyncVault.sol";
import {IAsyncRedeemManager} from "./interfaces/IVaultManagers.sol";
import {ISyncDepositManager} from "./interfaces/IVaultManagers.sol";
import {IBaseRequestManager} from "./interfaces/IBaseRequestManager.sol";

import {Auth} from "../misc/Auth.sol";
import "../misc/interfaces/IERC7540.sol";
import "../misc/interfaces/IERC7575.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {IERC7575} from "../misc/interfaces/IERC7575.sol";
import {EIP712Lib} from "../misc/libraries/EIP712Lib.sol";
import {IERC20Metadata} from "../misc/interfaces/IERC20.sol";
import {SignatureLib} from "../misc/libraries/SignatureLib.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {IRoot} from "../common/interfaces/IRoot.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {IVault} from "../spoke/interfaces/IVaultManager.sol";
import {IShareToken} from "../spoke/interfaces/IShareToken.sol";
import {IVaultManager} from "../spoke/interfaces/IVaultManager.sol";

abstract contract BaseVault is Auth, Recoverable, IBaseVault {
    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    IRoot public immutable root;
    IBaseRequestManager public baseManager;

    /// @inheritdoc IVault
    PoolId public immutable poolId;
    /// @inheritdoc IVault
    ShareClassId public immutable scId;

    /// @inheritdoc IERC7575
    address public immutable asset;

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

    constructor(
        PoolId poolId_,
        ShareClassId scId_,
        address asset_,
        IShareToken token_,
        address root_,
        IBaseRequestManager manager_
    ) Auth(msg.sender) {
        poolId = poolId_;
        scId = scId_;
        asset = asset_;
        share = address(token_);
        _shareDecimals = IERC20Metadata(share).decimals();
        root = IRoot(root_);
        baseManager = IBaseRequestManager(manager_);

        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        deploymentChainId = block.chainid;
        _DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external virtual auth {
        if (what == "manager") baseManager = IBaseRequestManager(data);
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

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IERC7540Operator).interfaceId || interfaceId == type(IERC7741).interfaceId
            || interfaceId == type(IERC7714).interfaceId || interfaceId == type(IERC7575).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-4626
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function totalAssets() external view returns (uint256) {
        return convertToAssets(IERC20Metadata(share).totalSupply());
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        shares = baseManager.convertToShares(this, assets);
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        assets = baseManager.convertToAssets(this, shares);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function manager() public view returns (IVaultManager) {
        return baseManager;
    }

    /// @notice Price of 1 unit of share, quoted in the decimals of the asset.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** _shareDecimals);
    }

    /// @notice Returns timestamp of the last share price update.
    function priceLastUpdated() external view returns (uint64) {
        return baseManager.priceLastUpdated(this);
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

abstract contract BaseAsyncRedeemVault is BaseVault, IAsyncRedeemVault {
    IAsyncRedeemManager public asyncRedeemManager;

    constructor(IAsyncRedeemManager asyncRequestManager_) {
        asyncRedeemManager = asyncRequestManager_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external virtual override auth {
        if (what == "manager") baseManager = IBaseRequestManager(data);
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

        require(asyncRedeemManager.requestRedeem(this, shares, controller, owner, sender, true), RequestRedeemFailed());

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
        emit CancelRedeemClaim(controller, receiver, REQUEST_ID, msg.sender, shares);
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

    constructor(ISyncDepositManager syncManager_) {
        syncDepositManager = syncManager_;
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
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(baseManager.poolEscrow(poolId)), assets);
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
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(baseManager.poolEscrow(poolId)), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual override(BaseVault) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
