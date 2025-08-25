// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../src/misc/interfaces/IERC20.sol";
import "../../../src/misc/interfaces/IERC7540.sol";
import "../../../src/misc/interfaces/IERC7575.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";
import {IERC7751} from "../../../src/misc/interfaces/IERC7751.sol";

import {MessageLib} from "../../../src/common/libraries/MessageLib.sol";

import "../../spoke/integration/BaseTest.sol";

import {ISpoke} from "../../../src/spoke/interfaces/ISpoke.sol";

import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {SyncDepositVault} from "../../../src/vaults/SyncDepositVault.sol";
import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";
import {IVaultRouter} from "../../../src/vaults/interfaces/IVaultRouter.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

contract VaultRouterTest is BaseTest {
    using MessageLib for *;
    using MathLib for uint256;

    uint256 constant GAS_BUFFER = 10_000_000; // 10M gas
    bytes PAYLOAD_FOR_GAS_ESTIMATION = MessageLib.NotifyPool(1).serialize();

    /// forge-config: default.isolate = true
    function testCFGRouterDeposit() public {
        _testCFGRouterDeposit(4, true);
    }

    /// forge-config: default.isolate = true
    function testCFGRouterDepositFuzz(uint256 amount) public {
        vm.assume(amount % 2 == 0);
        _testCFGRouterDeposit(amount, false);
    }

    function _testCFGRouterDeposit(uint256 amount, bool snap) internal {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);

        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vaultRouter.requestDeposit{value: 1 wei}(vault, amount, self, self);

        vaultRouter.enable(vault);
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vaultRouter.requestDeposit{value: 1 wei}(vault, amount, self, self);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);

        uint256 gas = DEFAULT_GAS + GAS_BUFFER;

        vm.expectPartialRevert(IERC7751.WrappedError.selector);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        erc20.approve(vault_, amount);

        address nonOwner = makeAddr("NonOwner");
        vm.deal(nonOwner, 10 ether);
        vm.prank(nonOwner);
        vm.expectRevert(IVaultRouter.InvalidOwner.selector);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);

        if (snap) {
            vm.startSnapshotGas("VaultRouter", "requestDeposit");
        }
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        if (snap) {
            vm.stopSnapshotGas();
        }

        for (uint8 i; i < testAdapters.length; i++) {
            MockAdapter adapter = MockAdapter(address(testAdapters[i]));
            uint256[] memory payCalls = adapter.callsWithValue("send");
            // Messages: registerAsset and requestDeposit
            assertEq(payCalls.length, 2);
        }

        // trigger - deposit order fulfillment
        (uint128 sharePayout) = fulfillDepositRequest(vault, assetId, amount, 0, self);

        assertEq(vault.maxMint(self), sharePayout);
        assertEq(vault.maxDeposit(self), amount);
        IShareToken shareToken = IShareToken(address(vault.share()));
        assertEq(shareToken.balanceOf(address(globalEscrow)), sharePayout);

        if (snap) {
            vm.startSnapshotGas("VaultRouter", "claimDeposit");
        }
        vaultRouter.claimDeposit(vault, self, self);
        if (snap) {
            vm.stopSnapshotGas();
        }
        assertApproxEqAbs(shareToken.balanceOf(self), sharePayout, 1);
        assertApproxEqAbs(shareToken.balanceOf(self), sharePayout, 1);
        assertApproxEqAbs(shareToken.balanceOf(address(globalEscrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), amount, 1);
    }

    function testEnableDisableVaults() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        root.veto(address(vaultRouter));
        vm.expectRevert(IBaseVault.NotEndorsed.selector);
        vaultRouter.enable(vault);
        assertEq(vault.isOperator(address(this), address(vaultRouter)), false);
        assertEq(vaultRouter.isEnabled(vault, address(this)), false);

        root.endorse(address(vaultRouter));
        vaultRouter.enable(vault);
        assertEq(vault.isOperator(address(this), address(vaultRouter)), true);
        assertEq(vaultRouter.isEnabled(vault, address(this)), true);

        root.veto(address(vaultRouter));
        vm.expectRevert(IBaseVault.NotEndorsed.selector);
        vaultRouter.disable(vault);
        assertEq(vault.isOperator(address(this), address(vaultRouter)), true);
        assertEq(vaultRouter.isEnabled(vault, address(this)), true);

        root.endorse(address(vaultRouter));
        vaultRouter.disable(vault);
        assertEq(vault.isOperator(address(this), address(vaultRouter)), false);
        assertEq(vaultRouter.isEnabled(vault, address(this)), false);
    }

    function testRouterAsyncDeposit(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        vaultRouter.enableLockDepositRequest(vault, amount);

        uint256 fuel = DEFAULT_GAS;

        // Any address should be able to call executeLockedDepositRequest for an investor
        address randomAddress = address(0x123);
        vm.label(randomAddress, "randomAddress");
        vm.deal(randomAddress, 10 ether);
        vm.startPrank(randomAddress);
        vaultRouter.executeLockedDepositRequest{value: fuel}(vault, address(this));
        vm.stopPrank();

        (uint128 sharePayout) = fulfillDepositRequest(vault, assetId, amount, 0, self);

        assertEq(vault.maxMint(self), sharePayout);
        assertEq(vault.maxDeposit(self), amount);
        IShareToken shareToken = IShareToken(address(vault.share()));
        assertEq(shareToken.balanceOf(address(globalEscrow)), sharePayout);

        // Any address should be able to call claimDeposit for an investor
        vm.prank(randomUser);
        vaultRouter.claimDeposit(vault, self, self);
        assertApproxEqAbs(shareToken.balanceOf(self), sharePayout, 1);
        assertApproxEqAbs(shareToken.balanceOf(address(globalEscrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), amount, 1);
    }

    /// forge-config: default.isolate = true
    function testRouterRedeem() public {
        _testRouterRedeem(4, true);
    }

    /// forge-config: default.isolate = true
    function testRouterRedeemFuzz(uint256 amount) public {
        vm.assume(amount % 2 == 0);
        _testRouterRedeem(amount, false);
    }

    function _testRouterRedeem(uint256 amount, bool snap) internal {
        amount = uint128(bound(amount, 4, MAX_UINT128));

        // deposit
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        if (snap) {
            vm.startSnapshotGas("VaultRouter", "enable");
        }
        vaultRouter.enable(vault);
        if (snap) {
            vm.stopSnapshotGas();
        }

        uint256 fuel = DEFAULT_GAS;
        vaultRouter.requestDeposit{value: fuel}(vault, amount, self, self);

        (uint128 sharePayout) = fulfillDepositRequest(vault, assetId, amount, 0, self);
        IShareToken shareToken = IShareToken(address(vault.share()));
        vaultRouter.claimDeposit(vault, self, self);
        shareToken.approve(address(vaultRouter), sharePayout);

        address nonOwner = makeAddr("NonOwner");
        vm.deal(nonOwner, 10 ether);
        vm.prank(nonOwner);
        vm.expectRevert(IVaultRouter.InvalidOwner.selector);
        vaultRouter.requestRedeem{value: fuel}(vault, sharePayout, self, self);

        // redeem
        if (snap) {
            vm.startSnapshotGas("VaultRouter", "requestRedeem");
        }
        vaultRouter.requestRedeem{value: fuel}(vault, sharePayout, self, self);
        if (snap) {
            vm.stopSnapshotGas();
        }
        (uint128 assetPayout) = fulfillRedeemRequest(vault, assetId, sharePayout, self);
        assertApproxEqAbs(shareToken.balanceOf(self), 0, 1);
        assertApproxEqAbs(shareToken.balanceOf(address(globalEscrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), assetPayout, 1);
        assertApproxEqAbs(erc20.balanceOf(self), 0, 1);
        vaultRouter.claimRedeem{value: fuel}(vault, self, self);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(self), assetPayout, 1);
    }

    function testRouterDepositIntoMultipleVaults(uint256 amount1, uint256 amount2) public {
        amount1 = uint128(bound(amount1, 4, MAX_UINT128));
        vm.assume(amount1 % 2 == 0);
        amount2 = uint128(bound(amount2, 4, MAX_UINT128));
        vm.assume(amount2 % 2 == 0);

        uint256 fuel = DEFAULT_GAS;
        (ERC20 erc20X, ERC20 erc20Y, AsyncVault vault1, AsyncVault vault2) = setUpMultipleVaults(amount1, amount2);

        vaultRouter.enable(vault1);
        vaultRouter.enable(vault2);

        vaultRouter.requestDeposit{value: fuel}(vault1, amount1, self, self);
        vaultRouter.requestDeposit{value: fuel}(vault2, amount2, self, self);

        // trigger - deposit order fulfillment
        AssetId assetId1 = spoke.assetToId(address(erc20X), erc20TokenId);
        AssetId assetId2 = spoke.assetToId(address(erc20Y), erc20TokenId);
        (uint128 sharePayout1) = fulfillDepositRequest(vault1, assetId1.raw(), amount1, 0, self);
        (uint128 sharePayout2) = fulfillDepositRequest(vault2, assetId2.raw(), amount2, 0, self);

        assertEq(vault1.maxMint(self), sharePayout1);
        assertEq(vault2.maxMint(self), sharePayout2);
        assertEq(vault1.maxDeposit(self), amount1);
        assertEq(vault2.maxDeposit(self), amount2);
        IShareToken shareToken1 = IShareToken(address(vault1.share()));
        IShareToken shareToken2 = IShareToken(address(vault2.share()));
        assertEq(shareToken1.balanceOf(address(globalEscrow)), sharePayout1);
        assertEq(shareToken2.balanceOf(address(globalEscrow)), sharePayout2);

        vaultRouter.claimDeposit(vault1, self, self);
        vaultRouter.claimDeposit(vault2, self, self);
        assertApproxEqAbs(shareToken1.balanceOf(self), sharePayout1, 1);
        assertApproxEqAbs(shareToken2.balanceOf(self), sharePayout2, 1);
        assertApproxEqAbs(shareToken1.balanceOf(address(globalEscrow)), 0, 1);
        assertApproxEqAbs(shareToken2.balanceOf(address(globalEscrow)), 0, 1);
        assertApproxEqAbs(erc20X.balanceOf(address(poolEscrowFactory.escrow(vault1.poolId()))), amount1, 1);
        assertApproxEqAbs(erc20Y.balanceOf(address(poolEscrowFactory.escrow(vault2.poolId()))), amount2, 1);
    }

    function testRouterRedeemFromMultipleVaults(uint256 amount1, uint256 amount2) public {
        amount1 = uint128(bound(amount1, 4, MAX_UINT128));
        vm.assume(amount1 % 2 == 0);
        amount2 = uint128(bound(amount2, 4, MAX_UINT128));
        vm.assume(amount2 % 2 == 0);

        uint256 fuel = DEFAULT_GAS;
        // deposit
        (ERC20 erc20X, ERC20 erc20Y, AsyncVault vault1, AsyncVault vault2) = setUpMultipleVaults(amount1, amount2);

        vaultRouter.enable(vault1);
        vaultRouter.enable(vault2);
        vaultRouter.requestDeposit{value: fuel}(vault1, amount1, self, self);
        vaultRouter.requestDeposit{value: fuel}(vault2, amount2, self, self);

        AssetId assetId1 = spoke.assetToId(address(erc20X), erc20TokenId);
        AssetId assetId2 = spoke.assetToId(address(erc20Y), erc20TokenId);
        (uint128 sharePayout1) = fulfillDepositRequest(vault1, assetId1.raw(), amount1, 0, self);
        (uint128 sharePayout2) = fulfillDepositRequest(vault2, assetId2.raw(), amount2, 0, self);
        vaultRouter.claimDeposit(vault1, self, self);
        vaultRouter.claimDeposit(vault2, self, self);

        // redeem
        IShareToken(address(vault1.share())).approve(address(vaultRouter), sharePayout1);
        IShareToken(address(vault2.share())).approve(address(vaultRouter), sharePayout2);
        vaultRouter.requestRedeem{value: fuel}(vault1, sharePayout1, self, self);
        vaultRouter.requestRedeem{value: fuel}(vault2, sharePayout2, self, self);
        (uint128 assetPayout1) = fulfillRedeemRequest(vault1, assetId1.raw(), sharePayout1, self);
        (uint128 assetPayout2) = fulfillRedeemRequest(vault2, assetId2.raw(), sharePayout2, self);
        assertApproxEqAbs(IShareToken(address(vault1.share())).balanceOf(self), 0, 1);
        assertApproxEqAbs(IShareToken(address(vault2.share())).balanceOf(self), 0, 1);
        assertApproxEqAbs(
            IShareToken(address(vault1.share())).balanceOf(address(poolEscrowFactory.escrow(vault1.poolId()))), 0, 1
        );
        assertApproxEqAbs(
            IShareToken(address(vault2.share())).balanceOf(address(poolEscrowFactory.escrow(vault2.poolId()))), 0, 1
        );
        assertApproxEqAbs(erc20X.balanceOf(address(poolEscrowFactory.escrow(vault1.poolId()))), assetPayout1, 1);
        assertApproxEqAbs(erc20Y.balanceOf(address(poolEscrowFactory.escrow(vault2.poolId()))), assetPayout2, 1);
        assertApproxEqAbs(erc20X.balanceOf(self), 0, 1);
        assertApproxEqAbs(erc20Y.balanceOf(self), 0, 1);

        // claim redeem
        vaultRouter.claimRedeem{value: DEFAULT_GAS}(vault1, self, self);
        vaultRouter.claimRedeem{value: DEFAULT_GAS}(vault2, self, self);
        assertApproxEqAbs(erc20X.balanceOf(address(poolEscrowFactory.escrow(vault1.poolId()))), 0, 1);
        assertApproxEqAbs(erc20Y.balanceOf(address(poolEscrowFactory.escrow(vault2.poolId()))), 0, 1);
        assertApproxEqAbs(erc20X.balanceOf(self), assetPayout1, 1);
        assertApproxEqAbs(erc20Y.balanceOf(self), assetPayout2, 1);
    }

    /// forge-config: default.isolate = true
    function testMulticallingApproveVaultAndExecuteLockedDepositRequest() public {
        _testMulticallingApproveVaultAndExecuteLockedDepositRequest(4, true);
    }

    /// forge-config: default.isolate = true
    function testMulticallingApproveVaultAndExecuteLockedDepositRequestFuzz(uint256 amount) public {
        vm.assume(amount % 2 == 0);
        _testMulticallingApproveVaultAndExecuteLockedDepositRequest(amount, false);
    }

    function _testMulticallingApproveVaultAndExecuteLockedDepositRequest(uint256 amount, bool snap) internal {
        amount = uint128(bound(amount, 4, MAX_UINT128));

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        vaultRouter.enable(vault);
        if (snap) {
            vm.startSnapshotGas("VaultRouter", "lockDepositRequest");
        }
        vaultRouter.lockDepositRequest(vault, amount, self, self);
        if (snap) {
            vm.stopSnapshotGas();
        }

        // multicall
        uint256 fuel = DEFAULT_GAS;
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(vaultRouter.executeLockedDepositRequest.selector, vault_, self, fuel);
        vaultRouter.multicall{value: fuel}(calls);

        (uint128 sharePayout) = fulfillDepositRequest(vault, assetId, amount, 0, self);

        assertEq(vault.maxMint(self), sharePayout);
        assertEq(vault.maxDeposit(self), amount);
        IShareToken shareToken = IShareToken(address(vault.share()));
        assertEq(shareToken.balanceOf(address(globalEscrow)), sharePayout);
    }

    function testMulticallingDepositClaimAndRequestRedeem(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        // deposit
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        vaultRouter.enable(vault);

        uint256 fuel = DEFAULT_GAS;
        vaultRouter.requestDeposit{value: fuel}(vault, amount, self, self);

        (uint128 sharePayout) = fulfillDepositRequest(vault, assetId, amount, 0, self);
        IShareToken shareToken = IShareToken(address(vault.share()));
        shareToken.approve(address(vaultRouter), sharePayout);

        // multicall
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(vaultRouter.claimDeposit.selector, vault_, self, self);
        calls[1] = abi.encodeWithSelector(vaultRouter.requestRedeem.selector, vault_, sharePayout, self, self, fuel);
        vaultRouter.multicall{value: fuel}(calls);

        (uint128 assetPayout) = fulfillRedeemRequest(vault, assetId, sharePayout, self);
        assertApproxEqAbs(shareToken.balanceOf(self), 0, 1);
        assertApproxEqAbs(shareToken.balanceOf(address(globalEscrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), assetPayout, 1);
        assertApproxEqAbs(erc20.balanceOf(self), 0, 1);
    }

    function testMulticallingDepositIntoMultipleVaults(uint256 amount1, uint256 amount2) public {
        amount1 = uint128(bound(amount1, 4, MAX_UINT128));
        vm.assume(amount1 % 2 == 0);
        amount2 = uint128(bound(amount2, 4, MAX_UINT128));
        vm.assume(amount2 % 2 == 0);

        (ERC20 erc20X, ERC20 erc20Y, AsyncVault vault1, AsyncVault vault2) = setUpMultipleVaults(amount1, amount2);

        vaultRouter.enable(vault1);
        vaultRouter.enable(vault2);

        uint256 gas = DEFAULT_GAS;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(vaultRouter.requestDeposit.selector, vault1, amount1, self, self);
        calls[1] = abi.encodeWithSelector(vaultRouter.requestDeposit.selector, vault2, amount2, self, self);
        vaultRouter.multicall{value: gas * calls.length}(calls);

        // trigger - deposit order fulfillment
        AssetId assetId1 = spoke.assetToId(address(erc20X), erc20TokenId);
        AssetId assetId2 = spoke.assetToId(address(erc20Y), erc20TokenId);
        (uint128 sharePayout1) = fulfillDepositRequest(vault1, assetId1.raw(), amount1, 0, self);
        (uint128 sharePayout2) = fulfillDepositRequest(vault2, assetId2.raw(), amount2, 0, self);

        assertEq(vault1.maxMint(self), sharePayout1);
        assertEq(vault2.maxMint(self), sharePayout2);
        assertEq(vault1.maxDeposit(self), amount1);
        assertEq(vault2.maxDeposit(self), amount2);
        IShareToken shareToken1 = IShareToken(address(vault1.share()));
        IShareToken shareToken2 = IShareToken(address(vault2.share()));
        assertEq(shareToken1.balanceOf(address(globalEscrow)), sharePayout1);
        assertEq(shareToken2.balanceOf(address(globalEscrow)), sharePayout2);
    }

    function testLockAndExecuteDepositRequest(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        (, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, 6, address(fullRestrictionsHook), bytes16(bytes("1")), address(erc20), 0, 0);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");
        vm.deal(investor, 10 ether);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);

        erc20.mint(investor, amount);
        vm.startPrank(investor);
        erc20.approve(address(vaultRouter), amount);

        uint256 fuel = DEFAULT_GAS + GAS_BUFFER;

        // multicall
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(vaultRouter.lockDepositRequest.selector, vault_, amount, investor, investor);
        calls[1] = abi.encodeWithSelector(vaultRouter.executeLockedDepositRequest.selector, vault_, investor, fuel);
        vaultRouter.multicall{value: fuel}(calls);

        (uint128 sharePayout) = fulfillDepositRequest(vault, assetId, amount, 0, investor);

        assertEq(vault.maxMint(investor), sharePayout);
        assertEq(vault.maxDeposit(investor), amount);
        IShareToken shareToken = IShareToken(address(vault.share()));
        assertEq(shareToken.balanceOf(address(globalEscrow)), sharePayout);
    }

    function testMultipleTopUpScenarios(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        erc20.approve(vault_, amount);
        vaultRouter.enable(vault);

        uint256 gasCost = ESTIMATE_ADAPTERS + GAS_COST_LIMIT * 3 * 2;

        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRouter.requestDeposit{value: gasCost}(IAsyncVault(makeAddr("maliciousVault")), amount, self, self);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(vaultRouter.requestDeposit.selector, vault_, amount / 2, self, self);
        calls[1] = abi.encodeWithSelector(vaultRouter.requestDeposit.selector, vault_, amount / 2, self, self);

        assertEq(address(vaultRouter).balance, 0);
        vaultRouter.multicall{value: gasCost}(calls);
    }

    // --- helpers ---
    function fulfillDepositRequest(
        AsyncVault vault,
        uint128 assetId,
        uint256 fulfilledAssetAmount,
        uint128 cancelledAssetAmount,
        address user
    ) public returns (uint128 sharePayout) {
        uint128 price = 2 * 10 ** 18;
        sharePayout = uint128(fulfilledAssetAmount * 10 ** 18 / price);
        assertApproxEqAbs(sharePayout, fulfilledAssetAmount / 2, 2);

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(user)),
            assetId,
            uint128(fulfilledAssetAmount),
            sharePayout,
            cancelledAssetAmount
        );
    }

    function fulfillRedeemRequest(AsyncVault vault, uint128 assetId, uint256 amount, address user)
        public
        returns (uint128 assetPayout)
    {
        uint128 price = 2 * 10 ** 18;
        assetPayout = uint128(amount * price / 10 ** 18);
        assertApproxEqAbs(assetPayout, amount * 2, 2);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(user)), assetId, assetPayout, uint128(amount), 0
        );
    }

    function setUpMultipleVaults(uint256 amount1, uint256 amount2)
        public
        returns (ERC20 erc20X, ERC20 erc20Y, AsyncVault vault1, AsyncVault vault2)
    {
        erc20X = _newErc20("X's Dollar", "USDX", 6);
        erc20Y = _newErc20("Y's Dollar", "USDY", 6);
        vm.label(address(erc20X), "erc20X");
        vm.label(address(erc20Y), "erc20Y");
        (, address vault1_,) =
            deployVault(VaultKind.Async, 6, address(fullRestrictionsHook), bytes16(bytes("1")), address(erc20X), 0, 0);
        (, address vault2_,) =
            deployVault(VaultKind.Async, 6, address(fullRestrictionsHook), bytes16(bytes("2")), address(erc20Y), 0, 0);
        vault1 = AsyncVault(vault1_);
        vault2 = AsyncVault(vault2_);
        vm.label(vault1_, "vault1");
        vm.label(vault2_, "vault2");

        erc20X.mint(self, amount1);
        erc20Y.mint(self, amount2);

        erc20X.approve(address(vault1_), amount1);
        erc20Y.approve(address(vault2_), amount2);

        centrifugeChain.updateMember(vault1.poolId().raw(), vault1.scId().raw(), self, type(uint64).max);
        centrifugeChain.updateMember(vault2.poolId().raw(), vault2.scId().raw(), self, type(uint64).max);
    }
}

