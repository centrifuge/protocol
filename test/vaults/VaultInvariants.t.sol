// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BucketReference} from "./BucketReference.sol";
import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";

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
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {PerInvestorPolicy, PerPeriodPolicy, PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {
    IAsyncVault,
    IVaultErrors,
    Bucket,
    VaultConfig,
    VaultPlugins,
    REASON_REDEEM
} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev A spoke that keeps the books instead of returning a canned answer. `vm.mockCall` makes every
///      escrow call succeed, which is what the unit tests want and what makes them unable to say
///      anything about backing: a vault could credit a claim the escrow never received and no
///      assertion would notice.
///
///      This records what the vault actually asks for — noted assets, reservations per reason, shares
///      issued and parked — so the invariants can be stated over the escrow's side of the ledger. It
///      is the accounting only; the token transfers themselves are the mocks' business.
contract TrackingSpoke {
    address public immutable escrowAddress;
    ISpokeRegistry public immutable spokeRegistryAddress;

    /// @dev Assets noted into the holding, less anything withdrawn out of it
    uint128 public noted;
    /// @dev Reservations by reason, the escrow's record of what is earmarked and for what
    mapping(bytes32 reason => uint128) public reserved;
    /// @dev Shares in existence, and the subset parked in the escrow awaiting a claim
    uint128 public shareSupply;
    uint128 public escrowShares;
    /// @dev Everything ever paid out of the escrow to somebody, and everything ever put in
    uint128 public paidOut;
    uint128 public takenIn;

    error Underflow(string what);

    constructor(address escrow_, ISpokeRegistry registry) {
        escrowAddress = escrow_;
        spokeRegistryAddress = registry;
    }

    function escrow(PoolId) external view returns (address) {
        return escrowAddress;
    }

    function spokeRegistry() external view returns (ISpokeRegistry) {
        return spokeRegistryAddress;
    }

    function noteDeposit(PoolId, ShareClassId, address, uint256, uint128 amount) external {
        noted += amount;
        takenIn += amount;
    }

    function reserve(PoolId, ShareClassId, address, uint256, uint128 amount, address, bytes32 reason) external {
        require(noted >= amount, Underflow("reserve beyond the holding"));
        noted -= amount;
        reserved[reason] += amount;
    }

    function unreserve(PoolId, ShareClassId, address, uint256, uint128 amount, address, bytes32 reason) external {
        require(reserved[reason] >= amount, Underflow("unreserve beyond the reservation"));
        reserved[reason] -= amount;
        noted += amount;
    }

    function withdraw(PoolId, ShareClassId, address, uint256, address, uint128 amount) external {
        require(noted >= amount, Underflow("withdraw beyond the holding"));
        noted -= amount;
        paidOut += amount;
    }

    function withdrawReserved(PoolId, ShareClassId, address, uint256, address, uint128 amount, address, bytes32 reason)
        external
    {
        require(reserved[reason] >= amount, Underflow("withdraw beyond the reservation"));
        reserved[reason] -= amount;
        paidOut += amount;
    }

    function issue(PoolId, ShareClassId, address to, uint128 shares) external {
        shareSupply += shares;
        if (to == escrowAddress) escrowShares += shares;
    }

    function revoke(PoolId, ShareClassId, uint128 shares) external {
        require(shareSupply >= shares, Underflow("revoke beyond the supply"));
        shareSupply -= shares;
    }

    function withdrawShares(PoolId, ShareClassId, address, uint128 amount) external {
        require(escrowShares >= amount, Underflow("claimed shares the escrow never held"));
        escrowShares -= amount;
    }

    function transferSharesFrom(PoolId, ShareClassId, address, address, address to, uint256 amount) external {
        if (to == escrowAddress) escrowShares += uint128(amount);
        else if (escrowShares >= uint128(amount)) escrowShares -= uint128(amount);
    }

    function availableBalanceOf(PoolId, ShareClassId, address, uint256) external view returns (uint128) {
        return noted;
    }
}

/// @dev Drives one vault through the operations an investor, a keeper and a request manager perform
///      on it, in whatever order the fuzzer picks, against the tracking spoke above. Amounts scale with
///      the suite's decimals and are bounded to what the position can actually support; the calls
///      that can still legitimately fail (claiming nothing, settling a spent or unflushed bucket,
///      flushing an open window) are swallowed and counted: what must hold is the accounting below,
///      not that every individual call succeeds. A claim of the full maximum is not one of them.
contract VaultInvariantHandler is Test {
    IAsyncVault public v;
    TrackingSpoke public spoke;

    address public router = makeAddr("requestManager");
    address[3] public actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];

    uint256 public immutable assetUnit;
    uint256 public immutable shareUnit;
    /// @dev Whether requests may be dust (down to one wei), so shared slices can floor to zero
    bool public immutable dust;

    /// @dev The first full claim that did not succeed or did not pay exactly its maximum
    string public broken;

    /// @dev Reachability counters. An invariant over a state the fuzzer never enters is vacuous, and
    ///      this suite's redeem path in particular is only reachable after a deposit has settled.
    uint256 public settledDeposits;
    uint256 public settledRedeems;
    uint256 public depositClaims;
    uint256 public redeemClaims;
    uint256 public transfers;
    uint256 public flushes;
    uint256 public cancels;
    /// @dev Settlements that landed on a bucket more than one controller held a stake in
    uint256 public sharedSettlements;
    mapping(bytes4 => uint256) public succeeded;
    mapping(bytes4 => uint256) public rejected;

    /// @dev Buckets this handler has opened, so settlement can only be aimed at real ones
    uint96[] public openBuckets;
    mapping(uint96 => bool) internal _known;
    mapping(uint96 => bool) public isDepositBucket;

    constructor(IAsyncVault v_, TrackingSpoke spoke_, uint8 assetDecimals, uint8 shareDecimals, bool dust_) {
        v = v_;
        spoke = spoke_;
        assetUnit = 10 ** assetDecimals;
        shareUnit = 10 ** shareDecimals;
        dust = dust_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev A bucket that can still change, or zero. Spent buckets nobody holds a stake in any more
    ///      are dropped as they are found, which keeps both the aim and the per-call checks over the
    ///      handful of buckets in play rather than every one a run ever opened.
    function _bucket(uint256 seed) internal returns (uint96 localId) {
        while (openBuckets.length != 0) {
            uint256 i = seed % openBuckets.length;
            localId = openBuckets[i];
            if (BucketReference.outstanding(v.bucket(localId)) != 0 || _stakes(localId) != 0) return localId;
            openBuckets[i] = openBuckets[openBuckets.length - 1];
            openBuckets.pop();
        }
        return 0;
    }

    function _record(bool ok) internal {
        if (ok) succeeded[msg.sig]++;
        else rejected[msg.sig]++;
    }

    function _remember(uint256 requestId, bool isDeposit) internal {
        uint96 localId = uint96(requestId);
        if (_known[localId]) return;
        _known[localId] = true;
        isDepositBucket[localId] = isDeposit;
        openBuckets.push(localId);
    }

    function bucketCount() external view returns (uint256) {
        return openBuckets.length;
    }

    function _stakes(uint96 localId) internal view returns (uint256 stakes) {
        for (uint256 i; i < actors.length; i++) {
            if (v.contribution(localId, actors[i]).amount != 0) stakes++;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Investor actions
    //----------------------------------------------------------------------------------------------

    function requestDeposit(uint256 actorSeed, uint128 assets) external {
        assets = _amount(assets, assetUnit);
        address who = _actor(actorSeed);

        vm.prank(who);
        try v.requestDeposit(assets, who, who) returns (uint256 requestId) {
            _remember(requestId, true);
            _record(true);
        } catch {
            _record(false);
        }
    }

    function requestRedeem(uint256 actorSeed, uint128 shares) external {
        shares = _amount(shares, shareUnit);
        address who = _actor(actorSeed);

        vm.prank(who);
        try v.requestRedeem(shares, who, who) returns (uint256 requestId) {
            _remember(requestId, false);
            _record(true);
        } catch {
            _record(false);
        }
    }

    /// @dev One request in four is dust when the suite allows it, else at least one whole unit.
    function _amount(uint128 seed, uint256 unit) internal view returns (uint128) {
        if (dust && seed % 4 == 0) return uint128(_bound(seed >> 2, 1, 100));
        return uint128(_bound(seed, unit, 1_000_000 * unit));
    }

    /// @dev ERC-7540 prop 9 on the deposit side: claiming exactly `maxMint` succeeds and moves exactly
    ///      that many shares, through the 3-arg or the 2-arg form, and so does `deposit(maxDeposit)`: the
    ///      ledger keeps exact totals, so a claim of the whole asset balance takes every filled share and
    ///      leaves only refunded ones, which carry no assets.
    function claimDeposit(uint256 actorSeed, uint256 mode) external {
        address who = _actor(actorSeed);
        uint256 claimable = v.maxMint(who);
        if (claimable == 0) return;
        uint256 ledger = v.claimableMint(who);
        _require(ledger == claimable, "maxMint is not the claimable ledger");

        if (mode % 3 == 2) return _claimMaxDeposit(who, ledger);

        uint128 parked = spoke.escrowShares();
        vm.prank(who);
        (bool ok,) = address(v)
            .call(
                mode % 3 == 0
                    ? abi.encodeWithSignature("mint(uint256,address,address)", claimable, who, who)
                    : abi.encodeWithSignature("mint(uint256,address)", claimable, who)
            );
        _require(ok, "claiming the full maxMint reverted");
        if (!ok) return;
        _require(parked - spoke.escrowShares() == claimable, "a full mint did not pay exactly maxMint");
        ledger = v.claimableMint(who);
        _require(ledger == 0, "a full mint left shares claimable");
        depositClaims++;
        _record(true);
    }

    function _claimMaxDeposit(address who, uint256 ledger) internal {
        uint256 assets = v.maxDeposit(who);
        if (assets == 0) return;
        uint128 parked = spoke.escrowShares();
        vm.prank(who);
        (bool ok,) = address(v).call(abi.encodeWithSignature("deposit(uint256,address,address)", assets, who, who));
        _require(ok, "deposit(maxDeposit) reverted");
        if (!ok) return;
        uint256 left = v.claimableMint(who);
        _require(parked - spoke.escrowShares() + left == ledger, "deposit(maxDeposit) did not pay its part exactly");
        _require(v.maxDeposit(who) == 0, "deposit(maxDeposit) left assets claimable");
        depositClaims++;
        _record(true);
    }

    /// @dev ERC-7540 prop 9 on the redeem side: claiming exactly `maxWithdraw` succeeds and pays exactly
    ///      those assets, through the 3-arg or the 2-arg form, and `redeem(maxRedeem)` pays every filled
    ///      asset, leaving only refunded ones, which no shares stand behind.
    function claimRedeem(uint256 actorSeed, uint256 mode) external {
        address who = _actor(actorSeed);
        uint256 claimable = v.maxWithdraw(who);
        if (claimable == 0) return;
        uint256 ledger = v.claimableWithdraw(who);
        _require(ledger == claimable, "maxWithdraw is not the claimable ledger");

        uint256 shares = v.maxRedeem(who);
        bool byShares = mode % 4 >= 2 && shares != 0;
        uint128 paid = spoke.paidOut();
        vm.prank(who);
        (bool ok,) = address(v)
            .call(
                byShares
                    ? mode % 2 == 0
                        ? abi.encodeWithSignature("redeem(uint256,address,address)", shares, who, who)
                        : abi.encodeWithSignature("redeem(uint256,address)", shares, who)
                    : mode % 2 == 0
                        ? abi.encodeWithSignature("withdraw(uint256,address,address)", claimable, who, who)
                        : abi.encodeWithSignature("withdraw(uint256,address)", claimable, who)
            );
        _require(ok, "claiming the full maxWithdraw or maxRedeem reverted");
        if (!ok) return;
        paid = spoke.paidOut() - paid;
        ledger = v.claimableWithdraw(who);
        _require(paid + ledger == claimable, "a full claim did not pay its part exactly");
        _require(byShares ? v.maxRedeem(who) == 0 : ledger == 0, "a full claim left its unit claimable");
        redeemClaims++;
        _record(true);
    }

    function _require(bool condition, string memory reason) internal {
        if (!condition && bytes(broken).length == 0) broken = reason;
    }

    function foldRequest(uint256 actorSeed, uint256 bucketSeed) external {
        uint96 localId = _bucket(bucketSeed);
        if (localId == 0) return;
        try v.foldRequest(localId, _actor(actorSeed)) {
            _record(true);
        } catch {
            _record(false);
        }
    }

    /// @dev ERC-8161: hands the unsettled remainder of a request to another controller. The vault folds
    ///      the sender out first, so only what is still pending moves.
    function transferRequest(uint256 fromSeed, uint256 toSeed, uint256 bucketSeed) external {
        uint96 localId = _bucket(bucketSeed);
        if (localId == 0) return;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to || v.contribution(localId, from).amount == 0) return;

        uint256 requestId = (uint256(uint160(address(v))) << 96) | localId;
        try this.doTransfer(requestId, from, to, isDepositBucket[localId]) {
            transfers++;
            _record(true);
        } catch {
            _record(false);
        }
    }

    function doTransfer(uint256 requestId, address from, address to, bool isDeposit) external {
        require(msg.sender == address(this), "handler only");
        vm.prank(from);
        if (isDeposit) v.transferDepositRequest(requestId, from, to);
        else v.transferRedeemRequest(requestId, from, to);
    }

    //----------------------------------------------------------------------------------------------
    // Keeper actions
    //----------------------------------------------------------------------------------------------

    /// @dev Time only matters to a batching policy: it closes the window a bucket collects into.
    function warp(uint32 secs) external {
        vm.warp(block.timestamp + _bound(secs, 1, 2 days));
    }

    function flush(uint256 bucketSeed) external {
        uint96 localId = _bucket(bucketSeed);
        if (localId == 0) return;
        try v.flushRequest(localId) {
            flushes++;
            _record(true);
        } catch {
            _record(false);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Request manager actions
    //----------------------------------------------------------------------------------------------

    /// @dev The whole deposit settlement, in the order the hub sends it: release the reservation into
    ///      the holding, mint the shares into the escrow, then make them claimable.
    function settleDeposit(uint256 bucketSeed, uint128 assets, uint128 shares) external {
        uint96 localId = _bucket(bucketSeed);
        if (localId == 0) return;
        if (!isDepositBucket[localId]) return;

        Bucket memory b = v.bucket(localId);
        uint128 sent = BucketReference.outstanding(b) - b.queued;
        if (sent == 0) return;

        // Full settlement half of the time, so buckets actually complete
        assets = assets % 2 == 0 ? sent : uint128(_bound(assets, 1, sent));
        shares = uint128(_bound(shares, 1, 1_000_000 * shareUnit));

        // All three legs or none. They are separate hub messages, but they arrive in order and the
        // gateway stops at the first failure, so a fulfillment never lands without its issuance.
        try this.driveDepositSettlement(localId, assets, shares) {
            settledDeposits++;
            if (_stakes(localId) > 1) sharedSettlements++;
            _record(true);
        } catch {
            _record(false);
        }
    }

    /// @dev The redeem settlement: reserve the payout, burn the escrowed shares, then make it claimable.
    function settleRedeem(uint256 bucketSeed, uint128 shares, uint128 assets) external {
        uint96 localId = _bucket(bucketSeed);
        if (localId == 0) return;
        if (isDepositBucket[localId]) return;

        Bucket memory b = v.bucket(localId);
        uint128 sent = BucketReference.outstanding(b) - b.queued;
        if (sent == 0) return;

        // A redemption burns shares that exist and pays assets the escrow is holding, so it can only
        // follow a settled deposit. Bounding to both is what lets the fuzzer reach the state at all:
        // unbounded, every redeem settlement reverted on the revocation and the ledger stayed empty.
        uint128 backing = spoke.noted();
        uint128 supply = spoke.shareSupply();
        if (backing == 0 || supply == 0) return;

        uint128 most = sent < supply ? sent : supply;
        shares = shares % 2 == 0 ? most : uint128(_bound(shares, 1, most));
        assets = uint128(_bound(assets, 1, backing));

        try this.driveRedeemSettlement(localId, assets, shares) {
            settledRedeems++;
            if (_stakes(localId) > 1) sharedSettlements++;
            _record(true);
        } catch {
            _record(false);
        }
    }

    function cancelDeposit(uint256 bucketSeed, uint128 gross, uint128 fee) external {
        _cancel(bucketSeed, gross, fee, true);
    }

    function cancelRedeem(uint256 bucketSeed, uint128 gross, uint128 fee) external {
        _cancel(bucketSeed, gross, fee, false);
    }

    function _cancel(uint256 bucketSeed, uint128 gross, uint128 fee, bool isDeposit) internal {
        uint96 localId = _bucket(bucketSeed);
        if (localId == 0) return;
        if (isDepositBucket[localId] != isDeposit) return;

        Bucket memory b = v.bucket(localId);
        uint128 sent = BucketReference.outstanding(b) - b.queued;
        if (sent == 0) return;

        gross = uint128(_bound(gross, 1, sent));
        uint128 net = gross - uint128(_bound(fee, 0, gross - 1));

        try this.doCancel(localId, gross, net, isDeposit) {
            cancels++;
            _record(true);
        } catch {
            _record(false);
        }
    }

    function doCancel(uint96 localId, uint128 gross, uint128 net, bool isDeposit) external {
        require(msg.sender == address(this), "handler only");
        vm.prank(router);
        if (isDeposit) IVaultDepositCallbacks(address(v)).cancelDeposit(localId, gross, net);
        else IVaultRedeemCallbacks(address(v)).cancelRedeem(localId, gross, net);
    }

    /// @dev External so the legs share one revert boundary. The prank lives inside: pranking around
    ///      the self-call would make this frame's own caller the request manager, not the handler.
    function driveDepositSettlement(uint96 localId, uint128 assets, uint128 shares) external {
        require(msg.sender == address(this), "handler only");

        vm.startPrank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(localId, assets);
        IVaultDepositCallbacks(address(v)).issueShares(localId, shares);
        IVaultDepositCallbacks(address(v)).fulfillDepositRequest(localId, assets, shares);
        vm.stopPrank();
    }

    function driveRedeemSettlement(uint96 localId, uint128 assets, uint128 shares) external {
        require(msg.sender == address(this), "handler only");

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, assets, shares);
        IVaultRedeemCallbacks(address(v)).fulfillRedeemRequest(localId, assets, shares);
        vm.stopPrank();
    }

    //----------------------------------------------------------------------------------------------
    // Views for the invariants
    //----------------------------------------------------------------------------------------------

    function claimableRedeemAssets() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; i++) {
            total += v.maxWithdraw(actors[i]);
        }
    }

    function claimableDepositShares() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; i++) {
            total += v.maxMint(actors[i]);
        }
    }

    function pendingDepositAssets() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; i++) {
            total += v.pendingDepositRequest(0, actors[i]);
        }
    }

    /// @dev Every bucket still in play keeps its stakes inside its denominator, and its pending inside
    ///      both. A dropped bucket is spent and stakeless, so nothing can change it any more.
    function checkBuckets() external view {
        for (uint256 i; i < openBuckets.length; i++) {
            uint96 localId = openBuckets[i];
            Bucket memory b = v.bucket(localId);
            uint256 stakes;
            for (uint256 a; a < actors.length; a++) {
                stakes += v.contribution(localId, actors[a]).amount;
            }
            require(stakes <= b.total, "stakes exceed the bucket's denominator");
            require(b.queued <= BucketReference.outstanding(b), "less outstanding than queued");
        }
    }

    function logStats() external view {
        bytes4[13] memory sels = [
            this.requestDeposit.selector,
            this.requestRedeem.selector,
            this.claimDeposit.selector,
            this.claimRedeem.selector,
            this.foldRequest.selector,
            this.transferRequest.selector,
            this.flush.selector,
            this.settleDeposit.selector,
            this.settleRedeem.selector,
            this.cancelDeposit.selector,
            this.cancelRedeem.selector,
            this.warp.selector,
            this.flush.selector
        ];
        string[13] memory names = [
            "requestDeposit",
            "requestRedeem",
            "claimDeposit",
            "claimRedeem",
            "foldRequest",
            "transferRequest",
            "flush",
            "settleDeposit",
            "settleRedeem",
            "cancelDeposit",
            "cancelRedeem",
            "warp",
            "flush"
        ];
        for (uint256 i; i < 11; i++) {
            console.log(names[i], succeeded[sels[i]], rejected[sels[i]]);
        }
        console.log("shared settlements / transfers / buckets", sharedSettlements, transfers, openBuckets.length);
    }
}

