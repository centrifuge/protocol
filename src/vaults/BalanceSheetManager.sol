// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {Noted, Entry, IBalanceSheetManager} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";

contract BalanceSheetManager is IAuth, IBalanceSheetManager, IUpdateContract {
    using BytesLib for bytes;
    using MathLib for uint256;
    using CastLib for *;

    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IMessageProcessor public sender;
    IPoolManager public poolManager;

    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address => true))) public permission;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address from => mapping(assetId => Noted)))) public notedWithdraw;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address from => mapping(assetId => Noted)))) public notedDeposit;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = IEscrow(escrow_);
    }

        /// @dev Check if the msg.sender has permissions
    modifier authOrPermission(uint64 poolId, bytes16 shareClassId, Permission perm) {
        require(wards[msg.sender] == 1 || permission(poolId, shareClassId, msg.sender), NotAuthorized());
        _;
    }

    // --- Administration ---
    /// @inheritdoc IPoolManager
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "sender") sender = IMessageProcessor(data);
        else revert("BalanceSheetManager/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IRecoverable
    function recoverTokens(address token, address to, uint256 amount) external auth {
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// --- IUpdateContract Implementation ---
    function updateContract(uint64 poolId, bytes16 shareClassId, bytes memory payload) external override auth {
        MessageLib.UpdateContractPermission memory m = MessageLib.deserializeUpdateContractPermission(payload);

        permission[poolId][shareClassId][m.contractAddr] = m.allowed;

        emit Permission(poolId, shareClassId, m.contractAddr, m.allowed);
    }

    /// --- Outgoing ---
    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external authOrPermission(poolId, shareClassId) {
        _increase(poolId, shareClassId, asset, tokenId, provider, amount, pricePerUnit, timestamp, debits, credits);
    }

    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        AssetId assetId,
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external authOrPermission(poolId, shareClassId) {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId));
        require(asset != address(0), "PoolManager/invalid-asset-id");

        _increase(poolId, shareClassId, asset, tokenId, provider, amount, pricePerUnit, timestamp, debits, credits);
    }

    function decrease(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external authOrPermission(msg.sender, poolId, shareClassId) {
        _decrease(poolId, shareClassId, asset, tokenId, receiver, amount, pricePerUnit, timestamp, debits, credits);
    }

    function decrease(
        uint64 poolId,
        bytes16 shareClassId,
        AssetId assetId,
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external authOrPermission(msg.sender, poolId, shareClassId) {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId));
        require(asset != address(0), "PoolManager/invalid-asset-id");

        _decrease(poolId, shareClassId, asset, tokenId, receiver, amount, pricePerUnit, timestamp, debits, credits);
    }

    function issue(
        uint64 poolId,
        bytes16 shareClassId,
        address to,
        uint256 shares, // delta change, positive - debit, negative - credit
        uint256 pricePerShare,
        uint64 timestamp
    ) external authOrPermission(poolId, shareClassId) {
        
        // TODO: Mint shares to to
        
        // TODO: Send message to CP IssuedShares()
    }

    function revoke(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 shares,
        uint256 pricePerShare,
        uint64 timestamp
    ) external authOrPermission(poolId, shareClassId) {
        // TODO: burn shares from from
     
        // TODO: Send message to CP RevokedShares()

    }

    function journal(
        uint64 poolId,
        bytes16 shareClassId,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external authOrPermission(poolId, shareClassId) {
        // TODO: Send message to CP JournalEntry()
    }

    // --- Incoming ---
    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address receiver,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        Entry[] memory debits,
        Entry[] memory credits,
        bool isUnnote,
    ) external authOrPermission(poolId, shareClassId) {
        Noted storage notedWithdraw = notedWithdraw[poolId][shareClassId][receiver][assetId];

        if (isUnnote) {
            notedWithdraw.amount -= amount;
        } else {
            notedWithdrawamount += amount;
        }

        notedWithdraw.pricePerUnit = pricePerUnit;
        notedWithdraw.debits = debits;
        notedWithdraw.credits = credits;

        if (notedDeposit.amount == 0) {
            delete notedWithdraw[poolId][shareClassId][from][assetId];
        }

        notedWithdraw[poolId][shareClassId][receiver][assetId] = notedWithdraw;

        emit NotedWithdraw(poolId, shareClassId, from, assetId, notedWithdraw.amount, pricePerUnit, debits, credits);
    }

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        Entry[] memory debits,
        Entry[] memory credits,
        bool isUnnote,
    ) external authOrPermission(poolId, shareClassId) {
        Noted storage notedDeposit = notedDeposit[poolId][shareClassId][from][assetId];

        if (isUnnote) {
            notedDeposit.amount -= amount;
        } else {
            notedDeposit.amount += amount;
        }

        notedDeposit.pricePerUnit = pricePerUnit;
        notedDeposit.debits = debits;
        notedDeposit.credits = credits;

        if (notedDeposit.amount == 0) {
            delete notedDeposit[poolId][shareClassId][from][assetId];
        }

        notedDeposit[poolId][shareClassId][from][assetId] = notedDeposit;

        emit NotedDeposit(poolId, shareClassId, from, assetId, notedWithdraw.amount, pricePerUnit, debits, credits);
    }

    function executeNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver,
    ) external {
        uint256 assetId = poolManager.assetToId(assetId, tokenId);

        Noted storage notedWithdraw = notedWithdraw[poolId][shareClassId][receiver][assetId];
        require(notedWithdraw.amount > 0, "BalanceSheetManager/invalid-noted-withdraw");

        _decrease(poolId, shareClassId, asset, tokenId, receiver, notedWithdraw.amount, notedWithdraw.pricePerUnit, block.timestamp, notedWithdraw.debits, notedWithdraw.credits);

        delete notedWithdraw[poolId][shareClassId][from][assetId];
    }

    function executeNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address provider,
    ) external {
        uint256 assetId = poolManager.assetToId(assetId, tokenId);

        Noted storage notedDeposit = notedDeposit[poolId][shareClassId][provider][assetId];
        require(notedDeposit.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        _increase(poolId, shareClassId, asset, tokenId, provider, notedDeposit.amount, notedDeposit.pricePerUnit, block.timestamp, notedDeposit.debits, notedDeposit.credits);

        delete notedDeposit[poolId][shareClassId][from][assetId];
    }


    function executeNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId,
        address receiver
    ) external {
        // TODO fetch storage
        Noted storage notedWithdraw = notedWithdraw[poolId][shareClassId][receiver][assetId];
        require(notedWithdraw.amount > 0, "BalanceSheetManager/invalid-noted-withdraw");

        _decrease(poolId, shareClassId, asset, tokenId, receiver, notedWithdraw.amount, notedWithdraw.pricePerUnit, block.timestamp, notedWithdraw.debits, notedWithdraw.credits);
    }

    function executeNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId,
        address provider,
    ) external {
        Noted storage notedDeposit = notedDeposit[poolId][shareClassId][provider][assetId];
        require(notedDeposit.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        _increase(poolId, shareClassId, asset, tokenId, provider, notedDeposit.amount, notedDeposit.pricePerUnit, block.timestamp, notedDeposit.debits, notedDeposit.credits);
    }

    // --- Internal ---
    function _decrease(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        address asset,
        uint256 tokenId
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits,
    ) internal {
        // TODO: ...
    }

    function _increase(
        uint64 poolId,
        bytes16 shareClassId,
        address provider,
        address asset,
        uint256 tokenId
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) internal {
        // TODO: Use PM to convert holding to assetId

        IPerPoolEscrow(escrow).pendingDepositIncrease(holding, assetId, poolId, shareClassId, add);

        // TODO: Transfer from provider to escrow

        IPerPoolEscrow(escrow).deposit(holding, assetId, poolId, shareClassId, add);

        // TODO: Send message to CP IncreaseHoldings()
    }

    // --- Internal Helpers ---
    // TODO: Check if really necessary. Maybe just use default on CP side if amount < total for the rest
    function _checkEntries(uint256 total, Entry[] entries) internal {
        if (entries.length ==  0) return;

        uint256 sum; 
        for (uint256 i = 0; i < entries.length; i++) {
            require(entries[i].part > 0, "PoolManager/invalid-entry-part");
            sum += entries[i].part;
        }

        require(total == sum, "PoolManager/invalid-entry-total");
    }