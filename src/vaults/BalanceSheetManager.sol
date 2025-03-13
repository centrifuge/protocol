// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {Noted, Entry, IBalanceSheetManager} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";



contract BalanceSheetManager is Auth, IRecoverable, IBalanceSheetManager, IUpdateContract {
    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IMessageProcessor public sender;
    IPoolManager public poolManager;

    mapping(uint64 => mapping(bytes16 => mapping(address => bool))) public permission;
    mapping(uint64 => mapping(bytes16 => mapping(address => mapping(uint256 => Noted)))) public notedWithdraw;
    mapping(uint64 => mapping(bytes16 => mapping(address => mapping(uint256 => Noted)))) public notedDeposit;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = IPerPoolEscrow(escrow_);
    }

        /// @dev Check if the msg.sender has permissions
    modifier authOrPermission(uint64 poolId, bytes16 shareClassId) {
        require(wards[msg.sender] == 1 || permission[poolId][shareClassId][msg.sender], "NotAuthorized");
        _;
    }

    // --- Administration ---
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
    function update(uint64 poolId, bytes16 shareClassId, bytes calldata payload) external override auth {
        MessageLib.UpdateContractPermission memory m = MessageLib.deserializeUpdateContractPermission(payload);

        permission[poolId][shareClassId][m.who] = m.allowed;

        emit Permission(poolId, shareClassId, m.who, m.allowed);
    }

    /// --- Outgoing ---
    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] calldata debits,
        Entry[] calldata credits
    ) external authOrPermission(poolId, shareClassId) {
        _increase(poolId, shareClassId, asset, tokenId, provider, amount, pricePerUnit, timestamp, debits, credits);
    }

    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId,
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] calldata debits,
        Entry[] calldata credits
    ) external authOrPermission(poolId, shareClassId) {
        // TODO
        /*
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        require(asset != address(0), "PoolManager/invalid-asset-id");

        _increase(poolId, shareClassId, asset, tokenId, provider, amount, pricePerUnit, timestamp, debits, credits);
        */
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
        Entry[] calldata debits,
        Entry[] calldata credits
    ) external authOrPermission(poolId, shareClassId) {
        _decrease(poolId, shareClassId, asset, tokenId, receiver, amount, pricePerUnit, timestamp, debits, credits);
    }

    function decrease(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId,
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] calldata debits,
        Entry[] calldata credits
    ) external authOrPermission(poolId, shareClassId) {
        // TODO
        /*
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId);
        require(asset != address(0), "PoolManager/invalid-asset-id");

        _decrease(poolId, shareClassId, asset, tokenId, receiver, amount, pricePerUnit, timestamp, debits, credits);
        */
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
        Entry[] calldata debits,
        Entry[] calldata credits
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
        Entry[] calldata debits,
        Entry[] calldata credits
    ) external authOrPermission(poolId, shareClassId) {
        Noted storage notedWithdraw_ = notedWithdraw[poolId][shareClassId][receiver][assetId];

        notedWithdraw_.amount = amount;
        notedWithdraw_.pricePerUnit = pricePerUnit;
        /* TODO: Fix this with via-ir pipelie?
        notedWithdraw_.debits = debits;
        notedWithdraw_.credits = credits;
        */

        if (notedWithdraw_.amount == 0) {
            delete notedWithdraw[poolId][shareClassId][receiver][assetId];
        }

        notedWithdraw[poolId][shareClassId][receiver][assetId] = notedWithdraw_;

        emit NoteWithdraw(poolId, shareClassId, receiver, assetId, amount, pricePerUnit, debits, credits);
    }

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        Entry[] calldata debits,
        Entry[] calldata credits
    ) external authOrPermission(poolId, shareClassId) {
        Noted storage notedDeposit_ = notedDeposit[poolId][shareClassId][from][assetId];

            notedDeposit_.amount = amount;

        notedDeposit_.pricePerUnit = pricePerUnit;
        /* TODO: Fix this with via-ir pipelie?
        notedDeposit_.debits = debits;
        notedDeposit_.credits = credits;
        */

        if (notedDeposit_.amount == 0) {
            delete notedDeposit[poolId][shareClassId][from][assetId];
        }

        notedDeposit[poolId][shareClassId][from][assetId] = notedDeposit_;

        emit NoteDeposit(poolId, shareClassId, from, assetId, amount, pricePerUnit, debits, credits);
    }

    function executeNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver
    ) external {
        // TODO
    }

    function executeNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId,
        address receiver
    ) external {
        Noted storage notedWithdraw_ = notedWithdraw[poolId][shareClassId][receiver][assetId];
        require(notedWithdraw_.amount > 0, "BalanceSheetManager/invalid-noted-withdraw");

        // _decrease(poolId, shareClassId, asset, tokenId, receiver, notedWithdraw_.amount, notedWithdraw_.pricePerUnit, block.timestamp, notedWithdraw_.debits, notedWithdraw_.credits);
    }

    function executeNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address provider
    ) external {
        // TODO
    }

    function executeNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId,
        address provider
    ) external {
        Noted storage notedDeposit_ = notedDeposit[poolId][shareClassId][provider][assetId];
        require(notedDeposit_.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        // _increase(poolId, shareClassId, asset, tokenId, provider, notedDeposit_.amount, notedDeposit_.pricePerUnit, block.timestamp, notedDeposit_.debits, notedDeposit_.credits);
    }

    // --- Internal ---
    function _decrease(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] calldata debits,
        Entry[] calldata credits
    ) internal {
        // TODO: ...
    }

    function _increase(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] calldata debits,
        Entry[] calldata credits
    ) internal {
        // TODO: Use PM to convert holding to assetId

        //   IPerPoolEscrow(escrow).pendingDepositIncrease(holding, assetId, poolId, shareClassId, add);

        // TODO: Transfer from provider to escrow

        //        IPerPoolEscrow(escrow).deposit(holding, assetId, poolId, shareClassId, add);

        // TODO: Send message to CP IncreaseHoldings()
    }
}