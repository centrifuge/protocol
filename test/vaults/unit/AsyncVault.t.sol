// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC165, IERC7575} from "../../../src/misc/interfaces/IERC7575.sol";
import {
    IERC7540Deposit,
    IERC7540Operator,
    IERC7540Redeem,
    IERC7714,
    IERC7741,
    IERC7887Deposit,
    IERC7887Redeem
} from "../../../src/misc/interfaces/IERC7540.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

import "forge-std/Test.sol";

contract MockShareToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract AsyncVaultTest is Test {
    PoolId constant POOL_ID = PoolId.wrap(1);
    ShareClassId constant SC_ID = ShareClassId.wrap(bytes16("sc1"));

    AsyncVault vault;

    function setUp() public {
        vault = new AsyncVault(
            POOL_ID,
            SC_ID,
            makeAddr("asset"),
            IShareToken(address(new MockShareToken())),
            makeAddr("root"),
            IAsyncRequestManager(makeAddr("manager"))
        );
    }

    // --- Administration ---
    function testFile() public {
        address random = makeAddr("random");

        vm.prank(random);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vault.file("manager", random);

        // address(this) is the deployer and has ward access
        vault.file("manager", random);

        vault.file("asyncRedeemManager", random);
        assertEq(address(vault.asyncRedeemManager()), random);

        vm.expectRevert(IBaseVault.FileUnrecognizedParam.selector);
        vault.file("random", random);
    }

    // --- erc165 checks ---
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
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
    /// @dev ERC-7540 async vaults MUST unconditionally revert on all preview functions
    function testPreviewReverts() public {
        vm.expectRevert(bytes(""));
        vault.previewDeposit(1e18);

        vm.expectRevert(bytes(""));
        vault.previewMint(1e18);

        vm.expectRevert(bytes(""));
        vault.previewRedeem(1e18);

        vm.expectRevert(bytes(""));
        vault.previewWithdraw(1e18);
    }
}
