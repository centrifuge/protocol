// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IPoolEscrow} from "./IPoolEscrow.sol";
import {IEndorsements} from "./IEndorsements.sol";
import {ISpokeRegistry} from "./ISpokeRegistry.sol";

import {ISpokeMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IManifest} from "../../hub/interfaces/IManifest.sol";
import {IBatchedMulticall} from "../../utils/interfaces/IBatchedMulticall.sol";
import {IPoolEscrowProvider} from "../factories/interfaces/IPoolEscrowFactory.sol";

struct ShareQueueAmount {
    // Net queued shares
    uint128 delta;
    // Whether the net queued shares lead to an issuance or revocation
    bool isPositive;
    // Number of queued asset IDs for this share class
    uint32 queuedAssetCounter;
    // Nonce for share + asset messages to the hub
    uint64 nonce;
}

struct AssetQueueAmount {
    // Gross queued deposit amount (asset units)
    uint128 deposits;
    // Gross queued withdrawal amount (asset units)
    uint128 withdrawals;
}

interface IBalanceSheet is IBatchedMulticall {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event SetManifest(PoolId indexed poolId, IManifest manifest);
    event UpdateManager(PoolId indexed poolId, address who, bool canManage);
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
    event SubmitQueuedShares(PoolId indexed poolId, ShareClassId indexed scId, ISpokeMessageSender.UpdateData data);
    event SubmitQueuedAssets(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, ISpokeMessageSender.UpdateData data
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error CannotTransferFromEndorsedContract();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'spoke', 'sender', 'gateway', 'poolEscrowProvider'
    /// @param data The new address
    function file(bytes32 what, address data) external;

    /// @notice Install or replace the policy manifest enforced on this pool's balance-sheet manager methods.
    /// @dev    Wards may call directly (break-glass). For managers the current manifest is enforced, so a
    ///         compromised manager cannot hot-swap the policy in a single transaction.
    /// @param poolId The pool identifier
    /// @param manifest The manifest to install (address(0) to remove policy enforcement)
    function setManifest(PoolId poolId, IManifest manifest) external;

    //----------------------------------------------------------------------------------------------
    // Management functions
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

    /// @notice Transfer share tokens parked in the pool escrow out to a receiver (hook-checked).
    /// @dev    Share issuance is accounted separately via issue/revoke, so this carries no hub queue.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param receiver The address to receive the shares
    /// @param amount The amount of shares to transfer
    function withdrawShares(PoolId poolId, ShareClassId scId, address receiver, uint128 amount) external payable;

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

    /// @notice Issue new share tokens
    /// @dev Increases the total issuance
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param to The address to issue shares to
    /// @param shares The number of shares to issue
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external payable;

    /// @notice Revoke share tokens
    /// @dev Decreases the total issuance. The shares are pulled from the caller (`msgSender()`), which must
    ///      have granted this balance sheet an ERC20 allowance of `shares` beforehand.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shares The number of shares to revoke
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external payable;

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
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the spoke registry contract
    function spoke() external view returns (ISpokeRegistry);

    /// @notice Returns the message sender contract
    function sender() external view returns (ISpokeMessageSender);

    /// @notice Returns the endorsements contract
    function endorsements() external view returns (IEndorsements);

    /// @notice Returns the pool escrow provider
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    /// @notice Returns the policy manifest installed for a pool (address(0) if none)
    function manifest(PoolId poolId) external view returns (IManifest);

    /// @notice Checks if an address is a manager for a pool
    function manager(PoolId poolId, address manager) external view returns (bool);

    /// @notice Returns the queued shares for a share class
    function queuedShares(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce);

    /// @notice Returns the queued assets for a share class and asset
    /// @return deposits Queued deposit amount
    /// @return withdrawals Queued withdrawal amount
    function queuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 deposits, uint128 withdrawals);

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
