// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ERC20} from "../../../../src/misc/ERC20.sol";
import {D18} from "../../../../src/misc/types/D18.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../../src/misc/interfaces/IERC165.sol";
import {IERC7575Share} from "../../../../src/misc/interfaces/IERC7575.sol";

import {Hub} from "../../../../src/core/hub/Hub.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {VaultKind} from "../../../../src/core/spoke/interfaces/IVault.sol";
import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {MessageLib} from "../../../../src/core/messaging/libraries/MessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {ISyncManager} from "../../../../src/vaults/interfaces/IVaultManagers.sol";
import {IAsyncRedeemVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {RequestCallbackMessageLib} from "../../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

import {FullReport} from "../../../../script/FullDeployer.s.sol";
import {VaultGraphQLData} from "../../../../script/spell/MigrationQueries.sol";

import {Test} from "forge-std/Test.sol";

import {IntegrationConstants} from "../../../integration/utils/IntegrationConstants.sol";

/// @notice Simple adapter that accepts outgoing messages without delivering them
/// @dev Used for cross-chain fork tests where we don't want immediate loop-back delivery
contract PassthroughAdapter is IAdapter {
    function send(uint16, bytes calldata, uint256, address refund) external payable returns (bytes32) {
        // Just refund the gas - don't try to deliver the message
        // The actual response will come from _simulateHubDepositSequence()
        (bool success,) = payable(refund).call{value: msg.value}("");
        require(success, "Refund failed");
        return bytes32(0);
    }

    function estimate(uint16, bytes calldata, uint256 gasLimit) external pure returns (uint256) {
        return gasLimit;
    }
}

struct InvestmentFlowResult {
    address vault;
    VaultKind kind;
    bool isCrossChain;
    bool depositPassed;
    bool redeemPassed;
    string depositError;
    string redeemError;
}

struct InvestmentFlowContext {
    FullReport report;
    VaultGraphQLData gql;
    uint16 localCentrifugeId;
    PoolId poolId;
    ShareClassId scId;
    AssetId assetId;
    uint128 testAmount;
    address shareToken;
}

struct ShareTokenMeta {
    address shareToken;
    PoolId poolId;
    ShareClassId scId;
    address depositAsset;
    bool exists;
}

/// @title InvestmentFlowExecutor
/// @notice Executes investment flows for vault validation
contract InvestmentFlowExecutor is Test {
    using CastLib for *;
    using MessageLib for *;
    using RequestCallbackMessageLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 constant GAS = IntegrationConstants.GAS;
    uint128 constant HOOK_GAS = IntegrationConstants.HOOK_GAS;
    uint256 constant UNIQUE_INVESTOR_OFFSET = 1000;

    mapping(address => ShareTokenMeta) internal _shareTokenCache;

    receive() external payable {}

    // ============================================
    // Entry Points
    // ============================================

    function executeAllFlows(FullReport memory report, VaultGraphQLData[] memory vaults, uint16 localCentrifugeId)
        external
        returns (InvestmentFlowResult[] memory results)
    {
        results = new InvestmentFlowResult[](vaults.length);

        _buildShareTokenCache(vaults);
        _fundHubManagers(vaults);

        for (uint256 i = 0; i < vaults.length; i++) {
            results[i] = _executeSingleVault(report, vaults[i], localCentrifugeId, i);
        }
    }

    function _executeSingleVault(
        FullReport memory report,
        VaultGraphQLData memory gql,
        uint16 localCentrifugeId,
        uint256 index
    ) internal returns (InvestmentFlowResult memory result) {
        result.vault = gql.vault;
        result.kind = _parseVaultKind(gql.kind);
        result.isCrossChain = gql.hubCentrifugeId != localCentrifugeId;

        InvestmentFlowContext memory ctx = _buildContext(report, gql, localCentrifugeId);

        if (result.kind == VaultKind.Async) {
            if (result.isCrossChain) {
                _executeCrossChainAsync(ctx, index, result);
            } else {
                _executeLocalAsync(ctx, index, result);
            }
        } else if (result.kind == VaultKind.SyncDepositAsyncRedeem) {
            _executeSyncDeposit(ctx, index, result);
        }
    }

    function _buildContext(FullReport memory report, VaultGraphQLData memory gql, uint16 localCentrifugeId)
        internal
        view
        returns (InvestmentFlowContext memory ctx)
    {
        ctx.report = report;
        ctx.gql = gql;
        ctx.localCentrifugeId = localCentrifugeId;
        ctx.poolId = PoolId.wrap(gql.poolIdRaw);
        ctx.scId = ShareClassId.wrap(gql.tokenIdRaw);
        ctx.assetId = report.core.spoke.assetToId(gql.assetAddress, 0);
        ctx.testAmount = _calculateTestAmount(gql.assetDecimals);
        ctx.shareToken = IBaseVault(gql.vault).share();
    }

    function _buildShareTokenCache(VaultGraphQLData[] memory vaults) internal {
        for (uint256 i = 0; i < vaults.length; i++) {
            VaultGraphQLData memory gql = vaults[i];
            address shareToken = IBaseVault(gql.vault).share();

            if (shareToken != address(0)) {
                _shareTokenCache[shareToken] = ShareTokenMeta({
                    shareToken: shareToken,
                    poolId: PoolId.wrap(gql.poolIdRaw),
                    scId: ShareClassId.wrap(gql.tokenIdRaw),
                    depositAsset: gql.assetAddress,
                    exists: true
                });
            }
        }
    }

    function _fundHubManagers(VaultGraphQLData[] memory vaults) internal {
        address[] memory funded = new address[](vaults.length);
        uint256 fundedCount = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            address manager = vaults[i].hubManager;

            bool alreadyFunded = false;
            for (uint256 j = 0; j < fundedCount; j++) {
                if (funded[j] == manager) {
                    alreadyFunded = true;
                    break;
                }
            }

            if (!alreadyFunded) {
                vm.deal(manager, 10 ether);
                funded[fundedCount++] = manager;
            }
        }
    }

    // ============================================
    // Local Async Flows
    // ============================================

    function _executeLocalAsync(InvestmentFlowContext memory ctx, uint256 index, InvestmentFlowResult memory result)
        internal
    {
        address depositInvestor = makeAddr(string.concat("DEPOSIT_", vm.toString(index)));
        address redeemInvestor = makeAddr(string.concat("REDEEM_", vm.toString(index)));

        try this.tryLocalAsyncDeposit(ctx, depositInvestor) {
            result.depositPassed = true;
        } catch Error(string memory reason) {
            result.depositError = reason;
        } catch (bytes memory data) {
            result.depositError = _formatRevertData(data);
        }

        try this.tryLocalAsyncRedeem(ctx, redeemInvestor) {
            result.redeemPassed = true;
        } catch Error(string memory reason) {
            result.redeemError = reason;
        } catch (bytes memory data) {
            result.redeemError = _formatRevertData(data);
        }
    }

    function tryLocalAsyncDeposit(InvestmentFlowContext memory ctx, address investor) external {
        if (_isShareToken(ctx.gql.assetAddress)) {
            ShareTokenMeta memory stMeta = _shareTokenCache[ctx.gql.assetAddress];
            require(stMeta.exists, "ShareToken not in cache");
            AssetId sourceAssetId = ctx.report.core.spoke.assetToId(stMeta.depositAsset, 0);
            _configurePrices(
                ctx.report, stMeta.poolId, stMeta.scId, sourceAssetId, ctx.gql.hubManager, ctx.localCentrifugeId
            );
            _whitelistInvestor(
                ctx.report, stMeta.poolId, stMeta.scId, investor, ctx.gql.hubManager, ctx.localCentrifugeId
            );
        }

        _whitelistInvestor(ctx.report, ctx.poolId, ctx.scId, investor, ctx.gql.hubManager, ctx.localCentrifugeId);
        _fundInvestor(ctx, investor);
        _asyncDepositFlow(ctx, investor);
    }

    function tryLocalAsyncRedeem(InvestmentFlowContext memory ctx, address investor) external {
        this.tryLocalAsyncDeposit(ctx, investor);
        _asyncRedeemFlow(ctx, investor);
    }

    function _asyncDepositFlow(InvestmentFlowContext memory ctx, address investor) internal {
        _configurePrices(ctx.report, ctx.poolId, ctx.scId, ctx.assetId, ctx.gql.hubManager, ctx.localCentrifugeId);

        IAsyncVault vault = IAsyncVault(ctx.gql.vault);

        vm.startPrank(investor);
        ERC20(ctx.gql.assetAddress).approve(ctx.gql.vault, ctx.testAmount);
        vault.requestDeposit(ctx.testAmount, investor, investor);
        vm.stopPrank();

        _ensureDepositEpochsAligned(ctx);
        _approveAndIssueDeposit(ctx, ctx.testAmount);
        _notifyAndClaimDeposit(ctx, investor, vault);
    }

    function _asyncRedeemFlow(InvestmentFlowContext memory ctx, address investor) internal {
        _whitelistInvestor(ctx.report, ctx.poolId, ctx.scId, investor, ctx.gql.hubManager, ctx.localCentrifugeId);

        IAsyncRedeemVault vault = IAsyncRedeemVault(ctx.gql.vault);

        uint128 shares = uint128(ctx.report.core.spoke.shareToken(ctx.poolId, ctx.scId).balanceOf(investor));

        vm.startPrank(investor);
        vault.requestRedeem(shares, investor, investor);
        vm.stopPrank();

        _ensureRedeemEpochsAligned(ctx);
        _approveAndRevokeRedeem(ctx, shares);
        _notifyAndClaimRedeem(ctx, investor, vault);
    }

    // ============================================
    // Sync Deposit Flow
    // ============================================

    function _executeSyncDeposit(InvestmentFlowContext memory ctx, uint256 index, InvestmentFlowResult memory result)
        internal
    {
        address investor = makeAddr(string.concat("SYNC_", vm.toString(index)));

        try this.trySyncDeposit(ctx, investor) {
            result.depositPassed = true;
        } catch Error(string memory reason) {
            result.depositError = reason;
        } catch (bytes memory data) {
            result.depositError = _formatRevertData(data);
        }

        try this.trySyncDepositThenRedeem(ctx, investor) {
            result.redeemPassed = true;
        } catch Error(string memory reason) {
            result.redeemError = reason;
        } catch (bytes memory data) {
            result.redeemError = _formatRevertData(data);
        }
    }

    function trySyncDeposit(InvestmentFlowContext memory ctx, address investor) external {
        _fundInvestorForSync(ctx, investor);
        _whitelistInvestor(ctx.report, ctx.poolId, ctx.scId, investor, ctx.gql.hubManager, ctx.localCentrifugeId);
        _syncDepositFlow(ctx, investor);
    }

    function trySyncDepositThenRedeem(InvestmentFlowContext memory ctx, address investor) external {
        // Different investor for isolation
        address redeemInvestor = makeAddr(string.concat("SYNC_REDEEM_", vm.toString(uint256(uint160(investor)))));
        _fundInvestorForSync(ctx, redeemInvestor);
        _whitelistInvestor(ctx.report, ctx.poolId, ctx.scId, redeemInvestor, ctx.gql.hubManager, ctx.localCentrifugeId);
        _syncDepositFlow(ctx, redeemInvestor);
        _asyncRedeemFlow(ctx, redeemInvestor);
    }

    function _syncDepositFlow(InvestmentFlowContext memory ctx, address investor) internal {
        _configurePrices(ctx.report, ctx.poolId, ctx.scId, ctx.assetId, ctx.gql.hubManager, ctx.localCentrifugeId);

        // Known issue: Plume SyncManager valuation misconfigured
        if (ctx.localCentrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
            address valuationContract = 0x0074949f14aA3DD72C3C77b715ED60e03B4A5bC9;
            vm.mockCall(
                valuationContract,
                abi.encodeWithSelector(bytes4(keccak256("pricePoolPerShare(uint64,bytes16)")), ctx.poolId, ctx.scId),
                abi.encode(IntegrationConstants.identityPrice())
            );
        }

        vm.startPrank(ctx.gql.hubManager);
        ctx.report.core.hub.updateContract{value: GAS}(
            ctx.poolId,
            ctx.scId,
            ctx.localCentrifugeId,
            address(ctx.report.syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(ctx.assetId, type(uint128).max),
            IntegrationConstants.EXTRA_GAS,
            address(this)
        );
        vm.stopPrank();

        IBaseVault vault = IBaseVault(ctx.gql.vault);
        uint256 initialShares = ctx.report.core.spoke.shareToken(ctx.poolId, ctx.scId).balanceOf(investor);

        vm.startPrank(investor);
        ERC20(vault.asset()).approve(ctx.gql.vault, ctx.testAmount);
        vault.deposit(ctx.testAmount, investor);
        vm.stopPrank();

        assertTrue(
            ctx.report.core.spoke.shareToken(ctx.poolId, ctx.scId).balanceOf(investor) > initialShares,
            "Investor should have received shares"
        );
    }

    // ============================================
    // Cross-Chain Async Flows
    // ============================================

    function _executeCrossChainAsync(
        InvestmentFlowContext memory ctx,
        uint256 index,
        InvestmentFlowResult memory result
    ) internal {
        try this.tryCrossChainAsyncDeposit(ctx, index) {
            result.depositPassed = true;
        } catch Error(string memory reason) {
            result.depositError = reason;
        } catch (bytes memory data) {
            result.depositError = _formatRevertData(data);
        }

        try this.tryCrossChainAsyncRedeem(ctx, index) {
            result.redeemPassed = true;
        } catch Error(string memory reason) {
            result.redeemError = reason;
        } catch (bytes memory data) {
            result.redeemError = _formatRevertData(data);
        }
    }

    function tryCrossChainAsyncDeposit(InvestmentFlowContext memory ctx, uint256 index)
        external
        returns (address investor)
    {
        investor = makeAddr(string.concat("XC_DEPOSIT_", vm.toString(index)));
        IAsyncVault vault = IAsyncVault(ctx.gql.vault);

        _simulateHubNotifyPrices(ctx);
        deal(ctx.gql.assetAddress, investor, IntegrationConstants.DEFAULT_USDC_AMOUNT);
        _simulateWhitelistMember(ctx, investor);
        _deployRefundEscrowIfNeeded(ctx);
        _configureHubAdaptersIfNeeded(ctx);

        vm.startPrank(investor);
        ERC20(ctx.gql.assetAddress).approve(ctx.gql.vault, IntegrationConstants.DEFAULT_USDC_AMOUNT);
        vault.requestDeposit(IntegrationConstants.DEFAULT_USDC_AMOUNT, investor, investor);
        vm.stopPrank();

        _simulateHubDepositSequence(
            ctx, investor, IntegrationConstants.DEFAULT_USDC_AMOUNT, IntegrationConstants.DEFAULT_USDC_AMOUNT, 0
        );

        uint256 initialShares = ERC20(ctx.shareToken).balanceOf(investor);
        uint256 maxMintable = vault.maxMint(investor);
        assertTrue(maxMintable > 0, "Should have shares to mint after Hub fulfillment");

        vm.startPrank(investor);
        vault.mint(maxMintable, investor);
        vm.stopPrank();

        assertTrue(ERC20(ctx.shareToken).balanceOf(investor) > initialShares, "Deposit flow should have minted shares");
    }

    function tryCrossChainAsyncRedeem(InvestmentFlowContext memory ctx, uint256 index) external {
        address investor = this.tryCrossChainAsyncDeposit(ctx, index + UNIQUE_INVESTOR_OFFSET);

        IAsyncVault vault = IAsyncVault(ctx.gql.vault);

        uint128 sharesToRedeem = uint128(ERC20(ctx.shareToken).balanceOf(investor));
        assertTrue(sharesToRedeem > 0, "Investor should have shares to redeem");

        vm.startPrank(investor);
        vault.requestRedeem(sharesToRedeem, investor, investor);
        vm.stopPrank();

        _simulateHubRedeemSequence(ctx, investor, IntegrationConstants.DEFAULT_USDC_AMOUNT, sharesToRedeem, 0);

        uint256 initialAssets = ERC20(ctx.gql.assetAddress).balanceOf(investor);
        uint256 maxWithdrawable = vault.maxWithdraw(investor);
        assertTrue(maxWithdrawable > 0, "Should have assets to withdraw after Hub fulfillment");

        vm.startPrank(investor);
        vault.withdraw(maxWithdrawable, investor, investor);
        vm.stopPrank();

        assertTrue(
            ERC20(ctx.gql.assetAddress).balanceOf(investor) > initialAssets,
            "Investor should have received assets from redeem"
        );
    }

    // ============================================
    // Hub Operations
    // ============================================

    function _configurePrices(
        FullReport memory report,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address hubManager,
        uint16 localCentrifugeId
    ) internal {
        vm.startPrank(hubManager);
        report.core.hub.updateSharePrice(poolId, scId, IntegrationConstants.identityPrice(), uint64(block.timestamp));
        report.core.hub.notifySharePrice{value: GAS}(poolId, scId, localCentrifugeId, address(this));
        report.core.hub.notifyAssetPrice{value: GAS}(poolId, scId, assetId, address(this));
        vm.stopPrank();
    }

    function _whitelistInvestor(
        FullReport memory report,
        PoolId poolId,
        ShareClassId scId,
        address investor,
        address hubManager,
        uint16 localCentrifugeId
    ) internal {
        vm.startPrank(hubManager);
        report.core.hub.updateRestriction{value: GAS}(
            poolId, scId, localCentrifugeId, _updateRestrictionMemberMsg(investor), HOOK_GAS, address(this)
        );
        vm.stopPrank();
    }

    function _approveAndIssueDeposit(InvestmentFlowContext memory ctx, uint128 amount) internal {
        vm.startPrank(ctx.gql.hubManager);

        uint32 depositEpochId = ctx.report.batchRequestManager.nowDepositEpoch(ctx.poolId, ctx.scId, ctx.assetId);
        D18 pricePoolPerAsset = ctx.report.core.hub.pricePoolPerAsset(ctx.poolId, ctx.scId, ctx.assetId);
        ctx.report.batchRequestManager.approveDeposits{value: GAS}(
            ctx.poolId, ctx.scId, ctx.assetId, depositEpochId, amount, pricePoolPerAsset, address(this)
        );

        uint32 issueEpochId = ctx.report.batchRequestManager.nowIssueEpoch(ctx.poolId, ctx.scId, ctx.assetId);
        (D18 sharePrice,) = ctx.report.core.shareClassManager.pricePoolPerShare(ctx.poolId, ctx.scId);
        ctx.report.batchRequestManager.issueShares{value: GAS}(
            ctx.poolId, ctx.scId, ctx.assetId, issueEpochId, sharePrice, HOOK_GAS, address(this)
        );

        vm.stopPrank();
    }

    function _notifyAndClaimDeposit(InvestmentFlowContext memory ctx, address investor, IAsyncVault vault) internal {
        address ANY = makeAddr("ANY");
        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        ctx.report.batchRequestManager.notifyDeposit{value: GAS}(
            ctx.poolId,
            ctx.scId,
            ctx.assetId,
            investor.toBytes32(),
            ctx.report.batchRequestManager.maxDepositClaims(ctx.poolId, ctx.scId, investor.toBytes32(), ctx.assetId),
            address(this)
        );
        vm.stopPrank();

        uint256 initialShares = ctx.report.core.spoke.shareToken(ctx.poolId, ctx.scId).balanceOf(investor);
        vm.startPrank(investor);
        vault.mint(vault.maxMint(investor), investor);
        vm.stopPrank();

        assertTrue(
            ctx.report.core.spoke.shareToken(ctx.poolId, ctx.scId).balanceOf(investor) > initialShares,
            "Investor should have received shares"
        );
    }

    function _approveAndRevokeRedeem(InvestmentFlowContext memory ctx, uint128 shares) internal {
        vm.startPrank(ctx.gql.hubManager);

        uint32 redeemEpochId = ctx.report.batchRequestManager.nowRedeemEpoch(ctx.poolId, ctx.scId, ctx.assetId);
        D18 pricePoolPerAsset = ctx.report.core.hub.pricePoolPerAsset(ctx.poolId, ctx.scId, ctx.assetId);
        ctx.report.batchRequestManager
            .approveRedeems(ctx.poolId, ctx.scId, ctx.assetId, redeemEpochId, shares, pricePoolPerAsset);

        uint32 revokeEpochId = ctx.report.batchRequestManager.nowRevokeEpoch(ctx.poolId, ctx.scId, ctx.assetId);
        (D18 sharePrice,) = ctx.report.core.shareClassManager.pricePoolPerShare(ctx.poolId, ctx.scId);
        ctx.report.batchRequestManager.revokeShares{value: GAS}(
            ctx.poolId, ctx.scId, ctx.assetId, revokeEpochId, sharePrice, HOOK_GAS, address(this)
        );

        vm.stopPrank();
    }

    function _notifyAndClaimRedeem(InvestmentFlowContext memory ctx, address investor, IAsyncRedeemVault vault)
        internal
    {
        address ANY = makeAddr("ANY");
        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        ctx.report.batchRequestManager.notifyRedeem{value: GAS}(
            ctx.poolId,
            ctx.scId,
            ctx.assetId,
            investor.toBytes32(),
            ctx.report.batchRequestManager.maxRedeemClaims(ctx.poolId, ctx.scId, investor.toBytes32(), ctx.assetId),
            address(this)
        );
        vm.stopPrank();

        uint256 initialAssets = IERC20(vault.asset()).balanceOf(investor);
        vm.startPrank(investor);
        vault.withdraw(vault.maxWithdraw(investor), investor, investor);
        vm.stopPrank();

        assertTrue(IERC20(vault.asset()).balanceOf(investor) > initialAssets, "Investor should have received assets");
    }

    function _ensureDepositEpochsAligned(InvestmentFlowContext memory ctx) internal {
        uint32 nowDepositEpoch = ctx.report.batchRequestManager.nowDepositEpoch(ctx.poolId, ctx.scId, ctx.assetId);
        uint32 nowIssueEpoch = ctx.report.batchRequestManager.nowIssueEpoch(ctx.poolId, ctx.scId, ctx.assetId);

        if (nowDepositEpoch != nowIssueEpoch) {
            vm.startPrank(ctx.gql.hubManager);
            while (nowIssueEpoch < nowDepositEpoch) {
                (D18 sharePrice,) = ctx.report.core.shareClassManager.pricePoolPerShare(ctx.poolId, ctx.scId);
                ctx.report.batchRequestManager.issueShares{value: GAS}(
                    ctx.poolId, ctx.scId, ctx.assetId, nowIssueEpoch, sharePrice, HOOK_GAS, address(this)
                );
                nowIssueEpoch = ctx.report.batchRequestManager.nowIssueEpoch(ctx.poolId, ctx.scId, ctx.assetId);
            }
            vm.stopPrank();
        }
    }

    function _ensureRedeemEpochsAligned(InvestmentFlowContext memory ctx) internal {
        uint32 nowRedeemEpoch = ctx.report.batchRequestManager.nowRedeemEpoch(ctx.poolId, ctx.scId, ctx.assetId);
        uint32 nowRevokeEpoch = ctx.report.batchRequestManager.nowRevokeEpoch(ctx.poolId, ctx.scId, ctx.assetId);

        if (nowRedeemEpoch != nowRevokeEpoch) {
            vm.startPrank(ctx.gql.hubManager);
            while (nowRevokeEpoch < nowRedeemEpoch) {
                (D18 sharePrice,) = ctx.report.core.shareClassManager.pricePoolPerShare(ctx.poolId, ctx.scId);
                ctx.report.batchRequestManager.revokeShares{value: GAS}(
                    ctx.poolId, ctx.scId, ctx.assetId, nowRevokeEpoch, sharePrice, HOOK_GAS, address(this)
                );
                nowRevokeEpoch = ctx.report.batchRequestManager.nowRevokeEpoch(ctx.poolId, ctx.scId, ctx.assetId);
            }
            vm.stopPrank();
        }
    }

    // ============================================
    // Cross-Chain Simulation Helpers
    // ============================================

    function _simulateHubNotifyPrices(InvestmentFlowContext memory ctx) internal {
        // Ensure AsyncRequestManager is registered as a manager for this pool in BalanceSheet
        // This fixes cross-chain pools where manager registration is missing from on-chain state
        // Only register if pool exists in local Hub (Ethereum mainnet has pools, spoke chains don't)
        if (ctx.report.core.hubRegistry.exists(ctx.poolId)) {
            vm.startPrank(address(ctx.report.root));
            ctx.report.core.balanceSheet.updateManager(ctx.poolId, address(ctx.report.asyncRequestManager), true);
            vm.stopPrank();
        }

        uint128 identityPriceUint128 = uint128(D18.unwrap(IntegrationConstants.identityPrice()));
        uint64 timestamp = uint64(block.timestamp);

        bytes memory shareMessage = MessageLib.NotifyPricePoolPerShare({
                poolId: ctx.poolId.raw(), scId: ctx.scId.raw(), price: identityPriceUint128, timestamp: timestamp
            }).serialize();

        bytes memory assetMessage = MessageLib.NotifyPricePoolPerAsset({
                poolId: ctx.poolId.raw(),
                scId: ctx.scId.raw(),
                assetId: ctx.assetId.raw(),
                price: identityPriceUint128,
                timestamp: timestamp
            }).serialize();

        vm.startPrank(address(ctx.report.core.gateway));
        ctx.report.core.messageProcessor.handle(1, shareMessage);
        ctx.report.core.messageProcessor.handle(1, assetMessage);
        vm.stopPrank();
    }

    function _simulateWhitelistMember(InvestmentFlowContext memory ctx, address investor) internal {
        bytes memory updateRestrictionMessage = MessageLib.UpdateRestriction({
                poolId: ctx.poolId.raw(),
                scId: ctx.scId.raw(),
                extraGasLimit: HOOK_GAS,
                payload: _updateRestrictionMemberMsg(investor)
            }).serialize();

        vm.startPrank(address(ctx.report.core.gateway));
        ctx.report.core.messageProcessor.handle(1, updateRestrictionMessage);
        vm.stopPrank();
    }

    function _deployRefundEscrowIfNeeded(InvestmentFlowContext memory ctx) internal {
        address escrowAddr = address(ctx.report.refundEscrowFactory.get(ctx.poolId));

        if (escrowAddr.code.length == 0) {
            vm.startPrank(address(ctx.report.root));
            ctx.report.refundEscrowFactory.newEscrow(ctx.poolId);
            vm.stopPrank();
        }
    }

    function _configureHubAdaptersIfNeeded(InvestmentFlowContext memory ctx) internal {
        uint16 hubCentrifugeId = ctx.gql.hubCentrifugeId;

        try ctx.report.core.multiAdapter.adapters(hubCentrifugeId, ctx.poolId, 0) returns (IAdapter existingAdapter) {
            if (address(existingAdapter) != address(0)) {
                return;
            }
        } catch {}

        // Use PassthroughAdapter for cross-chain fork tests
        // It accepts outgoing messages without trying to deliver them immediately
        // The actual hub response is simulated via _simulateHubDepositSequence()
        PassthroughAdapter hubAdapter = new PassthroughAdapter();

        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = IAdapter(address(hubAdapter));

        vm.startPrank(address(ctx.report.protocolGuardian));
        ctx.report.core.multiAdapter
            .setAdapters(hubCentrifugeId, ctx.poolId, adapters, uint8(adapters.length), uint8(adapters.length));
        vm.stopPrank();
    }

    function _simulateHubDepositSequence(
        InvestmentFlowContext memory ctx,
        address investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) internal {
        uint128 price = uint128(D18.unwrap(IntegrationConstants.identityPrice()));

        bytes[] memory payloads = new bytes[](3);

        payloads[0] = RequestCallbackMessageLib.ApprovedDeposits({
                assetAmount: fulfilledAssetAmount, pricePoolPerAsset: price
            }).serialize();

        payloads[1] = RequestCallbackMessageLib.IssuedShares({
                shareAmount: fulfilledShareAmount, pricePoolPerShare: price
            }).serialize();

        payloads[2] = RequestCallbackMessageLib.FulfilledDepositRequest({
                investor: investor.toBytes32(),
                fulfilledAssetAmount: fulfilledAssetAmount,
                fulfilledShareAmount: fulfilledShareAmount,
                cancelledAssetAmount: cancelledAssetAmount
            }).serialize();

        _sendCallbackBatch(ctx, payloads);
    }

    function _simulateHubRedeemSequence(
        InvestmentFlowContext memory ctx,
        address investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) internal {
        uint128 price = uint128(D18.unwrap(IntegrationConstants.identityPrice()));

        bytes[] memory payloads = new bytes[](2);

        payloads[0] = RequestCallbackMessageLib.RevokedShares({
                assetAmount: fulfilledAssetAmount, shareAmount: fulfilledShareAmount, pricePoolPerShare: price
            }).serialize();

        payloads[1] = RequestCallbackMessageLib.FulfilledRedeemRequest({
                investor: investor.toBytes32(),
                fulfilledAssetAmount: fulfilledAssetAmount,
                fulfilledShareAmount: fulfilledShareAmount,
                cancelledShareAmount: cancelledShareAmount
            }).serialize();

        _sendCallbackBatch(ctx, payloads);
    }

    function _sendCallbackBatch(InvestmentFlowContext memory ctx, bytes[] memory payloads) internal {
        vm.startPrank(address(ctx.report.core.gateway));

        for (uint256 i = 0; i < payloads.length; i++) {
            bytes memory message = MessageLib.RequestCallback({
                    poolId: ctx.poolId.raw(),
                    scId: ctx.scId.raw(),
                    assetId: ctx.assetId.raw(),
                    extraGasLimit: HOOK_GAS,
                    payload: payloads[i]
                }).serialize();

            ctx.report.core.messageProcessor.handle(ctx.gql.hubCentrifugeId, message);
        }

        vm.stopPrank();
    }

    // ============================================
    // Utility Functions
    // ============================================

    function _parseVaultKind(string memory kind) internal pure returns (VaultKind) {
        if (keccak256(bytes(kind)) == keccak256("Async")) {
            return VaultKind.Async;
        } else if (keccak256(bytes(kind)) == keccak256("SyncDepositAsyncRedeem")) {
            return VaultKind.SyncDepositAsyncRedeem;
        }
        revert(string.concat("Unknown vault kind: ", kind));
    }

    function _calculateTestAmount(uint8 decimals) internal pure returns (uint128) {
        if (decimals > 38) return type(uint128).max;
        return uint128(1000 * (10 ** uint256(decimals)));
    }

    function _isShareToken(address token) internal view returns (bool) {
        if (token == address(0)) return false;

        try IERC165(token).supportsInterface(type(IERC7575Share).interfaceId) returns (bool supported) {
            return supported;
        } catch {
            return false;
        }
    }

    function _fundInvestor(InvestmentFlowContext memory ctx, address investor) internal {
        if (_isShareToken(ctx.gql.assetAddress)) {
            vm.startPrank(IntegrationConstants.ROOT);
            IShareToken(ctx.gql.assetAddress).mint(investor, ctx.testAmount);
            vm.stopPrank();
        } else {
            deal(ctx.gql.assetAddress, investor, ctx.testAmount, true);
        }
    }

    function _fundInvestorForSync(InvestmentFlowContext memory ctx, address investor) internal {
        deal(ctx.gql.assetAddress, investor, ctx.testAmount, true);
    }

    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: addr.toBytes32(), validUntil: type(uint64).max
            }).serialize();
    }

    function _updateContractSyncDepositMaxReserveMsg(AssetId assetId, uint128 maxReserve)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(uint8(ISyncManager.TrustedCall.MaxReserve), assetId.raw(), maxReserve);
    }

    function _formatRevertData(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) {
            return "Empty revert data";
        }
        if (data.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 32))
            }
            return string.concat("Custom error: 0x", _toHexString(uint32(selector)));
        }
        return "Unknown revert";
    }

    function _toHexString(uint32 value) internal pure returns (string memory) {
        bytes memory buffer = new bytes(8);
        bytes16 symbols = "0123456789abcdef";
        for (uint256 i = 8; i > 0; i--) {
            buffer[i - 1] = symbols[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }
}