/// @dev The vault's own accounting, over arbitrary interleavings of requests, settlements, transfers
///      and claims. `BucketLibInvariants` does this for the settlement library; this does it one
///      level up, where the escrow is, and states the properties the specification calls out as the
///      backing of each side: nothing is claimable that the escrow is not holding for it.
///
///      Concrete suites below vary what the base leaves open: the request policy (one bucket per
///      request, or shared per-period windows), the asset and share decimals, and the oracle's prices.
///      Each checks every tenth call: the views behind the checks walk every controller's open
///      requests and dominate a run's cost roughly tenfold, while a broken backing stays broken until
///      the next check. Runs and depth come from the profile.
abstract contract VaultInvariantsBase is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    VaultInvariantHandler handler;
    TrackingSpoke spoke;
    IAsyncVault v;

    address spokeRegistry = address(new IsContract());
    address oracle = address(new IsContract());
    address escrow = address(new AmpleEscrow());

    function _decimals() internal pure virtual returns (uint8 assetDecimals, uint8 shareDecimals);

    function _prices() internal pure virtual returns (D18 pricePoolPerAsset, D18 pricePoolPerShare);

    /// @dev Whether requests may be dust, so a shared window's slices can floor to zero in one unit
    function _dust() internal pure virtual returns (bool) {
        return false;
    }

    function _policy() internal virtual returns (IRequestPolicy);

    function setUp() public {
        vm.warp(1_700_000_000);
        spoke = new TrackingSpoke(escrow, ISpokeRegistry(spokeRegistry));

        (uint8 assetDecimals, uint8 shareDecimals) = _decimals();
        IRequestPolicy requestPolicy = _policy();

        MockERC20 asset = new MockERC20(assetDecimals);
        Vault vault = new Vault(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            IShareToken(address(new MockShareToken(shareDecimals))),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(address(spoke)),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    // No instant lane: this suite is about the async ledger and its backing, and an
                    // instant deposit would put assets in the escrow that back no request.
                    instantPolicy: IInstantPolicy(address(0)),
                    requestPolicy: requestPolicy,
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
        v = IAsyncVault(address(vault));

        (D18 ppa, D18 pps) = _prices();
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ppa, pps, true));

        handler = new VaultInvariantHandler(v, spoke, assetDecimals, shareDecimals, _dust());
        vm.mockCall(
            spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(handler.router())
        );
        vm.mockCall(handler.router(), abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        vm.mockCall(handler.router(), abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.requestDeposit.selector;
        selectors[1] = handler.requestRedeem.selector;
        selectors[2] = handler.claimDeposit.selector;
        selectors[3] = handler.claimRedeem.selector;
        selectors[4] = handler.foldRequest.selector;
        selectors[5] = handler.transferRequest.selector;
        selectors[6] = handler.warp.selector;
        selectors[7] = handler.flush.selector;
        selectors[8] = handler.settleDeposit.selector;
        selectors[9] = handler.settleRedeem.selector;
        selectors[10] = handler.cancelDeposit.selector;
        selectors[11] = handler.cancelRedeem.selector;
        selectors[12] = handler.settleDeposit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function afterInvariant() public view {
        handler.logStats();
    }

    /// @dev The redeem side's solvency statement. Every asset a controller may withdraw was reserved
    ///      for them under `REASON_REDEEM` when the hub revoked their shares, and a claim draws from
    ///      that reservation and nothing else. If the ledger could ever exceed it, the last claimant
    ///      would find the escrow empty.
    function invariant_theRedeemLedgerIsBackedByTheReservation() public view {
        assertLe(
            handler.claimableRedeemAssets(),
            spoke.reserved(REASON_REDEEM),
            "more is claimable than the escrow has reserved for it"
        );
    }

    /// @dev The deposit side's twin. Fulfilled shares are minted to the escrow and parked there until
    ///      claimed, so what is claimable can never exceed what is parked.
    function invariant_theDepositLedgerIsBackedByParkedShares() public view {
        assertLe(
            handler.claimableDepositShares(),
            spoke.escrowShares(),
            "more shares are claimable than the escrow is holding"
        );
    }

    /// @dev Nothing leaves the escrow that did not first enter it. Fees and floor-rounding dust make
    ///      this an inequality rather than an equality, and it is the direction that matters: value can
    ///      be left behind in the pool, never conjured out of it.
    function invariant_nothingIsPaidOutThatWasNotPaidIn() public view {
        assertLe(spoke.paidOut(), spoke.takenIn(), "the escrow paid out more than it ever received");
    }

    /// @dev What is reserved and what is still in the holding are both drawn from what came in, so
    ///      their sum plus what has already left cannot exceed it.
    function invariant_theEscrowBooksBalance() public view {
        assertLe(
            uint256(spoke.noted()) + spoke.reserved(REASON_REDEEM) + spoke.paidOut(),
            spoke.takenIn(),
            "the escrow's books do not add up"
        );
    }

    /// @dev A request's assets sit in the escrow from the moment it is made, so the aggregate pending
    ///      is backed too — under its own per-request reservation reason rather than the flat redeem
    ///      one, which is why this is checked against what came in rather than against a single bucket.
    function invariant_pendingDepositsAreStillInTheEscrow() public view {
        assertLe(handler.pendingDepositAssets(), spoke.takenIn(), "more is pending than was ever deposited");
    }

    /// @dev Transfers and shared windows move stakes between controllers; none of it can push a
    ///      bucket's stakes past its denominator or its pending outside them.
    function invariant_bucketsStayConsistent() public view {
        handler.checkBuckets();
    }

    /// @dev Full-exit liveness, checked in the claim handlers and recorded there, since a reverting
    ///      handler call is dropped together with what it found.
    function invariant_aFullClaimPaysTheMax() public view {
        assertEq(handler.broken(), "", "a full claim failed");
    }

    function _checkAll() internal view {
        invariant_theRedeemLedgerIsBackedByTheReservation();
        invariant_theDepositLedgerIsBackedByParkedShares();
        invariant_nothingIsPaidOutThatWasNotPaidIn();
        invariant_theEscrowBooksBalance();
        invariant_pendingDepositsAreStillInTheEscrow();
        invariant_bucketsStayConsistent();
        invariant_aFullClaimPaysTheMax();
    }

    /// @dev Every invariant above is trivially true of a vault nothing ever happened to, and a random
    ///      sequence is not guaranteed to reach the interesting states. This drives the same handler
    ///      through a scripted round trip and asserts the quantities the invariants bound are actually
    ///      non-zero when they are bounded — so a change that breaks the backing fails here even if the
    ///      fuzzer misses it.
    ///
    ///      It exists because a deliberately broken vault (one that credits a redemption without
    ///      reserving the payout) passed the whole suite: no redemption had ever settled.
    function testTheInvariantsAreNotVacuous() public {
        uint256 assetUnit = handler.assetUnit();
        uint256 shareUnit = handler.shareUnit();

        handler.requestDeposit(0, uint128(1_000 * assetUnit));
        handler.requestDeposit(1, uint128(3_000 * assetUnit));
        _closeWindows();
        handler.settleDeposit(0, 0, uint128(4_000 * shareUnit));
        assertGt(handler.settledDeposits(), 0, "the deposit settled");
        assertGt(handler.claimableDepositShares(), 0, "and left shares claimable");
        assertGt(spoke.escrowShares(), 0, "backed by shares in the escrow");

        handler.claimDeposit(0, 0);
        assertGt(handler.depositClaims(), 0, "the claim went through");

        handler.requestRedeem(0, uint128(500 * shareUnit));
        handler.requestRedeem(2, uint128(100 * shareUnit));
        handler.transferRequest(2, 1, handler.bucketCount() - 1);
        assertEq(handler.transfers(), _transfers() ? 1 : 0, "a pending request changed hands where the policy lets it");
        _closeWindows();
        for (uint256 i; i < handler.bucketCount(); i++) {
            handler.settleRedeem(i, 0, uint128(300 * assetUnit));
        }
        assertGt(handler.settledRedeems(), 0, "the redemption settled");
        assertGt(handler.claimableRedeemAssets(), 0, "and left assets claimable");
        assertGt(spoke.reserved(REASON_REDEEM), 0, "backed by a reservation");

        handler.claimRedeem(0, 0);
        assertGt(handler.redeemClaims(), 0, "and it was claimable");

        _checkAll();
    }

    /// @dev Whether the policy lets a pending request change hands.
    function _transfers() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev How long a request waits before its window has closed: a day, unless a notice pushes it later.
    function _closeAfter() internal pure virtual returns (uint32) {
        return 1 days;
    }

    /// @dev A batching policy needs its window closed and flushed before the hub can answer; a
    ///      per-request one has already sent.
    function _closeWindows() internal {
        for (uint32 left = _closeAfter(); left > 0; left -= left > 2 days ? 2 days : left) {
            handler.warp(left > 2 days ? 2 days : left);
        }
        for (uint256 i; i < handler.bucketCount(); i++) {
            handler.flush(i);
        }
    }
}

/// @dev One bucket per request, six-decimal asset, eighteen-decimal share, prices at par.
/// forge-config: default.invariant.check_interval = 10
contract VaultInvariantsTest is VaultInvariantsBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }

    function _prices() internal pure override returns (D18, D18) {
        return (D18.wrap(1e18), D18.wrap(1e18));
    }

    function _policy() internal override returns (IRequestPolicy) {
        return IRequestPolicy(address(new PerRequestPolicy(true)));
    }
}

