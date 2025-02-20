// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";

contract MintTest is BaseTest {
    function testMint(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128));

        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);

        ITranche tranche = ITranche(address(vault.share()));
        root.denyContract(address(tranche), self);

        vm.expectRevert(bytes("Auth/not-authorized"));
        tranche.mint(investor, amount);

        root.relyContract(address(tranche), self); // give self auth permissions
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        tranche.mint(investor, amount);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);

        // success
        tranche.mint(investor, amount);
        assertEq(tranche.balanceOf(investor), amount);
        assertEq(tranche.balanceOf(investor), tranche.balanceOf(investor));
    }
}
