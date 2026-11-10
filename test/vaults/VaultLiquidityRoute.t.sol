// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract} from "./Vault.t.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC7575} from "../../src/misc/interfaces/IERC7575.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {IAsyncVault} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {VaultLiquidityRoute} from "../../src/vaults/liquidity/VaultLiquidityRoute.sol";
import {IVaultLiquidityRoute} from "../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import "forge-std/Test.sol";

/// @dev An 18-decimal ERC20 with a real balance ledger, standing in for a share token or an asset.
contract Token {
    string public name;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public frozen;

    constructor(string memory name_, uint8 decimals_) {
        name = name_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) public {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function freeze(address who) external {
        frozen[who] = true;
    }

    /// @dev The share token's restriction view, as `IShareToken` exposes it.
    function checkTransferRestriction(address from, address to, uint256) external view returns (bool) {
        return !frozen[from] && !frozen[to];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!frozen[msg.sender] && !frozen[to], "frozen");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!frozen[from] && !frozen[to], "frozen");
        if (msg.sender != from) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev The underlying vault, at the level of detail this route interacts with: an instant exit that
///      burns the caller's shares and pays the receiver, drawing on its own liquidity route whenever
///      its escrow falls short. That last step is what makes the chain in this test a chain.
contract UnderlyingVault {
    Token public shareToken;
    Token public asset;
    address public escrow;
    address public source;
    uint256 public price; // assets per share, 1e18
    uint256 public exitFeeBps;

    constructor(Token shareToken_, Token asset_, address escrow_, uint256 price_) {
        shareToken = shareToken_;
        asset = asset_;
        escrow = escrow_;
        price = price_;
    }

    function setSource(address source_) external {
        source = source_;
    }

    function share() external view returns (address) {
        return address(shareToken);
    }

    function setExitFee(uint256 bps) external {
        exitFeeBps = bps;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares * price / 1e18;
    }

    /// @dev Charged rounded up, in the vault's favour, as the real instant policies do.
    function _fee(uint256 assets) internal view returns (uint256) {
        return (assets * exitFeeBps + 9_999) / 10_000;
    }

    /// @dev What a position actually fetches on the way out: gross value less the exit fee.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        require(!broken, "invalid price");
        uint256 gross = convertToAssets(shares);
        return gross - _fee(gross);
    }

    /// @dev Inflates `previewWithdraw` without moving `previewRedeem` or the burn, so the quote and
    ///      what the exit consumes disagree. The route takes both from a contract it does not control,
    ///      which is the situation its `shares <= held` assertion exists for.
    uint256 public quoteSkewBps;

    function setQuoteSkew(uint256 bps) external {
        quoteSkewBps = bps;
    }

    /// @dev Pays the receiver this much less than it was asked for, while still burning in full.
    uint256 public shortfall;

    function setShortfall(uint256 amount) external {
        shortfall = amount;
    }

    /// @dev Pays this address instead of the receiver: an inflow into the top pool's escrow, as a
    ///      reentrant deposit into a sibling vault of that pool would make.
    address public misdirect;

    function setMisdirect(address to) external {
        misdirect = to;
    }

    /// @dev Makes every quote revert, as the real vault's do on an invalid price.
    bool public broken;

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    /// @dev The inverse: shares to burn to receive `assets` net, so the burn covers the fee too.
    function _burnFor(uint256 assets) internal view returns (uint256) {
        return ((assets + _fee(assets)) * 1e18 + price - 1) / price;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 shares = _burnFor(assets);
        return shares + (shares * quoteSkewBps) / 10_000;
    }

    function maxWithdraw(address) external view returns (uint256) {
        require(!broken, "invalid price");
        return previewRedeem(shareToken.totalSupply());
    }

    function withdrawCapacity(address owner) external view returns (uint256) {
        return this.maxWithdraw(owner);
    }

    /// @dev The instant exit: burn the caller's shares, top the escrow up from the route if it cannot
    ///      cover the payout, then pay the receiver.
    function withdraw(uint256 assets, address receiver) external returns (uint256) {
        uint256 shares = _burnFor(assets);
        shareToken.transferFrom(msg.sender, address(this), shares);
        shareToken.burn(address(this), shares);

        if (asset.balanceOf(escrow) < assets) {
            IBasinRouteLike(source).provide(address(this), uint128(assets - asset.balanceOf(escrow)));
        }

        Token(asset).transferFrom(escrow, misdirect == address(0) ? receiver : misdirect, assets - shortfall);
        return shares;
    }
}

