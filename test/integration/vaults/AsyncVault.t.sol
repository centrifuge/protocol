// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AsyncVault, VaultBaseTest as BaseTest, IShareToken, PoolId, ShareClassId, VaultKind} from "./VaultBaseTest.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

contract AsyncVaultTest is BaseTest {
    // Deployment
    function testFactorySetup(bytes16 scId, uint128 assetId, address nonWard) public {
        vm.assume(nonWard != address(root) && nonWard != address(this) && nonWard != address(asyncRequestManager));
        vm.assume(assetId > 0);

        (uint64 poolId, address vault_,) = deployVault(VaultKind.Async, erc20.decimals(), scId);
        AsyncVault vault = AsyncVault(vault_);

        // values set correctly
        assertEq(vault.asset(), address(erc20));
        assertEq(vault.scId().raw(), scId);
        IShareToken token = spoke.shareToken(PoolId.wrap(poolId), ShareClassId.wrap(scId));
        assertEq(address(vault.share()), address(token));

        // permissions set correctly
        assertEq(vault.wards(address(root)), 1);
        assertEq(vault.wards(address(asyncRequestManager)), 1);
        assertEq(vault.wards(nonWard), 0);
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

    // --- conversion with inverse decimals ---
    /// forge-config: default.isolate = true
    function testAssetShareConversionInverseDecimals() public {
        // Vault with 6-decimal shares and 18-decimal asset (inverse of the standard 18-dec share / 6-dec asset setup)
        ERC20 asset18 = _newErc20("18Dec Asset", "A18", 18);
        bytes16 scId = bytes16(bytes("6dec"));

        (uint64 poolId, address vaultAddr, uint128 assetId) =
            deployVault(VaultKind.Async, 6, address(fullRestrictionsHook), scId, address(asset18), 0, OTHER_CHAIN_ID);
        AsyncVault vault = AsyncVault(vaultAddr);

        // At 1:1 price: 1 full share (1e6 units) costs 1 full 18-dec asset (1e18 units)
        assertEq(vault.pricePerShare(), 1e18);
        assertEq(vault.convertToShares(1e18), 1e6);
        assertEq(vault.convertToAssets(1e6), 1e18);

        // Deposit 100 assets (100e18 units) → 100 shares (100e6 units)
        uint128 investmentAmount = 100e18;
        uint128 shares = 100e6;
        centrifugeChain.updateMember(poolId, scId, investor, type(uint64).max);
        asset18.mint(investor, investmentAmount);
        vm.startPrank(investor);
        asset18.approve(vaultAddr, investmentAmount);
        vault.requestDeposit(investmentAmount, investor, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(investor)), assetId, investmentAmount, shares, 0
        );

        vm.prank(investor);
        vault.deposit(investmentAmount, investor);

        // Confirm 1:1 conversions after deposit
        assertEq(vault.pricePerShare(), 1e18);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.convertToShares(100e18), 100e6);
        assertEq(vault.convertToAssets(100e6), 100e18);

        // Price update to 1.2 (each share now worth 1.2 full 18-dec assets)
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1200000000000000000, uint64(block.timestamp));

        assertEq(vault.pricePerShare(), 1.2e18);
        assertEq(vault.totalAssets(), 120e18);
        assertEq(vault.convertToShares(120e18), 100e6);
        assertEq(vault.convertToAssets(100e6), 120e18);
    }
}
