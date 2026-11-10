// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {IMulticall} from "../../src/misc/interfaces/IMulticall.sol";

import {RequestId} from "../../src/core/types/RequestId.sol";

import {IVaultRouter} from "../../src/vaults/interfaces/IVaultRouter.sol";
import {IReserveInstantPolicy} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {IAsyncVault, IVaultErrors, IVaultEvents} from "../../src/vaults/interfaces/IAsyncVault.sol";

import {Vm} from "forge-std/Vm.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {IShareTokenRegistrar} from "../../src/token/interfaces/IShareTokenRegistrar.sol";

/// @dev The router over the vault stack the deployment brings up. An investor makes it their operator with
///      `vault.setOperator`, and anyone can then claim for them through it.
contract VaultRouterTest is EndToEndFlows {
    using CastLib for *;

    function setUp() public override {
        super.setUp();
        _configurePool(_sameChain());
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        vm.recordLogs();
    }

    function _sameChain() internal pure virtual returns (bool) {
        return true;
    }

    function _enable(IAsyncVault vault) internal {
        vm.prank(INVESTOR_A);
        vault.setOperator(address(s.vaultRouter), true);
    }

    function testTheRouterIsEnabledByTheInvestorsOwnSetOperator() public {
        IAsyncVault vault = _deployVault();
        assertFalse(s.vaultRouter.isEnabled(vault, INVESTOR_A));

        _enable(vault);
        assertTrue(s.vaultRouter.isEnabled(vault, INVESTOR_A), "enabled");

        vm.prank(INVESTOR_A);
        vault.setOperator(address(s.vaultRouter), false);
        assertFalse(s.vaultRouter.isEnabled(vault, INVESTOR_A), "disabled");
    }

    function testRequestDepositThenAnyoneClaimsForTheInvestor() public {
        IAsyncVault vault = _deployVault();
        _enable(vault);

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1, "requested");

        _fulfill(true, RequestId.wrap(_lastRequestId(vault)), USDC_AMOUNT_1);

        vm.prank(ANY);
        s.vaultRouter.claimDeposit(vault, INVESTOR_A, INVESTOR_A);

        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "claimed");
        assertEq(vault.maxMint(INVESTOR_A), 0);
    }

    /// @dev Without the investor making the router their operator, only the controller claims through the router, and never to someone else
    function testAClaimForSomeoneElseNeedsTheirEnable() public {
        IAsyncVault vault = _deployVault();

        vm.prank(ANY);
        vm.expectRevert(IVaultRouter.InvalidSender.selector);
        s.vaultRouter.claimDeposit(vault, INVESTOR_A, INVESTOR_A);

        _enable(vault);
        vm.prank(ANY);
        vm.expectRevert(IVaultRouter.InvalidSender.selector);
        s.vaultRouter.claimDeposit(vault, ANY, INVESTOR_A);
    }

    function testRequestRedeemThenAnyoneClaimsForTheInvestor() public {
        IAsyncVault vault = _deployVault();
        _enable(vault);

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();
        _fulfill(true, RequestId.wrap(_lastRequestId(vault)), USDC_AMOUNT_1);
        vm.prank(ANY);
        s.vaultRouter.claimDeposit(vault, INVESTOR_A, INVESTOR_A);

        _addMember(INVESTOR_A);
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        vm.prank(INVESTOR_A);
        s.vaultRouter.requestRedeem(vault, shares, INVESTOR_A, INVESTOR_A);
        _fulfill(false, RequestId.wrap(_lastRequestId(vault)), shares);

        uint256 before = s.usdc.balanceOf(INVESTOR_A);
        vm.prank(ANY);
        s.vaultRouter.claimRedeem(vault, INVESTOR_A, INVESTOR_A);

        assertEq(s.usdc.balanceOf(INVESTOR_A) - before, shareToAsset(shares), "paid out");
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), 0);
    }

    /// @dev A position the router controlled would send its instant deposits down the async lane
    function testTheRouterCannotControlARequest() public {
        IAsyncVault vault = _deployVault();
        _enable(vault);

        vm.startPrank(INVESTOR_A);
        vm.expectRevert(IVaultRouter.InvalidController.selector);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, address(s.vaultRouter), INVESTOR_A);
        vm.expectRevert(IVaultRouter.InvalidController.selector);
        s.vaultRouter.requestRedeem(vault, 1, address(s.vaultRouter), INVESTOR_A);
        vm.stopPrank();
    }

    function testInstantDepositThroughTheRouter() public {
        IAsyncVault vault = _instantVault();

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(s.vaultRouter), USDC_AMOUNT_1);
        s.vaultRouter.deposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();

        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "issued");
        assertEq(s.usdc.balanceOf(address(s.vaultRouter)), 0, "nothing left in the router");
        assertEq(vault.pendingDepositRequest(0, address(s.vaultRouter)), 0, "not a request");
    }

    /// @dev The router never requests for itself and makes no one its operator, so on a vault with an instant lane only
    ///      a sponsor the pool allowed could credit it a position, and its instant deposits stay instant.
    function testAStrangerCannotCreditTheRouter() public {
        IAsyncVault vault = _instantVault();

        uint128 pushed = USDC_AMOUNT_1 / 10;
        s.usdc.mint(ANY, pushed);
        vm.startPrank(ANY);
        s.usdc.approve(address(vault), pushed);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        vault.requestDeposit(pushed, address(s.vaultRouter), ANY);
        vm.stopPrank();
        assertEq(vault.pendingDepositRequest(0, address(s.vaultRouter)), 0, "nothing credited to the router");
    }

    //----------------------------------------------------------------------------------------------
    // Owner handling, custody, permit, transfers and lookup
    //----------------------------------------------------------------------------------------------

    /// @dev The router is an investor's operator and a public relay, so a request it relayed for another controller would
    ///      pass the vault's consent check as that controller's own. It relays for the caller only.
    function testTheRouterRelaysRequestsOnlyForTheCaller() public {
        IAsyncVault vault = _instantVault();

        vm.startPrank(INVESTOR_A);
        vm.expectRevert(IVaultRouter.InvalidController.selector);
        s.vaultRouter.requestDeposit(vault, 1, ANY, INVESTOR_A);
        vm.expectRevert(IVaultRouter.InvalidController.selector);
        s.vaultRouter.requestRedeem(vault, 1, ANY, INVESTOR_A);
        vm.stopPrank();
    }

    function testTheOwnerIsTheCallerOrTheRouter() public {
        IAsyncVault vault = _instantVault();

        vm.startPrank(INVESTOR_A);
        vm.expectRevert(IVaultRouter.InvalidOwner.selector);
        s.vaultRouter.requestDeposit(vault, 1, INVESTOR_A, ANY);
        vm.expectRevert(IVaultRouter.InvalidOwner.selector);
        s.vaultRouter.requestRedeem(vault, 1, INVESTOR_A, ANY);
        vm.expectRevert(IVaultRouter.InvalidOwner.selector);
        s.vaultRouter.deposit(vault, 1, INVESTOR_A, ANY);
        vm.expectRevert(IVaultRouter.InvalidOwner.selector);
        s.vaultRouter.crosschainTransferShares(vault, 1, CENTRIFUGE_ID_B, bytes32("r"), ANY, 0, 0, REFUND);
        vm.stopPrank();
    }

    /// @dev Assets the router holds from an earlier call in a batch are what a request spends when the router
    ///      is the owner, for an investor who made it their operator, and nothing is left there afterwards
    function testARequestFundedByTheRouterLeavesNothingInIt() public {
        IAsyncVault vault = _deployVault();
        s.usdc.mint(address(s.vaultRouter), USDC_AMOUNT_1);

        vm.startPrank(INVESTOR_A);
        vault.setOperator(address(s.vaultRouter), true);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, address(s.vaultRouter));
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1, "requested for the controller");
        assertEq(s.usdc.balanceOf(address(s.vaultRouter)), 0, "nothing left in the router");
    }

    /// @dev On a vault with both lanes the vault sees the router as the owner of a request it funds, so the router
    ///      credits the investor only as their operator: without that the vault asks for a sponsor and refuses
    function testARequestFundedByTheRouterOnADualLaneVaultNeedsTheOperator() public {
        IAsyncVault vault = _instantVault();
        s.usdc.mint(address(s.vaultRouter), USDC_AMOUNT_1);

        vm.prank(INVESTOR_A);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, address(s.vaultRouter));

        vm.startPrank(INVESTOR_A);
        vault.setOperator(address(s.vaultRouter), true);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, address(s.vaultRouter));
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1, "requested for the controller");
        assertEq(s.usdc.balanceOf(address(s.vaultRouter)), 0, "nothing left in the router");
    }

    /// @dev One multicall: the investor's assets are pulled into the router, deposited instantly and the shares
    ///      sent on, none of it left behind
    function testAMulticallDepositsInstantlyAndLeavesNothingBehind() public {
        IAsyncVault vault = _instantVault();

        s.usdc.mint(INVESTOR_A, USDC_AMOUNT_1);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IVaultRouter.deposit, (vault, USDC_AMOUNT_1, address(s.vaultRouter), INVESTOR_A));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(s.vaultRouter), USDC_AMOUNT_1);
        s.vaultRouter.multicall(calls);
        vm.stopPrank();

        IShareToken share = IShareToken(vault.share());
        assertEq(share.balanceOf(address(s.vaultRouter)), assetToShare(USDC_AMOUNT_1), "the shares wait in the router");
        assertEq(s.usdc.balanceOf(address(s.vaultRouter)), 0, "no assets in the router");
    }

    /// @dev Without the bridger role the spoke refuses, so the router never holds a transfer half done
    function testASharesTransferWithoutTheBridgerRoleReverts() public {
        IAsyncVault vault = _deployVault();
        IShareToken share = IShareToken(vault.share());

        vm.startPrank(INVESTOR_A);
        share.approve(address(s.vaultRouter), 1);
        vm.expectRevert();
        s.vaultRouter.crosschainTransferShares{value: GAS}(
            vault, 1, CENTRIFUGE_ID_B, INVESTOR_A.toBytes32(), INVESTOR_A, HOOK_GAS, HOOK_GAS, INVESTOR_A
        );
        vm.stopPrank();
    }

    function testPermitSetsTheCallersAllowanceAndAFrontRunPermitDoesNotRevert() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                s.usdc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        s.usdc.PERMIT_TYPEHASH(), owner, address(s.vaultRouter), 5e6, s.usdc.nonces(owner), deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(key, digest);

        // The router is the spender here: a permit is for what the caller then spends through the router
        vm.prank(owner);
        s.vaultRouter.permit(address(s.usdc), address(s.vaultRouter), 5e6, deadline, v, r, sig);
        assertEq(s.usdc.allowance(owner, address(s.vaultRouter)), 5e6, "allowance set");

        // Replayed, as a front-runner would: the nonce is spent, and the call carries on instead of failing
        vm.prank(owner);
        s.vaultRouter.permit(address(s.usdc), address(s.vaultRouter), 5e6, deadline, v, r, sig);
        assertEq(s.usdc.allowance(owner, address(s.vaultRouter)), 5e6, "unchanged");
    }

    /// @dev The pointer on the share token comes from a separate hub message, `SetVault`, not from linking
    function testGetVaultFollowsTheSharesPointer() public {
        IAsyncVault vault = _deployVault();
        assertEq(s.vaultRouter.getVault(POOL_A, SC_1, address(s.usdc)), address(0), "not pointed yet");

        vm.prank(FM);
        h.hub.managerCall{value: sameChainCall() ? 0 : GAS}(
            POOL_A,
            s.centrifugeId,
            address(s.shareTokenRegistrar).toBytes32(),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetVault), SC_1, s.usdcId.raw(), address(vault)),
            0,
            0,
            REFUND
        );

        assertEq(s.vaultRouter.getVault(POOL_A, SC_1, address(s.usdc)), address(vault), "pointed at the vault");
    }

    /// @dev Under a membership hook the router is exempt as an endorsed contract, so an investor who is a member
    ///      deposits through it, and the router can hold the shares mid-batch without being a member itself
    function testAMemberDepositsThroughTheRouterUnderFullRestrictions() public {
        vm.prank(FM);
        _setHook(s, address(s.fullRestrictionsHook));
        _addMember(INVESTOR_A);
        IAsyncVault vault = _instantVault();

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(s.vaultRouter), USDC_AMOUNT_1);
        s.vaultRouter.deposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();

        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "issued");
    }

    /// @dev An instant deposit is gated twice: the vault hook sees the payer (an `InstantDeposit` action), the
    ///      share transfer hook sees the receiver. A non-member is refused on either side.
    function testAnInstantDepositIsGatedOnThePayerAndTheReceiver() public {
        vm.prank(FM);
        _setHook(s, address(s.fullRestrictionsHook));
        _addMember(INVESTOR_A);
        IAsyncVault vault = _instantVault();

        s.usdc.mint(ANY, USDC_AMOUNT_1);
        vm.startPrank(ANY);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vm.expectRevert();
        vault.deposit(USDC_AMOUNT_1, ANY);
        vm.expectRevert();
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();

        s.usdc.mint(INVESTOR_A, USDC_AMOUNT_1);
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vm.expectRevert();
        vault.deposit(USDC_AMOUNT_1, ANY);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "the member received");
    }

    /// @dev The vault sees the router as the depositor, so the router asks the hook about its caller: a non-member
    ///      cannot fund an instant deposit for a member through it, as it cannot directly.
    function testANonMemberCannotDepositThroughTheRouterForAMember() public {
        vm.prank(FM);
        _setHook(s, address(s.fullRestrictionsHook));
        _addMember(INVESTOR_A);
        IAsyncVault vault = _instantVault();

        s.usdc.mint(ANY, USDC_AMOUNT_1);
        vm.startPrank(ANY);
        s.usdc.approve(address(s.vaultRouter), USDC_AMOUNT_1);
        vm.expectRevert(IVaultRouter.InvalidSender.selector);
        s.vaultRouter.deposit(vault, USDC_AMOUNT_1, INVESTOR_A, ANY);
        vm.stopPrank();
    }

    /// @dev On a vault with an instant lane and an async lane, crediting a holder the caller does not act for takes a
    ///      sponsor the pool allowed on its instant policy. The sponsor funds the position but has no say over it.
    function testOnlyASponsorSetFromTheHubCanCreditAHolder() public {
        vm.prank(FM);
        _setHook(s, address(s.fullRestrictionsHook));
        _addMember(INVESTOR_A);
        _addMember(ANY);
        IAsyncVault vault = _instantVault();

        uint128 pushed = 1;
        s.usdc.mint(ANY, pushed);
        vm.startPrank(ANY);
        s.usdc.approve(address(vault), pushed);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        vault.requestDeposit(pushed, INVESTOR_A, ANY);
        vm.stopPrank();

        _instantPolicyCall(IReserveInstantPolicy.ConfigKind.Sponsor, abi.encode(ANY, true));
        vm.prank(ANY);
        vault.requestDeposit(pushed, INVESTOR_A, ANY);
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), pushed, "credited to the holder");

        vm.prank(ANY);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        vault.mint(1, ANY, INVESTOR_A);
    }

    function _instantPolicyCall(IReserveInstantPolicy.ConfigKind kind, bytes memory args) internal {
        vm.prank(FM);
        h.hub.managerCall{value: s.centrifugeId == h.centrifugeId ? 0 : GAS}(
            POOL_A,
            s.centrifugeId,
            address(s.reserveInstantPolicy).toBytes32(),
            abi.encode(kind, lastInstantVault, args),
            0,
            0,
            REFUND
        );
    }

    function _instantVault() internal returns (IAsyncVault vault) {
        vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));
    }

    /// @dev The request id of the last flush since logs were last read, as the OrderBook knows it.
    function _lastRequestId(IAsyncVault) internal returns (uint256 requestId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IVaultEvents.RequestFlushed.selector) requestId = uint256(logs[i].topics[1]);
        }
        require(requestId != 0, "no flush recorded");
    }
}

