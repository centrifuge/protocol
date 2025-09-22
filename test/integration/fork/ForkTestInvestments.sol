// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CHub, CSpoke, ForkTestBase} from "./ForkTestBase.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {D18} from "../../../src/misc/types/D18.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Root} from "../../../src/common/Root.sol";
import {Gateway} from "../../../src/common/Gateway.sol";
import {Guardian} from "../../../src/common/Guardian.sol";
import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {GasService} from "../../../src/common/GasService.sol";
import {MultiAdapter} from "../../../src/common/MultiAdapter.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {MessageProcessor} from "../../../src/common/MessageProcessor.sol";
import {MessageLib, VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";
import {RequestCallbackMessageLib} from "../../../src/common/libraries/RequestCallbackMessageLib.sol";

import {Hub} from "../../../src/hub/Hub.sol";
import {Holdings} from "../../../src/hub/Holdings.sol";
import {Accounting} from "../../../src/hub/Accounting.sol";
import {HubRegistry} from "../../../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../../../src/hub/ShareClassManager.sol";

import {Spoke} from "../../../src/spoke/Spoke.sol";
import {BalanceSheet} from "../../../src/spoke/BalanceSheet.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";
import {IAsyncRedeemVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";

import {MockSnapshotHook} from "../../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../../src/hooks/RedemptionRestrictions.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import "forge-std/Test.sol";

import {VMLabeling} from "../utils/VMLabeling.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

contract ForkTestInvestmentFlows is ForkTestBase, VMLabeling {
    using CastLib for *;
    using RequestCallbackMessageLib for *;
    using MessageLib for *;

    function setUp() public virtual override {
        super.setUp();
        _setupVMLabels();
    }

    //----------------------------------------------------------------------------------------------
    // Async Deposit Flows
    //----------------------------------------------------------------------------------------------

    function _asyncDepositFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address investor,
        uint128 amount,
        address existingVault
    ) internal {
        _baseConfigurePrices(hub, spoke, poolId, shareClassId, assetId, poolManager);

        // Deploy or get existing vault (with fallback for fork tests)
        IAsyncVault vault =
            _ensureAsyncVaultExists(hub, spoke, poolId, shareClassId, assetId, poolManager, existingVault);

        // Execute deposit request
        _executeAsyncDepositRequest(vault, investor, amount);

        // Ensure deposit/issue epochs are aligned before proceeding (handles live chain state)
        _ensureDepositEpochsAligned(hub, poolId, shareClassId, assetId, poolManager);

        // Process deposit approval and share issuance
        _processAsyncDepositApproval(hub, poolId, shareClassId, assetId, poolManager, amount);

        // Claim shares
        _processAsyncDepositClaim(hub, spoke, poolId, shareClassId, assetId, investor, vault);
    }

    function _ensureAsyncVaultExists(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address fallbackVault
    ) internal returns (IAsyncVault vault) {
        vm.startPrank(poolManager);

        // Check if vault already exists (for fork tests)
        vault = IAsyncVault(_getAsyncVault(spoke, poolId, shareClassId, assetId));
        if (address(vault) == address(0)) {
            // If we have a fallback vault (for fork tests), use it
            if (fallbackVault != address(0)) {
                vault = IAsyncVault(fallbackVault);
                vm.stopPrank();
                return vault;
            }

            // Otherwise try to create new vault
            hub.hub.updateVault(
                poolId, shareClassId, assetId, spoke.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
            );
            vault = IAsyncVault(_getAsyncVault(spoke, poolId, shareClassId, assetId));
        }

        vm.stopPrank();
        assertNotEq(address(vault), address(0));
    }

    function _executeAsyncDepositRequest(IAsyncVault vault, address investor, uint128 amount) internal {
        vm.startPrank(investor);
        ERC20(vault.asset()).approve(address(vault), amount);
        vault.requestDeposit(amount, investor, investor);
    }

    function _ensureDepositEpochsAligned(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal {
        uint32 nowDepositEpoch = hub.shareClassManager.nowDepositEpoch(shareClassId, assetId);
        uint32 nowIssueEpoch = hub.shareClassManager.nowIssueEpoch(shareClassId, assetId);

        // Handle live chain state: if deposits have been approved but not yet issued,
        // we need to issue outstanding epochs before we can approve new ones
        if (nowDepositEpoch != nowIssueEpoch) {
            vm.startPrank(poolManager);
            while (nowIssueEpoch < nowDepositEpoch) {
                (, D18 sharePrice) = hub.shareClassManager.metrics(shareClassId);
                hub.hub.issueShares(
                    poolId, shareClassId, assetId, nowIssueEpoch, sharePrice, IntegrationConstants.HOOK_GAS
                );
                nowIssueEpoch = hub.shareClassManager.nowIssueEpoch(shareClassId, assetId);
            }
            vm.stopPrank();
        }
    }

    function _processAsyncDepositApproval(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        uint128 amount
    ) internal {
        vm.startPrank(poolManager);
        uint32 depositEpochId = hub.shareClassManager.nowDepositEpoch(shareClassId, assetId);
        hub.hub.approveDeposits(poolId, shareClassId, assetId, depositEpochId, amount);

        uint32 issueEpochId = hub.shareClassManager.nowIssueEpoch(shareClassId, assetId);
        (, D18 sharePrice) = hub.shareClassManager.metrics(shareClassId);
        hub.hub.issueShares(poolId, shareClassId, assetId, issueEpochId, sharePrice, IntegrationConstants.HOOK_GAS);
    }

    function _processAsyncDepositClaim(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address investor,
        IAsyncVault vault
    ) internal {
        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        hub.hub.notifyDeposit(
            poolId,
            shareClassId,
            assetId,
            investor.toBytes32(),
            hub.shareClassManager.maxDepositClaims(shareClassId, investor.toBytes32(), assetId)
        );

        // Store initial share balance for fork tests
        uint256 initialShares = spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor);

        vm.startPrank(investor);
        vault.mint(vault.maxMint(investor), investor);

        // For fork tests just verify shares increased
        assertTrue(
            spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor) > initialShares,
            "Investor should have received shares"
        );
    }

    function completeAsyncDepositLocal(IBaseVault vault, address investor, uint128 amount) public {
        if (_isShareToken(vault.asset())) {
            vm.startPrank(IntegrationConstants.V2_ROOT);
            ERC20(vault.asset()).mint(investor, amount);
            vm.stopPrank();
        } else {
            // NOTE: Does not work for share tokens: [Revert] panic: arithmetic underflow or overflow (0x11)
            deal(vault.asset(), investor, amount, true);
        }
        _addPoolMember(vault, investor);

        _asyncDepositFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.spoke.assetToId(vault.asset(), 0),
            _poolAdmin(),
            investor,
            amount,
            address(vault)
        );
    }

    //----------------------------------------------------------------------------------------------
    // Async Redeem Flows
    //----------------------------------------------------------------------------------------------

    function _asyncRedeemFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address investor,
        address existingVault
    ) internal {
        _configureAsyncRedeemRestriction(hub, spoke, poolId, shareClassId, investor, poolManager);

        // Resolve vault - use existing if provided, otherwise get from manager
        IAsyncRedeemVault vault = existingVault != address(0)
            ? IAsyncRedeemVault(existingVault)
            : IAsyncRedeemVault(_getAsyncVault(spoke, poolId, shareClassId, assetId));

        vm.startPrank(investor);
        uint128 shares = uint128(spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor));

        vault.requestRedeem(shares, investor, investor);

        // Ensure epochs are aligned before proceeding (handles live chain state)
        _ensureRedeemEpochsAligned(hub, poolId, shareClassId, assetId, poolManager);

        _processAsyncRedeemApproval(hub, poolId, shareClassId, assetId, shares, poolManager);
        _processAsyncRedeemClaim(hub, poolId, shareClassId, assetId, investor, vault);
    }

    function _ensureRedeemEpochsAligned(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal {
        uint32 nowRedeemEpoch = hub.shareClassManager.nowRedeemEpoch(shareClassId, assetId);
        uint32 nowRevokeEpoch = hub.shareClassManager.nowRevokeEpoch(shareClassId, assetId);

        // Handle live chain state: if redemptions have been approved but not revoked,
        // we need to revoke outstanding epochs before we can approve new ones
        if (nowRedeemEpoch != nowRevokeEpoch) {
            vm.startPrank(poolManager);
            while (nowRevokeEpoch < nowRedeemEpoch) {
                (, D18 sharePrice) = hub.shareClassManager.metrics(shareClassId);
                hub.hub.revokeShares(
                    poolId, shareClassId, assetId, nowRevokeEpoch, sharePrice, IntegrationConstants.HOOK_GAS
                );
                nowRevokeEpoch = hub.shareClassManager.nowRevokeEpoch(shareClassId, assetId);
            }
            vm.stopPrank();
        }
    }

    function _configureAsyncRedeemRestriction(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        address investor,
        address poolManager
    ) internal {
        vm.startPrank(poolManager);
        hub.hub.updateRestriction(
            poolId, shareClassId, spoke.centrifugeId, _updateRestrictionMemberMsg(investor), EXTRA_GAS
        );
    }

    function _processAsyncRedeemApproval(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        uint128 shares,
        address poolManager
    ) internal {
        vm.startPrank(poolManager);
        uint32 redeemEpochId = hub.shareClassManager.nowRedeemEpoch(shareClassId, assetId);
        hub.hub.approveRedeems(poolId, shareClassId, assetId, redeemEpochId, shares);

        uint32 revokeEpochId = hub.shareClassManager.nowRevokeEpoch(shareClassId, assetId);
        (, D18 sharePrice) = hub.shareClassManager.metrics(shareClassId);
        hub.hub.revokeShares(poolId, shareClassId, assetId, revokeEpochId, sharePrice, IntegrationConstants.HOOK_GAS);
    }

    function _processAsyncRedeemClaim(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address investor,
        IAsyncRedeemVault vault
    ) internal {
        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        hub.hub.notifyRedeem(
            poolId,
            shareClassId,
            assetId,
            investor.toBytes32(),
            hub.shareClassManager.maxRedeemClaims(shareClassId, investor.toBytes32(), assetId)
        );

        // Store initial asset balance for fork tests
        uint256 initialAssets = IERC20(vault.asset()).balanceOf(investor);

        vm.startPrank(investor);
        vault.withdraw(vault.maxWithdraw(investor), investor, investor);

        assertTrue(
            IERC20(vault.asset()).balanceOf(investor) > initialAssets,
            "Investor should have received assets from redemption"
        );
    }

    function completeAsyncRedeemLocal(IBaseVault vault, address investor, uint128 amount) public {
        completeAsyncDepositLocal(vault, investor, amount);

        _asyncRedeemFlow(
            forkHub,
            forkSpoke,
            vault.poolId(),
            vault.scId(),
            forkSpoke.spoke.assetToId(vault.asset(), 0),
            _poolAdmin(),
            investor,
            address(vault)
        );
    }

    //----------------------------------------------------------------------------------------------
    // Sync Deposit Flows
    //----------------------------------------------------------------------------------------------

    function _syncDepositFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address investor,
        uint128 amount
    ) internal {
        _baseConfigurePrices(hub, spoke, poolId, shareClassId, assetId, poolManager);
        _configureSyncDepositVault(hub, spoke, poolId, shareClassId, assetId, poolManager);
        _processSyncDeposit(hub, spoke, poolId, shareClassId, assetId, investor, amount);
    }

    function _configureSyncDepositVault(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal {
        vm.startPrank(poolManager);
        // Check if vault already exists (for fork tests)
        address existingVault = _getAsyncVault(spoke, poolId, shareClassId, assetId);
        if (existingVault == address(0)) {
            hub.hub.updateVault(
                poolId, shareClassId, assetId, spoke.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
            );
        }
        hub.hub.updateContract(
            poolId,
            shareClassId,
            spoke.centrifugeId,
            address(spoke.syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(assetId, type(uint128).max),
            EXTRA_GAS
        );
    }

    function _processSyncDeposit(
        CHub memory,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address investor,
        uint128 amount
    ) internal {
        IBaseVault vault = IBaseVault(_getAsyncVault(spoke, poolId, shareClassId, assetId));

        // Store initial share balance for fork tests
        uint256 initialShares = spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor);

        vm.startPrank(investor);
        spoke.usdc.approve(address(vault), amount);
        vault.deposit(amount, investor);

        // For fork tests: just verify shares increased
        assertTrue(
            spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor) > initialShares,
            "Investor should have received shares"
        );
    }
}

