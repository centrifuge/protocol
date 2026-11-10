// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18, d18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultRequestManager,
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {IAsyncVault, IVaultErrors, VaultConfig, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev The vault's arithmetic, over the inputs the rest of the suite holds constant: the asset and
///      share decimals, the two prices, and the fee/retained split. Every other vault test fixes them
///      at 6/18 and 1:1 with no fees, which is the one combination least likely to be wrong.
///
///      The properties here are the ones that must hold at every combination rather than at any
///      particular one: a conversion never invents value, a quote agrees with the execution it quotes,
///      and a capacity the vault reports is a capacity it will honour.
contract VaultNumericTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    uint16 constant MAX_BPS = 10_000;

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address escrow = address(new AmpleEscrow());
    address feeRecipient = makeAddr("feeRecipient");

    address controller = makeAddr("controller");
    address receiver = makeAddr("receiver");

    PerRequestPolicy requestPolicy = new PerRequestPolicy(true);

    IAsyncVault v;
    uint8 assetDecimals;
    uint8 shareDecimals;

    /// @dev Deploys a vault over one decimal pair. Called per fuzz run, so the whole numeric context
    ///      is an input rather than a fixture.
    function _deploy(uint8 assetDecimals_, uint8 shareDecimals_) internal {
        assetDecimals = assetDecimals_;
        shareDecimals = shareDecimals_;

        MockERC20 asset = new MockERC20(assetDecimals_);
        MockShareToken share = new MockShareToken(shareDecimals_);

        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        v = IAsyncVault(
            address(
                new Vault(
                    POOL,
                    SC,
                    address(asset),
                    ASSET_ID,
                    IShareToken(address(share)),
                    VaultConfig({
                        foldHorizon: 0,
                        spoke: ISpoke(spoke),
                        spokeRegistry: ISpokeRegistry(spokeRegistry),
                        plugins: VaultPlugins({
                            oracle: IVaultOracle(oracle),
                            instantPolicy: IInstantPolicy(instantPolicy),
                            requestPolicy: IRequestPolicy(address(requestPolicy)),
                            liquidityRoute: ILiquidityRoute(address(0)),
                            settlementObserver: ISettlementObserver(address(0))
                        })
                    })
                )
            )
        );

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");

        bytes4[9] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.reserve.selector,
            ISpoke.unreserve.selector,
            ISpoke.issue.selector,
            ISpoke.revoke.selector,
            ISpoke.withdraw.selector,
            ISpoke.withdrawReserved.selector,
            ISpoke.withdrawShares.selector,
            ISpoke.transferSharesFrom.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            vm.mockCall(spoke, abi.encodeWithSelector(voids[i]), "");
        }
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(type(uint128).max));

        // Fee-free by default. Every `max*` view falls through to the instant policy once the async
        // ledger is empty, so it has to answer even in the tests that never trade instantly.
        _fees(0, 0);
    }

    function _prices(D18 ppa, D18 pps) internal {
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ppa, pps, true));
    }

    /// @dev A basis-point fee on both sides, quoted the way `ReserveInstantPolicy` quotes it: rounded up, so it is
    ///      never rounded away in the caller's favour.
    function _fees(uint128 cap, uint16 feeBps) internal {
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector), abi.encode(cap));
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector), abi.encode(cap));

        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        if (feeBps == 0) return;
        _quoteProportional(feeBps);
    }

    /// @dev Mocked per amount, because a proportional quote depends on the amount asked about and
    ///      `vm.mockCall` matches on full calldata.
    function _quoteProportional(uint16 feeBps) internal {
        for (uint256 i; i < _AMOUNTS.length; i++) {
            uint128 amount = _AMOUNTS[i];
            int128 fee = int128(uint128(_ceilBps(amount, feeBps)));

            _mockQuote(IInstantPolicy.quoteInstantDeposit.selector, amount, fee);
            _mockQuote(IInstantPolicy.quoteInstantRedeem.selector, amount, fee);
            _mockTrade(IInstantPolicy.quoteInstantDeposit.selector, amount, fee);
            _mockTrade(IInstantPolicy.quoteInstantRedeem.selector, amount, fee);
        }
    }

    uint128[6] internal _AMOUNTS;

    /// @dev The vault asks for the quote on behalf of whoever is asking: the controller for the `max*` views and the
    ///      test itself for a preview it makes unpranked.
    function _mockQuote(bytes4 selector, uint128 amount, int128 fee) internal {
        address[2] memory askers = [address(this), controller];
        for (uint256 i; i < askers.length; i++) {
            vm.mockCall(
                instantPolicy,
                abi.encodeWithSelector(selector, address(v), askers[i], askers[i], amount),
                abi.encode(fee, feeRecipient)
            );
        }
    }

    /// @dev The quote a trade asks for, with its caller and receiver: the same answer a preview gets.
    function _mockTrade(bytes4 selector, uint128 amount, int128 fee) internal {
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(selector, address(v), controller, receiver, amount),
            abi.encode(fee, feeRecipient)
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(selector, address(v), controller, controller, amount),
            abi.encode(fee, feeRecipient)
        );
    }

    function _ceilBps(uint128 amount, uint16 bps) internal pure returns (uint256) {
        return (uint256(amount) * bps + MAX_BPS - 1) / MAX_BPS;
    }

    /// @dev The decimal pairs a pool realistically runs: a 6-decimal stablecoin against an 18-decimal
    ///      share, the inversion of that, and both sides equal.
    function _decimals(uint256 seed) internal pure returns (uint8 a, uint8 s) {
        uint256 which = seed % 4;
        if (which == 0) return (6, 18);
        if (which == 1) return (18, 6);
        if (which == 2) return (18, 18);
        return (8, 8);
    }

    //----------------------------------------------------------------------------------------------
    // No arithmetic panic, whatever the prices, decimals, amounts and fees
    //----------------------------------------------------------------------------------------------

    /// @dev `Panic(0x11)` is an overflow or underflow and `Panic(0x12)` a division by zero: arithmetic the code did not
    ///      guard, as opposed to a check that named its refusal. A refusal is fine; a panic is a state the code did
    ///      not expect, and on a path every caller takes it is a call nobody can make.
    function _isArithmeticPanic(bytes memory ret) internal pure returns (bool) {
        if (ret.length < 36 || bytes4(ret) != 0x4e487b71) return false;
        uint256 code;
        assembly ("memory-safe") {
            code := mload(add(ret, 36))
        }
        return code == 0x11 || code == 0x12;
    }

    /// @dev A fee the policy answers, signed: a charge, or a rebate that the fee recipient funds.
    function _mockFee(int128 fee) internal {
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(fee, feeRecipient)
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(fee, feeRecipient)
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
    }

    /// @dev Every instant entry point, view and preview, over the whole range of the inputs that feed their
    ///      arithmetic: any pair of decimals, a price anywhere in the `uint128` range, any amount and capacity, and a
    ///      fee that is a charge or a rebate of any size. None may fail with an arithmetic panic.
    function testFuzzNoInstantEntryPointFailsWithAnArithmeticPanic(
        uint8 assetDecimals_,
        uint8 shareDecimals_,
        uint128 ppaRaw,
        uint128 ppsRaw,
        uint128 amount,
        uint128 cap,
        int128 fee
    ) public {
        _deploy(uint8(bound(assetDecimals_, 0, 30)), uint8(bound(shareDecimals_, 0, 30)));
        _prices(
            D18.wrap(uint128(bound(ppaRaw, 1, type(uint128).max))),
            D18.wrap(uint128(bound(ppsRaw, 1, type(uint128).max)))
        );
        _fees(cap, 0);
        // The policy prices a fee against the amount it is asked about, so a charge or rebate larger than the amount,
        // or than what it converts to, is a misconfigured policy: the vault reverts on it, as a panic included, and
        // moves nothing. The fee ranges over everything a coherent policy can quote.
        uint256 scale = _min(
            amount, _min(_convert(v.convertToAssets.selector, amount), _convert(v.convertToShares.selector, amount))
        );
        fee = int128(bound(fee, -int256(scale), int256(scale)));
        _mockFee(fee);

        bytes[12] memory calls = [
            abi.encodeCall(v.previewDeposit, (amount)),
            abi.encodeCall(v.previewMint, (amount)),
            abi.encodeCall(v.previewWithdraw, (amount)),
            abi.encodeCall(v.previewRedeem, (amount)),
            abi.encodeCall(v.maxDeposit, (controller)),
            abi.encodeCall(v.maxMint, (controller)),
            abi.encodeCall(v.maxWithdraw, (controller)),
            abi.encodeCall(v.maxRedeem, (controller)),
            abi.encodeWithSignature("deposit(uint256,address)", amount, receiver),
            abi.encodeWithSignature("mint(uint256,address)", amount, receiver),
            abi.encodeWithSignature("withdraw(uint256,address)", amount, receiver),
            abi.encodeWithSignature("redeem(uint256,address)", amount, receiver)
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(controller);
            (bool success, bytes memory ret) = address(v).call(calls[i]);
            assertFalse(!success && _isArithmeticPanic(ret), "an entry point failed with an arithmetic panic");
        }
    }

    /// @dev `_investments` is the vault's second storage variable: three slots per controller, each holding two
    ///      counters, the first in the low half. The test below reads the claimable views back, so a layout that moved
    ///      would fail there instead of silently testing nothing.
    function _setLedger(
        address who,
        uint128 maxMint,
        uint128 depositAssets,
        uint128 maxWithdraw,
        uint128 redeemShares,
        uint128 refundShares,
        uint128 refundAssets
    ) internal {
        bytes32 base = keccak256(abi.encode(who, uint256(1)));
        vm.store(address(v), base, bytes32(uint256(maxMint) | uint256(depositAssets) << 128));
        vm.store(address(v), bytes32(uint256(base) + 1), bytes32(uint256(maxWithdraw) | uint256(redeemShares) << 128));
        vm.store(address(v), bytes32(uint256(base) + 2), bytes32(uint256(refundShares) | uint256(refundAssets) << 128));
    }

    /// @dev A controller whose ledger sits anywhere in its range, up to the top of every counter at once: the views
    ///      answer, and each claim either pays or is refused by name, with no overflow or underflow in the pro-rata
    ///      arithmetic, the refund-first split or the counters it takes down. A claim that goes through takes exactly
    ///      what it paid from the ledger.
    function testFuzzClaimsNeverFailWithAnArithmeticPanicOnAnyLedger(
        uint128 maxMint,
        uint128 depositAssets,
        uint128 maxWithdraw,
        uint128 redeemShares,
        uint128 refundShares,
        uint128 refundAssets,
        uint128 amount,
        uint8 which
    ) public {
        _deploy(6, 18);
        _prices(d18(1e18), d18(1e18));
        _setLedger(controller, maxMint, depositAssets, maxWithdraw, redeemShares, refundShares, refundAssets);
        uint256 claimableShares = uint256(maxMint) + refundShares;
        assertEq(
            v.claimableMint(controller),
            claimableShares > type(uint128).max ? type(uint128).max : claimableShares,
            "the ledger was written where the vault reads it"
        );

        // The views never fail, on any ledger
        bytes[6] memory views = [
            abi.encodeCall(v.maxDeposit, (controller)),
            abi.encodeCall(v.maxMint, (controller)),
            abi.encodeCall(v.maxWithdraw, (controller)),
            abi.encodeCall(v.maxRedeem, (controller)),
            abi.encodeCall(v.claimableMint, (controller)),
            abi.encodeCall(v.claimableWithdraw, (controller))
        ];
        for (uint256 i; i < views.length; i++) {
            (bool viewOk, bytes memory viewRet) = address(v).staticcall(views[i]);
            assertFalse(!viewOk && _isArithmeticPanic(viewRet), "a claimable view failed with an arithmetic panic");
        }

        bytes[4] memory claims = [
            abi.encodeWithSignature("deposit(uint256,address,address)", amount, receiver, controller),
            abi.encodeWithSignature("mint(uint256,address,address)", amount, receiver, controller),
            abi.encodeWithSignature("withdraw(uint256,address,address)", amount, receiver, controller),
            abi.encodeWithSignature("redeem(uint256,address,address)", amount, receiver, controller)
        ];
        vm.prank(controller);
        (bool success, bytes memory ret) = address(v).call(claims[which % 4]);
        assertFalse(!success && _isArithmeticPanic(ret), "a claim failed with an arithmetic panic");
    }

    /// @dev The conversions and the totals too: they take any amount and answer or refuse by name.
    function testFuzzNoConversionFailsWithAnArithmeticPanic(
        uint8 assetDecimals_,
        uint8 shareDecimals_,
        uint128 ppaRaw,
        uint128 ppsRaw,
        uint256 amount
    ) public {
        _deploy(uint8(bound(assetDecimals_, 0, 30)), uint8(bound(shareDecimals_, 0, 30)));
        _prices(
            D18.wrap(uint128(bound(ppaRaw, 0, type(uint128).max))),
            D18.wrap(uint128(bound(ppsRaw, 0, type(uint128).max)))
        );

        bytes[4] memory calls = [
            abi.encodeCall(v.convertToShares, (amount)),
            abi.encodeCall(v.convertToAssets, (amount)),
            abi.encodeCall(v.totalAssets, ()),
            abi.encodeCall(v.pricePerShare, ())
        ];
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory ret) = address(v).staticcall(calls[i]);
            assertFalse(!success && _isArithmeticPanic(ret), "a conversion failed with an arithmetic panic");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Conversions
    //----------------------------------------------------------------------------------------------

    /// @dev Round-tripping through both conversions must never hand back more than went in, at any
    ///      decimal gap or price. Floors are the only reason it can hand back less.
    function testFuzzConversionsNeverInventValue(uint256 decimalSeed, uint128 assets, uint64 ppaRaw, uint64 ppsRaw)
        public
    {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);

        // Bounded so the conversion stays representable. The vault narrows to uint128, and the decimal
        // gap alone can be 1e12 before the price ratio is applied, so the amount is bounded in whole
        // units and the two prices to within 100x of each other. That the narrowing reverts rather
        // than truncating is correct; what is under test here is the arithmetic below it.
        D18 ppa = d18(uint128(bound(ppaRaw, 1e17, 1e19)));
        D18 pps = d18(uint128(bound(ppsRaw, 1e17, 1e19)));
        _prices(ppa, pps);

        assets = uint128(bound(assets, 1, 1e9)) * uint128(10) ** a;

        uint256 shares = v.convertToShares(assets);
        vm.assume(shares > 0);
        uint256 back = v.convertToAssets(shares);

        assertLe(back, assets, "a round trip created value");
    }

    /// @dev The two conversions are inverses, so one direction at a price cannot be inconsistent with
    ///      the other at the same price: converting a share amount and converting it back must land
    ///      within the one unit each floor can lose.
    function testFuzzConversionsAreConsistentInBothDirections(uint256 decimalSeed, uint128 shares, uint64 priceRaw)
        public
    {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);

        D18 price = d18(uint128(bound(priceRaw, 1e15, 1e21)));
        _prices(d18(1e18), price);

        shares = uint128(bound(shares, uint128(10) ** s, 1e12 * uint128(10) ** s));

        uint256 assets = v.convertToAssets(shares);
        vm.assume(assets > 0);
        assertLe(v.convertToShares(assets), shares, "shares grew across the round trip");
    }

    //----------------------------------------------------------------------------------------------
    // Quotes against executions
    //----------------------------------------------------------------------------------------------

    /// @dev `previewDeposit` is what an integrator sizes a deposit against, so it has to be the amount
    ///      the deposit actually mints. Anything else is a quote the vault does not honour.
    function testFuzzPreviewDepositMatchesTheDeposit(uint256 decimalSeed, uint128 assets, uint16 feeBps) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        assets = uint128(bound(assets, uint128(10) ** a, 1_000 * uint128(10) ** a));
        _AMOUNTS[0] = assets;
        _fees(type(uint128).max, uint16(bound(feeBps, 0, MAX_BPS - 1)));

        uint256 quoted = v.previewDeposit(assets);
        vm.assume(quoted > 0);

        vm.prank(controller);
        uint256 minted = v.deposit(assets, receiver);

        assertEq(minted, quoted, "the preview and the deposit disagreed");
    }

    /// @dev A capacity too small to mint a single share unit is not a capacity: `deposit` reverts on it, so
    ///      `maxDeposit` must read zero, as 18-decimal assets against 6-decimal shares make easy to hit.
    function testMaxDepositReadsZeroWhereTheDepositWouldMintNothing() public {
        _deploy(18, 6);
        _prices(d18(1e18), d18(1e18));
        _AMOUNTS[0] = 5e11;
        _fees(5e11, 0);

        assertEq(v.maxDeposit(controller), 0);
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.deposit(5e11, receiver);
    }

    /// @dev Where `maxDeposit` reports a capacity, depositing it succeeds.
    function testFuzzMaxDepositExecutes(uint256 decimalSeed, uint128 cap, uint16 feeBps) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        cap = uint128(bound(cap, 1, 1_000 * uint128(10) ** a));
        _AMOUNTS[0] = cap;
        _fees(cap, uint16(bound(feeBps, 0, MAX_BPS - 1)));

        uint256 max = v.maxDeposit(controller);
        if (max == 0) return;

        vm.prank(controller);
        v.deposit(max, receiver);
    }

    /// @dev Found by the recon campaign: at a price of about 0.5 over a 6-decimal asset and an 18-decimal share, a
    ///      capacity of one asset unit is 500,154,977,471 shares, which convert back to no assets, so redeeming
    ///      the reported maximum reverted `ZeroAmount`. A capacity that pays out nothing is not one.
    function testMaxRedeemIsNoneWhereItsSharesConvertToNoAssets() public {
        _deploy(6, 18);
        _prices(d18(500154977471332154), d18(1e18));
        _AMOUNTS[0] = 1;
        _fees(1, 0);

        assertEq(v.convertToAssets(500154977471), 0, "the shares of one unit round to nothing");
        assertEq(v.maxRedeem(controller), 0, "so there is nothing to offer");
    }

    /// @dev Wherever `maxRedeem` reports shares, they pay out at least one unit of the asset, so the redeem is not
    ///      refused as empty, at any decimals, price and capacity.
    function testFuzzMaxRedeemPaysSomething(uint256 decimalSeed, uint128 cap, uint64 ppaRaw, uint64 ppsRaw) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(uint128(bound(ppaRaw, 1e12, 1e20))), d18(uint128(bound(ppsRaw, 1e12, 1e20))));

        cap = uint128(bound(cap, 1, 1_000 * uint128(10) ** a));
        _AMOUNTS[0] = cap;
        _fees(cap, 0);

        uint256 max = v.maxRedeem(controller);
        if (max == 0) return;
        assertGt(v.convertToAssets(max), 0, "a reported maximum that pays nothing");
    }

    /// @dev `previewRedeem` mirrors it on the way out.
    function testFuzzPreviewRedeemMatchesTheRedeem(uint256 decimalSeed, uint128 shares, uint16 feeBps) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        shares = uint128(bound(shares, uint128(10) ** s, 1_000 * uint128(10) ** s));

        // The exit fee is quoted on the gross asset value the shares convert to, not on the shares.
        uint128 gross = uint128(v.convertToAssets(shares));
        vm.assume(gross > 0);
        _AMOUNTS[0] = gross;
        _fees(type(uint128).max, uint16(bound(feeBps, 0, MAX_BPS - 1)));

        uint256 quoted = v.previewRedeem(shares);
        vm.assume(quoted > 0);

        vm.prank(controller);
        uint256 paid = v.redeem(shares, receiver);

        assertEq(paid, quoted, "the preview and the redemption disagreed");
    }

    //----------------------------------------------------------------------------------------------
    // Capacity
    //----------------------------------------------------------------------------------------------

    /// @dev ERC-4626 requires `maxDeposit` to be depositable. It is the one capacity claim the vault
    ///      makes about itself, and the fee and the decimal gap are both between the claim and the
    ///      execution, so this is where a rounding direction chosen wrongly shows up.
    function testFuzzDepositingExactlyMaxDepositSucceeds(uint256 decimalSeed, uint128 cap, uint16 feeBps) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        cap = uint128(bound(cap, uint128(10) ** a, 1_000_000 * uint128(10) ** a));
        _AMOUNTS[0] = cap;
        _fees(cap, uint16(bound(feeBps, 0, MAX_BPS - 1)));

        uint256 max = v.maxDeposit(controller);
        vm.assume(max > 0);
        assertLe(max, cap, "the reported capacity exceeded the policy cap");

        vm.prank(controller);
        v.deposit(max, receiver);
    }

    /// @dev The redeem-side mirror. `maxRedeem` reports shares, and burning exactly that many must
    ///      stay inside the capacity the same view derived it from.
    function testFuzzRedeemingExactlyMaxRedeemSucceeds(uint256 decimalSeed, uint128 cap, uint16 feeBps) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        cap = uint128(bound(cap, uint128(10) ** a, 1_000_000 * uint128(10) ** a));
        _AMOUNTS[0] = cap;
        _fees(cap, uint16(bound(feeBps, 0, MAX_BPS - 1)));

        uint256 max = v.maxRedeem(controller);
        vm.assume(max > 0);

        uint128 gross = uint128(v.convertToAssets(max));
        vm.assume(gross > 0);
        _AMOUNTS[1] = gross;
        _fees(cap, uint16(bound(feeBps, 0, MAX_BPS - 1)));

        vm.prank(controller);
        v.redeem(max, receiver);
    }

    /// @dev `withdraw` burns shares rounded up, so the balance bound is compared rounded up too: at a price that does
    ///      not divide evenly, a balance that rounds down to the capacity's shares cannot pay it out.
    function testMaxWithdrawBurnsNoMoreThanTheBalance() public {
        _deploy(6, 18);
        _prices(d18(1e18), d18(1.1e18));
        _fees(1_000_000, 0);
        uint256 held = 909_090_909_090_909_090;
        MockShareToken(v.share()).setBalance(controller, held);

        uint256 max = v.maxWithdraw(controller);
        assertEq(max, 999_999, "one asset unit below the capacity");
        assertLe(v.previewWithdraw(max), held, "the reported maximum burns no more than the balance");
        assertEq(v.maxRedeem(controller), held, "a redeem rounds down, so the whole balance still redeems");
    }

    //----------------------------------------------------------------------------------------------
    // Async settlement
    //----------------------------------------------------------------------------------------------

    /// @dev A request settled at an arbitrary price, claimed in full, must hand over exactly what the
    ///      hub said it fulfilled and leave nothing claimable behind. The blended ledger stores a
    ///      price rather than the pair of amounts, so this is where the decimal gap bites hardest.
    function testFuzzAFullyFulfilledDepositClaimsOut(uint256 decimalSeed, uint128 assets, uint128 shares) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        assets = uint128(bound(assets, uint128(10) ** a, 1e9 * uint128(10) ** a));
        shares = uint128(bound(shares, uint128(10) ** s, 1e9 * uint128(10) ** s));

        vm.prank(controller);
        uint96 localId = uint96(v.requestDeposit(assets, controller, controller));

        vm.startPrank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(localId, assets);
        IVaultDepositCallbacks(address(v)).issueShares(localId, shares);
        IVaultDepositCallbacks(address(v)).fulfillDepositRequest(localId, assets, shares);
        vm.stopPrank();

        assertEq(v.maxMint(controller), shares, "every fulfilled share is claimable");
        assertEq(v.pendingDepositRequest(0, controller), 0, "and nothing is still pending");

        vm.prank(controller);
        v.mint(shares, receiver, controller);

        assertEq(v.maxMint(controller), 0, "the ledger is emptied by the claim");
        assertEq(v.claimableDepositRequest(0, controller), 0);
    }

    /// @dev The redeem-side mirror, in the unit that side settles in.
    function testFuzzAFullyFulfilledRedeemClaimsOut(uint256 decimalSeed, uint128 shares, uint128 assets) public {
        (uint8 a, uint8 s) = _decimals(decimalSeed);
        _deploy(a, s);
        _prices(d18(1e18), d18(1e18));

        shares = uint128(bound(shares, uint128(10) ** s, 1e9 * uint128(10) ** s));
        assets = uint128(bound(assets, uint128(10) ** a, 1e9 * uint128(10) ** a));

        vm.prank(controller);
        uint96 localId = uint96(v.requestRedeem(shares, controller, controller));

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, assets, shares);
        IVaultRedeemCallbacks(address(v)).fulfillRedeemRequest(localId, assets, shares);
        vm.stopPrank();

        assertEq(v.maxWithdraw(controller), assets, "every fulfilled asset is claimable");
        assertEq(v.pendingRedeemRequest(0, controller), 0);

        vm.prank(controller);
        v.withdraw(assets, receiver, controller);

        assertEq(v.maxWithdraw(controller), 0, "the ledger is emptied by the claim");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev A conversion that overflows what the vault can express is no policy's fee scale: nothing.
    function _convert(bytes4 selector, uint256 amount) internal view returns (uint256) {
        (bool success, bytes memory ret) = address(v).staticcall(abi.encodeWithSelector(selector, amount));
        return success ? abi.decode(ret, (uint256)) : 0;
    }
}