/// @dev Stands in for the spoke's balance sheet where the route touches it: `withdraw` releases a
///      holding out of the top pool's escrow to a manager, moving the tokens as the real one would.
///      Everything else the route reads is mocked per test.
contract ReleasingSpoke {
    address public immutable escrow;

    constructor(address escrow_) {
        escrow = escrow_;
    }

    function withdraw(PoolId, ShareClassId, address asset, uint256, address receiver, uint128 amount) external {
        Token(asset).transferFrom(escrow, receiver, amount);
    }
}

interface IBasinRouteLike {
    function provide(address vault, uint128 assets) external;
}

/// @dev The underlying vault's own route, standing in for `BasinLiquidityRoute`: it draws on a venue
///      and delivers into that vault's escrow.
contract BasinLike {
    Token public asset;
    address public escrow;
    uint256 public funded;

    constructor(Token asset_, address escrow_) {
        asset = asset_;
        escrow = escrow_;
    }

    function fund(uint256 amount) external {
        funded += amount;
        asset.mint(address(this), amount);
    }

    function provide(address, uint128 assets) external {
        require(asset.balanceOf(address(this)) >= assets, "basin dry");
        asset.transfer(escrow, assets);
    }
}

/// @dev A pool holding positions in other vaults, sourcing its own instant exits from them. The chain
///      under test is the one a fund-of-funds needs:
///
///        top-level vault -> VaultLiquidityRoute -> underlying vault -> its own route -> the venue
///
///      Each hop is a separate pool with separate accounting, and the point of the test is that a
///      redemption at the top is paid, in one transaction, out of a venue only the bottom knows about.
/// @dev An underlying whose quote never ends, as two pools holding each other's shares and routing to each other
///      make one: each `available` asks the other, recursing until the gas is gone.
contract GasBurningUnderlying {
    function withdrawCapacity(address) external view returns (uint256) {
        while (gasleft() > 0) {}
        return 0;
    }
}

/// @dev Answers every quote with a large payload, the cost of copying which falls on the caller.
contract ReturnBombUnderlying {
    function withdrawCapacity(address) external pure returns (uint256) {
        assembly {
            mstore(0, 1)
            return(0, 300000)
        }
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        assembly {
            mstore(0, 1)
            return(0, 300000)
        }
    }
}

