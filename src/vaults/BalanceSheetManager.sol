// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheetManager} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";

contract BalanceSheetManager is Auth, IRecoverable, IBalanceSheetManager, IUpdateContract {
    using MathLib for *;

    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IMessageProcessor public sender;
    IPoolManager public poolManager;

    mapping(uint64 => mapping(bytes16 => mapping(address => bool))) public permission;

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

    /// --- External ---
    function deposit(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        address valuation,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _deposit(
            poolId,
            scId,
            poolManager.assetToId(asset),
            asset,
            tokenId,
            provider,
            amount,
            _getPrice(valuation, asset, tokenId),
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
        address valuation,
        bool asAllowance,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _withdraw(
            poolId,
            scId,
            poolManager.assetToId(asset),
            asset,
            tokenId,
            receiver,
            amount,
            _getPrice(valuation, asset, tokenId),
            asAllowance,
            m
        );
    }

    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares, bool asAllowance)
        external
        authOrPermission(poolId, scId)
    {
        address token = poolManager.getTranche(poolId, scId);

        if (asAllowance) {
            ITranche(token).mint(address(this), shares);
            IERC20(token).approve(address(to), shares);
        } else {
            ITranche(token).mint(address(to), shares);
        }

        sender.sendIssueShares(poolId, scId, to, shares, block.timestamp);
        emit IssueShares(poolId, scId, to, shares);
    }

    function revoke(uint64 poolId, bytes16 scId, address from, uint128 shares)
        external
        authOrPermission(poolId, scId)
    {
        address token = poolManager.getTranche(poolId, scId);
        ITranche(token).burn(address(from), shares);

        sender.sendRevokeShares(poolId, scId, from, shares, block.timestamp);
        emit RevokeShares(poolId, scId, from, shares);
    }

    function journalEntry(uint64 poolId, bytes16 scId, Meta calldata m) external authOrPermission(poolId, scId) {
        sender.sendJournalEntry(poolId, scId, m.debits, m.credits);
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
        bool asAllowance,
        Meta memory m
    ) internal {
        escrow.withdraw(asset, tokenId, poolId, scId, amount);

        if (tokenId == 0) {
            if (asAllowance) {
                SafeTransferLib.safeTransferFrom(asset, address(escrow), address(this), amount);
                SafeTransferLib.safeApprove(asset, receiver, amount);
            } else {
                SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, amount);
            }
        } else {
            if (asAllowance) {
                IERC6909(asset).transferFrom(address(escrow), address(this), tokenId, amount);
                IERC6909(asset).approve(receiver, tokenId, amount);
            } else {
                IERC6909(asset).transferFrom(address(escrow), receiver, tokenId, amount);
            }
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
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta memory m
    ) internal {
        escrow.pendingDepositIncrease(asset, tokenId, poolId, scId, amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, provider, address(escrow), amount);
        } else {
            IERC6909(asset).transferFrom(provider, address(escrow), tokenId, amount);
        }

        escrow.deposit(asset, tokenId, poolId, scId, amount);
        sender.sendIncreaseHolding(
            poolId, scId, assetId, provider, amount, pricePerUnit, m.timestamp, m.debits, m.credits
        );

        emit Deposit(poolId, scId, asset, tokenId, provider, amount, pricePerUnit, m.timestamp, m.debits, m.credits);
    }

    function _getPrice(address valuation, address asset, uint256 /* tokenId */ ) internal returns (D18) {
        return d18(
            IERC7726(valuation).getQuote(1, address(0), asset) // TODO: Fix this - e.g. 1 *
                // poolManager.poolDecimals(poolId),
                // TODO: Fix this - e.g. poolManager.poolCurrency(poolId),
                /* TODO: tokenId compatible */
                .toUint128()
        );
    }
}
