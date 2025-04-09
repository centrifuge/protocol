// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {JournalEntry, Meta} from "src/common/libraries/JournalEntryLib.sol";
import {IVaultMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {IBalanceSheetGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {IPerPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

contract BalanceSheet is Auth, Recoverable, IBalanceSheet, IBalanceSheetGatewayHandler, IUpdateContract {
    using MathLib for *;

    IPerPoolEscrow public immutable escrow;

    IGateway public gateway;
    IPoolManager public poolManager;
    IVaultMessageSender public sender;

    mapping(PoolId => mapping(ShareClassId => mapping(address => bool))) public permission;

    constructor(address escrow_) Auth(msg.sender) {
        escrow = IPerPoolEscrow(escrow_);
    }

    /// @dev Check if the msg.sender has permissions
    modifier authOrPermission(PoolId poolId, ShareClassId scId) {
        require(wards[msg.sender] == 1 || permission[poolId][scId][msg.sender], IAuth.NotAuthorized());
        _;
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else if (what == "poolManager") poolManager = IPoolManager(data);
        else if (what == "sender") sender = IVaultMessageSender(data);
        else revert("BalanceSheet/file-unrecognized-param");
        emit File(what, data);
    }

    /// --- IUpdateContract Implementation ---
    function update(uint64 poolId_, bytes16 scId_, bytes calldata payload) external auth {
        MessageLib.UpdateContractPermission memory m = MessageLib.deserializeUpdateContractPermission(payload);

        PoolId poolId = PoolId.wrap(poolId_);
        ShareClassId scId = ShareClassId.wrap(scId_);
        address who = address(bytes20(m.who));

        permission[poolId][scId][who] = m.allowed;

        emit Permission(poolId, scId, who, m.allowed);
    }

    /// --- External ---
    /// @inheritdoc IBalanceSheet
    function deposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _deposit(
            poolId,
            scId,
            AssetId.wrap(poolManager.checkedAssetToId(asset, tokenId)),
            asset,
            tokenId,
            provider,
            amount,
            pricePerUnit,
            m
        );
    }

    /// @inheritdoc IBalanceSheet
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external authOrPermission(poolId, scId) {
        _withdraw(
            poolId,
            scId,
            AssetId.wrap(poolManager.checkedAssetToId(asset, tokenId)),
            asset,
            tokenId,
            receiver,
            amount,
            pricePerUnit,
            m
        );
    }

    /// @inheritdoc IBalanceSheet
    function updateValue(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, D18 pricePerUnit)
        external
        auth
    {
        uint128 assetId = poolManager.checkedAssetToId(asset, tokenId);
        sender.sendUpdateHoldingValue(poolId, scId, AssetId.wrap(assetId), pricePerUnit);
        emit UpdateValue(poolId, scId, asset, tokenId, pricePerUnit, uint64(block.timestamp));
    }

    /// @inheritdoc IBalanceSheet
    function revoke(PoolId poolId, ShareClassId scId, address from, D18 pricePerShare, uint128 shares)
        external
        authOrPermission(poolId, scId)
    {
        _revoke(poolId, scId, from, pricePerShare, shares);
    }

    /// @inheritdoc IBalanceSheet
    function issue(PoolId poolId, ShareClassId scId, address to, D18 pricePerShare, uint128 shares)
        external
        authOrPermission(poolId, scId)
    {
        _issue(poolId, scId, to, pricePerShare, shares);
    }

    /// @inheritdoc IBalanceSheet
    function journalEntry(PoolId poolId, ShareClassId scId, Meta calldata m) external authOrPermission(poolId, scId) {
        // We do not need to ensure the meta here. Could be part of a batch and does not have to be balanced
        sender.sendJournalEntry(poolId, m.debits, m.credits);
        emit UpdateEntry(poolId, scId, m.debits, m.credits);
    }

    /// --- IBalanceSheetHandler ---
    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.checkedIdToAsset(assetId.raw());

        _deposit(poolId, scId, assetId, asset, tokenId, provider, amount, pricePerUnit, m);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerWithdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external auth {
        (address asset, uint256 tokenId) = poolManager.checkedIdToAsset(assetId.raw());
        _withdraw(poolId, scId, assetId, asset, tokenId, receiver, amount, pricePerUnit, m);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address to, D18 pricePerShare, uint128 shares)
        external
        auth
    {
        _issue(poolId, scId, to, pricePerShare, shares);
    }

    /// @inheritdoc IBalanceSheetGatewayHandler
    function triggerRevokeShares(PoolId poolId, ShareClassId scId, address from, D18 pricePerShare, uint128 shares)
        external
        auth
    {
        _revoke(poolId, scId, from, pricePerShare, shares);
    }

    // --- Internal ---
    function _issue(PoolId poolId, ShareClassId scId, address to, D18 pricePerShare, uint128 shares) internal {
        address token = poolManager.checkedShareToken(poolId.raw(), scId.raw());
        IShareToken(token).mint(address(to), shares);

        sender.sendUpdateShares(poolId, scId, to, pricePerShare, shares, true);
        emit Issue(poolId, scId, to, pricePerShare, shares);
    }

    function _revoke(PoolId poolId, ShareClassId scId, address from, D18 pricePerShare, uint128 shares) internal {
        address token = poolManager.checkedShareToken(poolId.raw(), scId.raw());
        IShareToken(token).burn(address(from), shares);

        sender.sendUpdateShares(poolId, scId, from, pricePerShare, shares, false);
        emit Revoke(poolId, scId, from, pricePerShare, shares);
    }

    function _withdraw(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) internal {
        _ensureBalancedEntries(pricePerUnit.mulUint128(amount), m);
        escrow.withdraw(asset, tokenId, poolId.raw(), scId.raw(), amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, address(escrow), receiver, amount);
        } else {
            IERC6909(asset).transferFrom(address(escrow), receiver, tokenId, amount);
        }

        sender.sendUpdateHoldingAmount(poolId, scId, assetId, receiver, amount, pricePerUnit, true, m);

        emit Withdraw(
            poolId, scId, asset, tokenId, receiver, amount, pricePerUnit, uint64(block.timestamp), m.debits, m.credits
        );
    }

    function _deposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) internal {
        _ensureBalancedEntries(pricePerUnit.mulUint128(amount), m);
        escrow.pendingDepositIncrease(asset, tokenId, poolId.raw(), scId.raw(), amount);

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, provider, address(escrow), amount);
        } else {
            IERC6909(asset).transferFrom(provider, address(escrow), tokenId, amount);
        }

        escrow.deposit(asset, tokenId, poolId.raw(), scId.raw(), amount);
        sender.sendUpdateHoldingAmount(poolId, scId, assetId, provider, amount, pricePerUnit, false, m);

        emit Deposit(
            poolId, scId, asset, tokenId, provider, amount, pricePerUnit, uint64(block.timestamp), m.debits, m.credits
        );
    }

    function _ensureBalancedEntries(uint128 amount, Meta calldata m) internal pure {
        uint128 totalDebits;
        uint128 totalCredits;

        for (uint256 i = 0; i < m.debits.length; i++) {
            totalDebits += m.debits[i].amount;
        }

        for (uint256 i = 0; i < m.credits.length; i++) {
            totalCredits += m.credits[i].amount;
        }

        require(totalDebits <= amount && totalCredits <= amount, EntriesUnbalanced());
    }
}
