// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import "test/vaults/BaseTest.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

contract DepositTest is BaseTest {
    using CastLib for *;

    function testDepositMint(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), defaultAssetId, price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);

        // will fail - user not member: can not send funds
        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        vault.requestDeposit(amount, self, self);

        assertEq(vault.isPermissioned(self), false);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max); // add user as member
        assertEq(vault.isPermissioned(self), true);

        // will fail - user not member: can not receive tranche
        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        vault.requestDeposit(amount, nonMember, self);

        // will fail - user did not give asset allowance to vault
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        vault.requestDeposit(amount, self, self);

        // will fail - zero deposit not allowed
        vm.expectRevert(bytes("InvestmentManager/zero-amount-not-allowed"));
        vault.requestDeposit(0, self, self);

        // will fail - owner != msg.sender not allowed
        vm.expectRevert(bytes("ERC7540Vault/invalid-owner"));
        vault.requestDeposit(amount, self, nonMember);

        // will fail - investment asset not allowed
        centrifugeChain.disallowAsset(vault.poolId(), defaultAssetId);
        vm.expectRevert(bytes("InvestmentManager/asset-not-allowed"));
        vault.requestDeposit(amount, self, self);

        // will fail - cannot fulfill if there is no pending request
        uint128 _assetId = poolManager.assetToId(address(erc20)); // retrieve assetId
        uint128 shares = uint128((amount * 10 ** 18) / price); // tranchePrice = 2$
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("InvestmentManager/no-pending-deposit-request"));
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, uint128(amount), shares
        );

        // success
        centrifugeChain.allowAsset(vault.poolId(), defaultAssetId);
        erc20.approve(vault_, amount);
        snapStart("ERC7540Vault_requestDeposit");
        vault.requestDeposit(amount, self, self);
        snapEnd();

        // fail: no asset left
        vm.expectRevert(bytes("ERC7540Vault/insufficient-balance"));
        vault.requestDeposit(amount, self, self);

        // ensure funds are locked in escrow
        assertEq(erc20.balanceOf(address(escrow)), amount);
        assertEq(erc20.balanceOf(self), 0);
        assertEq(vault.pendingDepositRequest(0, self), amount);
        assertEq(vault.claimableDepositRequest(0, self), 0);

        // trigger executed collectInvest
        assertApproxEqAbs(shares, amount / 2, 2);
        snapStart("InvestmentManager_fulfillDepositRequest");
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), _assetId, uint128(amount), shares
        );
        snapEnd();

        // assert deposit & mint values adjusted
        assertEq(vault.maxMint(self), shares);
        assertApproxEqAbs(vault.maxDeposit(self), amount, 1);
        assertEq(vault.pendingDepositRequest(0, self), 0);
        assertEq(vault.claimableDepositRequest(0, self), amount);
        // assert tranche tokens minted
        assertEq(tranche.balanceOf(address(escrow)), shares);

        // check maxDeposit and maxMint are 0 for non-members
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, uint64(block.timestamp));
        vm.warp(block.timestamp + 1);
        assertEq(vault.maxDeposit(self), 0);
        assertEq(vault.maxMint(self), 0);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        vm.assume(randomUser != self);
        // deposit 50% of the amount
        vm.startPrank(randomUser); // try to claim deposit on behalf of user and set the wrong user as receiver
        vm.expectRevert(bytes("ERC7540Vault/invalid-controller"));
        vault.deposit(amount / 2, randomUser, self);
        vm.stopPrank();

        vault.deposit(amount / 2, self, self); // deposit half the amount
        // Allow 2 difference because of rounding
        assertApproxEqAbs(tranche.balanceOf(self), shares / 2, 2);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), shares - shares / 2, 2);
        assertApproxEqAbs(vault.maxMint(self), shares - shares / 2, 2);
        assertApproxEqAbs(vault.maxDeposit(self), amount - amount / 2, 2);

        // mint the rest
        vault.mint(vault.maxMint(self), self);
        assertEq(tranche.balanceOf(self), shares - vault.maxMint(self));
        assertTrue(tranche.balanceOf(address(escrow)) <= 1);
        assertTrue(vault.maxMint(self) <= 1);

        // minting or depositing more should revert
        vm.expectRevert(bytes("InvestmentManager/exceeds-deposit-limits"));
        vault.mint(1, self);
        vm.expectRevert(bytes("InvestmentManager/exceeds-max-deposit"));
        vault.deposit(2, self, self);

        // remainder is rounding difference
        assertTrue(vault.maxDeposit(self) <= amount * 0.01e18);
    }

    function testDepositWithPrepaymentFromGateway(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        (, uint256 gasToBePaid) = gateway.estimate("PAYLOAD_IS_IRRELEVANT");

        assertEq(address(gateway).balance, GATEWAY_INITIAL_BALACE);

        testDepositMint(amount);

        assertEq(address(gateway).balance, GATEWAY_INITIAL_BALACE - gasToBePaid);
    }

    function testPartialDepositExecutions(uint64 poolId, bytes16 trancheId, uint128 assetId) public {
        vm.assume(assetId > 0);

        uint8 TRANCHE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        address vault_ =
            deployVault(poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, assetId, address(asset));
        ERC7540Vault vault = ERC7540Vault(vault_);
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1000000000000000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstTranchePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout
        );

        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondTranchePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, secondTranchePayout
        );

        (,, depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstTranchePayout + secondTranchePayout);
    }

    // function testDepositFairRounding(uint256 totalAmount, uint256 tokenAmount) public {
    //     totalAmount = bound(totalAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);
    //     tokenAmount = bound(tokenAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);

    //     //Deploy a pool
    //     ERC7540Vault vault = ERC7540Vault(deploySimpleVault());
    //     ITranche tranche = ITranche(address(vault.share()));

    //     root.relyContract(address(tranche), self);
    //     tranche.mint(address(escrow), type(uint128).max); // mint buffer to the escrow. Mock funds from other
    // users

    //     // fund user & request deposit
    //     centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, uint64(block.timestamp));
    //     erc20.mint(self, totalAmount);
    //     erc20.approve(address(vault), totalAmount);
    //     vault.requestDeposit(totalAmount, self, self);

    //     // Ensure funds were locked in escrow
    //     assertEq(erc20.balanceOf(address(escrow)), totalAmount);
    //     assertEq(erc20.balanceOf(self), 0);

    //     // Gateway returns randomly generated values for amount of tranche tokens and asset
    //     centrifugeChain.isFulfilledDepositRequest(
    //         vault.poolId(),
    //         vault.trancheId(),
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
    //     assertApproxEqAbs(tranche.balanceOf(self), tokenAmount, 1);
    // }

    // function testMintFairRounding(uint256 totalAmount, uint256 tokenAmount) public {
    //     totalAmount = bound(totalAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);
    //     tokenAmount = bound(tokenAmount, 1 * 10 ** 6, type(uint128).max / 10 ** 12);

    //     //Deploy a pool
    //     ERC7540Vault vault = ERC7540Vault(deploySimpleVault());
    //     ITranche tranche = ITranche(address(vault.share()));

    //     root.relyContract(address(tranche), self);
    //     tranche.mint(address(escrow), type(uint128).max); // mint buffer to the escrow. Mock funds from other
    // users

    //     // fund user & request deposit
    //     centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, uint64(block.timestamp));
    //     erc20.mint(self, totalAmount);
    //     erc20.approve(address(vault), totalAmount);
    //     vault.requestDeposit(totalAmount, self, self);

    //     // Ensure funds were locked in escrow
    //     assertEq(erc20.balanceOf(address(escrow)), totalAmount);
    //     assertEq(erc20.balanceOf(self), 0);

    //     // Gateway returns randomly generated values for amount of tranche tokens and asset
    //     centrifugeChain.isFulfilledDepositRequest(
    //         vault.poolId(),
    //         vault.trancheId(),
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
    //     assertLe(tranche.balanceOf(self), tokenAmount);
    // }

    function testDepositMintToReceiver(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        address vault_ = deploySimpleVault();
        address receiver = makeAddr("receiver");
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));

        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), defaultAssetId, price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max); // add user as member
        erc20.approve(vault_, amount); // add allowance
        vault.requestDeposit(amount, self, self);

        // trigger executed collectInvest
        uint128 _assetId = poolManager.assetToId(address(erc20)); // retrieve assetId
        uint128 shares = uint128(amount * 10 ** 18 / price); // tranchePrice = 2$
        assertApproxEqAbs(shares, amount / 2, 2);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), _assetId, uint128(amount), shares
        );

        // assert deposit & mint values adjusted
        assertEq(vault.maxMint(self), shares); // max deposit
        assertEq(vault.maxDeposit(self), amount); // max deposit
        // assert tranche tokens minted
        assertEq(tranche.balanceOf(address(escrow)), shares);

        // deposit 1/2 funds to receiver
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        vault.deposit(amount / 2, receiver, self); // mint half the amount

        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        vault.mint(amount / 2, receiver); // mint half the amount

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), receiver, type(uint64).max); // add receiver
            // member

        // success
        vault.deposit(amount / 2, receiver, self); // mint half the amount
        vault.mint(vault.maxMint(self), receiver); // mint half the amount

        assertApproxEqAbs(tranche.balanceOf(receiver), shares, 1);
        assertApproxEqAbs(tranche.balanceOf(receiver), shares, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), amount, 1);
    }

    function testDepositAsEndorsedOperator(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;
        address vault_ = deploySimpleVault();
        address receiver = makeAddr("receiver");
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));

        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), defaultAssetId, price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max); // add user as member
        erc20.approve(vault_, amount); // add allowance
        vault.requestDeposit(amount, self, self);

        // trigger executed collectInvest
        uint128 _currencyId = poolManager.assetToId(address(erc20)); // retrieve currencyId
        uint128 tranchePayout = uint128(amount * 10 ** 18 / price); // tranchePrice = 2$
        assertApproxEqAbs(tranchePayout, amount / 2, 2);
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), bytes32(bytes20(self)), _currencyId, uint128(amount), tranchePayout
        );

        // assert deposit & mint values adjusted
        assertEq(vault.maxMint(self), tranchePayout); // max deposit
        assertEq(vault.maxDeposit(self), amount); // max deposit
        // assert tranche tokens minted
        assertEq(tranche.balanceOf(address(escrow)), tranchePayout);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), receiver, type(uint64).max); // add receiver

        address router = makeAddr("router");

        vm.startPrank(router);
        vm.expectRevert(bytes("ERC7540Vault/invalid-controller")); // fail without endorsement
        vault.deposit(amount, receiver, address(this));
        vm.stopPrank();

        // endorse router
        root.endorse(router);

        vm.startPrank(router);
        vm.expectRevert(bytes("ERC7540Vault/cannot-set-self-as-operator"));
        vault.setEndorsedOperator(address(router), true);

        vault.setEndorsedOperator(address(this), true);
        vault.deposit(amount, receiver, address(this));
        vm.stopPrank();

        assertApproxEqAbs(tranche.balanceOf(receiver), tranchePayout, 1);
        assertApproxEqAbs(tranche.balanceOf(receiver), tranchePayout, 1);
        assertApproxEqAbs(tranche.balanceOf(address(escrow)), 0, 1);
        assertApproxEqAbs(erc20.balanceOf(address(escrow)), amount, 1);
    }

    function testDepositAndRedeemPrecision(uint64 poolId, bytes16 trancheId, uint128 assetId) public {
        vm.assume(assetId > 0);

        uint8 TRANCHE_TOKEN_DECIMALS = 18; // Like DAI
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        address vault_ =
            deployVault(poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, assetId, address(asset));
        ERC7540Vault vault = ERC7540Vault(vault_);
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1000000000000000000, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest of the first 50% at a price of 1.2
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstTranchePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout
        );

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets, 1);
        assertEq(vault.maxMint(self), firstTranchePayout);

        // deposit price should be ~1.2*10**18
        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1200000000000000000);

        // trigger executed collectInvest of the second 50% at a price of 1.4
        assets = 50000000; // 50 * 10**6
        uint128 secondTranchePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, secondTranchePayout
        );

        // collect the tranche tokens
        vault.mint(firstTranchePayout + secondTranchePayout, self);
        assertEq(ITranche(address(vault.share())).balanceOf(self), firstTranchePayout + secondTranchePayout);

        // redeem
        vault.requestRedeem(firstTranchePayout + secondTranchePayout, address(this), address(this));

        // trigger executed collectRedeem at a price of 1.5
        // 50% invested at 1.2 and 50% invested at 1.4 leads to ~77 tranche tokens
        // when redeeming at a price of 1.5, this leads to ~115.5 asset
        assets = 115500000; // 115.5*10**6

        // mint interest into escrow
        asset.mint(address(escrow), assets - investmentAmount);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout + secondTranchePayout
        );

        // redeem price should now be ~1.5*10**18.
        (,,, uint256 redeemPrice,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(redeemPrice, 1492615384615384615);
    }

    function testDepositAndRedeemPrecisionWithInverseDecimals(uint64 poolId, bytes16 trancheId, uint128 assetId)
        public
    {
        vm.assume(assetId > 0);

        // uint8 TRANCHE_TOKEN_DECIMALS = 6; // Like DAI
        // uint8 INVESTMENT_CURRENCY_DECIMALS = 18; // 18, like USDC

        ERC20 asset = _newErc20("Currency", "CR", 18);
        address vault_ = deployVault(poolId, 6, restrictionManager, "", "", trancheId, assetId, address(asset));
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));
        centrifugeChain.updateTranchePrice(
            poolId, trancheId, assetId, 1000000000000000000000000000, uint64(block.timestamp)
        );

        // invest
        uint256 investmentAmount = 100000000000000000000; // 100 * 10**18
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest of the first 50% at a price of 1.2
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId
        uint128 assets = 50000000000000000000; // 50 * 10**18
        uint128 firstTranchePayout = 41666666; // 50 * 10**6 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout
        );

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets, 10);
        assertEq(vault.maxMint(self), firstTranchePayout);

        // deposit price should be ~1.2*10**18
        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1200000019200000307);

        // trigger executed collectInvest of the second 50% at a price of 1.4
        assets = 50000000000000000000; // 50 * 10**18
        uint128 secondTranchePayout = 35714285; // 50 * 10**6 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, secondTranchePayout
        );

        // collect the tranche tokens
        vault.mint(firstTranchePayout + secondTranchePayout, self);
        assertEq(tranche.balanceOf(self), firstTranchePayout + secondTranchePayout);

        // redeem
        vault.requestRedeem(firstTranchePayout + secondTranchePayout, address(this), address(this));

        // trigger executed collectRedeem at a price of 1.5
        // 50% invested at 1.2 and 50% invested at 1.4 leads to ~77 tranche tokens
        // when redeeming at a price of 1.5, this leads to ~115.5 asset
        assets = 115500000000000000000; // 115.5*10**18

        // mint interest into escrow
        asset.mint(address(escrow), assets - investmentAmount);

        centrifugeChain.isFulfilledRedeemRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout + secondTranchePayout
        );

        // redeem price should now be ~1.5*10**18.
        (,,, uint256 redeemPrice,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(redeemPrice, 1492615411252828877);

        // collect the asset
        vault.withdraw(assets, self, self);
        assertEq(asset.balanceOf(self), assets);
    }

    // Test that assumes the swap from usdc (investment asset) to dai (pool asset) has a cost of 1%
    function testDepositAndRedeemPrecisionWithSlippage(uint64 poolId, bytes16 trancheId, uint128 assetId) public {
        vm.assume(assetId > 0);

        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // 6, like USDC
        uint8 TRANCHE_TOKEN_DECIMALS = 18; // Like DAI

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        address vault_ =
            deployVault(poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, assetId, address(asset));
        ERC7540Vault vault = ERC7540Vault(vault_);

        // price = (100*10**18) /  (99 * 10**18) = 101.010101 * 10**18
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1010101010101010101, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a tranche token price of 1.2
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId
        uint128 assets = 99000000; // 99 * 10**6

        // invested amount in dai is 99 * 10**18
        // executed at price of 1.2, leads to a tranche token payout of
        // 99 * 10**18 / 1.2 = 82500000000000000000
        uint128 shares = 82500000000000000000;
        centrifugeChain.isFulfilledDepositRequest(poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, shares);
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1200000000000000000, uint64(block.timestamp));

        // assert deposit & mint values adjusted
        assertEq(vault.maxDeposit(self), assets);
        assertEq(vault.maxMint(self), shares);

        // lp price is set to the deposit price
        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1200000000000000000);
    }

    // Test that assumes the swap from usdc (investment asset) to dai (pool asset) has a cost of 1%
    function testDepositAndRedeemPrecisionWithSlippageAndWithInverseDecimal(
        uint64 poolId,
        bytes16 trancheId,
        uint128 assetId
    ) public {
        vm.assume(assetId > 0);

        uint8 INVESTMENT_CURRENCY_DECIMALS = 18; // 18, like DAI
        uint8 TRANCHE_TOKEN_DECIMALS = 6; // Like USDC

        ERC20 asset = _newErc20("Currency", "CR", INVESTMENT_CURRENCY_DECIMALS);
        address vault_ =
            deployVault(poolId, TRANCHE_TOKEN_DECIMALS, restrictionManager, "", "", trancheId, assetId, address(asset));
        ERC7540Vault vault = ERC7540Vault(vault_);

        // price = (100*10**18) /  (99 * 10**18) = 101.010101 * 10**18
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1010101010101010101, uint64(block.timestamp));

        // invest
        uint256 investmentAmount = 100000000000000000000; // 100 * 10**18
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(vault_, investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);

        // trigger executed collectInvest at a tranche token price of 1.2
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId
        uint128 assets = 99000000000000000000; // 99 * 10**18

        // invested amount in dai is 99 * 10**18
        // executed at price of 1.2, leads to a tranche token payout of
        // 99 * 10**6 / 1.2 = 82500000
        uint128 shares = 82500000;
        centrifugeChain.isFulfilledDepositRequest(poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, shares);
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, 1200000000000000000, uint64(block.timestamp));

        // assert deposit & mint values adjusted
        assertEq(vault.maxDeposit(self), assets);
        assertEq(vault.maxMint(self), shares);

        // lp price is set to the deposit price
        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1200000000000000000);
    }

    function testCancelDepositOrder(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        uint128 price = 2 * 10 ** 18;
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), defaultAssetId, price, uint64(block.timestamp)
        );
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max);

        vault.requestDeposit(amount, self, self);

        assertEq(erc20.balanceOf(address(escrow)), amount);
        assertEq(erc20.balanceOf(address(self)), 0);

        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("InvestmentManager/no-pending-cancel-deposit-request"));
        centrifugeChain.isFulfilledCancelDepositRequest(
            poolId, trancheId, self.toBytes32(), defaultAssetId, uint128(amount), uint128(amount)
        );

        // check message was send out to centchain
        vault.cancelDepositRequest(0, self);
        bytes memory cancelOrderMessage = abi.encodePacked(
            uint8(MessagesLib.Call.CancelDepositRequest),
            vault.poolId(),
            vault.trancheId(),
            bytes32(bytes20(self)),
            defaultAssetId
        );
        assertEq(cancelOrderMessage, adapter1.values_bytes("send"));

        assertEq(vault.pendingCancelDepositRequest(0, self), true);

        // Cannot cancel twice
        vm.expectRevert(bytes("InvestmentManager/cancellation-is-pending"));
        vault.cancelDepositRequest(0, self);

        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        vm.expectRevert(bytes("InvestmentManager/cancellation-is-pending"));
        vault.requestDeposit(amount, self, self);
        erc20.burn(self, amount);

        centrifugeChain.isFulfilledCancelDepositRequest(
            vault.poolId(), vault.trancheId(), self.toBytes32(), defaultAssetId, uint128(amount), uint128(amount)
        );
        assertEq(erc20.balanceOf(address(escrow)), amount);
        assertEq(erc20.balanceOf(self), 0);
        assertEq(vault.claimableCancelDepositRequest(0, self), amount);
        assertEq(vault.pendingCancelDepositRequest(0, self), false);

        // After cancellation is executed, new request can be submitted
        erc20.mint(self, amount);
        erc20.approve(vault_, amount);
        vault.requestDeposit(amount, self, self);
    }

    function partialDeposit(uint64 poolId, bytes16 trancheId, ERC7540Vault vault, ERC20 asset) public {
        ITranche tranche = ITranche(address(vault.share()));

        uint256 investmentAmount = 100000000; // 100 * 10**6
        centrifugeChain.updateMember(poolId, trancheId, self, type(uint64).max);
        asset.approve(address(vault), investmentAmount);
        asset.mint(self, investmentAmount);
        vault.requestDeposit(investmentAmount, self, self);
        uint128 _assetId = poolManager.assetToId(address(asset)); // retrieve assetId

        // first trigger executed collectInvest of the first 50% at a price of 1.4
        uint128 assets = 50000000; // 50 * 10**6
        uint128 firstTranchePayout = 35714285714285714285; // 50 * 10**18 / 1.4, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, firstTranchePayout
        );

        (,, uint256 depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1400000000000000000);

        // second trigger executed collectInvest of the second 50% at a price of 1.2
        uint128 secondTranchePayout = 41666666666666666666; // 50 * 10**18 / 1.2, rounded down
        centrifugeChain.isFulfilledDepositRequest(
            poolId, trancheId, bytes32(bytes20(self)), _assetId, assets, secondTranchePayout
        );

        (,, depositPrice,,,,,,,) = investmentManager.investments(address(vault), self);
        assertEq(depositPrice, 1292307679384615384);

        // assert deposit & mint values adjusted
        assertApproxEqAbs(vault.maxDeposit(self), assets * 2, 2);
        assertEq(vault.maxMint(self), firstTranchePayout + secondTranchePayout);

        // collect the tranche tokens
        vault.mint(firstTranchePayout + secondTranchePayout, self);
        assertEq(tranche.balanceOf(self), firstTranchePayout + secondTranchePayout);
    }

    function testDepositAsInvestorDirectly(uint256 amount) public {
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(vault.share()));

        assertEq(tranche.balanceOf(investor), 0);

        erc20.mint(investor, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max); // add user as

        vm.startPrank(investor);
        erc20.approve(vault_, amount);
        vault.requestDeposit(amount, investor, investor);
        vm.stopPrank();

        uint128 assetId = poolManager.assetToId(address(erc20));
        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.trancheId(), investor.toBytes32(), assetId, uint128(amount), uint128(amount)
        );
        vm.expectRevert(bytes("InvestmentManager/exceeds-max-deposit"));
        vault.deposit(amount, investor);

        vm.prank(investor);
        uint256 shares = vault.deposit(amount, investor);

        assertEq(tranche.balanceOf(investor), amount);
        assertEq(shares, amount);
    }
}
