// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultTargets} from "./VaultTargets.sol";

import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";

import {IAsyncVault, IVaultErrors} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {IRequestPolicy, IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice What ERC-4626, ERC-7575 and ERC-7540 ask of an async vault, as standing properties and handlers: the
///         identity and ERC-165 answers, conversions and previews that round against the caller, the roundtrips of
///         the instant lane, `max*` that can be executed, and the access rules around operators and strangers.
///         Where the vault deliberately departs from a standard, `SPECIFICATION.md` carries the `n` row and the
///         check here stops at what the vault does promise.
abstract contract StandardsTargets is VaultTargets {
    /// @dev An account that holds nothing and has nothing pending, so a view asked as it is the plain one.
    address internal constant PROBE = address(0xC0FFEE);

    //----------------------------------------------------------------------------------------------
    // Identity and interfaces
    //----------------------------------------------------------------------------------------------

    /// @dev A vault is its pool's asset and share for good, answers ERC-165 for what it implements, and advertises
    ///      ERC-8161 exactly where its request policy lets a transfer through.
    function property_vaultIdentityAndInterfaces() public {
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            eq(uint256(uint160(vault.asset())), uint256(uint160(address(usdc))), "a vault's asset moved");
            eq(uint256(uint160(vault.share())), uint256(uint160(address(shareA))), "a vault's share moved");
            t(vault.supportsInterface(0x01ffc9a7), "ERC-165 is not supported");
            t(!vault.supportsInterface(0xffffffff), "ERC-165 accepted the invalid id");
            t(vault.supportsInterface(0x2f0a18c5), "ERC-7575 is not advertised");
            t(vault.supportsInterface(0xe3bc4e65), "the ERC-7540 operator interface is not advertised");
            t(vault.supportsInterface(0xce3bbe50) && vault.supportsInterface(0x620ee8e4), "async ids not advertised");
            bool transfers = IRequestPolicy(address(vault.requestPolicy())).supportsTransfers();
            t(
                vault.supportsInterface(0x53b3bb0a) == transfers && vault.supportsInterface(0x7846f5bd) == transfers,
                "ERC-8161 is advertised against what its policy allows"
            );
        }
    }

    //----------------------------------------------------------------------------------------------
    // Conversions and previews
    //----------------------------------------------------------------------------------------------

    /// @dev `totalAssets` is the supply at the share price, and a conversion either way rounds down, so no round
    ///      trip gains and the supply converts back to no more than the assets.
    function property_conversionsAreConsistent() public {
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            if (!_supplyIsRepresentable(vault)) continue;
            uint256 supply = shareA.totalSupply();
            eq(vault.totalAssets(), vault.convertToAssets(supply), "totalAssets is not the supply at the price");
            lte(vault.convertToShares(vault.totalAssets()), supply, "the assets convert to more than the supply");
            lte(
                vault.convertToAssets(vault.convertToShares(37 * ONE_ASSET)),
                37 * ONE_ASSET,
                "assets -> shares -> assets gained"
            );
            lte(
                vault.convertToShares(vault.convertToAssets(37 * ONE_SHARE)),
                37 * ONE_SHARE,
                "shares -> assets -> shares gained"
            );
        }
    }

    /// @dev Each preview rounds against the one asking, against the conversion, and the eight roundtrips of the
    ///      instant lane never gain: every one is an inequality between previews, so none can be gamed by fees,
    ///      the oracle price or the decimal gap. Asked as an account with nothing to claim, on a valid price.
    function property_previewsRoundAgainstTheCaller() public {
        if (!_oracleValid()) return;
        for (uint256 v = 2; v < 4; v++) {
            IAsyncVault vault = vaults[v];
            uint256[2] memory assetAmounts = [uint256(ONE_ASSET), 37 * ONE_ASSET];
            uint256[2] memory shareAmounts = [uint256(ONE_SHARE), 3 * ONE_SHARE / 10];
            for (uint256 i; i < 2; i++) {
                _roundingOfAssets(vault, assetAmounts[i]);
                _roundingOfShares(vault, shareAmounts[i]);
            }
        }
    }

    function _roundingOfAssets(IAsyncVault vault, uint256 a) internal {
        (bool okD, uint256 depositShares) = _probe(vault, vault.previewDeposit.selector, a);
        (bool okW, uint256 withdrawShares) = _probe(vault, vault.previewWithdraw.selector, a);
        if (okD) lte(depositShares, vault.convertToShares(a), "previewDeposit gave more than the conversion");
        if (okW) gte(withdrawShares, vault.convertToShares(a), "previewWithdraw cost less than the conversion");
        if (okD && okW) {
            lte(depositShares, withdrawShares, "depositing an amount minted more than withdrawing it burns");
        }
        if (okD) {
            // redeem(deposit(a)) <= a
            (bool ok, uint256 back) = _probe(vault, vault.previewRedeem.selector, depositShares);
            if (ok) lte(back, a, "a deposit then a redemption paid out more than went in");
        }
        if (okW) {
            // mint(withdraw(a)) >= a
            (bool ok, uint256 paid) = _probe(vault, vault.previewMint.selector, withdrawShares);
            if (ok) gte(paid, a, "withdrawing then minting those shares cost less than the assets");
        }
    }

    function _roundingOfShares(IAsyncVault vault, uint256 s) internal {
        (bool okM, uint256 mintAssets) = _probe(vault, vault.previewMint.selector, s);
        (bool okR, uint256 redeemAssets) = _probe(vault, vault.previewRedeem.selector, s);
        if (okM) gte(mintAssets, vault.convertToAssets(s), "previewMint cost less than the conversion");
        if (okR) lte(redeemAssets, vault.convertToAssets(s), "previewRedeem paid more than the conversion");
        if (okM && okR) gte(mintAssets, redeemAssets, "minting shares cost less than redeeming them pays");
        if (okR) {
            // deposit(redeem(s)) <= s
            (bool ok, uint256 back) = _probe(vault, vault.previewDeposit.selector, redeemAssets);
            if (ok) lte(back, s, "a redemption then a deposit returned more shares than were redeemed");
        }
        if (okM) {
            // withdraw(mint(s)) >= s
            (bool ok, uint256 burned) = _probe(vault, vault.previewWithdraw.selector, mintAssets);
            if (ok) gte(burned, s, "minting then withdrawing those assets burned fewer shares than were minted");
        }
    }

    /// @dev A preview as the probe account, which has nothing to claim.
    function _probe(IAsyncVault vault, bytes4 selector, uint256 amount) internal returns (bool, uint256) {
        vm.prank(PROBE);
        return _staticQuote(address(vault), selector, amount);
    }

    /// @dev The conversions answer every account alike.
    function vault_conversionsIgnoreTheCaller(uint256 actorSeed, uint256 vaultSeed, uint256 amount)
        public
        updateGhosts(OpType.USER)
    {
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        address who = _actor(actorSeed);
        amount = between(amount, 1, 1_000 * ONE_SHARE);
        bytes4[2] memory selectors = [vault.convertToShares.selector, vault.convertToAssets.selector];
        for (uint256 i; i < 2; i++) {
            vm.prank(who);
            (bool okA, uint256 asActor) = _staticQuote(address(vault), selectors[i], amount);
            (bool okB, uint256 asProbe) = _probe(vault, selectors[i], amount);
            t(okA == okB, "a conversion refused for one account and not another");
            if (okA && okB) eq(asActor, asProbe, "a conversion depended on the caller");
        }
        _ok("vault_conversionsIgnoreTheCaller");
    }

    //----------------------------------------------------------------------------------------------
    // Capacity
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-4626: where `max*` reports capacity, a call at that capacity goes through. The deposit side is
    ///      limited by what the investor holds, which the standard assumes away, so the investor is funded to pay
    ///      the whole of it, and a gated lane is left out, since its `maxDeposit` cannot see the caller.
    function vault_maxExecutes(uint256 actorSeed, bool basinVault, uint8 kind) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        bool isDeposit = kind % 2 == 0;
        bool flag = kind / 2 % 2 == 1;
        address actor = _instantActor(actorSeed, vault, isDeposit);
        if (frozen[actor] || !_healthy(vault, actor) || !_oracleValid() || _inAsync(vault, actor, isDeposit)) {
            return;
        }

        uint256 max;
        if (isDeposit) {
            if (_gatedOut(vault, actor)) return;
            max = flag ? vault.maxMint(actor) : vault.maxDeposit(actor);
            uint256 cost = flag ? vault.previewMint(max) : max;
            if (max == 0) return;
            // The standard assumes an unlimited balance, so the investor is given what the call at the maximum costs
            if (cost > usdc.balanceOf(actor)) usdc.mint(actor, cost - usdc.balanceOf(actor));
        } else {
            max = flag ? vault.maxWithdraw(actor) : vault.maxRedeem(actor);
            if (max == 0) return;
        }

        bool success = _instant(vault, actor, max, flag, isDeposit);
        t(success, "a call at the reported maximum reverted");
        _ok("vault_maxExecutes");
    }

    /// @dev Whether the deposit lane is gated and the account is not on its list.
    function _gatedOut(IAsyncVault vault, address actor) internal view returns (bool) {
        (,,,, bool gatedDeposit,,) = reserveInstantPolicy.config(address(vault));
        return gatedDeposit
            && !reserveInstantPolicy.isAllowed(address(vault), IReserveInstantPolicy.ConfigKind.Depositor, actor);
    }

    /// @dev `maxDeposit` assumes an unlimited balance, so two accounts with nothing to claim, whatever they hold,
    ///      are offered the same.
    function vault_maxIgnoresBalance(uint256 aSeed, uint256 bSeed, bool basinVault) public updateGhosts(OpType.USER) {
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        address a = _actor(aSeed);
        address b = _actor(bSeed);
        if (a == b || frozen[a] || frozen[b] || _inAsync(vault, a, true) || _inAsync(vault, b, true)) return;
        if (!_healthy(vault, a) || !_healthy(vault, b)) return;
        if (usdc.balanceOf(a) == usdc.balanceOf(b)) return;

        eq(vault.maxDeposit(a), vault.maxDeposit(b), "maxDeposit depended on the balance held");
        _ok("vault_maxIgnoresBalance");
    }

    /// @dev Liquidity the route offers needs the underlying's consent and a route to it.
    function property_noDrawWithoutConsent() public {
        address top = address(vaults[2]);
        bool consented = vaultRoute.isConsented(address(vaultC), top);
        if (!consented || vaultRoute.routes(top).length == 0) {
            eq(vaultRoute.available(top), 0, "the route offered liquidity without consent or a route");
        }
    }

    /// @dev Reads asked as accounts that have never touched the vault still answer, and a request id of another
    ///      vault, or of none, has nothing pending.
    function property_maxViewsAnswerEveryone() public {
        address[3] memory askers = [PROBE, address(0), address(vaults[0])];
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            for (uint256 i; i < askers.length; i++) {
                _answers(address(vault), abi.encodeCall(vault.maxDeposit, (askers[i])));
                _answers(address(vault), abi.encodeCall(vault.maxMint, (askers[i])));
                _answers(address(vault), abi.encodeCall(vault.maxWithdraw, (askers[i])));
                _answers(address(vault), abi.encodeCall(vault.maxRedeem, (askers[i])));
                _answers(address(vault), abi.encodeCall(vault.claimableDepositRequest, (0, askers[i])));
                _answers(address(vault), abi.encodeCall(vault.claimableRedeemRequest, (0, askers[i])));
            }
        }
    }

    /// @dev A reported maximum redeem is something to redeem, in every state and not only where `vault_maxExecutes`
    ///      is drawn with the actor, vault, fee and balance that expose it: no holder is offered more shares than
    ///      they hold, and the shares pay something after the exit fee.
    function property_maxRedeemIsRedeemable() public {
        if (!_oracleValid()) return;
        for (uint256 v = 2; v < 4; v++) {
            IAsyncVault vault = vaults[v];
            for (uint256 i; i < actors.length; i++) {
                address actor = actors[i];
                if (frozen[actor] || !_healthy(vault, actor) || _inAsync(vault, actor, false)) continue;
                uint256 max = vault.maxRedeem(actor);
                if (max == 0) continue;
                t(max <= shareA.balanceOf(actor), "maxRedeem offered more shares than the holder has");
                vm.prank(actor);
                (bool ok, uint256 assets) = _staticQuote(address(vault), vault.previewRedeem.selector, max);
                t(ok && assets != 0, "maxRedeem offered shares whose preview pays nothing");
            }
        }
    }

    /// @dev A request id of another vault, one on the wrong side, or garbage, has nothing pending; an id the vault
    ///      issued carries its address and is never zero.
    function vault_requestIdsAreTheirs(uint256 reqSeed, uint256 actorSeed, uint256 garbage)
        public
        updateGhosts(OpType.USER)
    {
        address who = _actor(actorSeed);
        IAsyncVault vault = vaults[_vaultIndex(reqSeed)];
        address other = address(vaults[_vaultIndex(reqSeed + 1)]);
        uint256 foreign = (uint256(uint160(other)) << 96) | between(garbage, 1, 1_000);
        eq(vault.pendingDepositRequest(foreign, who), 0, "a foreign request id had a deposit pending");
        eq(vault.pendingRedeemRequest(foreign, who), 0, "a foreign request id had a redemption pending");
        uint256 noise = uint256(keccak256(abi.encode(garbage)));
        eq(vault.pendingDepositRequest(noise, who), 0, "a garbage request id had a deposit pending");
        eq(vault.pendingRedeemRequest(noise, who), 0, "a garbage request id had a redemption pending");

        if (reqs.length != 0) {
            Req memory r = reqs[reqSeed % reqs.length];
            t(r.requestId != 0, "a request id was zero");
            eq(r.requestId >> 96, uint256(uint160(address(vaults[r.vault]))), "a request id names another vault");
            IAsyncVault owner = vaults[r.vault];
            if (r.isDeposit) {
                eq(owner.pendingRedeemRequest(r.requestId, who), 0, "a deposit id had a redemption pending");
            } else {
                eq(owner.pendingDepositRequest(r.requestId, who), 0, "a redeem id had a deposit pending");
            }
        }
        _ok("vault_requestIdsAreTheirs");
    }

    //----------------------------------------------------------------------------------------------
    // Requests, operators and strangers
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-7540: `requestRedeem` reverts when the owner holds fewer shares than asked.
    function vault_requestRedeemBeyondBalance(uint256 ownerSeed, uint256 vaultSeed, uint256 extra)
        public
        updateGhosts(OpType.USER)
    {
        address owner = _actor(ownerSeed);
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        uint256 amount = shareA.balanceOf(owner) + between(extra, 1, ONE_SHARE);
        (bool success,) = _callAs(owner, address(vault), abi.encodeCall(vault.requestRedeem, (amount, owner, owner)));
        t(!success, "requestRedeem took more shares than the owner holds");
        _ok("vault_requestRedeemBeyondBalance");
    }

    /// @dev Nobody moves a controller's claims without being it or its operator: the four 3-argument calls refuse a
    ///      stranger, the allowance flow of ERC-4626 included, and for that reason. The victim has a real claim in
    ///      the unit the call is made in, so a call that went through would pay out, and the stranger sometimes holds
    ///      the victim's share allowance, which the claims never look at. `kind` picks deposit, mint, withdraw or
    ///      redeem, then the stranger, then whether it holds the allowance.
    function vault_strangerCannotClaimFor(uint256 victimSeed, uint256 vaultSeed, uint256 amount, uint8 kind)
        public
        updateGhosts(OpType.USER)
    {
        uint8 k = kind % 4;
        (IAsyncVault vault, address victim, uint256 max) = _findClaim(victimSeed, vaultSeed, k < 2, k % 2 == 1);
        if (max == 0) return;
        address stranger = _stranger(victim, vault, kind, false);
        if (stranger == address(0)) return;
        amount = between(amount, 1, max);

        uint256 prior = shareA.allowance(victim, stranger);
        if (kind / 12 % 2 == 1) {
            vm.prank(victim);
            shareA.approve(stranger, type(uint256).max);
        }
        bytes memory data = k == 0
            ? abi.encodeWithSignature("deposit(uint256,address,address)", amount, stranger, victim)
            : k == 1
                ? abi.encodeWithSignature("mint(uint256,address,address)", amount, stranger, victim)
                : k == 2
                    ? abi.encodeWithSignature("withdraw(uint256,address,address)", amount, stranger, victim)
                    : abi.encodeWithSignature("redeem(uint256,address,address)", amount, stranger, victim);
        (bool success, bytes memory ret) = _callAs(stranger, address(vault), data);
        vm.prank(victim);
        shareA.approve(stranger, prior);

        t(!success, "a stranger acted on a controller's claim");
        t(bytes4(ret) == IVaultErrors.InvalidController.selector, "a stranger was refused for another reason");
        _ok("vault_strangerCannotClaimFor");
    }

    /// @dev Nobody requests with another account's money or shares without being its operator or holding its
    ///      allowance, and the vault says so. The victim can pay (it holds the assets and has approved the vault for
    ///      them) or hold the shares the call would move, so the authority check is all that stands in the way: a
    ///      request for assets is refused as `InvalidOwner`, one for shares for want of the allowance.
    function vault_strangerCannotRequestFor(uint256 victimSeed, uint256 vaultSeed, uint256 amount, uint8 kind)
        public
        updateGhosts(OpType.USER)
    {
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        // The `linked` guard comes before the authority check, and a redemption needs an owner the hook lets exit
        if (vaultUnlinked[address(vault)]) return;
        bool isDeposit = kind % 2 == 0;
        address victim = isDeposit ? _actor(victimSeed) : _liquidHolder(victimSeed);
        address stranger = _stranger(victim, vault, kind, true);
        if (stranger == address(0)) return;

        bytes memory data;
        uint256 prior = usdc.allowance(victim, address(vault));
        if (isDeposit) {
            amount = between(amount, 1, 1e12);
            if (usdc.balanceOf(victim) < amount) usdc.mint(victim, amount - usdc.balanceOf(victim));
            vm.prank(victim);
            usdc.approve(address(vault), amount);
            data = abi.encodeCall(vault.requestDeposit, (amount, victim, victim));
        } else {
            if (frozen[victim] || !_healthy(vault, victim) || shareA.balanceOf(victim) == 0) return;
            amount = between(amount, 1, shareA.balanceOf(victim));
            data = abi.encodeCall(vault.requestRedeem, (amount, victim, victim));
        }
        (bool success, bytes memory ret) = _callAs(stranger, address(vault), data);
        if (isDeposit) {
            vm.prank(victim);
            usdc.approve(address(vault), prior);
        }

        t(!success, "a stranger requested with another account's assets or shares");
        // A redemption on a vault with both lanes is refused first as no sponsor, before the allowance is read
        bytes4 expected = isDeposit
            ? IVaultErrors.InvalidOwner.selector
            : (address(vault.instantPolicy()) != address(0)
                    ? IVaultErrors.NotSponsor.selector
                    : IERC20.InsufficientAllowance.selector);
        t(bytes4(ret) == expected, "a stranger was refused for another reason");
        _ok("vault_strangerCannotRequestFor");
    }

    /// @dev Nobody moves a controller's pending stake to another controller without being it or its operator: both
    ///      ERC-8161 transfers refuse a stranger as `InvalidController`, whichever side the request is on. The victim
    ///      holds a live stake in the request, so a call that went through would take it.
    function vault_strangerCannotMoveRequest(uint256 reqSeed, uint256 victimSeed, uint256 toSeed, uint8 kind)
        public
        updateGhosts(OpType.USER)
    {
        if (reqs.length == 0) return;
        Req memory r = reqs[reqSeed % reqs.length];
        IAsyncVault vault = vaults[r.vault];
        // The `linked` guard comes before the controller check
        if (vaultUnlinked[address(vault)]) return;
        address victim;
        for (uint256 a; a < actors.length && victim == address(0); a++) {
            address candidate = _actor(victimSeed + a);
            if (vault.contribution(uint96(r.requestId), candidate).amount != 0) victim = candidate;
        }
        if (victim == address(0)) return;
        address stranger = _stranger(victim, vault, kind, false);
        if (stranger == address(0)) return;
        address to = _actor(toSeed);
        if (to == victim) to = stranger;

        (bool deposited, bytes memory depositRet) =
            _callAs(stranger, address(vault), abi.encodeCall(vault.transferDepositRequest, (r.requestId, victim, to)));
        (bool redeemed, bytes memory redeemRet) =
            _callAs(stranger, address(vault), abi.encodeCall(vault.transferRedeemRequest, (r.requestId, victim, to)));
        t(!deposited && !redeemed, "a stranger moved a controller's pending stake");
        t(
            bytes4(depositRet) == IVaultErrors.InvalidController.selector
                && bytes4(redeemRet) == IVaultErrors.InvalidController.selector,
            "a stranger was refused for another reason"
        );
        _ok("vault_strangerCannotMoveRequest");
    }

    /// @dev An account that is not the victim and not its operator on this vault, and, where `noAllowance`, not holding
    ///      its share allowance, or zero when the seed leaves none.
    function _stranger(address victim, IAsyncVault vault, uint8 kind, bool noAllowance)
        internal
        view
        returns (address)
    {
        address[3] memory candidates = [OUTSIDER, PROBE, _actor(uint256(kind) + 1)];
        address stranger = candidates[kind / 4 % 3];
        if (stranger == victim || vault.isOperator(victim, stranger)) return address(0);
        if (noAllowance && shareA.allowance(victim, stranger) != 0) return address(0);
        return stranger;
    }

    /// @dev ERC-7540: `setOperator` records what it is given, for any operator, and returns true.
    function vault_setOperator(uint256 ownerSeed, uint256 vaultSeed, address operator, bool approved)
        public
        updateGhosts(OpType.USER)
    {
        address owner = _actor(ownerSeed);
        IAsyncVault vault = vaults[_vaultIndex(vaultSeed)];
        (bool success, bytes memory ret) =
            _callAs(owner, address(vault), abi.encodeCall(vault.setOperator, (operator, approved)));
        t(success && abi.decode(ret, (bool)), "setOperator refused or did not return true");
        t(vault.isOperator(owner, operator) == approved, "setOperator did not record what it was given");
        _ok("vault_setOperator");
    }

    /// @dev An operator claims for its controller, and what it claims is counted like any other claim. The shares or
    ///      assets go to the controller, so the claim totals stay with the controller's own.
    function vault_operatorClaim(uint256 ownerSeed, uint256 vaultSeed, uint256 amount, bool isDeposit)
        public
        updateGhosts(OpType.USER)
    {
        (IAsyncVault vault, address owner, uint256 max) = _findClaim(ownerSeed, vaultSeed, isDeposit, isDeposit);
        if (max == 0) return;
        address operator = _actor(ownerSeed + 1);
        if (operator == owner) return;
        vm.prank(owner);
        vault.setOperator(operator, true);

        amount = between(amount, 1, max);
        uint256 sharesBefore = shareA.balanceOf(owner);
        uint256 assetsBefore = usdc.balanceOf(owner);
        bytes memory data = isDeposit
            ? abi.encodeWithSignature("mint(uint256,address,address)", amount, owner, owner)
            : abi.encodeWithSignature("redeem(uint256,address,address)", amount, owner, owner);
        (bool success,) = _callAs(operator, address(vault), data);
        if (!success) return _reverted("vault_operatorClaim");

        _countClaimed(address(vault), owner, sharesBefore, assetsBefore);
        _ok("vault_operatorClaim");
    }
}