/// @title ForkTestAsyncInvestments
/// @notice Fork tests for async investment flows on Ethereum mainnet
contract ForkTestAsyncInvestments is ForkTestInvestmentFlows {
    using CastLib for *;
    using RequestCallbackMessageLib for *;
    using MessageLib for *;

    // TODO(later): After v2 disable, switch to JAAA
    IBaseVault constant VAULT = IBaseVault(IntegrationConstants.ETH_DEJAA_USDC_VAULT);

    uint128 constant depositAmount = IntegrationConstants.DEFAULT_USDC_AMOUNT;

    function test_completeAsyncDepositLocalFlow() public virtual {
        completeAsyncDepositLocal(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    function test_completeAsyncRedeemLocalFlow() public virtual {
        completeAsyncRedeemLocal(VAULT, makeAddr("INVESTOR_A"), depositAmount);
    }

    //----------------------------------------------------------------------------------------------
    // CROSS-CHAIN ASYNC FLOW VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates complete cross-chain async deposit flow for post-spell execution
    function completeAsyncDepositCrossChain(address vaultAddress) public {
        _completeAsyncDepositCrossChain(vaultAddress, "ASYNC_DEPOSIT_INVESTOR");
    }

    /// @notice Executes complete async deposit flow and returns investor/vault for further operations
    function _completeAsyncDepositCrossChain(address vaultAddress, string memory investorLabel)
        internal
        returns (address investor, IAsyncVault vault)
    {
        if (vaultAddress == address(0) || vaultAddress.code.length == 0) revert("Vault missing");

        investor = makeAddr(investorLabel);
        vault = IAsyncVault(vaultAddress);

        AssetId assetId = Spoke(IntegrationConstants.SPOKE).assetToId(vault.asset(), 0);
        require(assetId.raw() != 0, "Vault asset not registered on spoke");

        _simulateHubNotifyPrices(vault.poolId(), vault.scId(), assetId);

        deal(vault.asset(), investor, depositAmount);
        _simulateWhitelistMember(vault, investor);

        vm.startPrank(investor);
        ERC20(vault.asset()).approve(vaultAddress, depositAmount);
        vault.requestDeposit(depositAmount, investor, investor);
        vm.stopPrank();

        _simulateHubDepositSequence(vault.poolId(), vault.scId(), assetId, investor, depositAmount, depositAmount, 0);

        uint256 initialShares = ERC20(vault.share()).balanceOf(investor);
        uint256 maxMintable = vault.maxMint(investor);
        assertTrue(maxMintable > 0, "Should have shares to mint after Hub fulfillment");

        vm.startPrank(investor);
        vault.mint(maxMintable, investor);
        vm.stopPrank();

        uint256 finalShares = ERC20(vault.share()).balanceOf(investor);
        assertTrue(finalShares > initialShares, "Deposit flow should have minted shares");
    }

    /// @notice Validates complete cross-chain async redeem flow for post-spell execution
    function completeAsyncRedeemCrossChain(address vaultAddress) public {
        (address investor, IAsyncVault vault) = _completeAsyncDepositCrossChain(vaultAddress, "ASYNC_REDEEM_INVESTOR");

        AssetId assetId = Spoke(IntegrationConstants.SPOKE).assetToId(vault.asset(), 0);

        uint128 sharesToRedeem = uint128(ERC20(vault.share()).balanceOf(investor));
        assertTrue(sharesToRedeem > 0, "Investor should have shares to redeem");

        vm.startPrank(investor);
        vault.requestRedeem(sharesToRedeem, investor, investor);
        vm.stopPrank();

        _simulateHubRedeemSequence(vault.poolId(), vault.scId(), assetId, investor, depositAmount, sharesToRedeem, 0);

        uint256 initialAssets = ERC20(vault.asset()).balanceOf(investor);
        uint256 maxWithdrawable = vault.maxWithdraw(investor);
        assertTrue(maxWithdrawable > 0, "Should have assets to withdraw after Hub fulfillment");

        vm.startPrank(investor);
        vault.withdraw(maxWithdrawable, investor, investor);
        vm.stopPrank();

        uint256 finalAssets = ERC20(vault.asset()).balanceOf(investor);
        assertTrue(finalAssets > initialAssets, "Investor should have received assets from async redeem flow");
    }

    /// @notice Simulates complete Hub deposit sequence: ApprovedDeposits -> IssuedShares -> FulfilledDepositRequest
    function _simulateHubDepositSequence(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) internal {
        MessageProcessor processor = MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR);
        uint128 price = uint128(D18.unwrap(IntegrationConstants.identityPrice()));

        vm.startPrank(IntegrationConstants.GATEWAY);

        _sendRequestCallback(
            processor,
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.ApprovedDeposits({assetAmount: fulfilledAssetAmount, pricePoolPerAsset: price})
                .serialize()
        );

        _sendRequestCallback(
            processor,
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.IssuedShares({shareAmount: fulfilledShareAmount, pricePoolPerShare: price})
                .serialize()
        );

        _sendRequestCallback(
            processor,
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.FulfilledDepositRequest({
                investor: investor.toBytes32(),
                fulfilledAssetAmount: fulfilledAssetAmount,
                fulfilledShareAmount: fulfilledShareAmount,
                cancelledAssetAmount: cancelledAssetAmount
            }).serialize()
        );

        vm.stopPrank();
    }

    /// @notice Simulates complete Hub redeem sequence: RevokedShares -> FulfilledRedeemRequest
    function _simulateHubRedeemSequence(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) internal {
        MessageProcessor processor = MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR);
        uint128 price = uint128(D18.unwrap(IntegrationConstants.identityPrice()));

        vm.startPrank(IntegrationConstants.GATEWAY);

        _sendRequestCallback(
            processor,
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.RevokedShares({
                assetAmount: fulfilledAssetAmount,
                shareAmount: fulfilledShareAmount,
                pricePoolPerShare: price
            }).serialize()
        );

        _sendRequestCallback(
            processor,
            poolId,
            scId,
            assetId,
            RequestCallbackMessageLib.FulfilledRedeemRequest({
                investor: investor.toBytes32(),
                fulfilledAssetAmount: fulfilledAssetAmount,
                fulfilledShareAmount: fulfilledShareAmount,
                cancelledShareAmount: cancelledShareAmount
            }).serialize()
        );

        vm.stopPrank();
    }

    /// @notice Helper function to send RequestCallback messages
    function _sendRequestCallback(
        MessageProcessor processor,
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload
    ) internal {
        bytes memory message = MessageLib.RequestCallback({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            payload: payload
        }).serialize();
        processor.handle(1, message);
    }

    /// @notice Simulates whitelisting an investor via cross-chain restriction message
    function _simulateWhitelistMember(IAsyncVault vault, address investor) internal {
        bytes memory updateRestrictionMessage = MessageLib.UpdateRestriction({
            poolId: vault.poolId().raw(),
            scId: vault.scId().raw(),
            payload: _updateRestrictionMemberMsg(investor)
        }).serialize();

        Gateway gatewayContract = Gateway(payable(IntegrationConstants.GATEWAY));
        MessageProcessor messageProcessorContract = MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR);

        vm.startPrank(address(gatewayContract));
        messageProcessorContract.handle(1, updateRestrictionMessage); // TODO: Don't use hardcoded Ethereum hub
        vm.stopPrank();
    }

    /// @notice Simulates Hub notifying spoke about price updates
    function _simulateHubNotifyPrices(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        uint128 identityPriceUint128 = uint128(D18.unwrap(IntegrationConstants.identityPrice()));
        uint64 timestamp = uint64(block.timestamp);

        bytes memory shareMessage = MessageLib.NotifyPricePoolPerShare({
            poolId: poolId.raw(),
            scId: scId.raw(),
            price: identityPriceUint128,
            timestamp: timestamp
        }).serialize();

        bytes memory assetMessage = MessageLib.NotifyPricePoolPerAsset({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            price: identityPriceUint128,
            timestamp: timestamp
        }).serialize();

        Gateway gatewayContract = Gateway(payable(IntegrationConstants.GATEWAY));
        MessageProcessor messageProcessorContract = MessageProcessor(IntegrationConstants.MESSAGE_PROCESSOR);

        vm.startPrank(address(gatewayContract));
        messageProcessorContract.handle(1, shareMessage); // TODO: Don't use hardcoded Ethereum hub
        messageProcessorContract.handle(1, assetMessage); // TODO: Don't use hardcoded Ethereum hub
        vm.stopPrank();
    }
}

