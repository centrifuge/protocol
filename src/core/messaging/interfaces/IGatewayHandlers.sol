// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IPolicy} from "../../utils/interfaces/IPolicy.sol";
import {VaultUpdateKind} from "../libraries/MessageLib.sol";
import {IRegistrar} from "../../spoke/interfaces/IRegistrar.sol";
import {ISpokeRequestManager} from "../../spoke/interfaces/ISpokeRequestManager.sol";

//--------------------------------------------------------------------------------------------------
// Hub Handlers
//--------------------------------------------------------------------------------------------------

/// @notice Interface for Hub methods called by messages
interface IHubGatewayHandler {
    /// @notice Tells that an asset was already registered in Vaults, in order to perform the corresponding register.
    function registerAsset(AssetId assetId, uint8 decimals) external;

    /// @notice Handles a request originating from the Spoke side.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The request payload to be processed
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;

    /// @notice Update a holding by request from Vaults.
    /// @dev    The holding delta is valued at the hub-side valuation; the wire message's price field is
    ///         deprecated and ignored.
    function updateAssets(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) external;

    /// @notice Forward an initiated share transfer to the destination chain.
    function initiateTransferShares(
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 sender,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Updates the total issuance of shares by request from vaults.
    function updateShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        uint128 amount,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce
    ) external;
}

//--------------------------------------------------------------------------------------------------
// Spoke Handlers
//--------------------------------------------------------------------------------------------------

/// @notice Interface for spoke related methods called by messages
interface ISpokeGatewayHandler {
    /// @notice    New pool details from an existing Centrifuge pool are added.
    /// @param     poolId The pool id
    function addPool(PoolId poolId) external;

    /// @notice     New share class details from an existing Centrifuge pool are added.
    /// @param      salt Deterministic deployment salt, whose first 8 bytes MUST be `poolId`. Registrars are
    ///             shared across pools, so this keeps one pool out of another pool's salt namespace.
    /// @param      payload Opaque data forwarded to the registrar on token creation; empty if unused
    function addShareClass(
        PoolId poolId,
        ShareClassId scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        IRegistrar registrar,
        bytes memory payload
    ) external;

    /// @notice Updates the request manager for a pool
    /// @param  poolId The centrifuge pool id
    /// @param  manager The new request manager address
    function setRequestManager(PoolId poolId, ISpokeRequestManager manager) external;

    /// @notice Install or replace the policy enforced on this pool's balance-sheet manager methods
    /// @param  poolId The pool id
    /// @param  policy The policy contract to install (address(0) to remove policy enforcement)
    function setPolicy(PoolId poolId, IPolicy policy) external;

    /// @notice Record a Hub-authorized, out-of-policy call in the local ledger (from a Hub {Authorize} message)
    /// @param  poolId The pool the authorized call targets
    /// @param  data The exact spoke calldata being authorized
    function authorize(PoolId poolId, bytes calldata data) external;

    /// @notice Revoke one outstanding authorization for `data` (from a Hub {Unauthorize} message)
    /// @param  poolId The pool the authorized call targets
    /// @param  data The exact spoke calldata whose authorization is revoked
    function unauthorize(PoolId poolId, bytes calldata data) external;

    /// @notice Grants or revokes the spoke pool manager role
    function updateManager(PoolId poolId, address who, bool canManage) external;

    /// @notice Grants or revokes the bridger role gating cross-chain share transfers
    function updateBridger(PoolId poolId, address who, bool canBridge) external;

    /// @notice   Updates the tokenName and tokenSymbol of a share class token
    function updateShareMetadata(PoolId poolId, ShareClassId scId, string memory tokenName, string memory tokenSymbol)
        external;

    /// @notice  Updates the price (pool currency amount per share class token) of a share class token
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  price The price of pool currency per share class token.
    /// @param  computedAt The timestamp when the price was computed
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 price, uint64 computedAt) external;

    /// @notice  Updates the price (pool currency amount per asset unit) of an asset
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  price The price of pool currency per asset unit.
    /// @param  computedAt The timestamp when the price was computed
    function updatePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price, uint64 computedAt)
        external;

    /// @notice Updates the hook of a share class token
    /// @notice Updates the restrictions on a share class token for a specific user
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  update The restriction update in the form of a bytes array indicating
    ///                the restriction to be updated, the user to be updated, and a validUntil timestamp.
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update) external;

    /// @notice Mints share class tokens to a recipient
    function executeTransferShares(PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount) external;

    /// @notice Handles a request callback originating from the Hub side.
    /// @dev    Results from a Spoke-to-Hub-request as second order callback from the Hub.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The payload to be processed by the request callback
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external;

    /// @notice Updates a vault based on VaultUpdateKind
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  vaultOrFactory The address of the vault or the factory, depending on the kind value
    /// @param  kind The kind of action applied
    /// @param  payload Opaque data forwarded to the factory on DeployAndLink; empty otherwise
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address vaultOrFactory,
        VaultUpdateKind kind,
        bytes calldata payload
    ) external;
}
