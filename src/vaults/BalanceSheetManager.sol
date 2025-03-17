// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRecoverable} from "src/common/interfaces/IRoot.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {Noted, JournalEntry, IBalanceSheetManager, Meta} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IMessageProcessor} from "src/vaults/interfaces/IMessageProcessor.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";

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
        IERC7726 valuation,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _deposit(
            poolId, scId, poolManager.assetToId(asset), asset, tokenId, provider, amount, _getPrice(valuation, asset), m
        );
    }

    function deposit(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address provider,
        uint128 amount,
        IERC7726 valuation,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        address asset = poolManager.idToAsset(assetId);
        _deposit(
            poolId,
            scId,
            assetId,
            asset,
            0, // TODO: Fix this when pool manager returns tokenId
            provider,
            amount,
            _getPrice(valuation, asset),
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
        IERC7726 valuation,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _withdraw(
            poolId, scId, poolManager.assetToId(asset), asset, tokenId, receiver, amount, _getPrice(valuation, asset), m
        );
    }

    function withdraw(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address receiver,
        uint128 amount,
        IERC7726 valuation,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        address asset = poolManager.idToAsset(assetId);

        _withdraw(
            poolId,
            scId,
            assetId,
            asset,
            0, // TODO: Fix this when pool manager returns tokenId
            receiver,
            amount,
            _getPrice(valuation, asset),
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

    // --- Incoming ---
    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address receiver,
        uint128 amount,
        bytes32 encoded,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        Noted storage noted = notedWithdraw[poolId][scId][receiver][assetId];

        noted.amount = amount;
        noted.encoded = encoded;
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
            encoded,
            m.timestamp,
            m.debits,
            m.credits
        );
    }

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address provider,
        uint128 amount,
        bytes32 encoded,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        Noted storage noted = notedDeposit[poolId][scId][provider][assetId];

        noted.amount = amount;
        noted.encoded = encoded;
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
            encoded,
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

        D18 pricePerUnit;
        if (noted.isRawPrice()) {
            pricePerUnit = noted.asRawPrice();
        } else {
            // TODO: Check cast?
            pricePerUnit = _getPrice(noted.asValuation(), asset);
        }

        _withdraw(
            poolId, scId, assetId, asset, tokenId, receiver, noted.amount, pricePerUnit, noted.allowance(), noted.m
        );
    }

    function executeNotedWithdraw(uint64 poolId, bytes16 scId, uint128 assetId, address receiver) external {
        Noted storage noted = notedDeposit[poolId][scId][receiver][assetId];

        require(noted.amount > 0, "BalanceSheetManager/invalid-noted-deposit");

        if (noted.m.timestamp == 0) {
            // TODO: Fix timestamp to uint256
            // noted.m.timestamp = block.timestamp;
        }

        address asset = poolManager.idToAsset(assetId);

        D18 pricePerUnit;
        if (noted.isRawPrice()) {
            pricePerUnit = noted.asRawPrice();
        } else {
            // TODO: Check cast?
            pricePerUnit = _getPrice(noted.asValuation(), asset);
        }

        _withdraw(
            poolId,
            scId,
            assetId,
            asset,
            0, // TODO: Fix this when pool manager returns tokenId
            receiver,
            noted.amount,
            pricePerUnit,
            noted.allowance(),
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

        D18 pricePerUnit;
        if (noted.isRawPrice()) {
            pricePerUnit = noted.asRawPrice();
        } else {
            // TODO: Check cast?
            pricePerUnit = _getPrice(noted.asValuation(), asset);
        }

        _deposit(poolId, scId, assetId, asset, tokenId, provider, noted.amount, pricePerUnit, noted.m);
    }

    function executeNotedDeposit(uint64 poolId, bytes16 scId, uint128 assetId, address provider) external {
        Noted storage noted = notedWithdraw[poolId][scId][provider][assetId];

        require(noted.amount > 0, "BalanceSheetManager/invalid-noted-withdraw");

        if (noted.m.timestamp == 0) {
            // TODO: Fix timestamp to uint256
            // noted.m.timestamp = block.timestamp;
        }

        address asset = poolManager.idToAsset(assetId);
        D18 pricePerUnit;
        if (noted.isRawPrice()) {
            pricePerUnit = noted.asRawPrice();
        } else {
            pricePerUnit = _getPrice(noted.asValuation(), asset);
        }

        _deposit(
            poolId,
            scId,
            assetId,
            asset,
            0, /* TODO: Fix this when pool manager returns tokenId */
            provider,
            noted.amount,
            pricePerUnit,
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

    function _getPrice(address valuation, address asset) internal view returns (D18) {
        // TODO: Check cast?
        return d18(
            uint128(
                IERC7726(valuation).getQuote(
                    1, // TODO: Fix this - e.g. 1 * poolManager.poolDecimals(poolId),
                    address(0), // TODO: Fix this - e.g. poolManager.poolCurrency(poolId),
                    asset /* TODO: tokenId compatible */
                )
            )
        );
    }
}
