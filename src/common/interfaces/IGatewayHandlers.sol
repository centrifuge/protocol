// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRequestManager} from "./IRequestManager.sol";

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {VaultUpdateKind} from "../libraries/MessageLib.sol";

/// -----------------------------------------------------
///  Hub Handlers
/// -----------------------------------------------------

/// @notice Interface for Hub methods called by messages
interface IHubGatewayHandler {
    /// @notice Tells that an asset was already registered in Vaults, in order to perform the corresponding register.
    function registerAsset(AssetId assetId, uint8 decimals) external;

    /// @notice Handles a request originating from the Spoke side.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The request payload to be processed
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external payable;

    /// @notice Update a holding by request from Vaults.
    function updateHoldingAmount(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) external;

    /// @notice Forward an initiated share transfer to the destination chain.
    function initiateTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit
    ) external;

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

/// -----------------------------------------------------
///  Vaults Handlers
/// -----------------------------------------------------

/// @notice Interface for spoke related methods called by messages
interface ISpokeGatewayHandler {
    /// @notice    New pool details from an existing Centrifuge pool are added.
    /// @param     poolId The pool id
    function addPool(PoolId poolId) external;

    /// @notice     New share class details from an existing Centrifuge pool are added.
    function addShareClass(
        PoolId poolId,
        ShareClassId scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) external;

    /// @notice Updates the request manager for a specific asset
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  manager The new request manager address
    function setRequestManager(PoolId poolId, ShareClassId scId, AssetId assetId, IRequestManager manager) external;

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
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  hook The new hook address
    function updateShareHook(PoolId poolId, ShareClassId scId, address hook) external;

    /// @notice Updates the restrictions on a share class token for a specific user
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  update The restriction update in the form of a bytes array indicating
    ///                the restriction to be updated, the user to be updated, and a validUntil timestamp.
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update) external;

    /// @notice Mints share class tokens to a recipient
    function executeTransferShares(PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount) external;

    /// @notice Updates a vault based on VaultUpdateKind
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  vaultOrFactory The address of the vault or the factory, depending on the kind value
    /// @param  kind The kind of action applied
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address vaultOrFactory,
        VaultUpdateKind kind
    ) external;

    /// @notice Updates the max price age of an asset
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  maxPriceAge new max price age value
    function setMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external;

    /// @notice Updates the max price age of a share
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  maxPriceAge new max price age value
    function setMaxSharePriceAge(PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external;

    /// @notice Handles a request callback originating from the Hub side.
    /// @dev    Results from a Spoke-to-Hub-request as second order callback from the Hub.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  payload The payload to be processed by the request callback
    function requestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes memory payload) external;
}

/// @notice Interface for the update contract method, called by message
interface IUpdateContractGatewayHandler {
    /// @notice Updates the target address. Generic update function from Hub to Vaults
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  target The target address to be called
    /// @param  update The payload to be processed by the target address
    function execute(PoolId poolId, ShareClassId scId, address target, bytes memory update) external;
}

/// @notice Interface for methods implemented by a balance sheet
interface IBalanceSheetGatewayHandler {
    function updateManager(PoolId poolId, address who, bool canManage) external;
}