contract MaxQuotingUnderlying {
    function withdrawCapacity(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract VaultLiquidityRouteTest is Test {
    PoolId constant TOP_POOL = PoolId.wrap(1);
    PoolId constant JTRSY_POOL = PoolId.wrap(2);
    PoolId constant OTHER_POOL = PoolId.wrap(3);
    ShareClassId constant TOP_SC = ShareClassId.wrap(bytes16("top"));
    ShareClassId constant JTRSY_SC = ShareClassId.wrap(bytes16("jtrsy"));
    ShareClassId constant OTHER_SC = ShareClassId.wrap(bytes16("other"));

    address spokeRegistry = address(new IsContract());
    address envoy = makeAddr("envoy");
    address topEscrow = makeAddr("topEscrow");
    address jtrsyEscrow = makeAddr("jtrsyEscrow");
    address topVault = address(new IsContract());
    address receiver = makeAddr("receiver");
    address spoke = address(new ReleasingSpoke(topEscrow));

    Token usdc = new Token("USDC", 6);
    Token jtrsy = new Token("jTRSY", 18);
    Token other = new Token("OTHER", 18);

    UnderlyingVault jtrsyVault;
    UnderlyingVault otherVault;
    BasinLike basin;
    VaultLiquidityRoute route;

    /// @dev What the top pool's escrow holds of each underlying share token.
    mapping(address => uint128) internal held;

    function setUp() public {
        jtrsyVault = new UnderlyingVault(jtrsy, usdc, jtrsyEscrow, 1e18);
        otherVault = new UnderlyingVault(other, usdc, jtrsyEscrow, 1e18);
        basin = new BasinLike(usdc, jtrsyEscrow);
        jtrsyVault.setSource(address(basin));
        otherVault.setSource(address(basin));

        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));
        route = new VaultLiquidityRoute(ISpoke(spoke), envoy, makeAddr("root"));

        // Defaults, overridden per vault below: the registry knows nothing, and the pool holds nothing.
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(
                VaultDetails(
                    PoolId.wrap(0), ShareClassId.wrap(bytes16(0)), newAssetId(0, 0), address(0), uint256(0), false
                )
            )
        );
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(0)));
        _register(topVault, TOP_POOL, TOP_SC, address(usdc));
        _register(address(jtrsyVault), JTRSY_POOL, JTRSY_SC, address(usdc));
        _register(address(otherVault), OTHER_POOL, OTHER_SC, address(usdc));
        _shareClass(JTRSY_POOL, JTRSY_SC, address(jtrsy));
        _shareClass(OTHER_POOL, OTHER_SC, address(other));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector, TOP_POOL), abi.encode(topEscrow));

        // The escrows approve the parties that move their funds, standing in for the balance-sheet
        // permissions the real escrow grants its pool's managers.
        vm.prank(jtrsyEscrow);
        usdc.approve(address(jtrsyVault), type(uint256).max);
        vm.prank(jtrsyEscrow);
        usdc.approve(address(otherVault), type(uint256).max);

        // The route is a manager of the top pool, so it may release its holdings.
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.manager.selector), abi.encode(true));

        // `noteDeposit` books what comes back: the pool's own balance-sheet accounting.
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.noteDeposit.selector), "");
    }

    function _register(address vault, PoolId poolId, ShareClassId scId, address asset) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault),
            abi.encode(VaultDetails(poolId, scId, newAssetId(0, 1), asset, uint256(0), true))
        );
        vm.mockCall(vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(poolId));
        vm.mockCall(vault, abi.encodeWithSelector(IVault.scId.selector), abi.encode(scId));
    }

    /// @dev The registry's record of which token a share class issues.
    function _shareClass(PoolId poolId, ShareClassId scId, address shareToken) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, poolId, scId),
            abi.encode(shareToken)
        );
    }

    /// @dev The top pool holds `amount` of an underlying share token in its escrow, releasable through
    ///      the spoke.
    function _hold(Token shareToken, uint128 amount) internal {
        shareToken.mint(topEscrow, amount);
        held[address(shareToken)] += amount;

        vm.mockCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.availableBalanceOf.selector, TOP_POOL, TOP_SC, address(shareToken), uint256(0)
            ),
            abi.encode(held[address(shareToken)])
        );
        vm.prank(topEscrow);
        shareToken.approve(spoke, type(uint256).max);
    }

    function _configure(address[] memory underlying) internal {
        for (uint256 i; i < underlying.length; i++) {
            _consent(underlying[i], true);
        }
        vm.prank(envoy);
        route.fromHub(TOP_POOL, _routesPayload(underlying));
    }

    /// @dev The underlying's own pool lets the top vault draw on it.
    function _consent(address underlying, bool allowed) internal {
        PoolId pool = ISpokeRegistry(spokeRegistry).vaultDetails(underlying).poolId;
        vm.prank(envoy);
        route.fromHub(
            pool, abi.encode(IVaultLiquidityRoute.ConfigKind.Consent, underlying, abi.encode(topVault, allowed))
        );
    }

    function _routesPayload(address[] memory underlying) internal view returns (bytes memory) {
        return abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, topVault, abi.encode(underlying));
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    //----------------------------------------------------------------------------------------------
    // Configuration
    //----------------------------------------------------------------------------------------------

    /// @dev The manager-call transport is payable, so every `fromHub` refuses value rather than
    ///      accumulating it in a contract with no way to send it back out.
    function testConfigureRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.UnexpectedValue.selector);
        route.fromHub{value: 1}(TOP_POOL, _routesPayload(_one(address(jtrsyVault))));
    }

    /// @dev The route is one caller for every pool, so the underlying cannot tell the pools drawing on it apart: its
    ///      own pool consents to each routing vault, and a route through an underlying that did not is refused.
    function testARouteNeedsTheUnderlyingsConsent() public {
        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.NotConsented.selector);
        route.fromHub(TOP_POOL, _routesPayload(_one(address(jtrsyVault))));

        _configure(_one(address(jtrsyVault)));
        assertEq(route.routes(topVault)[0], address(jtrsyVault));
        assertTrue(route.isConsented(address(jtrsyVault), topVault));
    }

    /// @dev Both configuration events carry the pool that configured them and lead with the routing vault.
    function testConfigurationEventsCarryThePoolAndTheVault() public {
        vm.expectEmit(true, true, true, true, address(route));
        emit IVaultLiquidityRoute.SetConsent(JTRSY_POOL, topVault, address(jtrsyVault), true);
        _consent(address(jtrsyVault), true);

        vm.expectEmit(true, true, false, true, address(route));
        emit IVaultLiquidityRoute.SetRoutes(TOP_POOL, topVault, _one(address(jtrsyVault)));
        vm.prank(envoy);
        route.fromHub(TOP_POOL, _routesPayload(_one(address(jtrsyVault))));
    }

    function testConsentComesFromTheUnderlyingsOwnPool() public {
        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.WrongPool.selector);
        route.fromHub(
            TOP_POOL,
            abi.encode(IVaultLiquidityRoute.ConfigKind.Consent, address(jtrsyVault), abi.encode(topVault, true))
        );
    }

    function testRevokingConsentClosesTheRoute() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 1_000e18);
        assertEq(route.available(topVault), 1_000e18, "a held position is offered while consented");

        _consent(address(jtrsyVault), false);

        assertEq(route.available(topVault), 0, "no consent, no capacity");
    }

    function testOnlyEnvoyConfigures() public {
        vm.expectRevert(IVaultLiquidityRoute.NotEnvoy.selector);
        route.fromHub(TOP_POOL, _routesPayload(_one(address(jtrsyVault))));
    }

    /// @dev The same registry binding every policy uses: the pool a vault belongs to is not something
    ///      the vault gets to answer.
    function testConfigurationBindsToThePoolOwningTheVault() public {
        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.WrongPool.selector);
        route.fromHub(JTRSY_POOL, _routesPayload(_one(address(jtrsyVault))));
    }

    function testRoutesMustBeKnownVaults() public {
        // Never registered, so the registry reports it as nothing at all.
        address stranger = address(new IsContract());

        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.UnknownVault.selector);
        route.fromHub(TOP_POOL, _routesPayload(_one(stranger)));
    }

    /// @dev A route paying out a different asset would deliver the wrong token into the escrow.
    function testRoutesMustPayOutTheSameAsset() public {
        address wrongAsset = address(new IsContract());
        _register(wrongAsset, JTRSY_POOL, JTRSY_SC, address(jtrsy));

        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.AssetMismatch.selector);
        route.fromHub(TOP_POOL, _routesPayload(_one(wrongAsset)));
    }

    function testOnlyTheVaultMayDraw() public {
        _configure(_one(address(jtrsyVault)));

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IVaultLiquidityRoute.NotVault.selector);
        route.provide(topVault, 1e6);
    }

    //----------------------------------------------------------------------------------------------
    // Capacity
    //----------------------------------------------------------------------------------------------

    /// @dev This route sources liquidity out of the underlying vaults; the deposit-side `forward`
    ///      leg is optional, so it is a no-op that moves nothing. It leaves the held position and the
    ///      capacity untouched.
    function testForwardIsANoOp() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 1_000e18);

        uint256 heldBefore = jtrsy.balanceOf(topEscrow);

        vm.prank(topVault);
        route.forward(topVault, 1_000e6);

        assertEq(jtrsy.balanceOf(topEscrow), heldBefore, "forward moves none of the held position");
        assertEq(route.available(topVault), 1_000e18, "and does not disturb what can be sourced out");
    }

    /// @dev Capacity is the position the pool actually holds, valued at the underlying vault, and
    ///      bounded by what that vault could pay instantly.
    function testCapacityIsTheHeldPositionValuedAtTheUnderlyingVault() public {
        _configure(_one(address(jtrsyVault)));
        assertEq(route.available(topVault), 0, "nothing held, nothing to raise");

        _hold(jtrsy, 1_000e18);
        assertEq(route.available(topVault), 1_000e18, "the whole position, at par");
    }

    /// @dev The underlying's exit fee has to come out of the capacity advertised for that route.
    ///      Quoting the held position gross overstates the route by the fee, and the draw then needs
    ///      more shares than the pool holds — which fails inside the release, after the top-level vault
    ///      has already committed to paying the exit. The bound is `previewRedeem` for that reason: it
    ///      is the inverse of the `previewWithdraw` that sizes the burn.
    function testCapacityIsNetOfTheUnderlyingsExitFee() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 1_000e18);

        // Other investors in the underlying, so this pool's own position is the binding constraint
        // rather than the underlying's instant capacity.
        jtrsy.mint(makeAddr("otherInvestor"), 9_000e18);
        jtrsyVault.setExitFee(100); // 1%
        basin.fund(1_000e18);

        assertEq(route.available(topVault), 990e18, "1000 shares fetch 990 after the 1% exit fee");

        // And the whole advertised figure is actually drawable: the burn it costs stays inside the
        // position. Advertised gross, the burn would be 1010 against a position of 1000 and the
        // release reverts.

        vm.prank(topVault);
        route.provide(topVault, 990e18);

        // 999.9 shares covered the 990 payout plus the 9.9 fee; the rest went back to the escrow.
        assertEq(jtrsy.balanceOf(address(route)), 0, "nothing left resting on the route");
        assertEq(usdc.balanceOf(topVault), 990e18, "the full advertised capacity was raised");
    }

    function testCapacitySumsTheRoutes() public {
        address[] memory both = new address[](2);
        both[0] = address(jtrsyVault);
        both[1] = address(otherVault);
        _configure(both);

        _hold(jtrsy, 400e18);
        _hold(other, 600e18);

        assertEq(route.available(topVault), 1_000e18, "both positions count");
    }

    //----------------------------------------------------------------------------------------------
    // The chain
    //----------------------------------------------------------------------------------------------

    /// @dev The whole point. The top pool holds jTRSY and nothing else; the jTRSY vault's own escrow is
    ///      empty, so its exit draws on the basin. One call at the top, and the assets arrive in the
    ///      top pool's escrow from a venue two hops away.
    function testInstantExitIsPaidFromTheVenueTwoHopsDown() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 1_000e18);

        basin.fund(1_000e18);
        assertEq(usdc.balanceOf(jtrsyEscrow), 0, "the underlying escrow starts empty");

        vm.prank(topVault);
        route.provide(topVault, 250e18);

        assertEq(usdc.balanceOf(topVault), 250e18, "the top vault was paid, to forward into its escrow");
        assertEq(usdc.balanceOf(address(basin)), 750e18, "out of the basin");
        assertEq(jtrsy.totalSupply(), 750e18, "and the jTRSY position shrank by what was redeemed");
    }

    /// @dev With several underlying positions the route walks them in order, taking what each can
    ///      cover, so one exit can be funded out of two structures at once.
    function testADrawWalksTheRoutesInOrder() public {
        address[] memory both = new address[](2);
        both[0] = address(jtrsyVault);
        both[1] = address(otherVault);
        _configure(both);

        _hold(jtrsy, 300e18);
        _hold(other, 500e18);
        basin.fund(1_000e18);

        vm.prank(topVault);
        route.provide(topVault, 500e18);

        assertEq(usdc.balanceOf(topVault), 500e18, "funded in full");
        assertEq(jtrsy.totalSupply(), 0, "the first route was exhausted");
        assertEq(other.totalSupply(), 300e18, "and the second covered the remainder");
    }

    /// @dev All-or-nothing, like every liquidity route: a draw beyond what the positions can raise
    ///      fails rather than half-funding the exit.
    function testADrawBeyondTheHeldPositionsReverts() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 100e18);
        basin.fund(1_000e18);

        vm.prank(topVault);
        vm.expectRevert(IVaultLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(topVault, 500e18);
    }

    /// @dev And if the venue at the bottom is dry, the failure propagates up rather than the top-level
    ///      exit quietly settling for less.
    function testADryVenueFailsTheWholeChain() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 1_000e18);

        vm.prank(topVault);
        vm.expectRevert("basin dry");
        route.provide(topVault, 250e18);
    }

    /// @dev The configured route list is a full replacement, and it is the only way to see what a
    ///      vault will actually draw on before it draws.
    function testTheConfiguredRoutesAreReadable() public {
        assertEq(route.routes(topVault).length, 0, "nothing configured");

        address[] memory both = new address[](2);
        both[0] = address(jtrsyVault);
        both[1] = address(otherVault);
        _configure(both);

        address[] memory read = route.routes(topVault);
        assertEq(read.length, 2);
        assertEq(read[0], address(jtrsyVault), "in the order they are drawn");
        assertEq(read[1], address(otherVault));

        _configure(_one(address(otherVault)));
        read = route.routes(topVault);
        assertEq(read.length, 1, "a config update replaces the whole list");
        assertEq(read[0], address(otherVault));
    }

    /// @dev A route holding nothing contributes nothing and is stepped over, rather than failing the
    ///      draw for the routes behind it. A pool that has exited one underlying but left it in the
    ///      list would otherwise find its whole instant lane dead.
    function testADryRouteInTheWalkIsSkipped() public {
        address[] memory both = new address[](2);
        both[0] = address(jtrsyVault);
        both[1] = address(otherVault);
        _configure(both);

        // Only the second route is funded; the first holds nothing at all.
        _hold(other, 500e18);
        basin.fund(1_000e18);

        assertEq(route.available(topVault), otherVault.previewRedeem(500e18), "only the funded route counts");

        vm.prank(topVault);
        route.provide(topVault, 100e18);

        assertEq(usdc.balanceOf(topVault), 100e18, "the draw went through the route behind the dry one");
    }

    /// @dev The capacity bound is fee-aware, so the burn fits the position by construction. The
    ///      assertion is there because the two quotes come from a contract this one does not control:
    ///      an underlying that under-quotes its exit and then over-quotes the burn would otherwise
    ///      have the route try to spend shares the pool does not hold.
    function testAnUnderlyingThatMisquotesItsOwnBurnIsRefused() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);

        // The capacity it advertises is unchanged; only the burn it then asks for is inflated.
        jtrsyVault.setQuoteSkew(5_000);

        vm.prank(topVault);
        vm.expectRevert(IVaultLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(topVault, 300e18);
    }

    /// @dev `previewWithdraw` rounds the share pull up so it covers the burn, so a draw can leave
    ///      shares on the route. They belong to the pool, not to the route: whatever the redemption
    ///      does not consume goes back to the escrow and is re-noted into the holding, rather than
    ///      resting in a contract with no claim on it.
    function testShareDustFromARedemptionGoesBackToThePool() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        // The quote over-pulls by 1%, the burn takes only what it needs.
        jtrsyVault.setQuoteSkew(100);

        vm.expectEmit(true, true, true, true, address(route));
        emit IVaultLiquidityRoute.VaultRouteProvided(
            TOP_POOL, topVault, address(jtrsyVault), 100e18, 100e18, 101e18, 1e18, 100e18
        );
        vm.prank(topVault);
        route.provide(topVault, 100e18);

        assertEq(jtrsy.balanceOf(address(route)), 0, "the route keeps no shares of its own");
        assertEq(jtrsy.balanceOf(topEscrow), 200e18, "only the burn left the escrow");
    }

    /// @dev A draw reports what it cost the pool, the underlying's exit fee: the burned shares' worth at the
    ///      underlying's price beside what they fetched, so an instant policy can price its own exit fee from it.
    function testADrawReportsWhatItCost() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        jtrsyVault.setExitFee(100);

        // 100 out at a 1% fee burns 101 shares worth 101 at par: the draw cost 1
        vm.expectEmit(true, true, true, true, address(route));
        emit IVaultLiquidityRoute.VaultRouteProvided(
            TOP_POOL, topVault, address(jtrsyVault), 100e18, 100e18, 101e18, 0, 101e18
        );
        vm.prank(topVault);
        route.provide(topVault, 100e18);
    }

    /// @dev An underlying that prices nothing reports no value rather than failing the draw.
    function testADrawFromAnUnderlyingThatGivesNoPriceReportsNoValue() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        jtrsyVault.setExitFee(100);
        vm.mockCallRevert(address(jtrsyVault), abi.encodeWithSelector(UnderlyingVault.convertToAssets.selector), "");

        vm.expectEmit(true, true, true, true, address(route));
        emit IVaultLiquidityRoute.VaultRouteProvided(
            TOP_POOL, topVault, address(jtrsyVault), 100e18, 100e18, 101e18, 0, 0
        );
        vm.prank(topVault);
        route.provide(topVault, 100e18);
    }

    /// @dev The route is one contract serving every pool, so what it holds at the start of a draw is
    ///      not the drawing pool's: only what this draw released and the burn left over goes back.
    ///      Nor does it leave the underlying an allowance over its balance once the draw is done.
    function testADrawReturnsOnlyWhatItReleased() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        jtrsyVault.setQuoteSkew(100);

        // Shares on the route that this draw did not release, e.g. another pool's in flight.
        jtrsy.mint(address(route), 50e18);

        vm.prank(topVault);
        route.provide(topVault, 100e18);

        assertEq(jtrsy.balanceOf(address(route)), 50e18, "what the draw did not release stays put");
        assertEq(jtrsy.balanceOf(topEscrow), 200e18, "the escrow got back exactly its own dust");
        assertEq(jtrsy.allowance(address(route), address(jtrsyVault)), 0, "no allowance outlives the draw");
    }

    //----------------------------------------------------------------------------------------------
    // What the underlying answers
    //----------------------------------------------------------------------------------------------

    /// @dev The registry binds a linked contract to its pool, not to any code, so an underlying can
    ///      name any token as its `share()`. The token released is the registry's for the underlying's
    ///      share class: an underlying registered on jTRSY's share class that names another token this
    ///      pool holds gets nothing of it.
    function testTheReleasedTokenIsTheRegistrysNotTheUnderlyings() public {
        // Answers `share()` with OTHER, while the registry has it on jTRSY's share class.
        UnderlyingVault impostor = new UnderlyingVault(other, usdc, jtrsyEscrow, 1e18);
        impostor.setSource(address(basin));
        _register(address(impostor), JTRSY_POOL, JTRSY_SC, address(usdc));
        _configure(_one(address(impostor)));

        _hold(other, 500e18);
        basin.fund(1_000e18);

        assertEq(route.available(topVault), 0, "the pool holds none of the registry's token");

        vm.prank(topVault);
        vm.expectRevert(IVaultLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(topVault, 100e18);
        assertEq(other.balanceOf(topEscrow), 500e18, "the token it named never left the escrow");
    }

    /// @dev The vault notes the drawn amount as deposited once `provide` returns, so a payout the
    ///      underlying only claims to have made would be paid out of whatever else the escrow holds.
    function testAnUnderlyingThatUnderpaysIsRefused() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        jtrsyVault.setShortfall(1);

        vm.prank(topVault);
        vm.expectRevert(IVaultLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(topVault, 100e18);
    }

    /// @dev `available` must not revert: it backs the top vault's `max*` and its whole instant lane,
    ///      escrow liquidity included. An underlying whose quotes revert (the real vault's do on an
    ///      invalid price) counts as no capacity, and the routes behind it still count and still draw.
    function testAnUnderlyingThatCannotQuoteCountsAsNothing() public {
        address[] memory both = new address[](2);
        both[0] = address(jtrsyVault);
        both[1] = address(otherVault);
        _configure(both);
        _hold(jtrsy, 300e18);
        _hold(other, 500e18);
        basin.fund(1_000e18);

        jtrsyVault.setBroken(true);
        assertEq(route.available(topVault), 500e18, "only the route that can quote counts");

        vm.prank(topVault);
        route.provide(topVault, 200e18);
        assertEq(usdc.balanceOf(topVault), 200e18, "drawn from the route behind it");
        assertEq(jtrsy.balanceOf(topEscrow), 300e18, "the broken route was not touched");
    }

    /// @dev A share token that would refuse the release, such as one that froze the route, makes the
    ///      route undrawable, so it reports no capacity rather than a line every draw on it reverts.
    function testARouteTheShareTokenRefusesCountsAsNothing() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        assertEq(route.available(topVault), 300e18, "drawable before the freeze");

        jtrsy.freeze(address(route));
        assertEq(route.available(topVault), 0, "nothing once the route cannot take delivery");
    }

    //----------------------------------------------------------------------------------------------
    // Manager role, routes and balance measurement
    //----------------------------------------------------------------------------------------------

    /// @dev Releasing the pool's holdings takes the manager role, so a route the pool never made a
    ///      manager, or removed, advertises nothing rather than capacity every draw reverts on.
    function testARouteThatIsNotAManagerReportsNoCapacity() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        assertEq(route.available(topVault), 300e18);

        vm.mockCall(
            spokeRegistry, abi.encodeCall(ISpokeRegistry.manager, (TOP_POOL, address(route))), abi.encode(false)
        );
        assertEq(route.available(topVault), 0, "not a manager, nothing drawable");
    }

    /// @dev The routes are the pool's choice, so their number is not bounded here. Each is a share class of its own,
    ///      with a position of its own.
    function testAnyNumberOfUnderlying() public {
        address[] memory routes = new address[](8);
        for (uint256 i; i < routes.length; i++) {
            routes[i] = address(new IsContract());
            ShareClassId scId = ShareClassId.wrap(bytes16(uint128(i + 1)));
            Token shareToken = new Token("S", 18);
            _register(routes[i], JTRSY_POOL, scId, address(usdc));
            _shareClass(JTRSY_POOL, scId, address(shareToken));
            _hold(shareToken, 100e18);
            vm.mockCall(routes[i], abi.encodeWithSelector(IAsyncVault.withdrawCapacity.selector), abi.encode(100e18));
            vm.mockCall(routes[i], abi.encodeWithSelector(IERC7575.previewRedeem.selector), abi.encode(100e18));
        }
        _configure(routes);

        assertEq(route.routes(topVault).length, 8);
        assertEq(route.available(topVault), 100e18 * 8, "each entry quotes its own capacity");
    }

    /// @dev A quote into another pool's vault is bounded, so one that never ends reads as no capacity and costs
    ///      the top vault's views `QUOTE_GAS`, not everything they were given.
    /// @dev A neighbour that answers with the maximum is still an answer: it must not overflow the sum and fail
    ///      the capacity read of the vault routing to it.
    function testAnUnderlyingQuotingTheMaximumDoesNotOverflowTheSum() public {
        address maxed = address(new MaxQuotingUnderlying());
        ShareClassId maxedSc = ShareClassId.wrap(bytes16("maxed"));
        Token maxedShare = new Token("M", 18);
        _register(maxed, JTRSY_POOL, maxedSc, address(usdc));
        _shareClass(JTRSY_POOL, maxedSc, address(maxedShare));
        _hold(maxedShare, 400e18);
        address[] memory both = new address[](2);
        both[0] = address(jtrsyVault);
        both[1] = maxed;
        _configure(both);
        _hold(jtrsy, 400e18);

        assertEq(route.available(topVault), type(uint128).max, "saturates instead of reverting");
    }

    function testAnUnderlyingThatBurnsAllItsGasReadsAsNoCapacity() public {
        address burner = address(new GasBurningUnderlying());
        _register(burner, JTRSY_POOL, JTRSY_SC, address(usdc));
        _configure(_one(burner));
        _hold(jtrsy, 300e18);

        uint256 gasBefore = gasleft();
        uint256 capacity = route.available{gas: 3_000_000}(topVault);
        uint256 spent = gasBefore - gasleft();

        assertEq(capacity, 0, "no answer reads as nothing");
        assertLt(spent, route.QUOTE_GAS() + 200_000, "bounded by the quote cap");
    }

    function testADuplicateRouteIsRefused() public {
        address[] memory twice = new address[](2);
        twice[0] = address(jtrsyVault);
        twice[1] = address(jtrsyVault);
        _consent(address(jtrsyVault), true);

        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.DuplicateRoute.selector);
        route.fromHub(TOP_POOL, _routesPayload(twice));
    }

    /// @dev Two parallel vaults on one share class read the same position, so listing both would offer it twice:
    ///      `available` would report double what the escrow holds and a draw past the position would revert.
    function testTwoVaultsOnOneShareClassAreRefused() public {
        address sibling = makeAddr("jtrsySibling");
        _register(sibling, JTRSY_POOL, JTRSY_SC, address(usdc));
        _consent(address(jtrsyVault), true);
        _consent(sibling, true);
        address[] memory parallel = new address[](2);
        parallel[0] = address(jtrsyVault);
        parallel[1] = sibling;

        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.DuplicateRoute.selector);
        route.fromHub(TOP_POOL, _routesPayload(parallel));
    }

    function testTheVaultCannotRouteToItself() public {
        vm.prank(envoy);
        vm.expectRevert(IVaultLiquidityRoute.SelfRoute.selector);
        route.fromHub(TOP_POOL, _routesPayload(_one(topVault)));
    }

    /// @dev The payout is measured at the drawing vault, not at the top pool's escrow, which a
    ///      reentrant underlying could fill through a sibling vault's deposit and so pass off as paid.
    function testAnInflowIntoTheEscrowIsNotAPayout() public {
        _configure(_one(address(jtrsyVault)));
        _hold(jtrsy, 300e18);
        basin.fund(1_000e18);
        jtrsyVault.setMisdirect(topEscrow);

        vm.prank(topVault);
        vm.expectRevert(IVaultLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(topVault, 100e18);
    }

    /// @dev A quote is a one-word read: an underlying answering with a large payload costs the caller no more than
    ///      the underlying itself spends producing it, and the first word is still read.
    function testAReturnBombUnderlyingIsNotCopiedIntoTheCaller() public {
        address bomb = address(new ReturnBombUnderlying());
        _register(bomb, JTRSY_POOL, JTRSY_SC, address(usdc));
        _configure(_one(bomb));
        _hold(jtrsy, 300e18);

        uint256 gasBefore = gasleft();
        uint256 capacity = route.available{gas: 3_000_000}(topVault);
        uint256 spent = gasBefore - gasleft();

        assertEq(capacity, 1, "the first word of the answer is read");
        assertLt(spent, 450_000, "the callee pays for its payload, the caller does not copy it");
    }

    /// @dev Tokens sent to the route by mistake are not any pool's, so Root can return them.
    function testRootRecoversTokensSentToTheRoute() public {
        usdc.mint(address(route), 5e6);

        vm.prank(makeAddr("root"));
        route.recoverTokens(address(usdc), makeAddr("outsider"), 5e6);

        assertEq(usdc.balanceOf(makeAddr("outsider")), 5e6);
        assertEq(usdc.balanceOf(address(route)), 0);
    }

    function testOnlyRootRecoversTokens() public {
        usdc.mint(address(route), 5e6);

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        route.recoverTokens(address(usdc), makeAddr("outsider"), 5e6);
    }
}
