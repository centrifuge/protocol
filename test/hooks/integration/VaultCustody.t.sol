// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";
import {IShareTokenHook} from "../../../src/token/hooks/interfaces/IShareTokenHook.sol";

import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";

import {EndToEndFlows} from "../../integration/EndToEnd.t.sol";
import {RoleCheck} from "../../../src/token/interfaces/IRoleHook.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {FundOfFundsBasinTest} from "../../integration/FundOfFundsBasin.t.sol";
import {IntegrationConstants} from "../../integration/utils/IntegrationConstants.sol";

/// @dev Not a role hook: it answers every call, `onRoles` included, with empty success.
contract PermissiveFallbackHook {
    fallback() external {}
}

/// @dev Has the `onRoles` shape but answers with the wrong word; anything else succeeds empty.
contract WrongSelectorHook {
    function onRoles(address, RoleCheck[] calldata) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }

    fallback() external {}
}

/// @dev The vault requires `onRoles` to return its selector, as the token requires `onERC20Transfer` to,
///      so a hook set on the token without the `IRoleHook` surface fails every vault action closed.
/// forge-config: default.isolate = true
contract VaultActionSelectorTest is EndToEndFlows {
    function testHookWithPermissiveFallbackFailsClosed() public {
        _assertFailsClosed(address(new PermissiveFallbackHook()), "");
    }

    function testHookAnsweringTheWrongSelectorFailsClosed() public {
        _assertFailsClosed(
            address(new WrongSelectorHook()), abi.encodeWithSelector(IShareToken.RestrictionsFailed.selector)
        );
    }

    function _assertFailsClosed(address hook, bytes memory reason) internal {
        _configurePool(true);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();

        vm.startPrank(FM);
        _setHook(s, hook);
        vm.stopPrank();

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vm.expectRevert(reason);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();
    }
}

/// @dev A vault holds the shares it revokes between pulling them and the spoke burning them, on every
///      instant exit and every async settlement. Freezing it would brick every redemption through it.
/// forge-config: default.isolate = true
contract ShareClassVaultFreezeTest is EndToEndFlows {
    IAsyncVault vault;
    IShareToken share;
    ShareTokenHook hook;
    uint256 shares;

    function _setUpInstantVault() internal {
        _configurePool(true);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));
        share = IShareToken(vault.share());
        hook = ShareTokenHook(share.hook());

        // An instant exit passes the redeem-request gate, which RedemptionRestrictions holds to members.
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();
    }

    function testOwnVaultCannotBeFrozen() public {
        _setUpInstantVault();

        vm.prank(address(s.root));
        vm.expectRevert(IShareTokenHook.VaultCannotBeFrozen.selector);
        hook.freeze(address(share), address(vault));
    }

    /// @dev A vault's address is predictable, so its freeze bit can be set before it is linked, where
    ///      `freeze` cannot yet tell it is a vault. The exemption still holds on the revocation leg.
    function testPreexistingFreezeBitDoesNotBlockRevocation() public {
        _setUpInstantVault();
        vm.prank(address(hook));
        share.setHookData(address(vault), bytes16(uint128(1)));
        assertTrue(hook.isFrozen(address(share), address(vault)), "freeze bit set");

        vm.prank(INVESTOR_A);
        vault.redeem(shares, INVESTOR_A);
        assertEq(share.balanceOf(INVESTOR_A), 0, "shares revoked");
    }
}

/// @dev The underlying of a fund of funds pays its redemptions to the route, which forwards them; the top
///      pool's escrow and vault hold no membership on the underlying's token and need none.
/// forge-config: default.isolate = true
contract EscrowRedeemClaimTest is FundOfFundsBasinTest {
    function _memberOfJtrsy(address who) internal {
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(who), EXTRA_GAS, REFUND
        );
    }

    /// @dev Called after `_setUpChain`, which is what fills in the deployed hooks.
    function _drawThroughTheRouteUnder(address hook) internal {
        vm.startPrank(FM);
        _setHook(s, hook);
        vm.stopPrank();
        _memberOfJtrsy(address(vaultRoute));

        // The route's draw claims jTRSY's redemption to itself, a member, and passes it up the chain.
        uint256 before = s.usdc.balanceOf(INVESTOR_A);
        vm.prank(INVESTOR_A);
        topVault.withdraw(250e6, INVESTOR_A);
        assertEq(s.usdc.balanceOf(INVESTOR_A) - before, 250e6, "paid through the route");
    }

    function testRouteDrawUnderFullRestrictions() public {
        _setUpChain();
        _drawThroughTheRouteUnder(address(s.fullRestrictionsHook));
    }

    function testRouteDrawUnderFreelyTransferable() public {
        _setUpChain();
        _drawThroughTheRouteUnder(address(deployA.freelyTransferableHook()));
    }

    /// @dev The freeze exemption is the token's own share class only: the top pool's vault is not
    ///      jTRSY's, so jTRSY's hook may freeze it.
    function testOtherPoolVaultCanBeFrozen() public {
        _setUpChain();
        ShareTokenHook hook = ShareTokenHook(jtrsy.hook());
        assertTrue(s.spokeRegistry.isLinked(address(topVault)), "the top vault is linked");

        vm.prank(address(s.root));
        hook.freeze(address(jtrsy), address(topVault));
        assertTrue(hook.isFrozen(address(jtrsy), address(topVault)));
        assertFalse(hook.isShareClassVault(address(jtrsy), address(topVault)));
        assertTrue(hook.isShareClassVault(address(jtrsy), address(jtrsyVault)));

        vm.prank(address(s.root));
        vm.expectRevert(IShareTokenHook.VaultCannotBeFrozen.selector);
        hook.freeze(address(jtrsy), address(jtrsyVault));
    }
}
