// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

contract BurnTest is BaseTest {
    function testBurn(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        (address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);

        ITranche tranche = ITranche(address(vault.share()));
        root.relyContract(address(tranche), self); // give self auth permissions
        // add investor as member
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);

        tranche.mint(investor, amount);
        root.denyContract(address(tranche), self); // remove auth permissions from self

        vm.expectRevert(IAuth.NotAuthorized.selector);
        tranche.burn(investor, amount);

        root.relyContract(address(tranche), self); // give self auth permissions
        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        tranche.burn(investor, amount);

        // success
        vm.prank(investor);
        tranche.approve(self, amount); // approve to burn tokens
        tranche.burn(investor, amount);

        assertEq(tranche.balanceOf(investor), 0);
        assertEq(tranche.balanceOf(investor), tranche.balanceOf(investor));
    }
}
