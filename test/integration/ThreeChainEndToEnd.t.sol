// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IMultiAdapter} from "src/common/interfaces/adapters/IMultiAdapter.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";

import "test/integration/EndToEnd.t.sol";

/// @title  Three Chain End-to-End Test
/// @notice Extends the dual-chain setup to include a third chain (C) which acts as an additional spoke
///         Hub is on Chain A, with spokes on Chains B and C
contract ThreeChainEndToEndDeployment is EndToEndUtils {
    using CastLib for *;

    uint16 constant CENTRIFUGE_ID_C = 7;
    ISafe immutable safeAdminC = ISafe(makeAddr("SafeAdminC"));

    FullDeployer deployC = new FullDeployer();
    LocalAdapter adapterC;
    LocalAdapter adapterAToC;

    CSpoke sC;
    CSpoke sB;

    function setUp() public override {
        // Call the original setUp to set up chains A and B
        super.setUp();
        _setSpoke(false);
        sB = s;

        // Deploy the third chain (C)
        adapterC = _deployChain(deployC, CENTRIFUGE_ID_C, CENTRIFUGE_ID_A, safeAdminC);
        vm.label(address(adapterC), "AdapterC");

        adapterAToC = new LocalAdapter(CENTRIFUGE_ID_A, deployA.multiAdapter(), address(deployA));
        vm.label(address(adapterAToC), "AdapterAToC");

        // Connect Chain A to Chain C (spoke 2)
        vm.startPrank(address(sB.root));
        deployA.wire(CENTRIFUGE_ID_C, adapterAToC, address(adapterAToC));
        vm.stopPrank();

        adapterC.setEndpoint(adapterAToC);
        adapterAToC.setEndpoint(adapterC);

        _setThirdSpoke();
    }

    function _setThirdSpoke() internal {
        if (sC.centrifugeId != 0) return; // Already set

        sC = CSpoke({
            centrifugeId: CENTRIFUGE_ID_C,
            root: deployC.root(),
            guardian: deployC.guardian(),
            gateway: deployC.gateway(),
            balanceSheet: deployC.balanceSheet(),
            spoke: deployC.spoke(),
            router: deployC.vaultRouter(),
            fullRestrictionsHook: deployC.fullRestrictionsHook(),
            redemptionRestrictionsHook: deployC.redemptionRestrictionsHook(),
            asyncVaultFactory: address(deployC.asyncVaultFactory()).toBytes32(),
            syncDepositVaultFactory: address(deployC.syncDepositVaultFactory()).toBytes32(),
            asyncRequestManager: deployC.asyncRequestManager(),
            syncRequestManager: deployC.syncRequestManager(),
            usdc: new ERC20(6)
        });

        // Initialize USDC on chain C
        sC.usdc.file("name", "USD Coin");
        sC.usdc.file("symbol", "USDC");
    }
}

