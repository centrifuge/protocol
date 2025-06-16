// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "src/misc/interfaces/IERC20.sol";
import "src/misc/interfaces/IERC7540.sol";
import "src/misc/interfaces/IERC7575.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC7751} from "src/misc/interfaces/IERC7751.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {IVaultRouter} from "src/vaults/interfaces/IVaultRouter.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/IVaultManagers.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";

import "test/spoke/BaseTest.sol";

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

contract VaultRouterTest is BaseTest {
    using CastLib for *;
    using MessageLib for *;
    using MathLib for uint256;

    uint16 constant CHAIN_ID = 1;
    uint256 constant GAS_BUFFER = 10_000_000; // 10M gas
    bytes PAYLOAD_FOR_GAS_ESTIMATION = MessageLib.NotifyPool(1).serialize();

    function testInitialization() public {
        // redeploying within test to increase coverage
        new VaultRouter(address(routerEscrow), gateway, spoke, messageDispatcher, address(this));

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

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        vaultRouter.requestDeposit{value: gas - 1}(vault, amount, self, self);

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

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        vaultRouter.cancelDepositRequest{value: 0}(vault);

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

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        vaultRouter.requestRedeem{value: gas - 1}(vault, amount, self, self);

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

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        vaultRouter.cancelRedeemRequest{value: gas - 1}(vault);

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