/// @title ForkTestSyncInvestments
/// @notice Fork tests for sync investment flows on Plume network
contract ForkTestSyncInvestments is ForkTestInvestmentFlows {
    using CastLib for *;

    IBaseVault constant VAULT = IBaseVault(IntegrationConstants.PLUME_SYNC_DEPOSIT_VAULT);

    function setUp() public override {
        vm.createSelectFork(IntegrationConstants.RPC_PLUME);

        _loadContracts();
        _setupVMLabels();

        _baseConfigurePrices(
            forkHub, forkSpoke, VAULT.poolId(), VAULT.scId(), forkSpoke.spoke.assetToId(VAULT.asset(), 0), _poolAdmin()
        );
    }

    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_PLUME;
    }

    function _poolAdmin() internal pure override returns (address) {
        return IntegrationConstants.PLUME_POOL_ADMIN;
    }

    function _loadContracts() internal override {
        forkHub = CHub({
            centrifugeId: IntegrationConstants.PLUME_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            multiAdapter: MultiAdapter(IntegrationConstants.MULTI_ADAPTER),
            gasService: GasService(IntegrationConstants.GAS_SERVICE),
            hubRegistry: HubRegistry(IntegrationConstants.HUB_REGISTRY),
            accounting: Accounting(IntegrationConstants.ACCOUNTING),
            holdings: Holdings(IntegrationConstants.HOLDINGS),
            shareClassManager: ShareClassManager(IntegrationConstants.SHARE_CLASS_MANAGER),
            hub: Hub(IntegrationConstants.HUB),
            identityValuation: IdentityValuation(IntegrationConstants.IDENTITY_VALUATION),
            oracleValuation: OracleValuation(address(0)), // TODO: add this once deployed
            snapshotHook: MockSnapshotHook(address(0)) // Fork tests don't use snapshot hooks
        });

        forkSpoke = CSpoke({
            centrifugeId: IntegrationConstants.PLUME_CENTRIFUGE_ID,
            root: Root(IntegrationConstants.ROOT),
            guardian: Guardian(IntegrationConstants.GUARDIAN),
            gateway: Gateway(payable(IntegrationConstants.GATEWAY)),
            multiAdapter: MultiAdapter(IntegrationConstants.MULTI_ADAPTER),
            balanceSheet: BalanceSheet(IntegrationConstants.BALANCE_SHEET),
            spoke: Spoke(IntegrationConstants.SPOKE),
            router: VaultRouter(IntegrationConstants.ROUTER),
            asyncVaultFactory: IntegrationConstants.ASYNC_VAULT_FACTORY.toBytes32(),
            syncDepositVaultFactory: IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY.toBytes32(),
            asyncRequestManager: AsyncRequestManager(IntegrationConstants.ASYNC_REQUEST_MANAGER),
            syncManager: SyncManager(IntegrationConstants.SYNC_MANAGER),
            freezeOnlyHook: FreezeOnly(IntegrationConstants.FREEZE_ONLY_HOOK),
            fullRestrictionsHook: FullRestrictions(IntegrationConstants.FULL_RESTRICTIONS_HOOK),
            redemptionRestrictionsHook: RedemptionRestrictions(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK),
            usdc: ERC20(IntegrationConstants.PLUME_PUSD),
            usdcId: Spoke(IntegrationConstants.SPOKE).assetToId(IntegrationConstants.PLUME_PUSD, 0)
        });

        // Fund pool admin
        vm.deal(_poolAdmin(), 10 ether);
    }

    function test_completeSyncDepositFlow() public {
        // NOTE: Disabled because issues on live conditions
        // _completeSyncDeposit(makeAddr("INVESTOR_A"), 1000e18);
    }

    function test_completeSyncDepositAsyncRedeemFlow() public {
        // NOTE: Disabled because issues on live conditions
        // _completeSyncDepositAsyncRedeem(makeAddr("INVESTOR_A"), 1000e18);
    }

    function _completeSyncDeposit(address investor, uint128 amount) internal {
        _addPoolMember(VAULT, investor);

        deal(VAULT.asset(), investor, amount);
        _syncDepositFlow(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.spoke.assetToId(VAULT.asset(), 0),
            _poolAdmin(),
            investor,
            amount
        );
    }

    function _completeSyncDepositAsyncRedeem(address investor, uint128 amount) internal {
        _completeSyncDeposit(investor, amount);

        _asyncRedeemFlow(
            forkHub,
            forkSpoke,
            VAULT.poolId(),
            VAULT.scId(),
            forkSpoke.spoke.assetToId(VAULT.asset(), 0),
            _poolAdmin(),
            investor,
            address(VAULT)
        );
    }
}
