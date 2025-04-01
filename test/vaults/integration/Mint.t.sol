// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

contract MintTest is BaseTest {
    function testMint(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        (address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);

        IShareToken token = IShareToken(address(vault.share()));
        root.denyContract(address(token), self);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        token.mint(investor, amount);

        root.relyContract(address(token), self); // give self auth permissions
        vm.expectRevert(bytes("RestrictedTransfers/transfer-blocked"));
        token.mint(investor, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);

        // success
        token.mint(investor, amount);
        assertEq(token.balanceOf(investor), amount);
        assertEq(token.balanceOf(investor), token.balanceOf(investor));
    }
}
