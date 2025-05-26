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

import {IBaseVault} from "src/spoke/interfaces/IBaseVault.sol";
import {IERC7575} from "src/misc/interfaces/IERC7575.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseRequestManager} from "src/spoke/interfaces/IBaseRequestManager.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

abstract contract BaseVault is Auth, Recoverable, IBaseVault {
    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    IRoot public immutable root;
    /// @dev this naming MUST NEVER change - due to legacy v2 vaults
    IBaseRequestManager public manager;

    /// @inheritdoc IBaseVault
    PoolId public immutable poolId;
    /// @inheritdoc IBaseVault
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
        manager = IBaseRequestManager(manager_);

        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        deploymentChainId = block.chainid;
        _DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external virtual auth {
        if (what == "manager") manager = IBaseRequestManager(data);
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
        shares = manager.convertToShares(this, assets);
    }

    /// @inheritdoc IERC7575
    /// @notice     The calculation is based on the token price from the most recent epoch retrieved from Centrifuge.
    ///             The actual conversion MAY change between order submission and execution.
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        assets = manager.convertToAssets(this, shares);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @notice Price of 1 unit of share, quoted in the decimals of the asset.
    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** _shareDecimals);
    }

    /// @notice Returns timestamp of the last share price update.
    function priceLastUpdated() external view returns (uint64) {
        return manager.priceLastUpdated(this);
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