/// @dev Shared per-day windows, so several controllers hold pro-rata stakes in one bucket; eighteen
///      decimals on both sides, prices off par, and dust requests, so a slice can floor to zero shares
///      while still carrying assets, or the reverse.
/// forge-config: default.invariant.check_interval = 10
contract VaultInvariantsPerPeriodTest is VaultInvariantsBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 18);
    }

    function _prices() internal pure override returns (D18, D18) {
        return (D18.wrap(0.997e18), D18.wrap(1.2345e18));
    }

    function _policy() internal override returns (IRequestPolicy) {
        return IRequestPolicy(address(new PerPeriodPolicy(1 days, 0, 0, 0)));
    }

    function _dust() internal pure override returns (bool) {
        return true;
    }

    function testSharedWindowsAreReached() public {
        testTheInvariantsAreNotVacuous();
        assertGt(handler.sharedSettlements(), 0, "a settlement landed on a shared window");
    }
}

/// @dev A zero-decimal share against an eighteen-decimal asset, the widest gap the blend has to
///      price across, with an oracle far from par.
/// forge-config: default.invariant.check_interval = 10
contract VaultInvariantsDecimalsTest is VaultInvariantsBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 0);
    }

    function _prices() internal pure override returns (D18, D18) {
        return (D18.wrap(1e18), D18.wrap(250e18));
    }

    function _policy() internal override returns (IRequestPolicy) {
        return IRequestPolicy(address(new PerRequestPolicy(true)));
    }
}

