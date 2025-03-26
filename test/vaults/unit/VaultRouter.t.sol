// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "src/misc/interfaces/IERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import "src/vaults/interfaces/IERC7575.sol";
import "src/vaults/interfaces/IERC7540.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";

import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";
import {MockERC20Wrapper} from "test/vaults/mocks/MockERC20Wrapper.sol";
import "test/vaults/BaseTest.sol";

interface Authlike {
    function rely(address) external;
}

contract ERC20WrapperFake {
    address public underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract VaultRouterTest is BaseTest {
    using CastLib for *;

    uint16 constant CHAIN_ID = 1;
    uint256 constant GAS_BUFFER = 10 gwei;
    /// @dev Payload is not taken into account during gas estimation
    bytes constant PAYLOAD_FOR_GAS_ESTIMATION = "irrelevant_value";

    function testInitialization() public {
        // redeploying within test to increase coverage
        new VaultRouter(address(routerEscrow), address(gateway), address(poolManager));

        assertEq(address(vaultRouter.escrow()), address(routerEscrow));
        assertEq(address(vaultRouter.gateway()), address(gateway));
        assertEq(address(vaultRouter.poolManager()), address(poolManager));
    }

    function testGetVault() public {
        (address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        vm.label(vault_, "vault");

        assertEq(vaultRouter.getVault(vault.poolId(), vault.trancheId(), address(erc20)), vault_);
    }

    function testRecoverTokens() public {
        uint256 amount = 100;
        erc20.mint(address(vaultRouter), amount);
        vm.prank(address(root));
        vaultRouter.recoverTokens(address(erc20), erc20TokenId, address(this), amount);
        assertEq(erc20.balanceOf(address(this)), amount);
    }

    function testRequestDeposit() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas();

        vm.expectRevert("ERC7540Vault/invalid-owner");
        vaultRouter.requestDeposit{value: gas}(vault_, amount, self, self);
        vaultRouter.enable(vault_);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.requestDeposit{value: 0}(vault_, amount, self, self);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.requestDeposit{value: gas - 1}(vault_, amount, self, self);

        vaultRouter.requestDeposit{value: gas}(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function testLockDepositRequests() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        vm.expectRevert("PoolManager/unknown-vault");
        vaultRouter.lockDepositRequest(makeAddr("maliciousVault"), amount, self, self);

        vaultRouter.lockDepositRequest(vault_, amount, self, self);

        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
    }

    function testUnlockDepositRequests() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");

        uint256 amount = 100 * 10 ** 18;

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        vm.expectRevert(bytes("VaultRouter/no-locked-balance"));
        vaultRouter.unlockDepositRequest(vault_, self);

        vaultRouter.lockDepositRequest(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
        assertEq(erc20.balanceOf(self), 0);
        vaultRouter.unlockDepositRequest(vault_, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);
        assertEq(erc20.balanceOf(self), amount);
    }

    function testCancelDepositRequest() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);

        uint256 amount = 100 * 10 ** 18;
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);

        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        vaultRouter.enable(vault_);
        vaultRouter.lockDepositRequest(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);
        assertEq(vault.pendingCancelDepositRequest(0, self), false);

        uint256 fuel = estimateGas();
        vm.deal(address(this), 10 ether);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.cancelDepositRequest{value: 0}(vault_);

        vm.expectRevert("InvestmentManager/no-pending-deposit-request");
        vaultRouter.cancelDepositRequest{value: fuel}(vault_);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        vaultRouter.executeLockedDepositRequest{value: fuel}(vault_, self);
        assertEq(vault.pendingDepositRequest(0, self), amount);

        vaultRouter.cancelDepositRequest{value: fuel}(vault_);
        assertTrue(vault.pendingCancelDepositRequest(0, self));
    }

    function testClaimCancelDepositRequest() public {
        (address vault_, uint128 assetId) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);

        uint256 amount = 100 * 10 ** 18;

        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        uint256 gas = estimateGas() + GAS_BUFFER;
        vaultRouter.enable(vault_);
        vaultRouter.requestDeposit{value: gas}(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(escrow)), amount);

        vaultRouter.cancelDepositRequest{value: gas}(vault_);
        assertEq(vault.pendingCancelDepositRequest(0, self), true);
        assertEq(erc20.balanceOf(address(escrow)), amount);
        centrifugeChain.isFulfilledCancelDepositRequest(
            vault.poolId(), vault.trancheId(), self.toBytes32(), assetId, uint128(amount)
        );
        assertEq(vault.claimableCancelDepositRequest(0, self), amount);

        address nonMember = makeAddr("nonMember");
        vm.prank(nonMember);
        vm.expectRevert("VaultRouter/invalid-sender");
        vaultRouter.claimCancelDepositRequest(vault_, nonMember, self);

        vm.expectRevert("InvestmentManager/transfer-not-allowed");
        vaultRouter.claimCancelDepositRequest(vault_, nonMember, self);

        vaultRouter.claimCancelDepositRequest(vault_, self, self);
        assertEq(erc20.balanceOf(address(escrow)), 0);
        assertEq(erc20.balanceOf(self), amount);
    }

    function testRequestRedeem() external {
        // Deposit first
        (address vault_, uint128 assetId) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas();
        vaultRouter.enable(vault_);
        vaultRouter.requestDeposit{value: gas}(vault_, amount, self, self);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), assetId, uint128(amount), uint128(amount)
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(address(vaultRouter), amount);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.requestRedeem{value: 0}(vault_, amount, self, self);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.requestRedeem{value: gas - 1}(vault_, amount, self, self);

        vaultRouter.requestRedeem{value: gas}(vault_, amount, self, self);
        assertEq(share.balanceOf(address(self)), 0);
    }

    function testCancelRedeemRequest() public {
        // Deposit first
        (address vault_, uint128 assetId) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas();
        vaultRouter.enable(vault_);
        vaultRouter.requestDeposit{value: gas}(vault_, amount, self, self);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), assetId, uint128(amount), uint128(amount)
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(address(vaultRouter), amount);
        vaultRouter.requestRedeem{value: gas}(vault_, amount, self, self);
        assertEq(share.balanceOf(address(self)), 0);

        vm.deal(address(this), 10 ether);

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.cancelRedeemRequest{value: 0}(vault_);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.cancelRedeemRequest{value: gas - 1}(vault_);

        vaultRouter.cancelRedeemRequest{value: gas}(vault_);
        assertEq(vault.pendingCancelRedeemRequest(0, self), true);
    }

    function testClaimCancelRedeemRequest() public {
        // Deposit first
        (address vault_, uint128 assetId) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint256 amount = 100 * 10 ** 18;
        erc20.mint(self, amount);
        erc20.approve(address(vault_), amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);
        uint256 gas = estimateGas() + GAS_BUFFER;
        vaultRouter.enable(vault_);
        vaultRouter.requestDeposit{value: gas}(vault_, amount, self, self);
        IERC20 share = IERC20(address(vault.share()));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), assetId, uint128(amount), uint128(amount)
        );
        vault.deposit(amount, self, self);
        assertEq(share.balanceOf(address(self)), amount);

        // Then redeem
        share.approve(vault_, amount);
        share.approve(address(vaultRouter), amount);
        vaultRouter.requestRedeem{value: gas}(vault_, amount, self, self);
        assertEq(share.balanceOf(address(self)), 0);

        vaultRouter.cancelRedeemRequest{value: gas}(vault_);
        assertEq(vault.pendingCancelRedeemRequest(0, self), true);

        centrifugeChain.isFulfilledCancelRedeemRequest(
            vault.poolId(), vault.trancheId(), self.toBytes32(), assetId, uint128(amount)
        );

        address sender = makeAddr("maliciousUser");
        vm.prank(sender);
        vm.expectRevert("VaultRouter/invalid-sender");
        vaultRouter.claimCancelRedeemRequest(vault_, sender, self);

        vaultRouter.claimCancelRedeemRequest(vault_, self, self);
        assertEq(share.balanceOf(address(self)), amount);
    }

    function testPermit() public {
        (address vault_,) = deploySimpleVault();
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

    /// forge-config: default.isolate = true
    function testTransferTrancheTokensToAddressDestination() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        ERC20 share = ERC20(IERC7540Vault(vault_).share());

        uint256 amount = 100 * 10 ** 18;
        address destinationAddress = makeAddr("destinationAddress");

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), type(uint64).max);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), destinationAddress, type(uint64).max);

        vm.prank(address(root));
        share.mint(self, 100 * 10 ** 18);

        share.approve(address(vaultRouter), amount);
        uint256 fuel = estimateGas();

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.transferTrancheTokens{value: 0}(vault_, OTHER_CHAIN_ID, destinationAddress, uint128(amount));

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.transferTrancheTokens{value: fuel - 1}(vault_, OTHER_CHAIN_ID, destinationAddress, uint128(amount));

        snapStart("VaultRouter_transferTrancheTokens");
        vaultRouter.transferTrancheTokens{value: fuel}(vault_, OTHER_CHAIN_ID, destinationAddress, uint128(amount));
        snapEnd();
        assertEq(share.balanceOf(address(vaultRouter)), 0);
        assertEq(share.balanceOf(address(this)), 0);
    }

    function testTransferTrancheTokensToBytes32Destination() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);
        ERC20 share = ERC20(IERC7540Vault(vault_).share());

        uint256 amount = 100 * 10 ** 18;
        address destinationAddress = makeAddr("destinationAddress");
        bytes32 destinationAddressAsBytes32 = destinationAddress.toBytes32();

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), type(uint64).max);
        // centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(vaultRouter), type(uint64).max);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), destinationAddress, type(uint64).max);

        vm.prank(address(root));
        share.mint(self, 100 * 10 ** 18);

        share.approve(address(vaultRouter), amount);
        uint256 fuel = estimateGas();

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.transferTrancheTokens{value: 0}(
            vault_, OTHER_CHAIN_ID, destinationAddressAsBytes32, uint128(amount)
        );

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.transferTrancheTokens{value: fuel - 1}(
            vault_, OTHER_CHAIN_ID, destinationAddressAsBytes32, uint128(amount)
        );

        vaultRouter.transferTrancheTokens{value: fuel}(
            vault_, OTHER_CHAIN_ID, destinationAddressAsBytes32, uint128(amount)
        );
        assertEq(share.balanceOf(address(vaultRouter)), 0);
        assertEq(share.balanceOf(address(this)), 0);
    }

    function testRegisterAssetERC20() public {
        address asset = address(erc20);
        uint256 fuel = estimateGas();

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.registerAsset{value: 0}(asset, 0, OTHER_CHAIN_ID);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.registerAsset{value: fuel - 1}(asset, 0, OTHER_CHAIN_ID);

        vm.expectEmit();
        emit IPoolManager.RegisterAsset(defaultAssetId, asset, 0, erc20.name(), erc20.symbol(), erc20.decimals());
        vaultRouter.registerAsset{value: fuel}(asset, 0, OTHER_CHAIN_ID);
    }

    function testRegisterAssetERC6909() public {
        MockERC6909 erc6909 = new MockERC6909();
        address asset = address(erc6909);
        uint256 tokenId = 18;
        uint256 fuel = estimateGas();

        vm.expectRevert("Gateway/cannot-topup-with-nothing");
        vaultRouter.registerAsset{value: 0}(asset, tokenId, OTHER_CHAIN_ID);

        vm.expectRevert("Gateway/not-enough-gas-funds");
        vaultRouter.registerAsset{value: fuel - 1}(asset, tokenId, OTHER_CHAIN_ID);

        vm.expectEmit();
        emit IPoolManager.RegisterAsset(
            defaultAssetId, asset, tokenId, erc6909.name(tokenId), erc6909.symbol(tokenId), erc6909.decimals(tokenId)
        );
        vaultRouter.registerAsset{value: fuel}(asset, tokenId, OTHER_CHAIN_ID);
    }

    function testEnableAndDisable() public {
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");

        assertFalse(ERC7540Vault(vault_).isOperator(self, address(vaultRouter)));
        assertEq(vaultRouter.isEnabled(vault_, self), false);
        vaultRouter.enable(vault_);
        assertTrue(ERC7540Vault(vault_).isOperator(self, address(vaultRouter)));
        assertEq(vaultRouter.isEnabled(vault_, self), true);
        vaultRouter.disable(vault_);
        assertFalse(ERC7540Vault(vault_).isOperator(self, address(vaultRouter)));
        assertEq(vaultRouter.isEnabled(vault_, self), false);
    }

    function testWrap() public {
        uint256 amount = 150 * 10 ** 18;
        uint256 balance = 100 * 10 ** 18;
        address receiver = makeAddr("receiver");
        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));

        vm.expectRevert(bytes("VaultRouter/invalid-owner"));
        vaultRouter.wrap(address(wrapper), amount, receiver, makeAddr("ownerIsNeitherCallerNorRouter"));

        vm.expectRevert(bytes("VaultRouter/zero-balance"));
        vaultRouter.wrap(address(wrapper), amount, receiver, self);

        erc20.mint(self, balance);
        erc20.approve(address(vaultRouter), amount);
        wrapper.setFail("depositFor", true);
        vm.expectRevert(bytes("VaultRouter/wrap-failed"));
        vaultRouter.wrap(address(wrapper), amount, receiver, self);

        wrapper.setFail("depositFor", false);
        vaultRouter.wrap(address(wrapper), amount, receiver, self);
        assertEq(wrapper.balanceOf(receiver), balance);
        assertEq(erc20.balanceOf(self), 0);

        erc20.mint(address(vaultRouter), balance);
        vaultRouter.wrap(address(wrapper), amount, receiver, address(vaultRouter));
        assertEq(wrapper.balanceOf(receiver), 200 * 10 ** 18);
        assertEq(erc20.balanceOf(address(vaultRouter)), 0);
    }

    function testUnwrap() public {
        uint256 amount = 150 * 10 ** 18;
        uint256 balance = 100 * 10 ** 18;
        MockERC20Wrapper wrapper = new MockERC20Wrapper(address(erc20));
        erc20.mint(self, balance);
        erc20.approve(address(vaultRouter), amount);

        vm.expectRevert(bytes("VaultRouter/zero-balance"));
        vaultRouter.unwrap(address(wrapper), amount, self);

        vaultRouter.wrap(address(wrapper), amount, address(vaultRouter), self);
        wrapper.setFail("withdrawTo", true);
        vm.expectRevert(bytes("VaultRouter/unwrap-failed"));
        vaultRouter.unwrap(address(wrapper), amount, self);
        wrapper.setFail("withdrawTo", false);

        assertEq(wrapper.balanceOf(address(vaultRouter)), balance);
        assertEq(erc20.balanceOf(self), 0);
        vaultRouter.unwrap(address(wrapper), amount, self);
        assertEq(wrapper.balanceOf(address(vaultRouter)), 0);
        assertEq(erc20.balanceOf(self), balance);
    }

    function testEstimate() public view {
        bytes memory message = "IRRELEVANT";
        uint256 estimated = vaultRouter.estimate(CHAIN_ID, message);
        (, uint256 gatewayEstimated) = gateway.estimate(CHAIN_ID, message);
        assertEq(estimated, gatewayEstimated);
    }

    function testIfUserIsPermittedToExecuteRequests() public {
        uint256 amount = 100 * 10 ** 18;
        (address vault_,) = deploySimpleVault();
        vm.label(vault_, "vault");
        ERC7540Vault vault = ERC7540Vault(vault_);

        vm.deal(self, 1 ether);
        erc20.mint(self, amount);
        erc20.approve(address(vaultRouter), amount);

        bool canUserExecute = vaultRouter.hasPermissions(vault_, self);
        assertFalse(canUserExecute);

        vaultRouter.lockDepositRequest(vault_, amount, self, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), amount);

        uint256 gasLimit = vaultRouter.estimate(CHAIN_ID, "irrelevant_payload");

        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        vaultRouter.executeLockedDepositRequest{value: gasLimit}(vault_, self);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        canUserExecute = vaultRouter.hasPermissions(vault_, self);
        assertTrue(canUserExecute);

        vaultRouter.executeLockedDepositRequest{value: gasLimit}(vault_, self);
        assertEq(erc20.balanceOf(address(routerEscrow)), 0);
        assertEq(erc20.balanceOf(address(escrow)), amount);
    }

    function estimateGas() internal view returns (uint256 total) {
        (, total) = gateway.estimate(CHAIN_ID, PAYLOAD_FOR_GAS_ESTIMATION);
    }
}
