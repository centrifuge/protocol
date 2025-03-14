// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {D18} from "src/misc/types/D18.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {Noted, JournalEntry, IBalanceSheetManager, Meta} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";

contract BalanceSheetManager is Auth, IRecoverable, IBalanceSheetManager, IUpdateContract {
    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IMessageProcessor public sender;
    IPoolManager public poolManager;

    mapping(uint64 => mapping(bytes16 => mapping(address => bool))) public permission;
    mapping(uint64 => mapping(bytes16 => mapping(address => mapping(uint128 => Noted)))) public notedWithdraw;
    mapping(uint64 => mapping(bytes16 => mapping(address => mapping(uint128 => Noted)))) public notedDeposit;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = IPerPoolEscrow(escrow_);
    }

    /// @dev Check if the msg.sender has permissions
    modifier authOrPermission(uint64 poolId, bytes16 scId) {
        require(wards[msg.sender] == 1 || permission[poolId][scId][msg.sender], "NotAuthorized");
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
    function update(uint64 poolId, bytes16 scId, bytes calldata payload) external override auth {
        MessageLib.UpdateContractPermission memory m = MessageLib.deserializeUpdateContractPermission(payload);

        permission[poolId][scId][m.who] = m.allowed;

        emit Permission(poolId, scId, m.who, m.allowed);
    }

    /// --- Outgoing ---
    function deposit(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _deposit(poolId, scId, poolManager.assetToId(asset), asset, tokenId, provider, amount, pricePerUnit, m);
    }

    function deposit(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _deposit(
            poolId,
            scId,
            assetId,
            poolManager.idToAsset(assetId),
            0, // TODO: Fix this when pool manager returns tokenId
            provider,
            amount,
            pricePerUnit,
            m
        );
    }

    function withdraw(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _withdraw(poolId, scId, poolManager.assetToId(asset), asset, tokenId, receiver, amount, pricePerUnit, m);
    }

    function withdraw(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _withdraw(
            poolId,
            scId,
            assetId,
            poolManager.idToAsset(assetId),
            0, // TODO: Fix this when pool manager returns tokenId
            receiver,
            amount,
            pricePerUnit,
            m
        );
    }

    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares, D18 pricePerShare, uint64 timestamp)
        external
        authOrPermission(poolId, scId)
    {
        // TODO: Mint shares to to

        // TODO: Send message to CP UpdateShares()
    }

    function revoke(uint64 poolId, bytes16 scId, address from, uint128 shares, D18 pricePerShare, uint64 timestamp)
        external
        authOrPermission(poolId, scId)
    {
        // TODO: burn shares from from

        // TODO: Send message to CP UpdateShares()
    }

    function journalEntry(uint64 poolId, bytes16 scId, Meta calldata m) external authOrPermission(poolId, scId) {
        // TODO: Send message to CP JournalEntry()
    }

    // --- Incoming ---
    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 scId,
        address receiver,
        uint128 assetId,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        Noted storage noted = notedWithdraw[poolId][scId][receiver][assetId];

        noted.amount = amount;
        noted.pricePerUnit = pricePerUnit;
        noted.m = m;

        if (noted.amount == 0) {
            delete notedWithdraw[poolId][scId][receiver][assetId];
        } else {
            notedWithdraw[poolId][scId][receiver][assetId] = noted;
        }

        emit NoteWithdraw(
            poolId,
            scId,
            receiver,
            poolManager.idToAsset(assetId),
            0, /* TODO: Fix once ERC6909 is in */
            amount,
            pricePerUnit,
            m.timestamp,
            m.debits,
            m.credits
        );
    }

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 scId,
        address provider,
        uint128 assetId,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        Noted storage noted = notedDeposit[poolId][scId][provider][assetId];

        noted.amount = amount;
        noted.pricePerUnit = pricePerUnit;
        noted.m = m;

        if (noted.amount == 0) {
            delete notedDeposit[poolId][scId][provider][assetId];
        } else {
            notedDeposit[poolId][scId][provider][assetId] = noted;
        }

        emit NoteDeposit(
            poolId,
            scId,
            provider,
            poolManager.idToAsset(assetId),
            0, /* TODO: Fix once ERC6909 is in */
            amount,
            pricePerUnit,
            m.timestamp,
            m.debits,
            m.credits
        );
    }

    function executeNotedWithdraw(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address receiver)
        external
    {
        uint128 assetId = poolManager.assetToId(asset);
        Noted storage noted = notedDeposit[poolId][scId][receiver][assetId];

        require(noted.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        if (noted.m.timestamp == 0) {
            // TODO: Fix timestamp to uint256
            // noted.m.timestamp = block.timestamp;
        }

        _withdraw(
            poolId,
            scId,
            assetId,
            asset,
            tokenId,
            receiver,
            noted.amount,
            noted.pricePerUnit,
            noted.m
        );
    }

    function executeNotedWithdraw(uint64 poolId, bytes16 scId, uint128 assetId, address receiver) external {
        Noted storage noted = notedDeposit[poolId][scId][receiver][assetId];

        require(noted.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        if (noted.m.timestamp == 0) {
            // TODO: Fix timestamp to uint256
            // noted.m.timestamp = block.timestamp;
        }

        _withdraw(
            poolId,
            scId,
            assetId,
            poolManager.idToAsset(assetId),
            0, /* TODO: Fix once ERC6909 is in */
            receiver,
            noted.amount,
            noted.pricePerUnit,
            noted.m
        );
    }

    function executeNotedDeposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address provider)
        external
    {
        uint128 assetId = poolManager.assetToId(asset);
        Noted storage noted = notedDeposit[poolId][scId][provider][assetId];

        require(noted.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        if (noted.m.timestamp == 0) {
            // TODO: Fix timestamp to uint256
            // noted.m.timestamp = block.timestamp;
        }

        _deposit(
            poolId,
            scId,
            assetId,
            asset,
            tokenId,
            provider,
            noted.amount,
            noted.pricePerUnit,
            noted.m
        );
    }

    function executeNotedDeposit(uint64 poolId, bytes16 scId, uint128 assetId, address provider) external {
        Noted storage noted = notedWithdraw[poolId][scId][provider][assetId];

        require(noted.amount > 0, "BalanceSheetManager/invalid-noted-withdraw");

        if (noted.m.timestamp == 0) {
            // TODO: Fix timestamp to uint256
            // noted.m.timestamp = block.timestamp;
        }

        _deposit(
            poolId,
            scId,
            assetId,
            poolManager.idToAsset(assetId),
            0, /* TODO: Fix once ERC6909 is in */
            provider,
            noted.amount,
            noted.pricePerUnit,
            noted.m
        );
    }

    // --- Internal ---
    function _withdraw(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta memory m
    ) internal {
        escrow.withdraw(asset, tokenId, poolId, scId, amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, amount);
        } else {
            IERC6909(asset).transferFrom(address(escrow), receiver, tokenId, amount);
        }

        sender.sendDecreaseHolding(
            poolId, scId, assetId, receiver, amount, pricePerUnit, m.timestamp, m.debits, m.credits
        );

        emit Withdraw(poolId, scId, asset, tokenId, receiver, amount, pricePerUnit, m.timestamp, m.debits, m.credits);
    }

    function _deposit(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address asset,
        uint256 tokenId,
        address who,
        uint128 amount,
        D18 pricePerUnit,
        Meta memory m
    ) internal {
        escrow.pendingDepositIncrease(asset, tokenId, poolId, scId, amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, who, address(escrow), amount);
        } else {
            IERC6909(asset).transferFrom(who, address(escrow), tokenId, amount);
        }

        escrow.deposit(asset, tokenId, poolId, scId, amount);
        sender.sendIncreaseHolding(poolId, scId, assetId, who, amount, pricePerUnit, m.timestamp, m.debits, m.credits);

        emit Deposit(poolId, scId, asset, tokenId, who, amount, pricePerUnit, m.timestamp, m.debits, m.credits);
    }
}
