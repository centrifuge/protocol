// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpokeRegistry} from "./ISpokeRegistry.sol";

import {ISpokeMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

interface ISpoke {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event RegisterAsset(
        uint16 centrifugeId,
        AssetId indexed assetId,
        address indexed asset,
        uint256 indexed tokenId,
        string name,
        string symbol,
        uint8 decimals,
        bool isInitialization
    );
    event InitiateTransferShares(
        uint16 centrifugeId,
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed sender,
        address owner,
        bytes32 destinationAddress,
        uint128 amount
    );
    event ManagerCall(
        uint16 indexed centrifugeId, PoolId indexed poolId, bytes32 target, bytes payload, address indexed sender
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error TooFewDecimals();
    error TooManyDecimals();
    error AssetMissingDecimals();
    error LocalTransferNotAllowed();
    error InvalidRequestManager();
    error NotBridger();
    error NotManager();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Stores pool, share class, asset, and price state for the spoke side
    function spokeRegistry() external view returns (ISpokeRegistry);

    /// @notice Dispatches cross-chain messages from this spoke to the hub chain
    function sender() external view returns (ISpokeMessageSender);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts "spokeRegistry", "sender"
    /// @param data The new address
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @notice Transfers share class tokens to a cross-chain recipient address
    /// @dev To transfer to evm chains, pad a 20 byte evm address with 12 bytes of 0
    /// @param centrifugeId The destination chain id
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param receiver A bytes32 representation of the receiver address
    /// @param sender The originator of the transfer; attributed in the event and forwarded to the
    ///        destination-side bridging hook (e.g. the circuit breaker). A router/bridge passes the real user.
    /// @param owner The account whose shares are transferred and burned; must hold the bridger role and be
    ///        `msg.sender` unless the caller is a ward (e.g. a router bridging shares it pulled, or the
    ///        SpokeV3_1_0 compatibility layer forwarding the original caller).
    /// @param amount The amount of tokens to transfer
    /// @param extraGasLimit Extra gas limit used for computation on the intermediary hub
    /// @param remoteExtraGasLimit Extra gas limit used for computation in the destination chain
    /// @param refund Address to refund the excess of the payment
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        address sender,
        address owner,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable;

    /// @notice Registers an ERC-20 or ERC-6909 asset in another chain.
    /// @dev `decimals()` MUST return a `uint8` value between 2 and 18.
    /// @dev `name()` and `symbol()` MAY return no values.
    ///
    /// @param centrifugeId The centrifuge id of chain to where the shares are transferred
    /// @param asset The address of the asset to be registered
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @param refund Address to refund the excess of the payment
    /// @return assetId The underlying internal uint128 assetId.
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId, address refund)
        external
        payable
        returns (AssetId assetId);

    /// @notice Initiates a spoke-direction manager call to a destination contract, routed through the Envoy
    ///         to the target's `IManagerCallFromSpoke.fromSpoke`.
    /// @param poolId The pool identifier
    /// @param target The destination target contract (as bytes32 for cross-chain compatibility)
    /// @param payload The action payload (any share class id is encoded here)
    /// @param extraGasLimit Additional gas for cross-chain execution
    /// @param refund Address to refund excess payment
    /// @dev Permissionless by choice, forwards caller's address to the target for permission validation
    function managerCall(PoolId poolId, bytes32 target, bytes calldata payload, uint128 extraGasLimit, address refund)
        external
        payable;

    /// @notice Initializes a holding on the hub for a pool's share class and asset. Callable by a spoke manager.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation The valuation contract (on the hub) as bytes32
    /// @param asset The asset account id
    /// @param equity The equity account id
    /// @param gain The gain account id
    /// @param loss The loss account id
    /// @param refund Address to refund excess payment
    function initializeHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 valuation,
        AccountId asset,
        AccountId equity,
        AccountId gain,
        AccountId loss,
        address refund
    ) external payable;

    /// @notice Initializes a liability on the hub for a pool's share class and asset. Callable by a spoke manager.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation The valuation contract (on the hub) as bytes32
    /// @param expense The expense account id
    /// @param liability The liability account id
    /// @param refund Address to refund excess payment
    function initializeLiability(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 valuation,
        AccountId expense,
        AccountId liability,
        address refund
    ) external payable;

    /// @notice Handles a request originating from the Spoke side
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param payload The request payload to be processed
    /// @param extraGasLimit Additional gas stipend for cross-chain execution
    /// @param unpaid Whether to allow unpaid mode
    /// @param refund Address to refund excess payment
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable;
}
