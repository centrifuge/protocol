// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {ERC20Basin} from "./recon-end-to-end/mocks/ERC20Basin.sol";

import {D18, d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {AssetId} from "../../src/core/types/AssetId.sol";
import {ISnapshotHook} from "../../src/core/hub/interfaces/ISnapshotHook.sol";
import {ManagerKind, VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {NAVManager} from "../../src/hooks/accounting/NAVManager.sol";
import {INAVManager} from "../../src/hooks/accounting/interfaces/INAVManager.sol";
import {SimplePriceManager} from "../../src/hooks/accounting/SimplePriceManager.sol";

import {AccountingToken} from "../../src/managers/spoke/AccountingToken.sol";

import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {IAsyncVault, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {BasinLiquidityRoute} from "../../src/vaults/liquidity/BasinLiquidityRoute.sol";
import {
    IInstantPolicy,
    ILiquidityRoute,
    IReserveInstantPolicy,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev Two networks and a Basin-backed vault: network A has the vault, all issuance and the Basin debt its exits
///      book, network B has the pool's assets. `NAVManager` reports A's debt as a negative NAV and
///      `SimplePriceManager` sums the networks before it floors, so the debt is netted against B's assets: the
///      price stays at par and a redeemer is paid exactly its share's fair value, however it times its exits.
/// forge-config: default.isolate = true
contract BasinDebtAcrossNetworksTest is EndToEndFlows {
    using CastLib for *;

    uint128 constant DEPOSIT = 100e6;
    uint128 constant REDEEM_SHARES = 10e18;
    uint128 constant LINE = 100e6;
    uint16 constant REDEEM_FEE_BPS = 50;

    address immutable LP = makeAddr("liquidityProvider");
    address immutable FEE_RECIPIENT = makeAddr("feeRecipient");
    address immutable VICTIM = makeAddr("passiveVictim");

    CSpoke sideA;
    CSpoke sideB;

    NAVManager navManager;
    SimplePriceManager simplePriceManager;
    AccountingToken accountingToken;
    ERC20Basin basin;
    BasinLiquidityRoute route;
    IAsyncVault vault;

    AssetId liabilityId;
    uint256 liabilityTokenId;

    function _configureSpokeWithoutDefaultAccounting(CSpoke memory side) internal {
        if (h.centrifugeId != side.centrifugeId) _configureBasePoolWithCustomAdapters(side);

        _configureAsset(side);

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, side.centrifugeId, REFUND);
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, SC_1, side.centrifugeId, address(side.shareTokenRegistrar).toBytes32(), "", 0, REFUND
        );
        _setHook(side, address(side.freezeOnlyHook));
        h.hub.updateManager{value: GAS}(POOL_A, side.centrifugeId, ManagerKind.Spoke, BSM.toBytes32(), true, REFUND);
        vm.stopPrank();
    }

    function _managerCallA(address target, bytes memory payload) internal {
        vm.prank(FM);
        h.hub.managerCall(POOL_A, sideA.centrifugeId, target.toBytes32(), payload, EXTRA_GAS, 0, REFUND);
    }

    function _navCall(bytes memory payload) internal {
        _managerCallA(address(navManager), payload);
    }

    function _submitAsset(CSpoke storage side, AssetId assetId) internal {
        vm.prank(BSM);
        side.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, assetId, EXTRA_GAS, REFUND);
    }

    function _submitSharesA() internal {
        vm.prank(BSM);
        sideA.spoke.submitQueuedShares{value: GAS}(POOL_A, SC_1, EXTRA_GAS, REFUND);
    }

    function _notifyPriceA() internal {
        vm.prank(FM);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, sideA.centrifugeId, REFUND);
    }

    function _price() internal view returns (D18 price) {
        (price,) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
    }

    function _configureNAV() internal {
        vm.startPrank(FM);
        h.hub.setSnapshotHook(POOL_A, ISnapshotHook(address(navManager)));
        h.hub.updateHubManager(POOL_A, address(navManager), true);
        h.hub.updateHubManager(POOL_A, address(simplePriceManager), true);
        vm.stopPrank();

        _navCall(abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), address(simplePriceManager)));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.SetDefaultValuation), address(h.identityValuation)));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), sideA.centrifugeId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), sideB.centrifugeId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, sideA.usdcId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, sideB.usdcId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), SC_1, liabilityId));
    }

    function _deployBasinVault() internal {
        VaultPlugins memory plugins = VaultPlugins({
            oracle: IVaultOracle(address(sideA.spokeOracle)),
            instantPolicy: IInstantPolicy(address(sideA.reserveInstantPolicy)),
            requestPolicy: sideA.perRequestPolicy,
            liquidityRoute: ILiquidityRoute(address(route)),
            settlementObserver: ISettlementObserver(address(0))
        });
        bytes memory payload = abi.encode(plugins, uint64(0), uint256(0));

        vault = IAsyncVault(payable(sideA.vaultFactory.deploy(POOL_A, SC_1, address(sideA.usdc), 0, payload)));

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            sideA.usdcId,
            address(sideA.vaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            payload,
            EXTRA_GAS,
            REFUND
        );
        h.hub.updateManager{value: GAS}(
            POOL_A, sideA.centrifugeId, ManagerKind.Spoke, address(vault).toBytes32(), true, REFUND
        );
        vm.stopPrank();

        bytes memory terms =
            abi.encode(FEE_RECIPIENT, uint16(0), REDEEM_FEE_BPS, true, false, false, uint128(2 * DEPOSIT));
        _managerCallA(
            address(sideA.reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(vault), terms)
        );
    }

    function _setUpTwoNetworkPool() internal {
        _setSpoke(deployA, CENTRIFUGE_ID_A, sideA);
        _setSpoke(deployB, CENTRIFUGE_ID_B, sideB);

        _createPool();
        _configureSpokeWithoutDefaultAccounting(sideA);
        _configureSpokeWithoutDefaultAccounting(sideB);

        navManager = deployA.navManager();
        simplePriceManager = deployA.simplePriceManager();
        accountingToken = deployA.accountingToken();

        basin = new ERC20Basin(sideA.usdc, LP);
        route = new BasinLiquidityRoute(
            basin, sideA.spoke, address(deployA.envoy()), accountingToken, address(deployA.root())
        );

        liabilityTokenId = accountingToken.toTokenId(POOL_A, address(sideA.usdc), true);
        vm.prank(ANY);
        sideA.spoke.registerAsset{value: GAS}(h.centrifugeId, address(accountingToken), liabilityTokenId, ANY);
        liabilityId = sideA.spokeRegistry.assetToId(address(accountingToken), liabilityTokenId);

        _configureNAV();

        vm.prank(FM);
        h.hub.updateManager{value: GAS}(
            POOL_A, sideA.centrifugeId, ManagerKind.Spoke, address(route).toBytes32(), true, REFUND
        );
        _managerCallA(address(accountingToken), abi.encode(address(route).toBytes32(), true));

        _deployBasinVault();
        _managerCallA(address(route), abi.encode(address(vault), LINE));
        vm.prank(LP);
        route.setCredit(address(vault), LINE);
        vm.prank(ERC20_DEPLOYER);
        sideA.usdc.mint(address(basin), LINE);
        basin.advertise(LINE);

        vm.prank(FM);
        h.hub.updateSharePrice(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));
        vm.startPrank(FM);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, sideA.centrifugeId, REFUND);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, sideA.usdcId, REFUND);
        vm.stopPrank();
    }

    function _investOnAAndMoveAssetsToB() internal {
        vm.startPrank(INVESTOR_A);
        sideA.usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, INVESTOR_A);
        vm.stopPrank();

        // The pool deploys all subscription cash from A into an asset position on B.
        vm.prank(BSM);
        sideA.spoke.withdraw(POOL_A, SC_1, address(sideA.usdc), 0, BSM, DEPOSIT);

        vm.prank(ERC20_DEPLOYER);
        sideB.usdc.mint(BSM, DEPOSIT);
        vm.startPrank(BSM);
        sideB.usdc.approve(address(sideB.spoke), DEPOSIT);
        sideB.spoke.deposit(POOL_A, SC_1, address(sideB.usdc), 0, DEPOSIT);
        vm.stopPrank();

        // Publish both networks through their real queues and the real NAV hook.
        _submitAsset(sideB, sideB.usdcId);
        _submitAsset(sideA, sideA.usdcId);
        _submitSharesA();

        (int128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);
        assertEq(navManager.netAssetValue(POOL_A, sideA.centrifugeId), 0, "A has no positive NAV");
        assertEq(navManager.netAssetValue(POOL_A, sideB.centrifugeId), 100e18, "B holds the pool assets");
        assertEq(globalNAV, 100e18, "global NAV starts at 100");
        assertEq(globalIssuance, 100e18, "over 100 shares");
        assertEq(_price().raw(), 1e18, "initial price is par");
    }

    function _syncAfterRedeem() internal {
        skip(1 hours);
        _submitAsset(sideA, sideA.usdcId);
        _submitAsset(sideA, liabilityId);
        _submitSharesA();
        _notifyPriceA();
    }

    function testBasinDebtIsNettedAgainstAnotherNetworksAssets() public {
        _setUpTwoNetworkPool();
        _investOnAAndMoveAssetsToB();

        IShareToken share = IShareToken(vault.share());
        vm.prank(INVESTOR_A);
        share.transfer(VICTIM, 50e18);

        uint256 attackerBefore = sideA.usdc.balanceOf(INVESTOR_A);

        // Five ordinary 10-share redemptions, each priced by the real synchronization and notification before it.
        for (uint256 i; i < 5; i++) {
            vm.prank(INVESTOR_A);
            vault.redeem(REDEEM_SHARES, INVESTOR_A);
            _syncAfterRedeem();
        }

        uint256 attackerReceived = sideA.usdc.balanceOf(INVESTOR_A) - attackerBefore;
        uint256 fairAfterFees = 50e6 - 250_000; // five 10-USDC exits, each charged 50 bps

        (int128 globalNAV, uint128 globalIssuance) = simplePriceManager.metrics(POOL_A);
        uint128 debt = route.receivable(address(vault));
        int128 signedA = navManager.netAssetValue(POOL_A, sideA.centrifugeId);

        emit log_named_decimal_uint("attacker received for 50 shares", attackerReceived, 6);
        emit log_named_decimal_uint("fair receipt after 50 bps fees", fairAfterFees, 6);
        emit log_named_decimal_uint("published price", _price().raw(), 18);

        assertLt(signedA, 0, "network A reports its debt instead of flooring it to zero");
        assertEq(signedA, -int128(uint128(debt) * 1e12), "all of the Basin debt is in A's NAV");
        assertEq(navManager.netAssetValue(POOL_A, sideB.centrifugeId), 100e18, "B NAV is untouched");
        assertEq(globalNAV, 100e18 + signedA, "the pool's NAV nets the debt against B's assets");
        assertEq(globalIssuance, 50e18, "50 shares remain");
        assertEq(share.balanceOf(INVESTOR_A), 0, "the redeemer exited all of its shares");

        // The shares are worth what they were: the redeemer took its fair value, not the victim's.
        assertEq(_price().raw(), 1e18, "the published price stays at par");
        assertEq(attackerReceived, fairAfterFees, "the redeemer is paid exactly the fair value");
    }
}