/// @title  Three Chain End-to-End Use Cases
/// @notice Test cases for the three-chain setup
contract ThreeChainEndToEndUseCases is ThreeChainEndToEndDeployment {
    using CastLib for *;
    using MessageLib for *;

    /// @notice Configure the third chain (C) with assets
    /// forge-config: default.isolate = true
    function testConfigureThirdChainAsset() public {
        sC.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        sC.spoke.registerAsset{value: GAS}(h.centrifugeId, address(sC.usdc), 0);

        assertEq(h.hubRegistry.decimals(newAssetId(CENTRIFUGE_ID_C, 1)), 6, "expected decimals");
    }

    /// @notice Configure a pool with support for all three chains
    /// forge-config: default.isolate = true
    function testConfigurePoolWithThreeChains() public {
        // Configure spokes
        sB.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        sB.spoke.registerAsset{value: GAS}(h.centrifugeId, address(sB.usdc), 0);
        sC.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        sC.spoke.registerAsset{value: GAS}(h.centrifugeId, address(sC.usdc), 0);

        // Create and configure the pool on hub (chain A)
        vm.prank(address(h.guardian.safe()));
        h.guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool with three chains"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));

        h.hub.notifyPool{value: GAS}(POOL_A, sB.centrifugeId);
        h.hub.notifyPool{value: GAS}(POOL_A, sC.centrifugeId);

        h.hub.notifyShareClass{value: GAS}(POOL_A, SC_1, sB.centrifugeId, sB.redemptionRestrictionsHook.toBytes32());
        h.hub.notifyShareClass{value: GAS}(POOL_A, SC_1, sC.centrifugeId, sC.redemptionRestrictionsHook.toBytes32());

        h.hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        h.hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        h.hub.createAccount(POOL_A, LOSS_ACCOUNT, false);
        h.hub.createAccount(POOL_A, GAIN_ACCOUNT, false);

        AssetId USDC_ID_B = newAssetId(sB.centrifugeId, 1);
        AssetId USDC_ID_C = newAssetId(sC.centrifugeId, 1);

        h.hub.initializeHolding(
            POOL_A, SC_1, USDC_ID_B, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );
        h.hub.initializeHolding(
            POOL_A, SC_1, USDC_ID_C, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );

        h.hub.updateBalanceSheetManager{value: GAS}(sB.centrifugeId, POOL_A, BSM.toBytes32(), true);
        h.hub.updateBalanceSheetManager{value: GAS}(sC.centrifugeId, POOL_A, BSM.toBytes32(), true);

        h.hub.updateSharePrice(POOL_A, SC_1, IDENTITY_PRICE);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, sB.centrifugeId);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, sC.centrifugeId);

        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, USDC_ID_B);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, USDC_ID_C);
        vm.stopPrank();

        vm.startPrank(BSM);
        sB.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
        sC.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
    }

    /// @notice Test transferring shares between Chain B and Chain C via Hub A
    /// forge-config: default.isolate = true
    function testTransferSharesBetweenChains() public {
        uint128 amount = 1000 * 1e18;

        testConfigurePoolWithThreeChains();

        // B + C: Deploy vaults on both chains
        vm.startPrank(FM);
        AssetId USDC_ID_B = newAssetId(sB.centrifugeId, 1);
        h.hub.updateVault{value: GAS}(POOL_A, SC_1, USDC_ID_B, sB.asyncVaultFactory, VaultUpdateKind.DeployAndLink);
        AssetId USDC_ID_C = newAssetId(sC.centrifugeId, 1);
        h.hub.updateVault{value: GAS}(POOL_A, SC_1, USDC_ID_C, sC.asyncVaultFactory, VaultUpdateKind.DeployAndLink);
        vm.stopPrank();

        // B: Mint shares
        vm.startPrank(address(sB.root));
        IShareToken shareTokenB = IShareToken(sB.spoke.shareToken(POOL_A, SC_1));
        shareTokenB.mint(INVESTOR_A, amount);
        vm.stopPrank();
        assertEq(shareTokenB.balanceOf(INVESTOR_A), amount, "Investor should have minted shares on chain B");

        // B: Initiate transfer of shares
        vm.expectEmit();
        emit ISpoke.TransferShares(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A, INVESTOR_A.toBytes32(), amount);
        emit IHub.ForwardTransferShares(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), amount);
        vm.expectEmit(true, false, false, false);
        emit IGateway.UnderpaidBatch(sC.centrifugeId, bytes(""));
        vm.prank(INVESTOR_A);
        sB.spoke.transferShares{value: GAS}(sC.centrifugeId, POOL_A, SC_1, INVESTOR_A.toBytes32(), amount);

        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should be burned on chain B");

        // C: Transfer expected to be pending on A due to message being unpaid
        IShareToken shareTokenC = IShareToken(sC.spoke.shareToken(POOL_A, SC_1));
        assertEq(shareTokenC.balanceOf(INVESTOR_A), 0, "Share transfer not executed due to unpaid message");

        // A: Before calling repay, set a refund address for the pool
        vm.prank(address(h.root));
        h.gateway.setRefundAddress(POOL_A, IRecoverable(h.gateway));

        // A: Repay for unpaid ExecuteTransferShares message on A to trigger sending it to C
        bytes memory message = MessageLib.ExecuteTransferShares({
            poolId: PoolId.unwrap(POOL_A),
            scId: ShareClassId.unwrap(SC_1),
            receiver: INVESTOR_A.toBytes32(),
            amount: amount
        }).serialize();
        vm.expectEmit(true, false, false, false);
        emit IMultiAdapter.HandlePayload(h.centrifugeId, bytes32(""), bytes(""), adapterC);
        vm.expectEmit();
        emit IERC20.Transfer(address(0), INVESTOR_A, amount);
        h.gateway.repay{value: DEFAULT_SUBSIDY}(sC.centrifugeId, message);

        // C: Verify shares were minted
        assertEq(shareTokenC.balanceOf(INVESTOR_A), amount, "Shares should be minted on chain C");
        assertEq(shareTokenB.balanceOf(INVESTOR_A), 0, "Shares should still be burned on chain B");
    }
}
