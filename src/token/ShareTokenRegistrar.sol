// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareToken} from "./ShareToken.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {ITransferHook} from "./interfaces/ITransferHook.sol";
import {IShareTokenRegistrar} from "./interfaces/IShareTokenRegistrar.sol";

import {Auth} from "../misc/Auth.sol";
import {IAuth} from "../misc/interfaces/IAuth.sol";
import {IERC20} from "../misc/interfaces/IERC20.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IRegistrar} from "../core/spoke/interfaces/IRegistrar.sol";
import {IManagerCallFromHub} from "../core/utils/interfaces/IManagerCall.sol";
import {VaultDetails, ISpokeRegistry} from "../core/spoke/interfaces/ISpokeRegistry.sol";

/// @title  ShareTokenRegistrar
/// @notice Registrar for the protocol's own ShareToken standard. Deploys deterministic ShareToken
///         contracts using CREATE2 and operates them on behalf of the core spoke contracts, which
///         never interact with the token directly.
/// @dev    The registrar stays ward on every token it deploys. `burn` pulls the tokens to the calling
///         core contract before burning, so transfer hooks observe the same flow shapes as when the
///         core contracts held token permissions themselves (e.g. the Spoke as redemption source,
///         Spoke as crosschain transfer source).
contract ShareTokenRegistrar is Auth, IRegistrar, IShareTokenRegistrar, IManagerCallFromHub {
    address public immutable root;

    address public envoy;
    ISpokeRegistry public spokeRegistry;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IShareTokenRegistrar
    function file(bytes32 what, address data) external auth {
        if (what == "envoy") envoy = data;
        else if (what == "spokeRegistry") spokeRegistry = ISpokeRegistry(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Manager calls
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    /// @dev Hub-originated, Envoy-routed configuration (reached via `Hub.managerCall` targeting this
    ///      registrar). Resolves the share token from `(poolId, scId)`, refuses if this registrar does
    ///      not serve that share class, then dispatches on the leading discriminant.
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (uint8 kind, bytes16 rawScId) = abi.decode(payload, (uint8, bytes16));
        ShareClassId scId = ShareClassId.wrap(rawScId);

        (IERC20 token_, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(poolId, scId);
        require(registrar == IRegistrar(address(this)), NotRegistrar());
        address token = address(token_);

        if (kind == uint8(RegistrarCall.SetHook)) {
            (,, address hook) = abi.decode(payload, (uint8, bytes16, address));
            _updateHook(token, hook);
        } else if (kind == uint8(RegistrarCall.SetVault)) {
            _setVault(poolId, scId, token, payload);
        } else if (kind == uint8(RegistrarCall.UpdateWard)) {
            (,, address ward, bool authorized) = abi.decode(payload, (uint8, bytes16, address, bool));
            if (authorized) {
                IAuth(token).rely(ward);
            } else {
                require(ward != address(this), CannotDenySelf());
                IAuth(token).deny(ward);
            }
        } else {
            revert UnknownRegistrarCall();
        }
    }

    /// @dev Points the token's ERC-7575 vault for `asset` at (or clears it, with address(0), once unlinked
    ///      from) the registry's currently-linked vault, so the pointer can never diverge from the registry.
    function _setVault(PoolId poolId, ShareClassId scId, address token, bytes calldata payload) private {
        (,, uint128 assetId, address vault) = abi.decode(payload, (uint8, bytes16, uint128, address));
        AssetId assetId_ = AssetId.wrap(assetId);
        (address asset, uint256 tokenId) = spokeRegistry.idToAsset(assetId_, true);
        require(tokenId == 0, NonZeroTokenId());

        // Validate declaratively against registry storage, the sole authority on where a vault belongs:
        // a non-zero pointer must be a currently-linked vault that belongs to this (poolId, scId, assetId).
        if (vault != address(0)) {
            VaultDetails memory details = spokeRegistry.vaultDetails(vault);
            require(
                details.isLinked && details.assetId == assetId_ && details.poolId == poolId && details.scId == scId,
                VaultMismatch()
            );
        }

        IShareToken(token).updateVault(asset, vault);
    }

    //----------------------------------------------------------------------------------------------
    // Token creation
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRegistrar
    /// @dev `payload` is ignored: a ShareToken needs no creation data beyond its metadata, and hooks are set
    ///      afterwards over the Envoy path.
    function newToken(string memory name, string memory symbol, uint8 decimals, bytes32 salt, bytes memory)
        external
        auth
        returns (address)
    {
        ShareToken token = new ShareToken{salt: salt}(decimals);

        token.file("name", name);
        token.file("symbol", symbol);

        token.rely(root);

        return address(token);
    }

    //----------------------------------------------------------------------------------------------
    // Token operations
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRegistrar
    function mint(address token, address to, uint256 amount) external auth {
        IShareToken(token).mint(to, amount);
    }

    /// @inheritdoc IRegistrar
    /// @dev Pulls the tokens to the caller before burning, so transfer hooks observe the same flow
    ///      shapes as before. The burn consumes the allowance the caller granted to this registrar.
    function burn(address token, address from, uint256 amount) external auth {
        IShareToken(token).authTransferFrom(from, from, msg.sender, amount);
        IShareToken(token).burn(msg.sender, amount);
    }

    /// @inheritdoc IRegistrar
    function authTransferFrom(address token, address sender, address from, address to, uint256 amount) external auth {
        IShareToken(token).authTransferFrom(sender, from, to, amount);
    }

    /// @inheritdoc IRegistrar
    /// @dev The registry has already validated the link, so this trusted path is a thin pass-through; the
    ///      governance override (`RegistrarCall.SetVault` via `fromHub`) keeps its own declarative validation.
    function updateVault(address token, address asset, address vault) external auth {
        IShareToken(token).updateVault(asset, vault);
    }

    /// @inheritdoc IRegistrar
    function updateMetadata(address token, string memory name, string memory symbol) external auth {
        IShareToken token_ = IShareToken(token);
        require(
            keccak256(bytes(token_.name())) != keccak256(bytes(name))
                || keccak256(bytes(token_.symbol())) != keccak256(bytes(symbol)),
            OldMetadata()
        );

        token_.file("name", name);
        token_.file("symbol", symbol);
    }

    function _updateHook(address token, address hook) internal {
        require(hook != IShareToken(token).hook(), OldHook());
        IShareToken(token).file("hook", hook);
    }

    /// @inheritdoc IRegistrar
    function updateRestriction(address token, bytes memory update) external auth {
        address hook = IShareToken(token).hook();
        require(hook != address(0), InvalidHook());
        ITransferHook(hook).updateRestriction(token, update);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRegistrar
    function canBridge(address token, address from, uint16 centrifugeId, uint256 amount) external view returns (bool) {
        return IShareToken(token).checkTransferRestriction(from, address(uint160(centrifugeId)), amount);
    }

    /// @inheritdoc IRegistrar
    /// @dev The ShareToken address depends only on `decimals` and `salt`; name and symbol are set
    ///      post-deployment via `file` and `payload` is ignored, so they do not affect the CREATE2 address.
    function previewTokenAddress(string memory, string memory, uint8 decimals, bytes32 salt, bytes memory)
        external
        view
        returns (address)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(ShareToken).creationCode, abi.encode(decimals)))
            )
        );

        return address(uint160(uint256(hash)));
    }
}