/// @dev The same on a spoke apart from the hub, where shares can be sent on to the hub's chain: the investor's
///      shares leave through the router and none are left in it. A pool with only its own chain has no adapter to
///      send them over.
contract VaultRouterCrossChainTest is VaultRouterTest {
    using CastLib for *;

    function _sameChain() internal pure override returns (bool) {
        return false;
    }

    function testAnOwnersSharesAreSentCrossChainThroughTheRouter() public {
        IAsyncVault vault = _deployVault();
        _enable(vault);
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();
        _fulfill(true, RequestId.wrap(_lastRequestId(vault)), USDC_AMOUNT_1);
        vm.prank(INVESTOR_A);
        s.vaultRouter.claimDeposit(vault, INVESTOR_A, INVESTOR_A);

        IShareToken share = IShareToken(vault.share());
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        uint256 supply = share.totalSupply();

        // The router forwards the transfer, so it needs the pool's bridger role
        vm.prank(address(s.spokeHandler));
        s.spokeRegistry.updateBridger(POOL_A, address(s.vaultRouter), true);

        vm.startPrank(INVESTOR_A);
        share.approve(address(s.vaultRouter), shares);
        s.vaultRouter.crosschainTransferShares{value: GAS}(
            vault, shares, CENTRIFUGE_ID_A, INVESTOR_A.toBytes32(), INVESTOR_A, HOOK_GAS, HOOK_GAS, INVESTOR_A
        );
        vm.stopPrank();

        assertEq(share.balanceOf(INVESTOR_A), 0, "the owner's shares left");
        assertEq(share.balanceOf(address(s.vaultRouter)), 0, "the router holds none");
        assertEq(share.totalSupply(), supply - shares, "burned at the source");
    }

    /// @dev Every call of a multicall sees the same value, so the value funds one transfer: a second one would be
    ///      paid out of whatever other callers left in the router.
    function testAMulticallFundsOneBridgeTransferWithItsValue() public {
        IAsyncVault vault = _deployVault();
        _enable(vault);
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();
        _fulfill(true, RequestId.wrap(_lastRequestId(vault)), USDC_AMOUNT_1);
        vm.prank(INVESTOR_A);
        s.vaultRouter.claimDeposit(vault, INVESTOR_A, INVESTOR_A);

        IShareToken share = IShareToken(vault.share());
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        vm.prank(address(s.spokeHandler));
        s.spokeRegistry.updateBridger(POOL_A, address(s.vaultRouter), true);

        bytes[] memory calls = new bytes[](2);
        for (uint256 i; i < calls.length; i++) {
            calls[i] = abi.encodeCall(
                IVaultRouter.crosschainTransferShares,
                (vault, shares / 2, CENTRIFUGE_ID_A, INVESTOR_A.toBytes32(), INVESTOR_A, HOOK_GAS, HOOK_GAS, INVESTOR_A)
            );
        }

        vm.startPrank(INVESTOR_A);
        share.approve(address(s.vaultRouter), shares);
        vm.expectRevert(IVaultRouter.ValueAlreadySpent.selector);
        s.vaultRouter.multicall{value: GAS}(calls);
        vm.stopPrank();
    }

    /// @dev A multicall inside the batch does not end it: the value stays spent for the outer calls, so a nested
    ///      multicall cannot pay a second transfer out of what other callers left in the router.
    function testANestedMulticallDoesNotRearmTheValue() public {
        IAsyncVault vault = _deployVault();
        _enable(vault);
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        s.vaultRouter.requestDeposit(vault, USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();
        _fulfill(true, RequestId.wrap(_lastRequestId(vault)), USDC_AMOUNT_1);
        vm.prank(INVESTOR_A);
        s.vaultRouter.claimDeposit(vault, INVESTOR_A, INVESTOR_A);

        IShareToken share = IShareToken(vault.share());
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        vm.prank(address(s.spokeHandler));
        s.spokeRegistry.updateBridger(POOL_A, address(s.vaultRouter), true);
        vm.deal(address(s.vaultRouter), GAS);

        bytes memory transfer = abi.encodeCall(
            IVaultRouter.crosschainTransferShares,
            (vault, shares / 2, CENTRIFUGE_ID_A, INVESTOR_A.toBytes32(), INVESTOR_A, HOOK_GAS, HOOK_GAS, INVESTOR_A)
        );
        bytes[] memory inner = new bytes[](1);
        inner[0] = transfer;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IMulticall.multicall, (inner));
        calls[1] = transfer;

        vm.deal(INVESTOR_A, GAS);
        vm.startPrank(INVESTOR_A);
        share.approve(address(s.vaultRouter), shares);
        vm.expectRevert(IVaultRouter.ValueAlreadySpent.selector);
        s.vaultRouter.multicall{value: GAS}(calls);
        vm.stopPrank();
        assertEq(address(s.vaultRouter).balance, GAS, "what was left in the router stays");
    }
}
