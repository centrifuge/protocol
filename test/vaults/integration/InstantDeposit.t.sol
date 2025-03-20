// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {InstantDepositVault} from "src/vaults/InstantDepositVault.sol";
import {IInstantManager} from "src/vaults/interfaces/IInstantManager.sol";

contract DepositTest is BaseTest {
    using CastLib for *;
    using MessageLib for *;

    function _deploySyncVault(uint64 poolId, bytes16 trancheId, uint128 assetId) internal returns (address vault) {
        bytes memory syncVaultUpdate = MessageLib.UpdateContractVaultUpdate({
            factory: syncVaultFactory,
            assetId: assetId,
            isLinked: true,
            vault: address(0)
        }).serialize();

        poolManager.update(poolId, trancheId, syncVaultUpdate);

        // FIXME: How to retrieve newly deployed sync vault address?
        return address(0);
    }

    function testInstantDeposit(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;

        // Deploy async vault to ensure pool is set up
        (address asyncVault_, uint128 assetId) = deploySimpleAsyncVault();
        ERC7540Vault asyncVault = ERC7540Vault(asyncVault_);
        ITranche tranche = ITranche(address(asyncVault.share()));
        centrifugeChain.updateTranchePrice(
            asyncVault.poolId(), asyncVault.trancheId(), assetId, price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);

        // Deploy instant vault
        address syncVault_ = _deploySyncVault(asyncVault.poolId(), asyncVault.trancheId(), assetId);
        InstantDepositVault syncVault = InstantDepositVault(syncVault_);

        // Check price and max amounts
        assertEq(syncVault.previewMint(amount / 2), amount);
        assertEq(syncVault.previewDeposit(amount), amount / 2);
        assertEq(syncVault.maxDeposit(self), type(uint256).max);
        assertEq(syncVault.maxMint(self), type(uint256).max);

        // Will fail - user did not give asset allowance to syncVault
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        syncVault.deposit(amount, self);
        erc20.approve(address(syncVault), amount);

        // Will fail - user not member: can not send funds
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        syncVault.deposit(amount, self);

        assertEq(syncVault.isPermissioned(self), false);
        centrifugeChain.updateMember(syncVault.poolId(), syncVault.trancheId(), self, type(uint64).max); // add user as
            // member
        assertEq(syncVault.isPermissioned(self), true);

        syncVault.deposit(amount, self);
        assertEq(tranche.balanceOf(self), 0);
        assertEq(erc20.balanceOf(self), amount);

        syncVault.deposit(amount, self);
        assertEq(erc20.balanceOf(self), 0);
        assertEq(tranche.balanceOf(self), amount / 2);

        // Can now request redemption through async syncVault
        // TODO: doesn't work yet becuase investments in investment mgr are indexed by the async syncVault address
        // assertEq(asyncVault.pendingRedeemRequest(0, self), 0);
        // syncVault.requestRedeem(amount / 2, self, self);

        // assertEq(asyncVault.pendingRedeemRequest(0, self), amount / 2);
    }
}
