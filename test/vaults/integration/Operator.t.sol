// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IBaseVault, IAsyncVault} from "src/vaults/interfaces/IBaseVaults.sol";

contract OperatorTest is BaseTest {
    function testDepositAsOperator(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        address investor = makeAddr("investor");
        address operator = makeAddr("operator");
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), price, uint64(block.timestamp)
        );

        erc20.mint(investor, amount);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);
        vm.prank(investor);
        erc20.approve(vault_, amount);

        vm.prank(operator);
        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vault.requestDeposit(amount, investor, investor);

        vm.prank(investor);
        vm.expectRevert(IBaseVault.CannotSetSelfAsOperator.selector);
        vault.setOperator(investor, true);

        assertEq(vault.isOperator(investor, operator), false);
        vm.prank(investor);
        vault.setOperator(operator, true);
        assertEq(vault.isOperator(investor, operator), true);

        vm.prank(operator);
        vault.requestDeposit(amount, investor, investor);
        assertEq(vault.pendingDepositRequest(0, investor), amount);
        assertEq(vault.pendingDepositRequest(0, operator), 0);

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            assetId,
            uint128(amount),
            uint128(amount)
        );

        vm.prank(operator);
        vault.deposit(amount, investor, investor);
        assertEq(vault.pendingDepositRequest(0, investor), 0);
        assertEq(shareToken.balanceOf(investor), amount);

        vm.prank(investor);
        vault.setOperator(operator, false);

        vm.prank(operator);
        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vault.requestDeposit(amount, investor, investor);
    }

    function testDepositAsAuthorizedOperator(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        (address controller, uint256 controllerPk) = makeAddrAndKey("controller");
        address operator = makeAddr("operator");
        AsyncVault vault = AsyncVault(vault_);

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), price, uint64(block.timestamp)
        );

        erc20.mint(controller, amount);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), controller, type(uint64).max);
        vm.prank(controller);
        erc20.approve(vault_, amount);

        vm.prank(operator);
        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vault.requestDeposit(amount, controller, controller);

        uint256 deadline = type(uint64).max;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            controllerPk,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    vault.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            vault.AUTHORIZE_OPERATOR_TYPEHASH(),
                            controller,
                            controller,
                            true,
                            bytes32("nonce"),
                            deadline
                        )
                    )
                )
            )
        );
        bytes memory signature = abi.encodePacked(r, s, v);
        vm.prank(controller);
        vm.expectRevert(IBaseVault.CannotSetSelfAsOperator.selector);
        vault.authorizeOperator(controller, controller, true, bytes32("nonce"), deadline, signature);

        (v, r, s) = vm.sign(
            controllerPk,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    vault.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            vault.AUTHORIZE_OPERATOR_TYPEHASH(), controller, operator, true, bytes32("nonce"), deadline
                        )
                    )
                )
            )
        );
        signature = abi.encodePacked(r, s, v);
        delete r;
        delete s;
        delete v;

        assertEq(vault.isOperator(controller, operator), false);
        vm.prank(operator);
        vault.authorizeOperator(controller, operator, true, bytes32("nonce"), deadline, signature);
        assertEq(vault.isOperator(controller, operator), true);

        vm.prank(operator);
        vault.requestDeposit(amount, controller, controller);
        assertEq(vault.pendingDepositRequest(0, controller), amount);
        assertEq(vault.pendingDepositRequest(0, operator), 0);
    }

    function testRedeemAsOperator(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128 / 2));
        vm.assume(amount % 2 == 0);

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        address investor = makeAddr("investor");
        address operator = makeAddr("operator");
        AsyncVault vault = AsyncVault(vault_);

        deposit(vault_, investor, amount); // deposit funds first
        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), defaultPrice, uint64(block.timestamp)
        );

        vm.prank(operator);
        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        vault.requestRedeem(amount, investor, investor);

        assertEq(vault.isOperator(investor, operator), false);
        vm.prank(investor);
        vault.setOperator(operator, true);
        assertEq(vault.isOperator(investor, operator), true);

        vm.prank(operator);
        vault.requestRedeem(amount, investor, investor);
        assertEq(vault.pendingRedeemRequest(0, investor), amount);
        assertEq(vault.pendingRedeemRequest(0, operator), 0);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            assetId,
            uint128(amount),
            uint128(amount)
        );

        vm.prank(operator);
        vault.redeem(amount, investor, investor);
        assertEq(vault.pendingRedeemRequest(0, investor), 0);
        assertEq(erc20.balanceOf(investor), amount);

        vm.prank(investor);
        vault.setOperator(operator, false);

        deposit(vault_, investor, amount);
        vm.prank(operator);
        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        vault.requestRedeem(amount, investor, investor);
    }

    function testInvalidateNonce(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        (address controller, uint256 controllerPk) = makeAddrAndKey("controller");
        address operator = makeAddr("operator");
        AsyncVault vault = AsyncVault(vault_);

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), price, uint64(block.timestamp)
        );

        erc20.mint(controller, amount);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), controller, type(uint64).max);
        vm.prank(controller);
        erc20.approve(vault_, amount);

        vm.prank(operator);
        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vault.requestDeposit(amount, controller, controller);

        uint256 deadline = type(uint64).max;
        bytes32 nonce = bytes32("nonce");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            controllerPk,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    vault.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(vault.AUTHORIZE_OPERATOR_TYPEHASH(), controller, operator, true, deadline, nonce)
                    )
                )
            )
        );
        bytes memory signature = abi.encodePacked(r, s, v);
        delete r;
        delete s;
        delete v;

        vm.prank(controller);
        vault.invalidateNonce(nonce);

        assertEq(vault.authorizations(controller, nonce), true);

        vm.expectRevert(IBaseVault.AlreadyUsedAuthorization.selector);
        vm.prank(operator);
        vault.authorizeOperator(controller, operator, true, nonce, deadline, signature);
        assertEq(vault.isOperator(controller, operator), false);
    }
}
