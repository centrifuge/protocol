// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

contract BurnTest is BaseTest {
    function testBurn(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        (address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        IShareToken token = IShareToken(address(vault.share()));
        root.relyContract(address(token), self); // give self auth permissions
        // add investor as member
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);

        token.mint(investor, amount);
        root.denyContract(address(token), self); // remove auth permissions from self

        vm.expectRevert(IAuth.NotAuthorized.selector);
        token.burn(investor, amount);

        root.relyContract(address(token), self); // give self auth permissions
        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        token.burn(investor, amount);

        // success
        vm.prank(investor);
        token.approve(self, amount); // approve to burn tokens
        token.burn(investor, amount);

        assertEq(token.balanceOf(investor), 0);
        assertEq(token.balanceOf(investor), token.balanceOf(investor));
    }
}
