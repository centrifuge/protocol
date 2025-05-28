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

    // This represents the third Chain's spoke
    CSpoke sC;

    function setUp() public override {
        // Call the original setUp to set up chains A and B
        super.setUp();

        // Deploy the third chain (C)
        adapterC = _deployChain(deployC, CENTRIFUGE_ID_C, CENTRIFUGE_ID_A, safeAdminC);
        vm.label(address(adapterC), "AdapterC");

        // Connect Chain C to Chain A (hub)
        adapterC.setEndpoint(adapterA);

        // Connect Chain A to Chain C (spoke 2)
        vm.startPrank(address(deployA.root()));
        // FIXME: Breaks with NoDuplicatesAllowed even though A doesn't yet know about C?!
        deployA.wire(CENTRIFUGE_ID_C, adapterA, address(deployA));
        vm.stopPrank();

        adapterA.setEndpoint(adapterC);
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
        _setThirdSpoke();

        // Initialize USDC on chain C
        sC.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        sC.spoke.registerAsset{value: GAS}(h.centrifugeId, address(sC.usdc), 0);

        assertEq(h.hubRegistry.decimals(newAssetId(CENTRIFUGE_ID_C, 1)), 6, "expected decimals");
    }
}