interface Authlike {
    function rely(address) external;
}

contract ERC20WrapperFake {
    address public underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract MaliciousVault {
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == type(IERC7540Deposit).interfaceId;
    }
}

contract NonAsyncVault {
    function supportsInterface(bytes4) public pure returns (bool) {
        return false;
    }
}

contract VaultRouterMoreUnitaryTest is BaseTest {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for uint256;

    uint16 constant CHAIN_ID = 1;
    uint256 constant GAS_BUFFER = 10_000_000; // 10M gas
    bytes PAYLOAD_FOR_GAS_ESTIMATION = MessageLib.NotifyPool(1).serialize();

    function testInitialization() public {
        // redeploying within test to increase coverage
        new VaultRouter(address(routerEscrow), gateway, spoke, address(this));

        assertEq(address(vaultRouter.escrow()), address(routerEscrow));
        assertEq(address(vaultRouter.gateway()), address(gateway));
        assertEq(address(vaultRouter.spoke()), address(spoke));
    }

    function testGetVault() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        assertEq(vaultRouter.getVault(vault.poolId(), vault.scId(), address(erc20)), vault_);
    }

    function testRequestDeposit() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        uint256 gas = DEFAULT_GAS;

        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        vaultRouter.enable(vault);

        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        assertEq(erc20.balanceOf(address(globalEscrow)), amount);
    }

    function testRouterSyncDeposit() public {
        (uint64 poolId, address vault_,) = deploySimpleVault(VaultKind.SyncDepositAsyncRedeem);
        vm.label(vault_, "vault");
        SyncDepositVault vault = SyncDepositVault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);

        erc20.approve(address(vault_), amount);
        vm.expectPartialRevert(IERC7751.WrappedError.selector);
        vaultRouter.deposit(vault, amount, self, self);

        erc20.approve(address(vaultRouter), amount);
        vaultRouter.deposit(vault, amount, self, self);
        assertEq(erc20.balanceOf(address(balanceSheet.poolEscrowProvider().escrow(PoolId.wrap(poolId)))), amount);
    }

    function testLockDepositRequests() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        IAsyncVault maliciousVault = IAsyncVault(address(new MaliciousVault()));
        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRouter.lockDepositRequest(maliciousVault, amount, self, self);

        IAsyncVault nonAsyncVault = IAsyncVault(address(new NonAsyncVault()));
        vm.expectRevert(IVaultRouter.NonAsyncVault.selector);
        vaultRouter.lockDepositRequest(nonAsyncVault, amount, self, self);

        vaultRouter.lockDepositRequest(vault, amount, self, self);

        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
    }

    function testUnlockDepositRequests() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        vm.expectRevert(IVaultRouter.NoLockedBalance.selector);
        vaultRouter.unlockDepositRequest(vault, self);

        vaultRouter.lockDepositRequest(vault, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
        assertEq(erc20.balanceOf(self), 0);
        vaultRouter.unlockDepositRequest(vault, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);
        assertEq(erc20.balanceOf(self), amount);
    }

    function testCancelDepositRequest() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);

        uint256 amount = 100 * 10 ** 18;
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        vaultRouter.enable(vault);
        vaultRouter.lockDepositRequest(vault, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
        assertEq(vault.pendingCancelDepositRequest(0, self), false);

        uint256 fuel = DEFAULT_GAS;
        vm.deal(address(this), 10 ether);

        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        vaultRouter.cancelDepositRequest{value: fuel}(vault);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        vaultRouter.executeLockedDepositRequest{value: fuel}(vault, self);
        assertEq(vault.pendingDepositRequest(0, self), amount);

        vaultRouter.cancelDepositRequest{value: fuel}(vault);
        assertTrue(vault.pendingCancelDepositRequest(0, self));
    }

    function testClaimCancelDepositRequest() public {
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);

        uint256 amount = 100 * 10 ** 18;

        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);

        uint256 gas = DEFAULT_GAS + GAS_BUFFER;
        vaultRouter.enable(vault);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        assertEq(erc20.balanceOf(address(globalEscrow)), amount);

        vaultRouter.cancelDepositRequest{value: gas}(vault);
        assertEq(vault.pendingCancelDepositRequest(0, self), true);
        assertEq(erc20.balanceOf(address(globalEscrow)), amount);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), vault.scId().raw(), self.toBytes32(), assetId, 0, 0, uint128(amount)
        );
        assertEq(vault.claimableCancelDepositRequest(0, self), amount);

        address nonMember = makeAddr("nonMember");
        vm.prank(nonMember);
        vm.expectRevert(IVaultRouter.InvalidSender.selector);
        vaultRouter.claimCancelDepositRequest(vault, nonMember, self);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vaultRouter.claimCancelDepositRequest(vault, nonMember, self);

        vaultRouter.claimCancelDepositRequest(vault, self, self);
        assertEq(erc20.balanceOf(address(globalEscrow)), 0);
        assertEq(erc20.balanceOf(self), amount);
    }

    function testRequestRedeem() external {
        // Deposit first
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        uint256 gas = DEFAULT_GAS;
        vaultRouter.enable(vault);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(self)),
            assetId,
            uint128(amount),
            uint128(amount),
            0
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(address(vaultRouter), amount);

        vaultRouter.requestRedeem{value: gas}(vault, amount, self, self);
        assertEq(share.balanceOf(address(self)), 0);
    }

    function testCancelRedeemRequest() public {
        // Deposit first
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        uint256 gas = DEFAULT_GAS;
        vaultRouter.enable(vault);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(self)),
            assetId,
            uint128(amount),
            uint128(amount),
            0
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(address(vaultRouter), amount);
        vaultRouter.requestRedeem{value: gas}(vault, amount, self, self);
        assertEq(share.balanceOf(address(self)), 0);

        vm.deal(address(this), 10 ether);

        vaultRouter.cancelRedeemRequest{value: gas}(vault);
        assertEq(vault.pendingCancelRedeemRequest(0, self), true);
    }

    function testClaimCancelRedeemRequest() public {
        // Deposit first
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);
        uint256 gas = DEFAULT_GAS + GAS_BUFFER;
        vaultRouter.enable(vault);
        vaultRouter.requestDeposit{value: gas}(vault, amount, self, self);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(self)),
            assetId,
            uint128(amount),
            uint128(amount),
            0
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(vault_, amount);
        share.approve(address(vaultRouter), amount);
        vaultRouter.requestRedeem{value: gas}(vault, amount, self, self);
        assertEq(share.balanceOf(address(self)), 0);

        vaultRouter.cancelRedeemRequest{value: gas}(vault);
        assertEq(vault.pendingCancelRedeemRequest(0, self), true);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), self.toBytes32(), assetId, 0, 0, uint128(amount)
        );

        address sender = makeAddr("maliciousUser");
        vm.prank(sender);
        vm.expectRevert(IVaultRouter.InvalidSender.selector);
        vaultRouter.claimCancelRedeemRequest(vault, sender, self);

        vaultRouter.claimCancelRedeemRequest(vault, self, self);
        assertEq(share.balanceOf(address(self)), amount);
    }

    function testPermit() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);
        vm.label(owner, "owner");
        vm.label(address(vaultRouter), "spender");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    erc20.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(vaultRouter), 1e18, 0, block.timestamp))
                )
            )
        );

        vm.prank(owner);
        vaultRouter.permit(address(erc20), address(vaultRouter), 1e18, block.timestamp, v, r, s);

        assertEq(erc20.allowance(owner, address(vaultRouter)), 1e18);
        assertEq(erc20.nonces(owner), 1);
    }

    function testEnableAndDisable() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        vm.label(vault_, "vault");

        assertFalse(AsyncVault(vault_).isOperator(self, address(vaultRouter)));
        assertEq(vaultRouter.isEnabled(vault, self), false);
        vaultRouter.enable(vault);
        assertTrue(AsyncVault(vault_).isOperator(self, address(vaultRouter)));
        assertEq(vaultRouter.isEnabled(vault, self), true);
        vaultRouter.disable(vault);
        assertFalse(AsyncVault(vault_).isOperator(self, address(vaultRouter)));
        assertEq(vaultRouter.isEnabled(vault, self), false);
    }

    function testIfUserIsPermittedToExecuteRequests() public {
        uint256 amount = 100 * 10 ** 18;
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        vm.label(vault_, "vault");
        AsyncVault vault = AsyncVault(vault_);

        vm.deal(self, 1 ether);
        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        bool canUserExecute = vaultRouter.hasPermissions(vault, self);
        assertFalse(canUserExecute);

        vaultRouter.lockDepositRequest(vault, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);

        uint256 gasLimit = DEFAULT_GAS;

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vaultRouter.executeLockedDepositRequest{value: gasLimit}(vault, self);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);

        canUserExecute = vaultRouter.hasPermissions(vault, self);
        assertTrue(canUserExecute);

        vaultRouter.executeLockedDepositRequest{value: gasLimit}(vault, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);
        assertEq(erc20.balanceOf(address(globalEscrow)), amount);
    }
}
