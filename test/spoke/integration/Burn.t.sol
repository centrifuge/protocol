// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./BaseTest.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

contract BurnTest is BaseTest {
    function testBurn(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        IShareToken shareToken = IShareToken(address(vault.share()));
        root.relyContract(address(shareToken), self); // give self auth permissions
        // add investor as member
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);

        shareToken.mint(investor, amount);
        root.denyContract(address(shareToken), self); // remove auth permissions from self

        vm.expectRevert(IAuth.NotAuthorized.selector);
        shareToken.burn(investor, amount);

        root.relyContract(address(shareToken), self); // give self auth permissions
        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        shareToken.burn(investor, amount);

        // success
        vm.prank(investor);
        shareToken.approve(self, amount); // approve to burn shareTokens
        shareToken.burn(investor, amount);

        assertEq(shareToken.balanceOf(investor), 0);
        assertEq(shareToken.balanceOf(investor), shareToken.balanceOf(investor));
    }
}
