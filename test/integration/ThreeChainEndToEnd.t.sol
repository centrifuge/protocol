// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import "test/integration/EndToEnd.t.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

/// @title  Three Chain End-to-End Test
/// @notice Extends the dual-chain setup to include a third chain (C) which acts as an additional spoke
///         Hub is on Chain A, with spokes on Chains B and C
contract ThreeChainEndToEndDeployment is EndToEndDeployment {
    using CastLib for *;

    uint16 constant CENTRIFUGE_ID_C = 7;
    ISafe immutable safeAdminC = ISafe(makeAddr("SafeAdminC"));

    FullDeployer deployC = new FullDeployer();
    LocalAdapter adapterC;
    LocalAdapter adapterAToC;

    // This represents the third Chain's spoke
    CSpoke sC;

    function setUp() public override {
        // Call the original setUp to set up chains A and B
        super.setUp();
        _setSpoke(false);

        // Deploy the third chain (C)
        adapterC = _deployChain(deployC, CENTRIFUGE_ID_C, CENTRIFUGE_ID_A, safeAdminC);
        vm.label(address(adapterC), "AdapterC");

        adapterAToC = new LocalAdapter(CENTRIFUGE_ID_A, deployA.multiAdapter(), address(deployA));
        vm.label(address(adapterAToC), "AdapterAToC");

        // Connect Chain A to Chain C (spoke 2)
        vm.startPrank(address(deployA.root()));
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
        s.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(s.usdc), 0);
        sC.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        sC.spoke.registerAsset{value: GAS}(h.centrifugeId, address(sC.usdc), 0);

        // Create and configure the pool on hub (chain A)
        vm.prank(address(h.guardian.safe()));
        h.guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool with three chains"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));

        h.hub.notifyPool{value: GAS}(POOL_A, s.centrifugeId);
        h.hub.notifyPool{value: GAS}(POOL_A, sC.centrifugeId);

        h.hub.notifyShareClass{value: GAS}(POOL_A, SC_1, s.centrifugeId, s.redemptionRestrictionsHook.toBytes32());
        h.hub.notifyShareClass{value: GAS}(POOL_A, SC_1, sC.centrifugeId, sC.redemptionRestrictionsHook.toBytes32());

        h.hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        h.hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        h.hub.createAccount(POOL_A, LOSS_ACCOUNT, false);
        h.hub.createAccount(POOL_A, GAIN_ACCOUNT, false);

        AssetId USDC_ID_B = newAssetId(s.centrifugeId, 1);
        AssetId USDC_ID_C = newAssetId(sC.centrifugeId, 1);

        h.hub.initializeHolding(
            POOL_A, SC_1, USDC_ID_B, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );
        h.hub.initializeHolding(
            POOL_A, SC_1, USDC_ID_C, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );

        h.hub.updateBalanceSheetManager{value: GAS}(s.centrifugeId, POOL_A, BSM.toBytes32(), true);
        h.hub.updateBalanceSheetManager{value: GAS}(sC.centrifugeId, POOL_A, BSM.toBytes32(), true);

        h.hub.updateSharePrice(POOL_A, SC_1, IDENTITY_PRICE);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, s.centrifugeId);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, sC.centrifugeId);

        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, USDC_ID_B);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, USDC_ID_C);
        vm.stopPrank();

        vm.startPrank(BSM);
        s.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
        sC.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
    }
}
