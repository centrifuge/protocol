// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";

import {Auth} from "src/misc/Auth.sol";
import {IERC20, IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {EIP712Lib} from "src/misc/libraries/EIP712Lib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SignatureLib} from "src/misc/libraries/SignatureLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IAsyncInvestmentManager} from "src/vaults/interfaces/investments/IAsyncInvestmentManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

abstract contract BaseVault is Auth, IBaseVault {
    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    IRoot public immutable root;
    IAsyncInvestmentManager public manager;

    /// @inheritdoc IBaseVault
    uint64 public immutable poolId;
    /// @inheritdoc IBaseVault
    bytes16 public immutable trancheId;

    /// @inheritdoc IERC7575
    address public immutable asset;
    /// @dev NOTE: Should never be used in production in any external contract as there will be old vaults without this
    /// storage. Instead, refer to poolManager.vaultDetails(vault).
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
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address manager_
    ) Auth(msg.sender) {
        poolId = poolId_;
        trancheId = trancheId_;
        asset = asset_;
        tokenId = tokenId_;
        share = share_;
        _shareDecimals = IERC20Metadata(share).decimals();
        root = IRoot(root_);
        manager = IAsyncInvestmentManager(manager_);

        nameHash = keccak256(bytes("Centrifuge"));
        versionHash = keccak256(bytes("1"));
        deploymentChainId = block.chainid;
        _DOMAIN_SEPARATOR = EIP712Lib.calculateDomainSeparator(nameHash, versionHash);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "manager") manager = IAsyncInvestmentManager(data);
        else revert("ERC7540Vault/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, uint256 tokenId_, address to, uint256 amount) external auth {
        if (tokenId_ == 0) {
            SafeTransferLib.safeTransfer(token, to, amount);
        } else {
            IERC6909(token).transfer(to, tokenId_, amount);
        }
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) public virtual returns (bool success) {
        require(msg.sender != operator, "ERC7540Vault/cannot-set-self-as-operator");
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    /// @inheritdoc IBaseVault
    function setEndorsedOperator(address owner, bool approved) public virtual {
        require(msg.sender != owner, "ERC7540Vault/cannot-set-self-as-operator");
        require(root.endorsed(msg.sender), "ERC7540Vault/not-endorsed");
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
        require(controller != operator, "ERC7540Vault/cannot-set-self-as-operator");
        require(block.timestamp <= deadline, "ERC7540Vault/expired");
        require(!authorizations[controller][nonce], "ERC7540Vault/authorization-used");

        authorizations[controller][nonce] = true;

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(AUTHORIZE_OPERATOR_TYPEHASH, controller, operator, approved, nonce, deadline))
            )
        );

        require(SignatureLib.isValidSignature(controller, digest, signature), "ERC7540Vault/invalid-authorization");

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
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        // TODO(@wischli): Add sync interfaces?
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC7540CancelRedeem).interfaceId || interfaceId == type(IERC7575).interfaceId
            || interfaceId == type(IERC7741).interfaceId || interfaceId == type(IERC7714).interfaceId
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
        return ITranche(share).checkTransferRestriction(address(0), controller, 0);
    }

    /// @notice Ensures msg.sender can operate on behalf of controller.
    function _validateController(address controller) internal view {
        require(controller == msg.sender || isOperator[controller][msg.sender], "ERC7540Vault/invalid-controller");
    }
}
