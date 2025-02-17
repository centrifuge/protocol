// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import "src/vaults/interfaces/IERC7575.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC20.sol";
import {CentrifugeRouter} from "src/vaults/CentrifugeRouter.sol";
import {MockERC20Wrapper} from "test/vaults/mocks/MockERC20Wrapper.sol";
import {CastLib} from "src/vaults/libraries/CastLib.sol";
import {Domain} from "src/vaults/interfaces/IPoolManager.sol";
import {ITransferProxyFactory} from "src/vaults/interfaces/factories/ITransferProxy.sol";

interface Authlike {
    function rely(address) external;
}

contract ERC20WrapperFake {
    address public underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract CentrifugeRouterTest is BaseTest {
    using CastLib for *;

    uint256 constant GAS_BUFFER = 10 gwei;
    /// @dev Payload is not taken into account during gas estimation
    bytes constant PAYLOAD_FOR_GAS_ESTIMATION = "irrelevant_value";

    function testInitialization() public {
        // redeploying within test to increase coverage
        new CentrifugeRouter(address(routerEscrow), address(gateway), address(poolManager));

        assertEq(address(router.escrow()), address(routerEscrow));
        assertEq(address(router.gateway()), address(gateway));
        assertEq(address(router.poolManager()), address(poolManager));
    }

    function testGetVault() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        assertEq(router.getVault(vault.poolId(), vault.trancheId(), address(erc20)), vault_);
    }

    function testRecoverTokens() public {
        uint256 amount = 100;
        erc20.mint(address(router), amount);
        vm.prank(address(root));
        router.recoverTokens(address(erc20), address(this), amount);
        assertEq(erc20.balanceOf(address(this)), amount);
    }

    function testRequestDeposit() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas();

        vm.expectRevert("ERC7540Vault/invalid-owner");
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        router.enable(vault_);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.requestDeposit(vault_, amount, self, self, gas);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.requestDeposit{value: gas}(vault_, amount, self, self, 0);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas - 1);

        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function testLockDepositRequests() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);

        erc20.mint(self, amount);
        erc20.approve(address(router), amount);

        vm.expectRevert("PoolManager/unknown-vault");
        router.lockDepositRequest(makeAddr("maliciousVault"), amount, self, self);

        router.lockDepositRequest(vault_, amount, self, self);

        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
    }

    function testUnlockDepositRequests() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;

        erc20.mint(self, amount);
        erc20.approve(address(router), amount);

        vm.expectRevert(bytes("CentrifugeRouter/no-locked-balance"));
        router.unlockDepositRequest(vault_, self);

        router.lockDepositRequest(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
        assertEq(erc20.balanceOf(self), 0);
        router.unlockDepositRequest(vault_, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);
        assertEq(erc20.balanceOf(self), amount);
    }

    function testCancelDepositRequest() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);

        uint256 amount = 100 * 10 ** 18;
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);

        erc20.mint(self, amount);
        erc20.approve(address(router), amount);

        router.enable(vault_);
        router.lockDepositRequest(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
        assertEq(vault.pendingCancelDepositRequest(0, self), false);

        uint256 fuel = estimateGas();
        vm.deal(address(this), 10 ether);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.cancelDepositRequest(vault_, fuel);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.cancelDepositRequest(vault_, fuel);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.cancelDepositRequest{value: fuel}(vault_, 0);

        vm.expectRevert("InvestmentManager/no-pending-deposit-request");
        router.cancelDepositRequest{value: fuel}(vault_, fuel);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        router.executeLockedDepositRequest{value: fuel}(vault_, self, fuel);
        assertEq(vault.pendingDepositRequest(0, self), amount);

        router.cancelDepositRequest{value: fuel}(vault_, fuel);
        assertTrue(vault.pendingCancelDepositRequest(0, self));
    }

    function testClaimCancelDepositRequest() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);

        uint256 amount = 100 * 10 ** 18;

        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        uint256 gas = estimateGas() + GAS_BUFFER;
        router.enable(vault_);
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        assertEq(erc20.balanceOf(address(escrow)), amount);

        router.cancelDepositRequest{value: gas}(vault_, gas);
        assertEq(vault.pendingCancelDepositRequest(0, self), true);
        assertEq(erc20.balanceOf(address(escrow)), amount);
        centrifugeChain.isFulfilledCancelDepositRequest(
            vault.poolId(), vault.trancheId(), self.toBytes32(), defaultAssetId, uint128(amount), uint128(amount)
        );
        assertEq(vault.claimableCancelDepositRequest(0, self), amount);

        address sender = makeAddr("maliciousUser");
        vm.prank(sender);
        vm.expectRevert("CentrifugeRouter/invalid-sender");
        router.claimCancelDepositRequest(vault_, sender, self);

        router.claimCancelDepositRequest(vault_, self, self);
        assertEq(erc20.balanceOf(address(escrow)), 0);
        assertEq(erc20.balanceOf(self), amount);
    }

    function testRequestRedeem() external {
        // Deposit first
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas();
        router.enable(vault_);
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), defaultAssetId, uint128(amount), uint128(amount)
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(address(router), amount);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.requestRedeem(vault_, amount, self, self, gas);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.requestRedeem{value: gas}(vault_, amount, self, self, 0);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.requestRedeem{value: gas}(vault_, amount, self, self, gas - 1);

        router.requestRedeem{value: gas}(vault_, amount, self, self, gas);
        assertEq(share.balanceOf(address(self)), 0);
    }

    function testCancelRedeemRequest() public {
        // Deposit first
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas();
        router.enable(vault_);
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), defaultAssetId, uint128(amount), uint128(amount)
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(address(router), amount);
        router.requestRedeem{value: gas}(vault_, amount, self, self, gas);
        assertEq(share.balanceOf(address(self)), 0);

        vm.deal(address(this), 10 ether);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.cancelRedeemRequest(vault_, gas);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.cancelRedeemRequest{value: gas}(vault_, 0);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.cancelRedeemRequest{value: gas}(vault_, gas - 1);

        router.cancelRedeemRequest{value: gas}(vault_, gas);
        assertEq(vault.pendingCancelRedeemRequest(0, self), true);
    }

    function testClaimCancelRedeemRequest() public {
        // Deposit first
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas() + GAS_BUFFER;
        router.enable(vault_);
        router.requestDeposit{value: gas}(vault_, amount, self, self, gas);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), defaultAssetId, uint128(amount), uint128(amount)
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(vault_, amount);
        share.approve(address(router), amount);
        router.requestRedeem{value: gas}(vault_, amount, self, self, gas);
        assertEq(share.balanceOf(address(self)), 0);

        router.cancelRedeemRequest{value: gas}(vault_, gas);
        assertEq(vault.pendingCancelRedeemRequest(0, self), true);

        centrifugeChain.isFulfilledCancelRedeemRequest(
            vault.poolId(), vault.trancheId(), self.toBytes32(), defaultAssetId, uint128(amount)
        );

        address sender = makeAddr("maliciousUser");
        vm.prank(sender);
        vm.expectRevert("CentrifugeRouter/invalid-sender");
        router.claimCancelRedeemRequest(vault_, sender, self);

        router.claimCancelRedeemRequest(vault_, self, self);
        assertEq(share.balanceOf(address(self)), amount);
    }

    function testPermit() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 privateKey = 0xBEEF;
        address owner = vm.addr(privateKey);
        vm.label(owner, "owner");
        vm.label(address(router), "spender");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    erc20.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(router), 1e18, 0, block.timestamp))
                )
            )
        );

        vm.prank(owner);
        router.permit(address(erc20), address(router), 1e18, block.timestamp, v, r, s);

        assertEq(erc20.allowance(owner, address(router)), 1e18);
        assertEq(erc20.nonces(owner), 1);
    }

    function testTransferAssetsToAddress() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;
        address recipient = address(2);
        erc20.mint(self, amount);

        uint256 fuel = estimateGas();
        vm.deal(address(this), 10 ether);
        erc20.approve(address(router), amount);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.transferAssets(address(erc20), recipient, uint128(amount), fuel);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.transferAssets{value: fuel}(address(erc20), recipient, uint128(amount), 0);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.transferAssets{value: fuel}(address(erc20), recipient, uint128(amount), fuel - 1);

        snapStart("CentrifugeRouter_transferAssets");
        router.transferAssets{value: fuel}(address(erc20), recipient, uint128(amount), fuel);
        snapEnd();

        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function testTransferAssetsToBytes32() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;
        bytes32 recipient = address(2).toBytes32();
        erc20.mint(self, amount);

        uint256 fuel = estimateGas();
        vm.deal(address(this), 10 ether);
        erc20.approve(address(router), amount);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.transferAssets(address(erc20), recipient, uint128(amount), fuel);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.transferAssets{value: fuel}(address(erc20), recipient, uint128(amount), 0);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.transferAssets{value: fuel}(address(erc20), recipient, uint128(amount), fuel - 1);

        router.transferAssets{value: fuel}(address(erc20), recipient, uint128(amount), fuel);

        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function testTransferAssetsUsingTransferProxy() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;
        bytes32 recipient = address(2).toBytes32();

        uint256 fuel = estimateGas();
        vm.deal(address(this), 10 ether);

        address proxy = ITransferProxyFactory(transferProxyFactory).newTransferProxy(recipient);
        erc20.mint(address(proxy), amount);

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.transferAssetsFromProxy(proxy, address(erc20), fuel);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.transferAssetsFromProxy{value: fuel}(proxy, address(erc20), 0);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.transferAssetsFromProxy{value: fuel}(proxy, address(erc20), fuel - 1);

        assertEq(erc20.balanceOf(address(escrow)), 0);

        router.transferAssetsFromProxy{value: fuel}(proxy, address(erc20), fuel);

        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function testTranferTrancheTokensToAddressDestination() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        ERC20 share = ERC20(IERC7540Vault(vault_).share());

        uint256 amount = 100 * 10 ** 18;
        uint64 destinationChainId = 2;
        address destinationAddress = makeAddr("destinationAddress");

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), type(uint64).max);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), destinationAddress, type(uint64).max);

        vm.prank(address(root));
        share.mint(self, 100 * 10 ** 18);

        share.approve(address(router), amount);
        uint256 fuel = estimateGas();

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.transferTrancheTokens(vault_, Domain.EVM, destinationChainId, destinationAddress, uint128(amount), fuel);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.transferTrancheTokens{value: fuel}(
            vault_, Domain.EVM, destinationChainId, destinationAddress, uint128(amount), 0
        );

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.transferTrancheTokens{value: fuel}(
            vault_, Domain.EVM, destinationChainId, destinationAddress, uint128(amount), fuel - 1
        );

        snapStart("CentrifugeRouter_transferTrancheTokens");
        router.transferTrancheTokens{value: fuel}(
            vault_, Domain.EVM, destinationChainId, destinationAddress, uint128(amount), fuel
        );
        snapEnd();
        assertEq(share.balanceOf(address(router)), 0);
        assertEq(share.balanceOf(address(this)), 0);
    }

    function testTranferTrancheTokensToBytes32Destination() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        ERC20 share = ERC20(IERC7540Vault(vault_).share());

        uint256 amount = 100 * 10 ** 18;
        uint64 destinationChainId = 2;
        address destinationAddress = makeAddr("destinationAddress");
        bytes32 destinationAddressAsBytes32 = destinationAddress.toBytes32();

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), type(uint64).max);
        // centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(router), type(uint64).max);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), destinationAddress, type(uint64).max);

        vm.prank(address(root));
        share.mint(self, 100 * 10 ** 18);

        share.approve(address(router), amount);
        uint256 fuel = estimateGas();

        vm.expectRevert("CentrifugeRouter/insufficient-funds");
        router.transferTrancheTokens(
            vault_, Domain.EVM, destinationChainId, destinationAddressAsBytes32, uint128(amount), fuel
        );

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        router.transferTrancheTokens{value: fuel}(
            vault_, Domain.EVM, destinationChainId, destinationAddressAsBytes32, uint128(amount), 0
        );

        vm.expectRevert("Gateway/not-enough-gas-funds");
        router.transferTrancheTokens{value: fuel}(
            vault_, Domain.EVM, destinationChainId, destinationAddressAsBytes32, uint128(amount), fuel - 1
        );

        router.transferTrancheTokens{value: fuel}(
            vault_, Domain.EVM, destinationChainId, destinationAddressAsBytes32, uint128(amount), fuel
        );
        assertEq(share.balanceOf(address(router)), 0);
        assertEq(share.balanceOf(address(this)), 0);
    }

    function testEnableAndDisable() public {
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");

        assertFalse(ERC7540Vault(vault_).isOperator(self, address(router)));
        assertEq(router.isEnabled(vault_, self), false);
        router.enable(vault_);
        assertTrue(ERC7540Vault(vault_).isOperator(self, address(router)));
        assertEq(router.isEnabled(vault_, self), true);
        router.disable(vault_);
        assertFalse(ERC7540Vault(vault_).isOperator(self, address(router)));
        assertEq(router.isEnabled(vault_, self), false);
    }

    function testWrap() public {
        uint256 amount = 150 * 10 ** 18;
        uint256 balance = 100 * 10 ** 18;
        address receiver = makeAddr("receiver");
        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));

        vm.expectRevert(bytes("CentrifugeRouter/invalid-owner"));
        router.wrap(address(wrapper), amount, receiver, makeAddr("ownerIsNeitherCallerNorRouter"));

        vm.expectRevert(bytes("CentrifugeRouter/zero-balance"));
        router.wrap(address(wrapper), amount, receiver, self);

        erc20.mint(self, balance);
        erc20.approve(address(router), amount);
        wrapper.setFail("depositFor", true);
        vm.expectRevert(bytes("CentrifugeRouter/wrap-failed"));
        router.wrap(address(wrapper), amount, receiver, self);

        wrapper.setFail("depositFor", false);
        router.wrap(address(wrapper), amount, receiver, self);
        assertEq(wrapper.balanceOf(receiver), balance);
        assertEq(erc20.balanceOf(self), 0);

        erc20.mint(address(router), balance);
        router.wrap(address(wrapper), amount, receiver, address(router));
        assertEq(wrapper.balanceOf(receiver), 200 * 10 ** 18);
        assertEq(erc20.balanceOf(address(router)), 0);
    }

    function testUnwrap() public {
        uint256 amount = 150 * 10 ** 18;
        uint256 balance = 100 * 10 ** 18;
        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        erc20.mint(self, balance);
        erc20.approve(address(router), amount);

        vm.expectRevert(bytes("CentrifugeRouter/zero-balance"));
        router.unwrap(address(wrapper), amount, self);

        router.wrap(address(wrapper), amount, address(router), self);
        wrapper.setFail("withdrawTo", true);
        vm.expectRevert(bytes("CentrifugeRouter/unwrap-failed"));
        router.unwrap(address(wrapper), amount, self);
        wrapper.setFail("withdrawTo", false);

        assertEq(wrapper.balanceOf(address(router)), balance);
        assertEq(erc20.balanceOf(self), 0);
        router.unwrap(address(wrapper), amount, self);
        assertEq(wrapper.balanceOf(address(router)), 0);
        assertEq(erc20.balanceOf(self), balance);
    }

    function testEstimate() public view {
        bytes memory message = "IRRELEVANT";
        uint256 estimated = router.estimate(message);
        (, uint256 gatewayEstimated) = gateway.estimate(message);
        assertEq(estimated, gatewayEstimated);
    }

    function testIfUserIsPermittedToExecuteRequests() public {
        uint256 amount = 100 * 10 ** 18;
        address vault_ = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);

        vm.deal(self, 1 ether);
        erc20.mint(self, amount);
        erc20.approve(address(router), amount);

        bool canUserExecute = router.hasPermissions(vault_, self);
        assertFalse(canUserExecute);

        router.lockDepositRequest(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);

        uint256 gasLimit = router.estimate("irrelevant_payload");

        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        router.executeLockedDepositRequest{value: gasLimit}(vault_, self, gasLimit);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        canUserExecute = router.hasPermissions(vault_, self);
        assertTrue(canUserExecute);

        router.executeLockedDepositRequest{value: gasLimit}(vault_, self, gasLimit);
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);
        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function estimateGas() internal view returns (uint256 total) {
        (, total) = gateway.estimate(PAYLOAD_FOR_GAS_ESTIMATION);
    }
}
