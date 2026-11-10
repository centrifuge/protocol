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

/// @dev The two isolation properties the specification states and nothing checked: one vault cannot
///      reach into another on the same position, and an investor operation moves tokens only between
///      the parties it names.
///
///      Parallel vaults are the reason the first matters at all. Several vaults with different
///      policies are meant to run on one (pool, share class, asset) position, which is what makes
///      "vault A cannot touch vault B" a property rather than a tautology.
contract VaultIsolationTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address oracle = address(new IsContract());
    address escrow = address(new AmpleEscrow());
    address router = makeAddr("requestManager");

    address controller = makeAddr("controller");

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);

    IAsyncVault a;
    IAsyncVault b;

    function setUp() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        // Two vaults on the same pool, share class and asset, differing only in their request policy.
        a = _deploy(address(new PerRequestPolicy(true)));
        b = _deploy(address(new PerRequestPolicy(true)));
        assertTrue(address(a) != address(b), "two distinct vaults on one position");

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
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
    }

    function _deploy(address requestPolicy) internal returns (IAsyncVault) {
        return IAsyncVault(
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
                            instantPolicy: IInstantPolicy(address(0)),
                            requestPolicy: IRequestPolicy(requestPolicy),
                            liquidityRoute: ILiquidityRoute(address(0)),
                            settlementObserver: ISettlementObserver(address(0))
                        })
                    })
                )
            )
        );
    }

    //----------------------------------------------------------------------------------------------
    // Vault against vault
    //----------------------------------------------------------------------------------------------

    /// @dev Both policies count from one, so the two vaults hand out the same local ids. The request
    ///      id namespaces them by vault address, which is what stops a settlement aimed at one from
    ///      landing on the other's bucket of the same number.
    function testTwoVaultsIssueTheSameLocalIdWithoutColliding() public {
        vm.startPrank(controller);
        uint256 onA = a.requestDeposit(1_000e6, controller, controller);
        uint256 onB = b.requestDeposit(400e6, controller, controller);
        vm.stopPrank();

        assertEq(uint96(onA), uint96(onB), "the same local id on both");
        assertTrue(onA != onB, "but not the same request id");

        assertEq(a.bucket(uint96(onA)).total, 1_000e6);
        assertEq(b.bucket(uint96(onB)).total, 400e6, "each bucket holds only its own vault's request");
        assertEq(a.pendingDepositRequest(0, controller), 1_000e6);
        assertEq(b.pendingDepositRequest(0, controller), 400e6);
    }

    /// @dev A settlement is addressed to a vault, so the manager settling one cannot move the other's
    ///      ledger even for the same controller and the same local id.
    function testSettlingOneVaultLeavesTheOtherUntouched() public {
        vm.startPrank(controller);
        uint96 onA = uint96(a.requestDeposit(1_000e6, controller, controller));
        uint96 onB = uint96(b.requestDeposit(400e6, controller, controller));
        vm.stopPrank();

        vm.startPrank(router);
        IVaultDepositCallbacks(address(a)).approveDeposits(onA, 1_000e6);
        IVaultDepositCallbacks(address(a)).issueShares(onA, 1_000e18);
        IVaultDepositCallbacks(address(a)).fulfillDepositRequest(onA, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(a.maxMint(controller), 1_000e18, "A settled");
        assertEq(b.maxMint(controller), 0, "B did not");
        assertEq(b.pendingDepositRequest(0, controller), 400e6, "and B's request is still outstanding");
        assertEq(BucketReference.outstanding(b.bucket(onB)), 400e6, "with its bucket untouched");
    }

    /// @dev Each vault reads its own request ids and nobody else's, so a foreign id is not merely
    ///      unrecognised but reported as zero rather than as some bucket of its own.
    function testAVaultReadsNothingFromAForeignRequestId() public {
        vm.prank(controller);
        uint256 onA = a.requestDeposit(1_000e6, controller, controller);

        assertEq(a.pendingDepositRequest(onA, controller), 1_000e6, "A knows its own id");
        assertEq(b.pendingDepositRequest(onA, controller), 0, "B reads nothing from it");
    }

    /// @dev A request transfer is bounded by the vault it was made on: the id names A, so B refuses it
    ///      outright rather than moving a bucket of its own that happens to share the local id.
    function testAVaultRefusesToTransferAForeignRequest() public {
        vm.prank(controller);
        uint256 onA = a.requestDeposit(1_000e6, controller, controller);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        b.transferDepositRequest(onA, controller, makeAddr("newController"));
    }

    //----------------------------------------------------------------------------------------------
    // Bystanders
    //----------------------------------------------------------------------------------------------

    /// @dev A request moves the owner's assets to the escrow and touches no third party. Asserted
    ///      by recording every transfer the mock asset sees, which is the only way to say "and nothing
    ///      else happened" rather than checking the balances the test happens to think of.
    function testARequestMovesTokensOnlyBetweenTheOwnerAndTheEscrow() public {
        RecordingERC20 recorded = new RecordingERC20(6);
        IAsyncVault vault = _deployWithAsset(address(recorded));

        vm.prank(controller);
        vault.requestDeposit(1_000e6, controller, controller);

        assertEq(recorded.transferCount(), 1, "exactly one asset movement");
        (address from, address to, uint256 amount) = recorded.transferAt(0);
        assertEq(from, controller, "out of the owner");
        assertEq(to, escrow, "into the escrow");
        assertEq(amount, 1_000e6, "for exactly the requested amount");
    }

    function _deployWithAsset(address asset_) internal returns (IAsyncVault vault) {
        vault = IAsyncVault(
            address(
                new Vault(
                    POOL,
                    SC,
                    asset_,
                    ASSET_ID,
                    IShareToken(address(share)),
                    VaultConfig({
                        foldHorizon: 0,
                        spoke: ISpoke(spoke),
                        spokeRegistry: ISpokeRegistry(spokeRegistry),
                        plugins: VaultPlugins({
                            oracle: IVaultOracle(oracle),
                            instantPolicy: IInstantPolicy(address(0)),
                            requestPolicy: IRequestPolicy(address(new PerRequestPolicy(true))),
                            liquidityRoute: ILiquidityRoute(address(0)),
                            settlementObserver: ISettlementObserver(address(0))
                        })
                    })
                )
            )
        );
    }
}

/// @dev Records every movement rather than only its balances, so a test can assert that nothing else
///      moved at all.
contract RecordingERC20 {
    struct Movement {
        address from;
        address to;
        uint256 amount;
    }

    uint8 public decimals;
    Movement[] internal _transfers;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function transferCount() external view returns (uint256) {
        return _transfers.length;
    }

    function transferAt(uint256 i) external view returns (address, address, uint256) {
        Movement memory m = _transfers[i];
        return (m.from, m.to, m.amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _transfers.push(Movement(from, to, amount));
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfers.push(Movement(msg.sender, to, amount));
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}