/// @dev Dealing windows with an offset and a notice on each side, the redeem notice longer than a window: several
///      windows of a side are open at once, the next window's first request no longer sends the previous one, a
///      keeper flushes each closed window, and the horizon (the policy's `maxOpenBuckets`) holds them all.
/// forge-config: default.invariant.check_interval = 10
contract VaultInvariantsNoticeTest is VaultInvariantsBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }

    function _prices() internal pure override returns (D18, D18) {
        return (D18.wrap(1.01e18), D18.wrap(0.987e18));
    }

    function _policy() internal override returns (IRequestPolicy) {
        return IRequestPolicy(address(new PerPeriodPolicy(1 days, 7 hours, 5 hours, 30 hours)));
    }

    /// @dev Past the redeem notice and the window it lands in.
    function _closeAfter() internal pure override returns (uint32) {
        return 3 days;
    }

    function _dust() internal pure override returns (bool) {
        return true;
    }
}

/// @dev One bucket per controller and side, the default policy: a controller keeps extending its own bucket after it
///      is sent, and reopens the same id once it retires.
/// forge-config: default.invariant.check_interval = 10
contract VaultInvariantsPerInvestorTest is VaultInvariantsBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }

    function _prices() internal pure override returns (D18, D18) {
        return (D18.wrap(1e18), D18.wrap(1.05e18));
    }

    function _policy() internal override returns (IRequestPolicy) {
        return IRequestPolicy(address(new PerInvestorPolicy()));
    }

    function _transfers() internal pure override returns (bool) {
        return false;
    }
}
