// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {d18} from "src/misc/types/D18.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import "test/vaults/BaseTest.sol";
import {IHook} from "src/common/interfaces/IHook.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/investments/IAsyncRequestManager.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IBaseVault, IAsyncVault} from "src/vaults/interfaces/IBaseVaults.sol";

contract DepositTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;
    using MathLib for uint256;

    /// forge-config: default.isolate = true
    function testDepositMint() public {
        _testDepositMint(4, true);
    }

    /// forge-config: default.isolate = true
    function testDepositMintFuzz(uint256 amount) public {
        vm.assume(amount % 2 == 0);
        _testDepositMint(amount, false);
    }

    function _testDepositMint(uint256 amount, bool snap) internal {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));

        uint128 price = 2 * 10 ** 18;

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));
        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);

        // will fail - user not member: can not send funds
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vault.requestDeposit(amount, self, self);

        assertEq(vault.isPermissioned(self), false);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max); // add user as
            // member
        assertEq(vault.isPermissioned(self), true);

        // will fail - user not member: can not receive share class
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vault.requestDeposit(amount, nonMember, self);

        // will fail - user did not give asset allowance to vault
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        vault.requestDeposit(amount, self, self);

        // will fail - zero deposit not allowed
        vm.expectRevert(IAsyncRequestManager.ZeroAmountNotAllowed.selector);
        vault.requestDeposit(0, self, self);

        // will fail - owner != msg.sender not allowed
        vm.expectRevert(IAsyncVault.InvalidOwner.selector);
        vault.requestDeposit(amount, self, nonMember);

        // will fail - cannot fulfill if there is no pending request
        uint128 shares = uint128((amount * 10 ** 18) / price); // sharePrice = 2$
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        asyncRequestManager.fulfillDepositRequest(poolId, scId, self, AssetId.wrap(assetId), uint128(amount), shares);

        // success
        erc20.approve(vault_, amount);
        if (snap) {
            vm.startSnapshotGas("AsyncVault", "requestDeposit");
        }
        vault.requestDeposit(amount, self, self);
        if (snap) {
            vm.stopSnapshotGas();
        }

        // fail: no asset left
        vm.expectRevert(IBaseVault.InsufficientBalance.selector);
        vault.requestDeposit(amount, self, self);

        // ensure funds are locked in escrow
        assertEq(erc20.balanceOf(address(globalEscrow)), amount);
        assertEq(erc20.balanceOf(self), 0);
        assertEq(vault.pendingDepositRequest(0, self), amount);
        assertEq(vault.claimableDepositRequest(0, self), 0);

        // trigger executed collectInvest
        assertApproxEqAbs(shares, amount / 2, 2);
        if (snap) {
            vm.startSnapshotGas("AsyncVault", "fulfillDepositRequest");
        }
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(self)), assetId, uint128(amount), shares
        );
        if (snap) {
            vm.stopSnapshotGas();
        }

        // assert deposit & mint values adjusted
        assertEq(vault.maxMint(self), shares);
        assertApproxEqAbs(vault.maxDeposit(self), amount, 1);
        assertEq(vault.pendingDepositRequest(0, self), 0);
        assertEq(vault.claimableDepositRequest(0, self), amount);
        // assert share class tokens minted
        assertEq(shareToken.balanceOf(address(globalEscrow)), shares);

        // check maxDeposit and maxMint are 0 for non-members
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);
        assertEq(vault.maxDeposit(self), 0);
        assertEq(vault.maxMint(self), 0);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max);

        vm.assume(randomUser != self);
        // deposit 50% of the amount
        vm.startPrank(randomUser); // try to claim deposit on behalf of user and set the wrong user as receiver
        vm.expectRevert(IBaseVault.InvalidController.selector);
        vault.deposit(amount / 2, randomUser, self);
        vm.stopPrank();

        vault.deposit(amount / 2, self, self); // deposit half the amount
        // Allow 2 difference because of rounding
        assertApproxEqAbs(shareToken.balanceOf(self), shares / 2, 2);
        assertApproxEqAbs(shareToken.balanceOf(address(globalEscrow)), shares - shares / 2, 2);
        assertApproxEqAbs(vault.maxMint(self), shares - shares / 2, 2);
        assertApproxEqAbs(vault.maxDeposit(self), amount - amount / 2, 2);

        // mint the rest
        vault.mint(vault.maxMint(self), self);
        assertApproxEqAbs(shareToken.balanceOf(self), shares - vault.maxMint(self), 2);
        assertTrue(shareToken.balanceOf(address(globalEscrow)) <= 1);
        assertTrue(vault.maxMint(self) <= 1);

        // minting or depositing more should revert
        vm.expectRevert(IAsyncRequestManager.ExceedsDepositLimits.selector);
        vault.mint(1, self);
        vm.expectRevert(IBaseInvestmentManager.ExceedsMaxDeposit.selector);
        vault.deposit(2, self, self);

        // remainder is rounding difference
        assertTrue(vault.maxDeposit(self) <= amount * 0.01e18);
    }

    function testPartialDepositExecutions() public {
        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, SHARE_TOKEN_DECIMALS, fullRestrictionsHook, bytes16(bytes("1")), address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        centrifugeChain.updatePricePoolPerShare(
            poolId, vault.scId().raw(), 1000000000000000000, uint64(block.timestamp)
        );

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, vault.scId().raw(), self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstSharePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, firstSharePayout
        );

        (,, uint256 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondSharePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, secondSharePayout
        );

        (,, depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstSharePayout + secondSharePayout);
    }

    // function testDepositFairRounding(uint256 totalAmount, uint256 tokenAmount) public {
    //     totalAmount = bound(totalAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);
    //     tokenAmount = bound(tokenAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);

    //     //Deploy a pool
    //     AsyncVault vault = AsyncVault(deploySimpleVault(VaultKind.Async));
    //     IShareToken shareToken = IShareToken(address(vault.share()));

    //     root.relyContract(address(token), self);
    //     shareToken.mint(poolEscrowFactory.escrow(POOL_A), type(uint128).max); // mint buffer to the escrow.
    // Mock funds from other
    // users

    //     // fund user & request deposit
    //     centrifugeChain.updateMember(vault.poolId(), vault.scId(), self, uint64(block.timestamp));
    //     erc20.mint(self, totalAmount);
    //     erc20.approve(address(vault), totalAmount);
    //     vault.requestDeposit(totalAmount, self, self);

    //     // Ensure funds were locked in escrow
    //     assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), totalAmount);
    //     assertEq(erc20.balanceOf(self), 0);

    //     // Gateway returns randomly generated values for amount of share class tokens and asset
    //     centrifugeChain.isFulfilledDepositRequest(
    //         vault.poolId(),
    //         vault.scId(),
    //         bytes32(bytes20(self)),
    //         defaultAssetId,
    //         uint128(totalAmount),
    //         uint128(tokenAmount)
    //     );

    //     // user claims multiple partial deposits
    //     vm.assume(vault.maxDeposit(self) > 0);
    //     assertEq(erc20.balanceOf(self), 0);
    //     uint256 remaining = type(uint128).max;
    //     while (vault.maxDeposit(self) > 0 && vault.maxDeposit(self) > remaining) {
    //         uint256 randomDeposit = random(vault.maxDeposit(self), 1);

    //         try vault.deposit(randomDeposit, self, self) {
    //             if (vault.maxDeposit(self) == 0 && vault.maxMint(self) > 0) {
    //                 // If you cannot deposit anymore because the 1 wei remaining is rounded down,
    //                 // you should mint the remainder instead.
    //                 uint256 minted = vault.mint(vault.maxMint(self), self);
    //                 remaining -= minted;
    //                 break;
    //             }
    //         } catch {
    //             // If you cannot deposit anymore because the 1 wei remaining is rounded down,
    //             // you should mint the remainder instead.
    //             uint256 minted = vault.mint(vault.maxMint(self), self);
    //             remaining -= minted;
    //             break;
    //         }
    //     }

    //     assertEq(vault.maxDeposit(self), 0);
    //     assertApproxEqAbs(shareToken.balanceOf(self), tokenAmount, 1);
    // }

    // function testMintFairRounding(uint256 totalAmount, uint256 tokenAmount) public {
    //     totalAmount = bound(totalAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);
    //     tokenAmount = bound(tokenAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);

    //     //Deploy a pool
    //     AsyncVault vault = AsyncVault(deploySimpleVault(VaultKind.Async));
    //     IShareToken shareToken = IShareToken(address(vault.share()));

    //     root.relyContract(address(token), self);
    //     shareToken.mint(poolEscrowFactory.escrow(POOL_A), type(uint128).max); // mint buffer to the escrow.
    // Mock funds from other
    // users

    //     // fund user & request deposit
    //     centrifugeChain.updateMember(vault.poolId(), vault.scId(), self, uint64(block.timestamp));
    //     erc20.mint(self, totalAmount);
    //     erc20.approve(address(vault), totalAmount);
    //     vault.requestDeposit(totalAmount, self, self);

    //     // Ensure funds were locked in escrow
    //     assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), totalAmount);
    //     assertEq(erc20.balanceOf(self), 0);

    //     // Gateway returns randomly generated values for amount of share class tokens and asset
    //     centrifugeChain.isFulfilledDepositRequest(
    //         vault.poolId(),
    //         vault.scId(),
    //         bytes32(bytes20(self)),
    //         defaultAssetId,
    //         uint128(totalAmount),
    //         uint128(tokenAmount)
    //     );

    //     // user claims multiple partial mints
    //     uint256 i = 0;
    //     while (vault.maxMint(self) > 0) {
    //         uint256 randomMint = random(vault.maxMint(self), i);
    //         try vault.mint(randomMint, self) {
    //             i++;
    //         } catch {
    //             break;
    //         }
    //     }

    //     assertEq(vault.maxMint(self), 0);
    //     assertLe(shareToken.balanceOf(self), tokenAmount);
    // }

    function testDepositMintToReceiver(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        address receiver = makeAddr("receiver");
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), price, uint64(block.timestamp)
        );
        erc20.mint(self, amount);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max); // add user as
            // member
        erc20.approve(vault_, amount); // add allowance
        vault.requestDeposit(amount, self, self);

        // trigger executed collectInvest
        uint128 shares = uint128(amount * 10 ** 18 / price); // sharePrice = 2$
        assertApproxEqAbs(shares, amount / 2, 2);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(self)), assetId, uint128(amount), shares
        );

        // assert deposit & mint values adjusted
        assertEq(vault.maxMint(self), shares); // max deposit
        assertEq(vault.maxDeposit(self), amount); // max deposit
        // assert share class tokens minted
        assertEq(shareToken.balanceOf(address(globalEscrow)), shares);

        // deposit 1/2 funds to receiver
        vm.expectRevert(SafeTransferLib.SafeTransferFailed.selector);
        vault.deposit(amount / 2, receiver, self); // mint half the amount

        vm.expectRevert(SafeTransferLib.SafeTransferFailed.selector);
        vault.mint(amount / 2, receiver); // mint half the amount

        // add receiver number
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), receiver, type(uint64).max);

        // success
        vault.deposit(amount / 2, receiver, self); // mint half the amount
        vault.mint(vault.maxMint(self), receiver); // mint half the amount

        assertApproxEqAbs(shareToken.balanceOf(receiver), shares, 1);
        assertApproxEqAbs(shareToken.balanceOf(receiver), shares, 1);
        assertApproxEqAbs(shareToken.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), amount, 1);
    }

    function testDepositAsEndorsedOperator(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        address receiver = makeAddr("receiver");
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), self, type(uint64).max); // add user as
            // member
        erc20.approve(vault_, amount); // add allowance
        vault.requestDeposit(amount, self, self);

        // trigger executed collectInvest
        uint128 sharePayout = uint128(amount * 10 ** 18 / price); // sharePrice = 2$
        assertApproxEqAbs(sharePayout, amount / 2, 2);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(self)), assetId, uint128(amount), sharePayout
        );

        // assert deposit & mint values adjusted
        assertEq(vault.maxMint(self), sharePayout); // max deposit
        assertEq(vault.maxDeposit(self), amount); // max deposit
        // assert share class tokens minted
        assertEq(shareToken.balanceOf(address(globalEscrow)), sharePayout);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), receiver, type(uint64).max); // add
            // receiver

        address router = makeAddr("router");

        vm.startPrank(router);
        vm.expectRevert(IBaseVault.InvalidController.selector); // fail without endorsement
        vault.deposit(amount, receiver, address(this));
        vm.stopPrank();

        // endorse router
        root.endorse(router);

        vm.startPrank(router);
        vm.expectRevert(IBaseVault.CannotSetSelfAsOperator.selector);
        vault.setEndorsedOperator(address(router), true);

        vault.setEndorsedOperator(address(this), true);
        vault.deposit(amount, receiver, address(this));
        vm.stopPrank();

        assertApproxEqAbs(shareToken.balanceOf(receiver), sharePayout, 1);
        assertApproxEqAbs(shareToken.balanceOf(receiver), sharePayout, 1);
        assertApproxEqAbs(shareToken.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), amount, 1);
    }

    function testDepositAndRedeemPrecision() public {
        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) = deployVault(
            VaultKind.Async, SHARE_TOKEN_DECIMALS, fullRestrictionsHook, bytes16(bytes("1")), address(asset), 0, 0
        );
        AsyncVault vault = AsyncVault(vault_);
        centrifugeChain.updatePricePoolPerShare(
            poolId, vault.scId().raw(), 1000000000000000000, uint64(block.timestamp)
        );

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, vault.scId().raw(), self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest of the first 50% at a price of 1.2
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstSharePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, firstSharePayout
        );

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets, 1);
        assertEq(vault.maxMint(self), firstSharePayout);

        // deposit price should be ~1.2*10**18
        (,, uint256 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1200000000000000000);

        // trigger executed collectInvest of the second 50% at a price of 1.4
        assets = 50000000; // 50 * 10**6
        uint128 secondSharePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, secondSharePayout
        );

        // collect the share class tokens
        vault.mint(firstSharePayout + secondSharePayout, self);
        assertEq(IShareToken(address(vault.share())).balanceOf(self), firstSharePayout + secondSharePayout);

        // redeem
        vault.requestRedeem(firstSharePayout + secondSharePayout, address(this), address(this));

        // trigger executed collectRedeem at a price of 1.5
        // 50% invested at 1.2 and 50% invested at 1.4 leads to ~77 share class tokens
        // when redeeming at a price of 1.5, this leads to ~115.5 asset
        assets = 115500000; // 115.5*10**6

        // mint interest into escrow
        asset.mint(address(poolEscrowFactory.escrow(vault.poolId())), assets - investmentAmount);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, vault.scId().raw(), bytes32(bytes20(self)), assetId, assets, firstSharePayout + secondSharePayout
        );

        // redeem price should now be ~1.5*10**18.
        (,,, uint256 redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice, 1492615384615384615);
    }

    function testDepositAndRedeemPrecisionWithInverseDecimals(bytes16 scId) public {
        ERC20 asset = _newErc20("Currency", "CR", 18);
        (uint64 poolId, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, 6, fullRestrictionsHook, scId, address(asset), 0, 0);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1000000000000000000000000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100e18;
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest of the first 50% at a price of 1.2
        uint128 assets = 50e18;
        uint128 firstSharePayout = 41666666; // 50 * 10**6 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, assets, firstSharePayout
        );

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets, 10);
        assertEq(vault.maxMint(self), firstSharePayout);

        // deposit price should be ~1.2*10**18
        (,, uint256 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1200000019200000307);

        // trigger executed collectInvest of the second 50% at a price of 1.4
        assets = 50e18; // 50 * 10**18
        uint128 secondSharePayout = 35714285; // 50 * 10**6 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, assets, secondSharePayout
        );

        // collect the share class tokens
        vault.mint(firstSharePayout + secondSharePayout, self);
        assertEq(shareToken.balanceOf(self), firstSharePayout + secondSharePayout);

        // redeem
        vault.requestRedeem(firstSharePayout + secondSharePayout, address(this), address(this));

        // trigger executed collectRedeem at a price of 1.5
        // 50% invested at 1.2 and 50% invested at 1.4 leads to ~77 share class tokens
        // when redeeming at a price of 1.5, this leads to ~115.5 assets
        // assets = 115500000000000000000; // 115.5*10**18
        assets = 115.5e18; // 115.5*10**18

        // Adjust escrow for interest
        // NOTE: In reality, the FM would have allocate the interest;
        asset.approve(address(poolEscrowFactory.escrow(PoolId.wrap(poolId))), type(uint256).max);
        _topUpEscrow(PoolId.wrap(poolId), ShareClassId.wrap(scId), asset, assets - investmentAmount);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, scId, bytes32(bytes20(self)), assetId, assets, firstSharePayout + secondSharePayout
        );

        // redeem price should now be ~1.5*10**18.
        (,,, uint256 redeemPrice,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(redeemPrice, 1492615411252828877);

        // collect the asset
        vault.withdraw(assets, self, self);
        assertEq(asset.balanceOf(self), assets);
    }

    // Test that assumes the swap from usdc (investment asset) to dai (pool asset) has a cost of 1%
    function testDepositAndRedeemPrecisionWithSlippage(bytes16 scId) public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC
        uint8 SHARE_TOKEN_DECIMALS = 18; // Like DAI

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, SHARE_TOKEN_DECIMALS, fullRestrictionsHook, scId, address(asset), 0, 0);
        AsyncVault vault = AsyncVault(vault_);

        // price = (100*10**18) /  (99 * 10**18) = 101.010101 * 10**18
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1010101010101010101, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a share class token price of 1.2
        uint128 assets = 99000000; // 99 * 10**6

        // invested amount in dai is 99 * 10**18
        // executed at price of 1.2, leads to a share class token payout of
        // 99 * 10**18 / 1.2 = 82500000000000000000
        uint128 shares = 82500000000000000000;
        centrifugeChain.isFulfilledDepositRequest(poolId, scId, bytes32(bytes20(self)), assetId, assets, shares);
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1200000000000000000, uint64(block.timestamp));

        // assert deposit & mint values adjusted
        assertEq(vault.maxDeposit(self), assets);
        assertEq(vault.maxMint(self), shares);

        // lp price is set to the deposit price
        (,, uint256 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1200000000000000000);
    }

    // Test that assumes the swap from usdc (investment asset) to dai (pool asset) has a cost of 1%
    function testDepositAndRedeemPrecisionWithSlippageAndWithInverseDecimal(bytes16 scId) public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 18; // 18, like DAI
        uint8 SHARE_TOKEN_DECIMALS = 6; // Like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        (uint64 poolId, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, SHARE_TOKEN_DECIMALS, fullRestrictionsHook, scId, address(asset), 0, 0);
        AsyncVault vault = AsyncVault(vault_);

        // price = (100*10**18) /  (99 * 10**18) = 101.010101 * 10**18
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1010101010101010101, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000000000000000; // 100 * 10**18
        centrifugeChain.updateMember(poolId, scId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a share class token price of 1.2
        uint128 assets = 99000000000000000000; // 99 * 10**18

        // invested amount in dai is 99 * 10**18
        // executed at price of 1.2, leads to a share class token payout of
        // 99 * 10**6 / 1.2 = 82500000
        uint128 shares = 82500000;
        centrifugeChain.isFulfilledDepositRequest(poolId, scId, bytes32(bytes20(self)), assetId, assets, shares);
        centrifugeChain.updatePricePoolPerShare(poolId, scId, 1200000000000000000, uint64(block.timestamp));

        // assert deposit & mint values adjusted
        assertEq(vault.maxDeposit(self), assets);
        assertEq(vault.maxMint(self), shares);

        // lp price is set to the deposit price
        (,, uint256 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1200000000000000000);
    }

    function testCancelDepositOrder(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        uint128 price = 2 * 10 ** 18;
        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        centrifugeChain.updatePricePoolPerShare(poolId.raw(), scId.raw(), price, uint64(block.timestamp));
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        centrifugeChain.updateMember(poolId.raw(), scId.raw(), self, type(uint64).max);

        vault.requestDeposit(amount, self, self);

        assertEq(erc20.balanceOf(address(globalEscrow)), amount);
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0);
        assertEq(erc20.balanceOf(address(self)), 0);

        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        asyncRequestManager.fulfillCancelDepositRequest(
            poolId, scId, self, AssetId.wrap(assetId), uint128(amount), uint128(amount)
        );

        // check message was send out to centchain
        vault.cancelDepositRequest(0, self);

        MessageLib.CancelDepositRequest memory m = adapter1.values_bytes("send").deserializeCancelDepositRequest();
        assertEq(m.poolId, vault.poolId().raw());
        assertEq(m.scId, vault.scId().raw());
        assertEq(m.investor, bytes32(bytes20(self)));
        assertEq(m.assetId, assetId);

        assertEq(vault.pendingCancelDepositRequest(0, self), true);

        // Cannot cancel twice
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        vault.cancelDepositRequest(0, self);

        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        vault.requestDeposit(amount, self, self);
        erc20.burn(self, amount);

        centrifugeChain.isFulfilledCancelDepositRequest(
            vault.poolId().raw(), vault.scId().raw(), self.toBytes32(), assetId, uint128(amount)
        );
        assertEq(erc20.balanceOf(address(globalEscrow)), amount);
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(vault.poolId()))), 0);
        assertEq(erc20.balanceOf(self), 0);
        assertEq(vault.claimableCancelDepositRequest(0, self), amount);
        assertEq(vault.pendingCancelDepositRequest(0, self), false);

        // After cancellation is executed, new request can be submitted
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        vault.requestDeposit(amount, self, self);
    }

    function partialDeposit(bytes16 scId, AsyncVault vault, ERC20 asset) public {
        IShareToken shareToken = IShareToken(address(vault.share()));

        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(vault.poolId().raw(), scId, self, type(uint64).max);
        asset.approve(address(vault), investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);
        AssetId assetId = poolManager.assetToId(address(asset), erc20TokenId); // retrieve assetId

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstSharePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), scId, bytes32(bytes20(self)), assetId.raw(), assets, firstSharePayout
        );

        (,, uint256 depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondSharePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), scId, bytes32(bytes20(self)), assetId.raw(), assets, secondSharePayout
        );

        (,, depositPrice,,,,,,,) = asyncRequestManager.investments(vault, self);
        assertEq(depositPrice, 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstSharePayout + secondSharePayout);

        // collect the share class tokens
        vault.mint(firstSharePayout + secondSharePayout, self);
        assertEq(shareToken.balanceOf(self), firstSharePayout + secondSharePayout);
    }

    function testDepositAsInvestorDirectly(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        (, address vault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        assertEq(shareToken.balanceOf(investor), 0);

        erc20.mint(investor, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max); // add user
            // as

        vm.startPrank(investor);
        erc20.approve(vault_, amount);
        vault.requestDeposit(amount, investor, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(), vault.scId().raw(), investor.toBytes32(), assetId, uint128(amount), uint128(amount)
        );
        vm.expectRevert(IBaseInvestmentManager.ExceedsMaxDeposit.selector);
        vault.deposit(amount, investor);

        vm.prank(investor);
        uint256 shares = vault.deposit(amount, investor);

        assertEq(shareToken.balanceOf(investor), amount);
        assertEq(shares, amount);
    }

    function _topUpEscrow(PoolId poolId, ShareClassId scId, ERC20 asset, uint256 assetAmount) internal {
        asset.mint(address(this), assetAmount);
        asset.approve(address(balanceSheet), assetAmount);
        balanceSheet.deposit(poolId, scId, address(asset), 0, address(this), assetAmount.toUint128());
    }
}
