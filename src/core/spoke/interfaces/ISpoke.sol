// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IPoolEscrow} from "./IPoolEscrow.sol";
import {ISnapshotQueue} from "./ISnapshotQueue.sol";
import {ISpokeRegistry} from "./ISpokeRegistry.sol";

import {ISpokeMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IManifest} from "../../hub/interfaces/IManifest.sol";
import {IBatchedMulticall} from "../../utils/interfaces/IBatchedMulticall.sol";
import {IPoolEscrowProvider} from "../factories/interfaces/IPoolEscrowFactory.sol";

interface ISpoke is IBatchedMulticall {
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
    event Withdraw(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    );
    event WithdrawShares(PoolId indexed poolId, ShareClassId indexed scId, address receiver, uint128 shares);
    event Deposit(
        PoolId indexed poolId, ShareClassId indexed scId, address sender, address asset, uint256 tokenId, uint128 amount
    );
    /// @dev Emitted instead of `Deposit` when the assets are credited to the escrow without an accompanying
    ///      token transfer, so indexers can reconcile escrow balances from `Deposit`/`Withdraw` transfers alone.
    event NoteDeposit(
        PoolId indexed poolId, ShareClassId indexed scId, address sender, address asset, uint256 tokenId, uint128 amount
    );
    event Issue(PoolId indexed poolId, ShareClassId indexed scId, address sender, address to, uint128 shares);
    event Revoke(PoolId indexed poolId, ShareClassId indexed scId, address sender, address from, uint128 shares);
    event TransferSharesFrom(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address sender,
        address indexed from,
        address to,
        uint256 amount
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error TooManyDecimals();
    error AssetMissingDecimals();
    error LocalTransferNotAllowed();
    error CrossChainTransferNotAllowed();
    error InvalidRequestManager();
    error NotBridger();
    error NotManager();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts "gateway", "sender", "snapshotQueue", "spokeRegistry", "poolEscrowProvider"
    /// @param data The new address
    function file(bytes32 what, address data) external;

    /// @notice Install or replace the policy manifest enforced on this pool's balance-sheet manager methods.
    /// @dev    Wards may call directly (break-glass). For managers the current manifest is enforced, so a
    ///         compromised manager cannot hot-swap the policy in a single transaction.
    /// @param poolId The pool identifier
    /// @param manifest The manifest to install (address(0) to remove policy enforcement)
    function setManifest(PoolId poolId, IManifest manifest) external;

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

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

    /// @notice Initializes a holding on the hub for a pool's share class and asset. Callable by a spoke manager.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    //----------------------------------------------------------------------------------------------
    // Balance sheet: asset methods
    //----------------------------------------------------------------------------------------------

    /// @notice Deposit assets into the escrow of the pool, counting them into the hub-accounted holding.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID (SHOULD be 0 for ERC20 assets. ERC6909 assets with tokenId=0 are not supported)
    /// @param amount The amount to deposit
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external payable;

    /// @notice Count assets already held by the pool escrow into the hub-accounted holding, without moving tokens.
    /// @dev    For reconciling assets that reached the escrow outside a `deposit` (donation, accidental transfer,
    ///         surplus). Does not verify the escrow balance, so a manager can over-credit: use with care.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID (SHOULD be 0 for ERC20 assets. ERC6909 assets with tokenId=0 are not supported)
    /// @param amount The amount to count into the holding
    function noteDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable;

    /// @notice Withdraw assets from the pool escrow, decreasing the hub-accounted holding.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID (SHOULD be 0 for ERC20 assets. ERC6909 assets with tokenId=0 are not supported)
    /// @param receiver The address to receive the withdrawn assets
    /// @param amount The amount to withdraw
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external payable;

    /// @notice Withdraw previously-reserved assets from the pool escrow.
    /// @dev    The hub holding decrease was already queued when the funds were reserved, so this does not queue again.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID (SHOULD be 0 for ERC20 assets. ERC6909 assets with tokenId=0 are not supported)
    /// @param receiver The address to receive the withdrawn assets
    /// @param amount The amount to withdraw
    /// @param reserver The address that owns the reservation
    /// @param reason The reason code that was used when reserving
    function withdrawReserved(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        address reserver,
        uint32 reason
    ) external payable;

    /// @notice Reserve assets, removing them from the hub-accounted holding.
    /// @dev These assets are removed from the available balance and from the hub holding (accounted = total - reserved),
    ///      queueing a holding decrease. It is possible to reserve more than the current balance, to lock future
    ///      expected assets. Any manager can reserve on behalf of any address, enabling recovery of stuck funds.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID
    /// @param amount The amount to reserve
    /// @param reserver The address that will own the reservation (tracked in PoolEscrow)
    /// @param reason The reason code (1=DEPOSIT, 2=REDEEM)
    function reserve(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        uint32 reason
    ) external payable;

    /// @notice Unreserve assets, returning them to the hub-accounted holding.
    /// @dev Re-adds the funds to the available balance and the hub holding, queueing a holding increase.
    ///      Any manager can unreserve any reserver's funds, enabling recovery of stuck funds.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID
    /// @param amount The amount to unreserve
    /// @param reserver The address that owns the reservation to be unreserved
    /// @param reason The reason code that was used when reserving
    function unreserve(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        uint32 reason
    ) external payable;

    /// @notice Sends the queued updated holding amount to the Hub, which values it at its own valuation
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param extraGasLimit Extra gas limit for cross-chain execution
    /// @param refund Address to receive excess gas refund
    function submitQueuedAssets(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    //----------------------------------------------------------------------------------------------
    // Balance sheet: share methods
    //----------------------------------------------------------------------------------------------

    /// @notice Issue new share tokens
    /// @dev Increases the total issuance
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param to The address to issue shares to
    /// @param shares The number of shares to issue
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external payable;

    /// @notice Revoke share tokens
    /// @dev Decreases the total issuance
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shares The number of shares to revoke
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external payable;

    /// @notice Transfer share tokens parked in the pool escrow out to a receiver (hook-checked).
    /// @dev    Share issuance is accounted separately via issue/revoke, so this carries no hub queue.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param receiver The address to receive the shares
    /// @param amount The amount of shares to transfer
    function withdrawShares(PoolId poolId, ShareClassId scId, address receiver, uint128 amount) external payable;

    /// @notice Sends the queued updated shares changed to the Hub
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param extraGasLimit Extra gas limit for cross-chain execution
    /// @param refund Address to receive excess gas refund
    function submitQueuedShares(PoolId poolId, ShareClassId scId, uint128 extraGasLimit, address refund)
        external
        payable;

    /// @notice Force-transfers share tokens
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param sender The address initiating the transfer
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param amount The amount to transfer
    function transferSharesFrom(
        PoolId poolId,
        ShareClassId scId,
        address sender,
        address from,
        address to,
        uint256 amount
    ) external payable;

    //----------------------------------------------------------------------------------------------
    // Bridging
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
    ///        the resolved sender unless the caller is a ward (e.g. a router bridging shares it pulled, or the
    ///        SpokeV3_1_0 compatibility layer forwarding the original caller). Must have granted this contract
    ///        an ERC20 allowance for `amount` (optionally via permit); the shares are pulled with a standard
    ///        transferFrom so the flow works for share tokens without a force-transfer mechanism.
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

    //----------------------------------------------------------------------------------------------
    // Requests & manager calls
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Stores pool, share class, asset, and price state for the spoke side
    function spokeRegistry() external view returns (ISpokeRegistry);

    /// @notice Dispatches cross-chain messages from this spoke to the hub chain
    function sender() external view returns (ISpokeMessageSender);

    /// @notice Stores the queued share and asset deltas pending submission to the hub
    function snapshotQueue() external view returns (ISnapshotQueue);

    /// @notice Returns the pool escrow provider
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    /// @notice Returns the policy manifest installed for a pool (address(0) if none)
    function manifest(PoolId poolId) external view returns (IManifest);

    /// @notice Returns the pool escrow.
    /// @dev    Assets for pending deposit requests are not held by the pool escrow.
    function escrow(PoolId poolId) external view returns (IPoolEscrow);

    /// @notice Returns the amount of assets that can be withdrawn from the balance sheet.
    /// @dev    Assets that are locked (reserved) are not available for withdrawals.
    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        external
        view
        returns (uint128);
}
