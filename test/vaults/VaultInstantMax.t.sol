// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {d18} from "../../src/misc/types/D18.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {IAsyncVault, VaultConfig, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {IRoleHook, RoleCheck} from "../../src/token/interfaces/IRoleHook.sol";

/// @dev An instant policy charging a signed rate in basis points: positive is a fee, paid to the recipient or retained
///      with none, negative a rebate the recipient pays.
contract SignedFeePolicy {
    uint128 public dCap;
    uint128 public rCap;
    int256 public dBps;
    int256 public rBps;
    address public recipient;

    function set(uint128 d, uint128 r, int256 db, int256 rb, address rec) external {
        (dCap, rCap, dBps, rBps, recipient) = (d, r, db, rb, rec);
    }

    function maxInstantDeposit(address, address) external view returns (uint128) {
        return dCap;
    }

    function maxInstantRedeem(address, address) external view returns (uint128) {
        return rCap;
    }

    function _fee(uint128 a, bool exactOut, int256 bps) internal pure returns (int128) {
        if (bps >= 0) {
            uint256 b = uint256(bps);
            if (!exactOut) return MathLib.toInt128((MathLib.mulDiv(a, b, 10_000, MathLib.Rounding.Up)));
            uint256 g = MathLib.mulDiv(a, 10_000, 10_000 - b, MathLib.Rounding.Up);
            return MathLib.toInt128((g - a));
        }
        uint256 r = uint256(-bps);
        if (!exactOut) return -MathLib.toInt128((MathLib.mulDiv(a, r, 10_000, MathLib.Rounding.Down)));
        return -MathLib.toInt128((MathLib.mulDiv(a, r, 10_000 + r, MathLib.Rounding.Down)));
    }

    function quoteInstantDeposit(address, address, address, uint128 a, bool exactOut)
        external
        view
        returns (int128, address)
    {
        return (_fee(a, exactOut, dBps), recipient);
    }

    function quoteInstantRedeem(address, address, address, uint128 a, bool exactOut)
        external
        view
        returns (int128, address)
    {
        return (_fee(a, exactOut, rBps), recipient);
    }

    function onInstantDeposit(address, address, address, uint128, bool) external {}
    function onInstantRedeem(address, address, address, uint128, bool) external {}

    function canCredit(address, address, address) external pure returns (bool) {
        return true;
    }
}

/// @dev A share hook capping every check's assets and shares, which it reports in `maxAllowed` and enforces in
///      `onRoles`.
contract CappingHook {
    uint256 public maxA = type(uint256).max;
    uint256 public maxS = type(uint256).max;

    function set(uint256 a, uint256 s) external {
        (maxA, maxS) = (a, s);
    }

    function _ok(RoleCheck[] calldata checks) internal view returns (bool) {
        for (uint256 i; i < checks.length; i++) {
            if (checks[i].assets > maxA || checks[i].shares > maxS) return false;
        }
        return true;
    }

    function onRoles(address, RoleCheck[] calldata checks) external view returns (bytes4) {
        require(_ok(checks), "hook cap");
        return IRoleHook.onRoles.selector;
    }

    function checkRoles(address, RoleCheck[] calldata checks) external view returns (bool) {
        return _ok(checks);
    }

    function maxAllowed(address, RoleCheck[] calldata) external view returns (uint256, uint256) {
        return (maxA, maxS);
    }
}

