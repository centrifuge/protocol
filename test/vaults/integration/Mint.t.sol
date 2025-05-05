// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IHook} from "src/common/interfaces/IHook.sol";

contract MintTest is BaseTest {
    function testMint(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        IShareToken shareToken = IShareToken(address(vault.share()));
        root.denyContract(address(shareToken), self);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        shareToken.mint(investor, amount);

        root.relyContract(address(shareToken), self); // give self auth permissions
        vm.expectRevert(IHook.TransferBlocked.selector);
        shareToken.mint(investor, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);

        // success
        shareToken.mint(investor, amount);
        assertEq(shareToken.balanceOf(investor), amount);
    }
}
