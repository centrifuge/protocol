// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../src/misc/interfaces/IERC7540.sol";
import "../../../src/misc/interfaces/IERC7575.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import "../../spoke/integration/BaseTest.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

contract AsyncVaultTest is BaseTest {
    // Deployment
    function testFactorySetup(bytes16 scId, uint128 assetId, address nonWard) public {
        vm.assume(nonWard != address(root) && nonWard != address(this) && nonWard != address(asyncRequestManager));
        vm.assume(assetId > 0);

        (uint64 poolId, address vault_,) = deployVault(VaultKind.Async, erc20.decimals(), scId);
        AsyncVault vault = AsyncVault(vault_);

        // values set correctly
        assertEq(address(vault.manager()), address(asyncRequestManager));
        assertEq(vault.asset(), address(erc20));
        assertEq(vault.scId().raw(), scId);
        IShareToken token = spoke.shareToken(PoolId.wrap(poolId), ShareClassId.wrap(scId));
        assertEq(address(vault.share()), address(token));

        // permissions set correctly
        assertEq(vault.wards(address(root)), 1);
        assertEq(vault.wards(address(asyncRequestManager)), 1);
        assertEq(vault.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vault.file("manager", self);

        root.relyContract(vault_, self);
        vault.file("manager", self);

        address random = makeAddr("random");
        vault.file("manager", random);
        assertEq(address(vault.manager()), random);

        vault.file("asyncRedeemManager", random);
        assertEq(address(vault.asyncRedeemManager()), random);

        vm.expectRevert(IBaseVault.FileUnrecognizedParam.selector);
        vault.file("random", self);
    }

    // --- uint128 type checks ---
    /// @dev Make sure all function calls would fail when overflow uint128
    /// @dev requestRedeem is not checked because the share class token supply is already capped at uint128
    function testAssertUint128(uint256 amount) public {
        vm.assume(amount > MAX_UINT128); // amount has to overflow UINT128
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        vault.convertToShares(amount);

        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        vault.convertToAssets(amount);

        vm.expectRevert(IAsyncRequestManager.ExceedsMaxDeposit.selector);
        vault.deposit(amount, randomUser, self);

        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        vault.mint(amount, randomUser);

        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        vault.withdraw(amount, randomUser, self);

        vm.expectRevert(IAsyncRequestManager.ExceedsMaxRedeem.selector);
        vault.redeem(amount, randomUser, self);

        erc20.mint(address(this), amount);
        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        vault.requestDeposit(amount, self, self);
    }

    // --- erc165 checks ---
    function testERC165Support(bytes4 unsupportedInterfaceId) public {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 erc7575Vault = 0x2f0a18c5;
        bytes4 asyncVaultOperator = 0xe3bc4e65;
        bytes4 asyncVaultDeposit = 0xce3bbe50;
        bytes4 asyncVaultRedeem = 0x620ee8e4;
        bytes4 asyncVaultCancelDeposit = 0x8bf840e3;
        bytes4 asyncVaultCancelRedeem = 0xe76cffc7;
        bytes4 erc7741 = 0xa9e50872;
        bytes4 erc7714 = 0x78d77ecb;

        vm.assume(
            unsupportedInterfaceId != erc165 && unsupportedInterfaceId != erc7575Vault
                && unsupportedInterfaceId != asyncVaultOperator && unsupportedInterfaceId != asyncVaultDeposit
                && unsupportedInterfaceId != asyncVaultRedeem && unsupportedInterfaceId != asyncVaultCancelDeposit
                && unsupportedInterfaceId != asyncVaultCancelRedeem && unsupportedInterfaceId != erc7741
                && unsupportedInterfaceId != erc7714
        );

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IERC7575).interfaceId, erc7575Vault);
        assertEq(type(IERC7540Operator).interfaceId, asyncVaultOperator);
        assertEq(type(IERC7540Deposit).interfaceId, asyncVaultDeposit);
        assertEq(type(IERC7540Redeem).interfaceId, asyncVaultRedeem);
        assertEq(type(IERC7887Deposit).interfaceId, asyncVaultCancelDeposit);
        assertEq(type(IERC7887Redeem).interfaceId, asyncVaultCancelRedeem);
        assertEq(type(IERC7741).interfaceId, erc7741);
        assertEq(type(IERC7714).interfaceId, erc7714);

        assertEq(vault.supportsInterface(erc165), true);
        assertEq(vault.supportsInterface(erc7575Vault), true);
        assertEq(vault.supportsInterface(asyncVaultOperator), true);
        assertEq(vault.supportsInterface(asyncVaultDeposit), true);
        assertEq(vault.supportsInterface(asyncVaultRedeem), true);
        assertEq(vault.supportsInterface(asyncVaultCancelDeposit), true);
        assertEq(vault.supportsInterface(asyncVaultCancelRedeem), true);
        assertEq(vault.supportsInterface(erc7741), true);
        assertEq(vault.supportsInterface(erc7714), true);

        assertEq(vault.supportsInterface(unsupportedInterfaceId), false);
    }

    // --- preview checks ---
    function testPreviewReverts(uint256 amount) public {
        vm.assume(amount > MAX_UINT128); // amount has to overflow UINT128
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        vm.expectRevert(bytes(""));
        vault.previewDeposit(amount);

        vm.expectRevert(bytes(""));
        vault.previewRedeem(amount);

        vm.expectRevert(bytes(""));
        vault.previewMint(amount);

        vm.expectRevert(bytes(""));
        vault.previewWithdraw(amount);
    }
}
