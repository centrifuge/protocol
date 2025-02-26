// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import "src/misc/interfaces/IERC20.sol";
import {IMulticall} from "src/misc/interfaces/IMulticall.sol";

import "test/vaults/BaseTest.sol";
import "src/vaults/interfaces/IERC7575.sol";
import "src/vaults/interfaces/IERC7540.sol";
import {CentrifugeRouter} from "src/vaults/CentrifugeRouter.sol";
import {MockERC20Wrapper} from "test/vaults/mocks/MockERC20Wrapper.sol";
import {MockReentrantERC20Wrapper1, MockReentrantERC20Wrapper2} from "test/vaults/mocks/MockReentrantERC20Wrapper.sol";

contract CentrifugeRouterTest is BaseTest {
    uint256 constant GAS_BUFFER = 10 gwei;
    /// @dev Payload is not taken into account during gas estimation
    bytes constant PAYLOAD_FOR_GAS_ESTIMATION = "irrelevant_value";

    /// forge-config: default.isolate = true
    function testCFGRouterDeposit(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);

        vm.expectRevert(bytes("Gateway/cannot-topup-with-nothing"));
        router.requestDeposit(vault_, amount, self, self, 0);

        vm.expectRevert(bytes("ERC7540Vault/invalid-owner"));
        router.requestDeposit{value: 1 wei}(vault_, amount, self, self, 1 wei);

        router.enable(vault_);
        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        router.requestDeposit{value: 1 wei}(vault_, amount, self, self, 1 wei);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        uint256 gas = estimateGas() + GAS_BUFFER;

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        erc20.approve(vault_, amount);

        address nonOwner = makeAddr("NonOwner");
        vm.deal(nonOwner, 10 ether);
        vm.prank(nonOwner);
        vm.expectRevert(bytes("CentrifugeRouter/invalid-owner"));
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);

        snapStart("CentrifugeRouter_requestDeposit");
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        snapEnd();

        assertEq(address(gateway).balance, GATEWAY_INITIAL_BALACE + GAS_BUFFER);
        for (uint8 i; i < testAdapters.length; i++) {
            MockAdapter adapter = MockAdapter(testAdapters[i]);
            uint256[] memory payCalls = adapter.callsWithValue("pay");
            assertEq(payCalls.length, 1);
            assertEq(
                payCalls[0],
                adapter.estimate(PAYLOAD_FOR_GAS_ESTIMATION, mockedGasService.estimate(PAYLOAD_FOR_GAS_ESTIMATION))
            );
        }

        // trigger - deposit order fulfillment
        uint128 assetId = poolManager.assetToId(address(erc20));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, self);

        assertEq(vault.maxMint(self), tranchePayout);
        assertEq(vault.maxDeposit(self), amount);
        ITranche tranche = ITranche(address(vault.share()));
        assertEq(tranche.balanceOf(address(escrow)), tranchePayout);

        snapStart("CentrifugeRouter_claimDeposit");
        router.claimDeposit(vault_, self, self);
        snapEnd();
        assertApproxEqAbs(tranche.balanceOf(self), tranchePayout, 1);
        assertApproxEqAbs(tranche.balanceOf(self), tranchePayout, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), amount, 1);
    }

    function testEnableDisableVaults() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        root.veto(address(router));
        vm.expectRevert(bytes("ERC7540Vault/not-endorsed"));
        router.enable(vault_);
        assertEq(vault.isOperator(address(this), address(router)), false);
        assertEq(router.isEnabled(vault_, address(this)), false);

        root.endorse(address(router));
        router.enable(vault_);
        assertEq(vault.isOperator(address(this), address(router)), true);
        assertEq(router.isEnabled(vault_, address(this)), true);

        root.veto(address(router));
        vm.expectRevert(bytes("ERC7540Vault/not-endorsed"));
        router.disable(vault_);
        assertEq(vault.isOperator(address(this), address(router)), true);
        assertEq(router.isEnabled(vault_, address(this)), true);

        root.endorse(address(router));
        router.disable(vault_);
        assertEq(vault.isOperator(address(this), address(router)), false);
        assertEq(router.isEnabled(vault_, address(this)), false);
    }

    function testRouterAsyncDeposit(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);
        erc20.approve(address(router), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        router.enableLockDepositRequest(vault_, amount);

        uint256 fuel = estimateGas();

        // Any address should be able to call executeLockedDepositRequest for an investor
        address randomAddress = address(0x123);
        vm.label(randomAddress, "randomAddress");
        vm.deal(randomAddress, 10 ether);
        vm.startPrank(randomAddress);
        router.executeLockedDepositRequest{value: fuel}(vault_, address(this), fuel);
        vm.stopPrank();

        uint128 assetId = poolManager.assetToId(address(erc20));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, self);

        assertEq(vault.maxMint(self), tranchePayout);
        assertEq(vault.maxDeposit(self), amount);
        ITranche tranche = ITranche(address(vault.share()));
        assertEq(tranche.balanceOf(address(escrow)), tranchePayout);

        // Any address should be able to call claimDeposit for an investor
        vm.prank(randomUser);
        router.claimDeposit(vault_, self, self);
        assertApproxEqAbs(tranche.balanceOf(self), tranchePayout, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), amount, 1);
    }

    /// forge-config: default.isolate = true
    function testRouterRedeem(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        // deposit
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        snapStart("CentrifugeRouter_enable");
        router.enable(vault_);
        snapEnd();

        uint256 fuel = estimateGas();
        router.requestDeposit{value: fuel}(vault_, amount, self, self, fuel);

        uint128 assetId = poolManager.assetToId(address(erc20));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, self);
        ITranche tranche = ITranche(address(vault.share()));
        router.claimDeposit(vault_, self, self);
        tranche.approve(address(router), tranchePayout);

        address nonOwner = makeAddr("NonOwner");
        vm.deal(nonOwner, 10 ether);
        vm.prank(nonOwner);
        vm.expectRevert(bytes("CentrifugeRouter/invalid-owner"));
        router.requestRedeem{value: fuel}(vault_, tranchePayout, self, self, fuel);

        // redeem
        snapStart("CentrifugeRouter_requestRedeem");
        router.requestRedeem{value: fuel}(vault_, tranchePayout, self, self, fuel);
        snapEnd();
        (uint128 assetPayout) = fulfillRedeemRequest(vault, assetId, tranchePayout, self);
        assertApproxEqAbs(tranche.balanceOf(self), 0, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), assetPayout, 1);
        assertApproxEqAbs(erc20.balanceOf(self), 0, 1);
        router.claimRedeem(vault_, self, self);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(self), assetPayout, 1);
    }

    function testRouterDepositIntoMultipleVaults(uint256 amount1, uint256 amount2) public {
        amount1 = uint128(bound(amount1, 4, MAX_UINT128));
        vm.assume(amount1 % 2 == 0);
        amount2 = uint128(bound(amount2, 4, MAX_UINT128));
        vm.assume(amount2 % 2 == 0);

        uint256 fuel = estimateGas();
        (ERC20 erc20X, ERC20 erc20Y, ERC7540Vault vault1, ERC7540Vault vault2) = setUpMultipleVaults(amount1, amount2);

        router.enable(address(vault1));
        router.enable(address(vault2));

        router.requestDeposit{value: fuel}(address(vault1), amount1, self, self, fuel);
        router.requestDeposit{value: fuel}(address(vault2), amount2, self, self, fuel);

        // trigger - deposit order fulfillment
        uint128 assetId1 = poolManager.assetToId(address(erc20X));
        uint128 assetId2 = poolManager.assetToId(address(erc20Y));
        (uint128 tranchePayout1) = fulfillDepositRequest(vault1, assetId1, amount1, self);
        (uint128 tranchePayout2) = fulfillDepositRequest(vault2, assetId2, amount2, self);

        assertEq(vault1.maxMint(self), tranchePayout1);
        assertEq(vault2.maxMint(self), tranchePayout2);
        assertEq(vault1.maxDeposit(self), amount1);
        assertEq(vault2.maxDeposit(self), amount2);
        ITranche tranche1 = ITranche(address(vault1.share()));
        ITranche tranche2 = ITranche(address(vault2.share()));
        assertEq(tranche1.balanceOf(address(escrow)), tranchePayout1);
        assertEq(tranche2.balanceOf(address(escrow)), tranchePayout2);

        router.claimDeposit(address(vault1), self, self);
        router.claimDeposit(address(vault2), self, self);
        assertApproxEqAbs(tranche1.balanceOf(self), tranchePayout1, 1);
        assertApproxEqAbs(tranche2.balanceOf(self), tranchePayout2, 1);
        assertApproxEqAbs(tranche1.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(tranche2.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20X.balanceOf(address(escrow)), amount1, 1);
        assertApproxEqAbs(erc20Y.balanceOf(address(escrow)), amount2, 1);
    }

    function testRouterRedeemFromMultipleVaults(uint256 amount1, uint256 amount2) public {
        amount1 = uint128(bound(amount1, 4, MAX_UINT128));
        vm.assume(amount1 % 2 == 0);
        amount2 = uint128(bound(amount2, 4, MAX_UINT128));
        vm.assume(amount2 % 2 == 0);

        uint256 fuel = estimateGas();
        // deposit
        (ERC20 erc20X, ERC20 erc20Y, ERC7540Vault vault1, ERC7540Vault vault2) = setUpMultipleVaults(amount1, amount2);

        router.enable(address(vault1));
        router.enable(address(vault2));

        router.requestDeposit{value: fuel}(address(vault1), amount1, self, self, fuel);
        router.requestDeposit{value: fuel}(address(vault2), amount2, self, self, fuel);

        uint128 assetId1 = poolManager.assetToId(address(erc20X));
        uint128 assetId2 = poolManager.assetToId(address(erc20Y));
        (uint128 tranchePayout1) = fulfillDepositRequest(vault1, assetId1, amount1, self);
        (uint128 tranchePayout2) = fulfillDepositRequest(vault2, assetId2, amount2, self);
        router.claimDeposit(address(vault1), self, self);
        router.claimDeposit(address(vault2), self, self);

        // redeem
        ITranche(address(vault1.share())).approve(address(router), tranchePayout1);
        ITranche(address(vault2.share())).approve(address(router), tranchePayout2);
        router.requestRedeem{value: fuel}(address(vault1), tranchePayout1, self, self, fuel);
        router.requestRedeem{value: fuel}(address(vault2), tranchePayout2, self, self, fuel);
        (uint128 assetPayout1) = fulfillRedeemRequest(vault1, assetId1, tranchePayout1, self);
        (uint128 assetPayout2) = fulfillRedeemRequest(vault2, assetId2, tranchePayout2, self);
        assertApproxEqAbs(ITranche(address(vault1.share())).balanceOf(self), 0, 1);
        assertApproxEqAbs(ITranche(address(vault2.share())).balanceOf(self), 0, 1);
        assertApproxEqAbs(ITranche(address(vault1.share())).balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(ITranche(address(vault2.share())).balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20X.balanceOf(address(escrow)), assetPayout1, 1);
        assertApproxEqAbs(erc20Y.balanceOf(address(escrow)), assetPayout2, 1);
        assertApproxEqAbs(erc20X.balanceOf(self), 0, 1);
        assertApproxEqAbs(erc20Y.balanceOf(self), 0, 1);
        router.claimRedeem(address(vault1), self, self);
        router.claimRedeem(address(vault2), self, self);
        assertApproxEqAbs(erc20X.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20Y.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20X.balanceOf(self), assetPayout1, 1);
        assertApproxEqAbs(erc20Y.balanceOf(self), assetPayout2, 1);
    }

    /// forge-config: default.isolate = true
    function testMulticallingApproveVaultAndExecuteLockedDepositRequest(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);
        erc20.approve(address(router), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        router.enable(address(vault_));
        snapStart("CentrifugeRouter_lockDepositRequest");
        router.lockDepositRequest(vault_, amount, self, self);
        snapEnd();

        // multicall
        uint256 fuel = estimateGas();
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(router.executeLockedDepositRequest.selector, vault_, self, fuel);
        router.multicall{value: fuel}(calls);

        uint128 assetId = poolManager.assetToId(address(erc20));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, self);

        assertEq(vault.maxMint(self), tranchePayout);
        assertEq(vault.maxDeposit(self), amount);
        ITranche tranche = ITranche(address(vault.share()));
        assertEq(tranche.balanceOf(address(escrow)), tranchePayout);
    }

    function testMulticallingDepositClaimAndRequestRedeem(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        // deposit
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        router.enable(vault_);

        uint256 fuel = estimateGas();
        router.requestDeposit{value: fuel}(vault_, amount, self, self, fuel);

        uint128 assetId = poolManager.assetToId(address(erc20));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, self);
        ITranche tranche = ITranche(address(vault.share()));
        tranche.approve(address(router), tranchePayout);

        // multicall
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(router.claimDeposit.selector, vault_, self, self);
        calls[1] = abi.encodeWithSelector(router.requestRedeem.selector, vault_, tranchePayout, self, self, fuel);
        router.multicall{value: fuel}(calls);

        (uint128 assetPayout) = fulfillRedeemRequest(vault, assetId, tranchePayout, self);
        assertApproxEqAbs(tranche.balanceOf(self), 0, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), assetPayout, 1);
        assertApproxEqAbs(erc20.balanceOf(self), 0, 1);
    }

    function testMulticallingDepositIntoMultipleVaults(uint256 amount1, uint256 amount2) public {
        amount1 = uint128(bound(amount1, 4, MAX_UINT128));
        vm.assume(amount1 % 2 == 0);
        amount2 = uint128(bound(amount2, 4, MAX_UINT128));
        vm.assume(amount2 % 2 == 0);

        (ERC20 erc20X, ERC20 erc20Y, ERC7540Vault vault1, ERC7540Vault vault2) = setUpMultipleVaults(amount1, amount2);

        router.enable(address(vault1));
        router.enable(address(vault2));

        uint256 gas = estimateGas();
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(router.requestDeposit.selector, vault1, amount1, self, self, gas);
        calls[1] = abi.encodeWithSelector(router.requestDeposit.selector, vault2, amount2, self, self, gas);
        router.multicall{value: gas * calls.length}(calls);

        // trigger - deposit order fulfillment
        uint128 assetId1 = poolManager.assetToId(address(erc20X));
        uint128 assetId2 = poolManager.assetToId(address(erc20Y));
        (uint128 tranchePayout1) = fulfillDepositRequest(vault1, assetId1, amount1, self);
        (uint128 tranchePayout2) = fulfillDepositRequest(vault2, assetId2, amount2, self);

        assertEq(vault1.maxMint(self), tranchePayout1);
        assertEq(vault2.maxMint(self), tranchePayout2);
        assertEq(vault1.maxDeposit(self), amount1);
        assertEq(vault2.maxDeposit(self), amount2);
        ITranche tranche1 = ITranche(address(vault1.share()));
        ITranche tranche2 = ITranche(address(vault2.share()));
        assertEq(tranche1.balanceOf(address(escrow)), tranchePayout1);
        assertEq(tranche2.balanceOf(address(escrow)), tranchePayout2);
    }

    function testLockAndExecuteDepositRequest(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");
        vm.deal(investor, 10 ether);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);

        erc20.mint(investor, amount);
        vm.startPrank(investor);
        erc20.approve(address(router), amount);

        uint256 fuel = estimateGas() + GAS_BUFFER;

        // multicall
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(router.wrap.selector, wrapper, amount, address(router), investor);
        calls[1] = abi.encodeWithSelector(router.lockDepositRequest.selector, vault_, amount, investor, address(router));
        calls[2] = abi.encodeWithSelector(router.executeLockedDepositRequest.selector, vault_, investor, fuel);
        router.multicall{value: fuel}(calls);

        uint128 assetId = poolManager.assetToId(address(wrapper));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, investor);

        assertEq(vault.maxMint(investor), tranchePayout);
        assertEq(vault.maxDeposit(investor), amount);
        ITranche tranche = ITranche(address(vault.share()));
        assertEq(tranche.balanceOf(address(escrow)), tranchePayout);
    }

    function testWrapAndUnwrap(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);
        router.enable(vault_);

        erc20.mint(investor, amount);
        vm.startPrank(investor);
        erc20.approve(address(router), amount);

        assertEq(erc20.balanceOf(investor), amount);

        // multicall
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(router.wrap.selector, address(wrapper), amount, address(router), investor);
        calls[1] = abi.encodeWithSelector(router.unwrap.selector, address(wrapper), amount, investor);
        router.multicall(calls);

        assertEq(erc20.balanceOf(investor), amount);
    }

    function testWrapAndDeposit(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);
        router.enable(vault_);

        erc20.mint(investor, amount);
        vm.startPrank(investor);
        erc20.approve(address(router), amount);

        assertEq(erc20.balanceOf(investor), amount);

        vm.deal(investor, 10 ether);
        uint256 fuel = estimateGas();
        router.wrap(address(wrapper), amount, address(router), investor);
        router.requestDeposit{value: fuel}(address(vault), amount, investor, address(router), fuel);
    }

    function testWrapAndAutoUnwrapOnRedeem(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");

        erc20.mint(investor, amount);

        // Investor locks deposit request and enables permissionless lcaiming
        vm.startPrank(investor);
        erc20.approve(address(router), amount);
        router.enableLockDepositRequest(vault_, amount);
        vm.stopPrank();

        // Anyone else can execute the request and claim the deposit
        uint256 fuel = estimateGas();
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);
        router.executeLockedDepositRequest{value: fuel}(vault_, investor, fuel);
        uint128 assetId = poolManager.assetToId(address(wrapper));
        (uint128 tranchePayout) = fulfillDepositRequest(vault, assetId, amount, investor);

        ITranche tranche = ITranche(address(vault.share()));
        router.claimDeposit(vault_, investor, investor);

        // Investors submits redemption  request
        vm.deal(investor, 10 ether);
        vm.startPrank(investor);
        tranche.approve(address(router), tranchePayout);
        router.requestRedeem{value: fuel}(vault_, tranchePayout, investor, investor, fuel);
        vm.stopPrank();

        // Anyone else claims the redeem
        (uint128 assetPayout) = fulfillRedeemRequest(vault, assetId, tranchePayout, investor);
        assertEq(wrapper.balanceOf(address(escrow)), assetPayout);
        assertEq(erc20.balanceOf(address(investor)), 0);
        router.claimRedeem(vault_, investor, investor);

        // Token was immediately unwrapped
        assertEq(wrapper.balanceOf(address(escrow)), 0);
        assertEq(erc20.balanceOf(investor), assetPayout);
    }

    function testEnableLockDepositRequest(uint256 wrappedAmount, uint256 underlyingAmount) public {
        wrappedAmount = uint128(bound(wrappedAmount, 4, MAX_UINT128));
        vm.assume(wrappedAmount % 2 == 0);

        underlyingAmount = uint128(bound(underlyingAmount, 4, MAX_UINT128));
        vm.assume(underlyingAmount % 2 == 0);

        vm.assume(wrappedAmount != underlyingAmount);
        vm.assume(wrappedAmount < underlyingAmount);

        address routerEscrowAddress = address(routerEscrow);

        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        vm.label(vault_, "vault");

        erc20.mint(self, underlyingAmount);
        erc20.approve(address(router), underlyingAmount);
        wrapper.mint(self, wrappedAmount);
        wrapper.approve(address(router), wrappedAmount);

        // Testing partial of wrapped asset balance
        uint256 wrappedBalance = wrapper.balanceOf(self);
        uint256 deposit = wrappedBalance / 2;
        uint256 remainingWrapped = wrappedBalance / 2;
        uint256 remainingUnderlying = erc20.balanceOf(self);
        uint256 escrowBalance = deposit;
        router.enableLockDepositRequest(vault_, deposit);
        assertEq(wrapper.balanceOf(routerEscrowAddress), escrowBalance);
        assertEq(wrapper.balanceOf(self), remainingWrapped);
        assertEq(erc20.balanceOf(routerEscrowAddress), 0);
        assertEq(erc20.balanceOf(self), remainingUnderlying);

        // Testing more than the wrapped asset balance
        wrappedBalance = wrapper.balanceOf(self);
        deposit = wrappedBalance + 1;
        remainingWrapped = wrappedBalance;
        remainingUnderlying = erc20.balanceOf(self) - deposit;
        escrowBalance = escrowBalance + deposit;
        router.enableLockDepositRequest(vault_, deposit);
        assertEq(wrapper.balanceOf(routerEscrowAddress), escrowBalance); // amount was used from the underlying asset
            // and wrapped
        assertEq(wrapper.balanceOf(self), remainingWrapped);
        assertEq(erc20.balanceOf(routerEscrowAddress), 0);
        assertEq(erc20.balanceOf(self), remainingUnderlying);

        // Testing whole wrapped amount
        wrappedBalance = wrapper.balanceOf(self);
        deposit = wrappedBalance;
        remainingUnderlying = erc20.balanceOf(self);
        escrowBalance = escrowBalance + deposit;
        router.enableLockDepositRequest(vault_, deposit);
        assertEq(wrapper.balanceOf(routerEscrowAddress), escrowBalance);
        assertEq(wrapper.balanceOf(self), 0);
        assertEq(erc20.balanceOf(routerEscrowAddress), 0);
        assertEq(erc20.balanceOf(self), remainingUnderlying);

        // Testing more than the underlying
        uint256 underlyingBalance = erc20.balanceOf(self);
        deposit = underlyingBalance + 1;
        remainingUnderlying = underlyingBalance;
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        router.enableLockDepositRequest(vault_, deposit);
        assertEq(wrapper.balanceOf(routerEscrowAddress), escrowBalance);
        assertEq(wrapper.balanceOf(self), 0);
        assertEq(erc20.balanceOf(routerEscrowAddress), 0);
        assertEq(erc20.balanceOf(self), remainingUnderlying);

        // Testing all the underlying
        deposit = erc20.balanceOf(self);
        escrowBalance = escrowBalance + deposit;
        router.enableLockDepositRequest(vault_, deposit);
        assertEq(wrapper.balanceOf(routerEscrowAddress), escrowBalance);
        assertEq(wrapper.balanceOf(self), 0);
        assertEq(erc20.balanceOf(routerEscrowAddress), 0);
        assertEq(erc20.balanceOf(self), 0);

        // Testing with empty balance for both wrapped and underlying
        vm.expectRevert(bytes("CentrifugeRouter/zero-balance"));
        router.enableLockDepositRequest(vault_, wrappedAmount);
    }

    function testMultipleTopUpScenarios(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        erc20.mint(self, amount);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        erc20.approve(vault_, amount);
        router.enable(vault_);

        uint256 gasLimit = estimateGas();
        uint256 lessGas = gasLimit - 1;

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.requestDeposit(vault_, amount, self, self, 0);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.requestDeposit{value: lessGas}(vault_, amount, self, self, gasLimit);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.requestDeposit{value: lessGas}(vault_, amount, self, self, lessGas);

        vm.expectRevert("PoolManager/unknown-vault");
        router.requestDeposit{value: lessGas}(makeAddr("maliciousVault"), amount, self, self, lessGas);

        vm.expectRevert("PoolManager/unknown-vault");
        router.requestDeposit{value: lessGas}(makeAddr("maliciousVault"), amount, self, self, lessGas);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(router.requestDeposit.selector, vault_, amount / 2, self, self, gasLimit);
        calls[1] = abi.encodeWithSelector(router.requestDeposit.selector, vault_, amount / 2, self, self, gasLimit);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.multicall{value: gasLimit}(calls);

        uint256 coverMoreThanItIsNeeded = gasLimit * calls.length + 1;
        assertEq(address(router).balance, 0);
        router.multicall{value: coverMoreThanItIsNeeded}(calls);
        assertEq(address(router).balance, 1);
    }

    // --- helpers ---
    function fulfillDepositRequest(ERC7540Vault vault, uint128 assetId, uint256 amount, address user)
        public
        returns (uint128 tranchePayout)
    {
        uint128 price = 2 * 10 ** 18;
        tranchePayout = uint128(amount * 10 ** 18 / price);
        assertApproxEqAbs(tranchePayout, amount / 2, 2);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(user)), assetId, uint128(amount), tranchePayout
        );
    }

    function fulfillRedeemRequest(ERC7540Vault vault, uint128 assetId, uint256 amount, address user)
        public
        returns (uint128 assetPayout)
    {
        uint128 price = 2 * 10 ** 18;
        assetPayout = uint128(amount * price / 10 ** 18);
        assertApproxEqAbs(assetPayout, amount * 2, 2);
        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(user)), assetId, assetPayout, uint128(amount)
        );
    }

    function setUpMultipleVaults(uint256 amount1, uint256 amount2)
        public
        returns (ERC20 erc20X, ERC20 erc20Y, ERC7540Vault vault1, ERC7540Vault vault2)
    {
        erc20X = _newErc20("X's Dollar", "USDX", 6);
        erc20Y = _newErc20("Y's Dollar", "USDY", 6);
        vm.label(address(erc20X), "erc20X");
        vm.label(address(erc20Y), "erc20Y");
        address vault1_ =
            deployVault(5, 6, restrictionManager, "name1", "symbol1", bytes16(bytes("1")), 1, address(erc20X));
        address vault2_ =
            deployVault(4, 6, restrictionManager, "name2", "symbol2", bytes16(bytes("2")), 2, address(erc20Y));
        vault1 = ERC7540Vault(vault1_);
        vault2 = ERC7540Vault(vault2_);
        vm.label(vault1_, "vault1");
        vm.label(vault2_, "vault2");

        erc20X.mint(self, amount1);
        erc20Y.mint(self, amount2);

        erc20X.approve(address(vault1_), amount1);
        erc20Y.approve(address(vault2_), amount2);

        centrifugeChain.updateMember(vault1.poolId(), vault1.trancheId(), self, type(uint64).max);
        centrifugeChain.updateMember(vault2.poolId(), vault2.trancheId(), self, type(uint64).max);
    }

    function testReentrancyCheck(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        MockReentrantERC20Wrapper1 wrapper = new MockReentrantERC20Wrapper1(address(erc20), address(router));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");

        erc20.mint(investor, amount);

        // Investor locks deposit request and enables permissionless lcaiming
        vm.startPrank(investor);
        erc20.approve(address(router), amount);
        vm.expectRevert(IMulticall.UnauthorizedSender.selector);
        router.enableLockDepositRequest(vault_, amount);
        vm.stopPrank();
    }

    function testMulticallReentrancyCheck(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        MockReentrantERC20Wrapper2 wrapper = new MockReentrantERC20Wrapper2(address(erc20), address(router));
        address vault_ = deployVault(
            5, 6, restrictionManager, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(wrapper)
        );
        vm.label(vault_, "vault");

        address investor = makeAddr("investor");

        erc20.mint(investor, amount);

        // Investor locks deposit request and enables permissionless lcaiming
        vm.startPrank(investor);
        erc20.approve(address(router), amount);
        vm.expectRevert(IMulticall.AlreadyInitiated.selector);
        router.enableLockDepositRequest(vault_, amount);
        vm.stopPrank();
    }

    function estimateGas() internal view returns (uint256 total) {
        (, total) = gateway.estimate(PAYLOAD_FOR_GAS_ESTIMATION);
    }
}