/// @dev ERC-4626's "a call at `max*` succeeds", with the previews on the right side of the result, across what the
///      instant lane combines: the fee's sign (charge, retained, rebate), a hook capping assets, shares or both, four
///      decimal pairs, prices, policy capacity and balances. Each lane is called at exactly its reported maximum.
contract VaultInstantMaxTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address escrow = address(new AmpleEscrow());
    SignedFeePolicy policy = new SignedFeePolicy();
    CappingHook hook = new CappingHook();
    MockShareToken share;
    IAsyncVault v;
    address user = makeAddr("user");

    struct P {
        uint256 decSeed;
        uint128 ppa;
        uint128 pps;
        uint128 cap;
        int16 bps;
        bool retained;
        uint128 hookA;
        uint128 hookS;
        uint128 bal;
        uint8 hookMode;
    }

    function _setup(P memory p) internal {
        uint256 w = p.decSeed % 4;
        (uint8 a, uint8 s) = w == 0 ? (6, 18) : w == 1 ? (18, 6) : w == 2 ? (18, 18) : (8, 8);
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));
        MockERC20 asset = new MockERC20(a);
        share = new MockShareToken(s);
        share.setHook(address(hook));
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
                            instantPolicy: IInstantPolicy(address(policy)),
                            requestPolicy: IRequestPolicy(address(new PerRequestPolicy(true))),
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
        _voids();
        _configure(p, a, s);
    }

    function _voids() internal {
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
    }

    function _configure(P memory p, uint8 a, uint8 s) internal {
        uint128 ppa = uint128(bound(p.ppa, 1e15, 1e21));
        uint128 pps = uint128(bound(p.pps, 1e15, 1e21));
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(d18(ppa), d18(pps), true));

        uint128 cap = uint128(bound(p.cap, 1, 1e9 * uint128(10) ** a));
        int256 bps = int256(bound(int256(p.bps), -5_000, 9_000));
        address rec = p.retained && bps > 0 ? address(0) : makeAddr("feeRecipient");
        policy.set(cap, cap, bps, bps, rec);

        uint8 mode = p.hookMode % 4;
        uint256 hA = mode & 1 == 1 ? bound(p.hookA, 1, 1e12 * uint256(10) ** a) : type(uint256).max;
        uint256 hS = mode & 2 == 2 ? bound(p.hookS, 1, 1e12 * uint256(10) ** s) : type(uint256).max;
        hook.set(hA, hS);
        share.setBalance(user, bound(p.bal, 0, 1e13 * uint256(10) ** s));
    }

    function testFuzzDepositAtMaxDeposit(P memory p) public {
        _setup(p);
        uint256 max = v.maxDeposit(user);
        if (max == 0) return;
        vm.prank(user);
        uint256 preview = v.previewDeposit(max);
        vm.prank(user);
        uint256 shares = v.deposit(max, user);
        assertGe(shares, preview, "previewDeposit promised more than the deposit issued");
        assertLe(shares, hook.maxS(), "the deposit issued past the hook's share cap");
    }

    function testFuzzMintAtMaxMint(P memory p) public {
        _setup(p);
        uint256 max = v.maxMint(user);
        if (max == 0) return;
        vm.prank(user);
        uint256 preview = v.previewMint(max);
        vm.prank(user);
        uint256 assets = v.mint(max, user);
        assertLe(assets, preview, "previewMint quoted less than the mint took");
    }

    function testFuzzWithdrawAtMaxWithdraw(P memory p) public {
        _setup(p);
        uint256 max = v.maxWithdraw(user);
        if (max == 0) return;
        vm.prank(user);
        uint256 preview = v.previewWithdraw(max);
        vm.prank(user);
        uint256 shares = v.withdraw(max, user);
        assertLe(shares, preview, "previewWithdraw quoted fewer shares than the withdrawal burned");
        assertLe(shares, share.balanceOf(user), "the withdrawal burned past the balance");
    }

    function testFuzzRedeemAtMaxRedeem(P memory p) public {
        _setup(p);
        uint256 max = v.maxRedeem(user);
        if (max == 0) return;
        vm.prank(user);
        uint256 preview = v.previewRedeem(max);
        vm.prank(user);
        uint256 assets = v.redeem(max, user);
        assertGe(assets, preview, "previewRedeem promised more than the redemption paid");
        assertLe(max, share.balanceOf(user), "maxRedeem reported past the balance");
    }
}
