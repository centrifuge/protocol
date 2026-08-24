# Messaging Tester

Recon/Chimera invariant suite for `MultiAdapter` + `Gateway` in isolation, with no Hub, Spoke or Vaults.

It covers the inbound voting flow (`MultiAdapter.handle`/`vote`/`execute` → `Gateway.handle`), the outbound send path (`Gateway.send` → `MultiAdapter.send` → adapter), `retry`/`clearFailedMessage`/pause/`blockSession`-`unblockSession`, source-chain enforcement, and adapter reconfiguration across sessions.

Sister suite is [`test/integration/recon-end-to-end/`](../recon-end-to-end/) (Hub + Vaults). Properties and ghosts are scoped to one suite each, so don't conflate them.

## What is real and what is mocked

**The contracts under test are the real ones.** `Setup.sol` deploys `new Gateway(...)` and `new MultiAdapter(...)` directly from `src/core/messaging/`. There is no `MockGateway` or `MockMultiAdapter` here, unlike the end-to-end suite which stubs the gateway.

Mocks exist only at the four peripheral interfaces the two contracts talk to, plus one non-ward actor:

| Interface | Mock | Why |
|---|---|---|
| `IAdapter` | `mocks/SimpleAdapter.sol` | no real bridge in-process |
| `IMessageHandler` | `mocks/CountingProcessor.sol` | observable per-payload execution count |
| `IMessageProperties` | `mocks/MockMessageProperties.sol` | controllable routing / source restriction / gas limits |
| `IProtocolPauser` | `mocks/MockProtocolPauser.sol` | freely togglable pause |
| n/a | `mocks/ManagerActor.sol` | a non-ward caller, to exercise the manager role |

Consequence for coverage reports: `src/core/messaging/{Gateway,MultiAdapter}.sol` **must** show substantial line coverage after a real campaign. As of the current tip a 50k-call Echidna run gives `MultiAdapter` 145/147 and `Gateway` 80/162. A report showing 0 for either is an attribution bug in the build, not an accurate measurement. See [Coverage attribution](#coverage-attribution) below.

## Messaging-layer surface under test

- Sessions are per-(`centrifugeId`, `poolId`) `uint16`. Inbound payloads are wrapped with a 2-byte sessionId prefix, and an unwrapped or mis-wrapped payload reverts `InvalidAdapter`.
- Votes are pool-namespaced: `_votes[cId][voteKey]` where `voteKey = keccak256(abi.encodePacked(routedPoolId, wrappedPayload))`. A global-set vote and a pool-set vote on identical bytes no longer share a slot.
- `setAdapters(cId, pool, adapters, threshold, targetSessionId)` takes 5 args. `targetSessionId` must equal `nextActiveSessionId(cId, pool)` (active + 1) or it reverts `UnexpectedSessionId()`. A `threshold == 0` over a non-empty set reverts `ZeroThreshold()`.
- Session ids plain-increment. There is no wrap from max back to 1 and no skip of 0, so at `type(uint16).max` `setAdapters` panics `0x11` and that (cId, pool) is exhausted permanently. Session id 0 therefore always means "never configured".
- `blockSession`/`unblockSession`, the `vote`/`execute` split, `Gateway.clearFailedMessage`, and the `CannotBeReceivedLocally`/`SourceMismatch` guards are all in scope. `Gateway.blockOutgoing` and `recoveryIndex` no longer exist.

## File map

| File | Role |
|------|------|
| `Setup.sol` | Deploys Gateway + MultiAdapter + 3 `SimpleAdapter` mocks. Wires wards. Defines constants `THRESHOLD=2`, `ADAPTER_COUNT=3`, `LOCAL_CENTRIFUGE_ID=1`, `REMOTE_CENTRIFUGE_ID=2`, `GLOBAL_POOL=PoolId(0)`. Defines `_wrap(payload)`, which prefixes the current active sessionId (2 bytes); EVERY inbound delivery must use it (unwrapped payloads revert `InvalidAdapter`). Defines `_voteKey(wrapped)`, the `multiAdapter.votes` key `keccak256(uint64 poolId ++ wrapped)`; the `uint64` width is load-bearing. Also `_activeList()`/`_isActive()` for live active-adapter-set reads. |
| `BeforeAfter.sol` | Ghost variables. Two layers: per-session (reset on reconfigure via `_clearTrackedDeliveries`) for the M1/M4/G2/G4 bound checks, and cumulative / cross-session (NEVER reset) for M1c and callCount monotonicity. `_captureBaselines` (pre-deliver) + `_recordSuccessfulDelivery` (post-success) split, so reverts don't pollute ghosts. `ghost_voteKey[cId][unwrappedHash]` maps to the pool-namespaced vote key. `_recordExecutionDelta` is a cumulative-ledger update without a delivery increment, for `execute()`/`retry`. Top-level `TrackedPair` struct. No active-set ghost: targets read `_activeList()`/`_isActive()` live. |
| `targets/MultiAdapterTargets.sol` | `multiAdapter_deliver{,All,ToThreshold}`, `multiAdapter_vote`, `multiAdapter_execute` (positive); `multiAdapter_reconfigure(countSeed, thresholdSeed)` (state-mutating; clears per-session ghosts; asserts inline that `nextActiveSessionId == activeSessionId + 1` and that the call installs exactly that id, the only coverage of that getter); `multiAdapter_blockSession`/`multiAdapter_unblockSession` (state-mutating, inline asserts on the blocked flag, active-set cleared/restored, blocked-session delivery rejected); manager path `multiAdapter_updateManager` (toggles the role for the non-ward `mocks/ManagerActor.sol`) and `multiAdapter_managerDeliver` (3-arg handle on behalf of an active adapter); negatives M6.a/b/d/e/f (`setAdapters`: `ExceedsMax` / `ThresholdHigherThanQuorum` / `NoDuplicatesAllowed` / `ZeroThreshold` / `UnexpectedSessionId`), B1/B2 (block/unblock), V2 (execute below threshold → `NotEnoughVotes`), MA1 (non-manager on-behalf submission → `NotAuthorized`), `multiAdapter_oldAdapter_mustRevert`, `multiAdapter_alex1_replay_must_not_execute`. Defines the `validPayload` modifier. |
| `targets/GatewayTargets.sol` | `gateway_send` (cId clamped to the configured route with a rare escape; asserts S1 fan-out hits every active adapter exactly once, plus S2 payload wrapped with the active sessionId), `gateway_retry` (cId clamped; baseline-bump when the consumed failure predates the session baseline), `gateway_clearFailedMessage`, `gateway_setPaused`, `gateway_setProcessorFail(bytes payload, bool)` which takes a bucketed payload rather than a free `bytes32`, and that is what makes the fail→retry/clear cycle fuzzer-reachable; negatives G3 (retry non-failed), G5/G5b (pause), G6 (send after `blockSession` of the active session → `EmptyAdapterSet`), G7 (clear non-failed), G8 (local-origin batch → `CannotBeReceivedLocally`), G9 (source-restricted message from the wrong chain → `SourceMismatch`). Inherits `MultiAdapterTargets`. |
| `properties/MessagingProperties.sol` | Per-session: M1, M2 (4-arg `adapters(cId,pool,sid,i)` getter), M3 (`1 <= threshold <= quorum` whenever a set is active; the lower bound is the always-on form of the `ZeroThreshold` fix, covering write paths other than `setAdapters`), M4 (reads votes via `ghost_voteKey`), G1, G2, G4 (G2/G4 use saturating baseline diffs, since retry/clear can push `failedMessages` below baseline). Cumulative cross-session: M1c, callCount monotonicity. G3/G5-G9, B1/B2 and V1/V2 are enforced inline in the targets instead. |
| `TargetFunctions.sol` | Aggregator: `is GatewayTargets, MessagingProperties` (GatewayTargets pulls in MultiAdapterTargets transitively). |
| `CryticMessagingTester.sol` | Fuzzer entry point. Run with `--config echidna-messaging.yaml` from the project root. |
| `CryticToFoundry.sol` | Foundry harness. 38 deterministic tests: smoke, C1/H3 regressions, M6.a-f negatives, vote-key pinning, vote/execute, blockSession, clearFailedMessage, source enforcement, Alex-1, M1c cross-session retry. |
| `mocks/SimpleAdapter.sol` | Stub `IAdapter`. `deliver`→handle, `deliverVote`→vote, `deliverExecute`→execute, all expecting session-WRAPPED payloads. `send` records `sendCount` + `lastSentPayloadHash` for S1/S2 observability and returns `bytes32(0)`; `estimate` returns `0`. |
| `mocks/CountingProcessor.sol` | `IMessageHandler` mock. `callCount[cId][hash]` per (cId, UNWRAPPED payloadHash). `setFail(...)` is intentionally unauthenticated. |
| `mocks/MockMessageProperties.sol` | `IMessageProperties` mock. Single-message batches only (`messageLength == payload.length`). All payloads route to `GLOBAL_POOL` (`routePoolId` ignores the fallback flag). `messageSourceCentrifugeId`: messages starting with magic `0xFE` + `bytes2(source)` are source-restricted, everything else returns 0 meaning any. `messageProcessingGasLimit=200_000`, `messageFailureGasReserve=35_000`, `maxBatchGasLimit=10_000_000`. |
| `mocks/MockProtocolPauser.sol` | Trivial. `setPaused` is intentionally unauthenticated. |
| `mocks/ManagerActor.sol` | A non-ward address used to exercise the manager role on `MultiAdapter`. |

## Property semantics

Read this before touching properties. There are two ghost lifetimes (per-session vs cumulative) and three hash domains.

### Hash domains

Mixing these up is the easiest way to break the suite, and the failure is often silent.

- **Unwrapped hash** `keccak256(payload)`. The domain of `countingProcessor.callCount`, `gateway.failedMessages`, and ALL ghosts (`ghost_deliveries`, `ghost_cum*`, baselines). Targets pass the UNWRAPPED payload to `_captureBaselines`/`_recordSuccessfulDelivery`.
- **Wrapped hash** `keccak256(2-byte sessionId ++ payload)`. What `SimpleAdapter.send` records as `lastSentPayloadHash`. Used ONLY by the outbound S1/S2 assertions in `GatewayTargets.sol` and the two Foundry send tests. It is not a vote key; do not "fix" these to `_voteKey`.
- **Vote key** `keccak256(uint64 routedPoolId ++ 2-byte sessionId ++ payload)`. The domain of `multiAdapter.votes`, via `_voteKey(...)`. Properties reading votes use `ghost_voteKey[cId][unwrappedHash]`, captured at the first in-session track. It is session-scoped because the sessionId is inside the hashed bytes, and pool-scoped because of the prefix.

Reading the wrong vote key fails SILENTLY. `votes()` returns an all-zero array for an unknown key, so M4 reports `positiveSum == 0 <= deliveries` and passes vacuously, and V2's, Alex-1's and G5's clean-slate preconditions stop constraining anything. `test_voteKey_addresses_the_live_tally` is the guard: it asserts the vote key sees a live tally AND that the bare wrapped hash does not. Keep it.

The `uint64` width of the pool prefix matters, because `abi.encodePacked` contributes 8 bytes and not 32. A `uint256(0)` prefix compiles fine and addresses a different, permanently empty slot.

### Per-session ghosts (M1, M2, M3, M4, G1, G2, G4)

These evaluate against the current session only, as bounds within a single `setAdapters` epoch. Enforced by:

1. `_captureBaselines` (pre-deliver) snapshots `countingProcessor.callCount(cId, hash)` and `gateway.failedMessages(cId, hash)` into `ghost_baselineCallCount` / `ghost_baselineFailedMessages`, on first track within the session.
2. Properties subtract those baselines from current values, to express "executions caused by this session's deliveries".
3. `multiAdapter_reconfigure` calls `_clearTrackedDeliveries()`, which deletes all per-session ghosts.

This pattern fixes the C1 bug class: M1/G2 read the current threshold but ghost counters span sessions, so a reconfigure that raises the threshold trips the property.

If you add a property that reads `multiAdapter.threshold(...)` or `multiAdapter.quorum(...)` and compares it to anything counted across deliveries, mirror the baseline pattern. Otherwise the property will trip on reconfigure.

### Cumulative cross-session ghosts (M1c, callCount monotonicity)

These are NEVER reset by reconfigure. They validate that protocol behaviour stays correct across session transitions, which is the original motivation for the suite: an adapter-set reconfiguration must not let a stale, already-counted delivery execute a second time.

- `ghost_cumDeliveries[cId][hash]`: total deliveries forever.
- `ghost_cumExecutionsWeighted[cId][hash]`: sum of `(callCount_delta × threshold_at_observation)` for each detected execution.
- `ghost_cumLastSeenCallCount[cId][hash]`: last observed callCount, for delta detection and monotonicity.
- `ghost_cumTracked` / `ghost_isCumTracked`: list of all (cId, hash) pairs ever delivered.

The pre-deliver `_captureBaselines` + post-success `_recordSuccessfulDelivery` split ensures reverts pollute neither domain.

### M2 is a real cross-storage invariant

It iterates `multiAdapter.adapters(cId, pool, activeSessionId, i)` and asserts pairwise distinctness and non-zero. Don't replace it with `quorum == ghost_adapterCount`, which was the original tautology.

### Alex-1 replay (`multiAdapter_alex1_replay_must_not_execute`)

This PASSES under the multi-session design, because votes are keyed by a session-bearing key, so a stale replay counts under the OLD session's threshold of ≥ 2 and cannot re-execute. The target replays the original wrapped bytes (stale sessionId prefix) and asserts callCount is unchanged; it stays live as a regression guard. Preconditions are a clean vote slate for the wrapped payload and threshold ≥ 2, since threshold-1 duplicate re-execution is by-design parallel-message semantics rather than the replay bug. The complementary kill-switch is `blockSession` on the old session, which rejects stale replays outright and is asserted inline in `multiAdapter_blockSession`.

## Conventions for adding handlers and properties

1. **Negative `*_mustRevert` targets must use selector-checked catches.** An empty `catch {}` swallows wrong-reason reverts and silently passes the property. Always:

   ```solidity
   try someCall() {
       t(false, "...: should have reverted");
   } catch (bytes memory err) {
       t(bytes4(err) == ISomeInterface.ExpectedError.selector, "...: wrong revert");
   }
   ```

2. **Use the `_captureBaselines` (pre-deliver) + `_recordSuccessfulDelivery` (post-success) split.** Capture happens before the on-chain effect, so executions caused by THIS delivery show up as a delta. The increment happens only on success, so reverts don't pollute ghosts. Never call the post-hook outside the success branch.

3. **Payload keyspace is bounded to `PAYLOAD_BUCKETS` (16) via `_bucket(payload)` in `Setup.sol`, not via `validPayload`.** `validPayload` is only a length guard. Every state-producing or failure handler canonicalizes its payload with `bytes memory p = _bucket(payload)` at entry and uses `p` thereafter. This is what makes multi-step sequences collide on the same (cId, hash), which matters most for the fail→retry/clear cycle: that cycle was fuzzer-unreachable while `gateway_setProcessorFail` took a free `bytes32` that never matched a delivered payload. `_bucket` is idempotent, so canonical 1-byte payloads pass through and Foundry tests can wrap their payload definition once with `_bucket(abi.encode(...))` and keep referencing `keccak256(payload)`. When adding a handler that must share the delivery/failure keyspace, canonicalize with `_bucket` and keep everything keyed off `p`.

4. **Per-session ghost reset.** Anything tracked per (cId, hash) must be cleared in `_clearTrackedDeliveries()`. Anything tracked per session, such as `ghost_adapterCount`, must be set in `setup()` and updated on reconfigure.

5. **Sentinel `t(true, ...)` properties are forbidden.** Live enforcement goes in negative target functions. Document the property in NatSpec near the target, not as a no-op property.

6. **The test contract (`address(this)`) is the deployer and ward** of both `Gateway` and `MultiAdapter`. Don't replace this with a per-actor pattern without re-thinking auth on the `onlyAuthOrManager` surfaces (`setAdapters`, `blockSession`/`unblockSession`, `gateway.handle`, `clearFailedMessage`) and on the untested `updateManager` / manager-submission paths.

7. **Wrap every inbound payload with `_wrap(...)`** before handing it to an adapter mock, and pass the UNWRAPPED payload to the ghost helpers. To read votes, wrap first, then `_voteKey(...)`.

   In Foundry tests, hoist ANY staticcall into a local BEFORE `vm.expectRevert`. The expectation is armed first, so an argument evaluated after it consumes the expectation and the test fails with "call did not revert as expected". This bites `_wrap`/`_voteKey`, which read `activeSessionId`, and `nextActiveSessionId(...)` passed as the 5th argument to `setAdapters`.

8. **State-mutating targets with inline asserts** (`multiAdapter_blockSession`, `multiAdapter_unblockSession`, `multiAdapter_reconfigure`, Alex-1) must NOT end with `require(false)`. Their state change is the point.

9. **Adapter activeness is always read LIVE** via `_activeList()`/`_isActive()` in `Setup.sol`, never mirrored in a ghost. The Alex-1 target installs non-prefix sets such as `[adapter1]`, and a "first N of adapter0..2" count ghost misrepresents them. That produced false positives in `oldAdapter_mustRevert` and V2.

## Running

```bash
# Foundry: fast, deterministic, 38 tests
forge test --match-contract CryticMessagingToFoundry -vv

# Single test
forge test --match-test test_C1_M1_after_threshold_increase_reconfigure -vvv
```

### Echidna takes the FILE target

```bash
FOUNDRY_PROFILE=echidna echidna test/integration/recon-messaging/CryticMessagingTester.sol \
  --contract CryticMessagingTester --config echidna-messaging.yaml --test-limit 3000000 --workers 8
# quick local smoke: drop --test-limit (Echidna default 50k)
```

Run the file target, not `echidna .`. Both compile — `EnvConnections.load` used to be a `public` library
function needing linking that whole-project compilation could not provide, but it is `internal` now — the
reason that survives is parity: the file target is what Recon Cloud uses, so running it locally keeps the
two in sync.

### `recon fuzz` takes the OPPOSITE target

```bash
FOUNDRY_PROFILE=echidna recon fuzz . \
  --contract CryticMessagingTester --config echidna-messaging.yaml --workers 16 --test-limit 10000
```

`recon fuzz` (Recon's own Rust fuzzer) wants a Foundry project path, not a file. Passing the `.sol` file fails with "Failed to compile project / Failed to run forge build (No such file or directory)". It does not go through crytic-compile, so the file-target rule above does not apply to it.

`--recon-corpus-dir <dir>` keeps recon's corpus separate and auto-exports an Echidna-compatible copy into `corpusDir`, so the same yaml serves both fuzzers without them fighting.

### Coverage attribution

`FOUNDRY_PROFILE=echidna` is required for every fuzzer invocation, not optional.

The profile sets `bytecode_hash = "ipfs"` and `cbor_metadata = true`. `[profile.default]` sets them to `"none"` and `false` so that deployed bytecode stays deterministic, and that is correct for production but wrong for fuzzing. Without a CBOR metadata trailer, hevm keys its coverage map on the full runtime bytecode. Immutables are patched into runtime bytecode at deploy time, so any separately deployed contract with constructor-set immutables no longer matches its compiled artifact and gets no coverage attributed at all.

Measured on the same command, changing only the profile:

| | default profile | `FOUNDRY_PROFILE=echidna` |
|---|---|---|
| `MultiAdapter.sol` | 1/312 combined | 145/147 |
| `Gateway.sol` | (same 1/312) | 80/162 |
| `SimpleAdapter`, `ManagerActor` | 0 | 17/19, 5/6 |

Contracts inherited into `CryticMessagingTester` itself (`Setup`, `BeforeAfter`, targets, properties) are attributed either way, because Echidna knows that deployment by name. Mocks without immutables (`CountingProcessor`, `MockMessageProperties`, `MockProtocolPauser`) are also attributed either way. So a report where the targets and properties look healthy but `Gateway` and `MultiAdapter` read 0 is diagnostic of a missing profile, not of an idle fuzzer.

The same missing metadata destabilises the coverage key, so every sequence looks like new coverage, which grows the corpus without bound and eventually OOMs.

### Config and corpus

`echidna-messaging.yaml` deliberately omits `testLimit`, `workers`, `seqLen`, `timeout`, `symExec` and `seed`, so it works on Recon Cloud (where the UI governs run params) and locally (where CLI flags do). Do NOT add a `timeout`, since it would cap a long cloud campaign early.

Compilation takes roughly 150s because the project is large with many libraries, so the first run is the slowest. The corpus persists in `corpusDir: echidna-messaging` at the project root.

**Wipe the corpus after any handler-ABI change** (`rm -rf echidna-messaging/`). It stores concrete calldata, so entries recorded before a signature change either decode into a different call or get discarded. Either way the campaign restarts from a corpus that no longer means what it says.

### Recon Cloud (getrecon.xyz/dashboard/jobs)

- Path to test contract: `test/integration/recon-messaging/CryticMessagingTester.sol`
- Echidna config filename: `echidna-messaging.yaml`, Tester Contract Name: `CryticMessagingTester`
- Corpus Dir: `echidna-messaging`, Mode: assertion, Fork Mode: Non-Forked
- Branch: the branch under test, committed and pushed first. Test Limit: 10M for the first (no-corpus) run.
- Corpus Reuse Job ID: LEAVE EMPTY. The corpus is suite-specific, so never paste the recon-end-to-end job id. Once a run completes, reuse ITS job id for subsequent higher-limit messaging runs.

Cloud jobs currently build with the default foundry profile, so treat `src/**` coverage from a cloud report as unusable until that is resolved. Property results are unaffected, since only the source mapping breaks.

## Setup constants

- `THRESHOLD=2`, `ADAPTER_COUNT=3`. The initial `setAdapters` in `setup()` creates session 1.
- `multiAdapter_reconfigure` fuzzes count in [1,3] and threshold in [1,count], where threshold ≥ 1 keeps it clear of the `ZeroThreshold` guard. Session ids are per-(cId, pool) `uint16` and increment by exactly 1 per `setAdapters`, and the caller must pass that id as `targetSessionId`.
- `MAX_ADAPTER_COUNT=8` from `IMultiAdapter.sol`. The M6.a negative deliberately exceeds it.
- `PAYLOAD_BUCKETS=16`, the bounded payload keyspace behind `_bucket(...)`.
- `messageOverallGasLimit` returns `0` (unpaid mode), `messageProcessingGasLimit` returns `200_000`, `messageFailureGasReserve` returns `35_000`. Gateway forwards `gasLimit - reserve` to the processor, so the reserve must stay well below the processing limit.

## Known coverage gaps

These are deferred follow-ups rather than bugs in the existing suite. Each warrants its own PR, so don't add them ad-hoc. If you close one, update this section.

- **Multi-message inbound batches** (`Gateway.handle` looping over `messageLength`). `MockMessageProperties` returns the full payload length, so batches are always single-message and the `MalformedBatch` revert path is unreachable.
- **`withBatch` / `repay` / underpaid batches.** Outbound batching, transient slot clearing and batch locator parsing are not exercised, which is the bulk of the uncovered `Gateway` lines. `property_G1_isBatching_false` is a tautology as a result. Note that the end-to-end suite uses a `MockGateway`, so this suite's number is the protocol's total stateful `Gateway` coverage.
- **`Gateway.file` and `Gateway.updateManager`** have no handler.
- **Multi-remote / multi-pool.** Only `REMOTE_CENTRIFUGE_ID=2` and `GLOBAL_POOL` are configured, so per-(cId, pool) accounting bugs and the `routePoolId` SetPoolAdapters→global fallback are out of reach. This also leaves the vote key's pool namespacing untested: the whole point of `voteKey = keccak256(poolId ++ wrapped)` is that a global-set vote and a pool-set vote on identical bytes land in separate tallies, and with one pool the prefix is a constant. The missing property is to deliver the same payload under two pools with different adapter sets and assert neither tally counts toward the other's threshold. Closing it means teaching `MockMessageProperties.routePoolId` to route a payload subset to a second pool, configuring adapters for it, and re-keying `ghost_voteKey` and `_voteKey` by (cId, pool, hash).
- **Manager paths, partially covered.** `MultiAdapter.updateManager` and the manager-driven `handle(cId, payload, adapter)` overload are fuzzed via the non-ward `ManagerActor`. Still unfuzzed: the manager-driven `vote`/`execute` overloads, and the gateway-side manager role (`gateway.updateManager`, manager-gated `gateway.handle`/`clearFailedMessage`).
- **StandbyAdapter** (`src/adapters/StandbyAdapter.sol`): the forwardable-credit invariant (forwards ≤ sends), `estimate == 0`, and inbound relay via `underlying`. Model it as a 4th adapter configuration and reuse the mocks from `test/adapters/StandbyAdapter.t.sol`.
- **AdapterFailover** (`src/managers/adapters/AdapterFailover.sol`): the steward/timelock failover lifecycle into `setAdapters`, plus hub veto. Replaces the old recoveryIndex model.
- **`SimpleAdapter` doesn't model Axelar's pull-based commandId queue.** The Alex-1 target works around this by orchestrating the reconfigure inside the target. A higher-fidelity adapter mock with a `pendingDelivery(hash)` queue surviving reconfigure would let more attack patterns emerge organically.
- **Session-id exhaustion** (`activeSessionId == type(uint16).max`), where `setAdapters` panics `0x11` instead of wrapping and permanently bricks reconfiguration for that (cId, pool). Unreachable in fuzz sequences since `seqLen` 50 is far below 65535, and not modelled here. The DoS shape is a protocol-design question rather than a harness gap.

## Known revert reasons

When a target catches an unexpected revert, check this first.

| Selector | Source | Common cause |
|----------|--------|--------------|
| `IGateway.Paused` | `Gateway.handle/send/retry/repay` (`pauseable` modifier) | `mockProtocolPauser.paused() == true` |
| `IGateway.NotFailedMessage` | `Gateway.retry/clearFailedMessage` | `failedMessages[cId][hash] == 0` |
| `IGateway.CannotBeReceivedLocally` | `Gateway.handle` | `centrifugeId == localCentrifugeId` (forgery guard) |
| `IGateway.SourceMismatch` | `Gateway.handle` | message source-restricted via the mock magic `0xFE ++ bytes2(src)` and delivered from a different chain |
| `IGateway.EmptyMessage` / `TooLongMessage` | `Gateway.send` | payload bounds; the `validPayload` modifier prevents this |
| `IMultiAdapter.InvalidAdapter` | `MultiAdapter._resolve` | adapter not configured for the (cId, pool, sessionId-from-payload-prefix): after a reconfigure to a smaller count, on unwrapped or mis-wrapped payloads, or on a blocked session |
| `IMultiAdapter.{ExceedsMax, ThresholdHigherThanQuorum, NoDuplicatesAllowed}` | `MultiAdapter.setAdapters` | exercised by the M6.a/b/d negatives |
| `IMultiAdapter.ZeroThreshold` | `MultiAdapter.setAdapters` | `threshold == 0` with a non-empty adapter set; an empty set with 0 is the legal disable path (M6.e) |
| `IMultiAdapter.UnexpectedSessionId` | `MultiAdapter.setAdapters` | `targetSessionId != nextActiveSessionId(cId, pool)`. Raised BEFORE `_installSession`, so a negative target aiming at `NoDuplicatesAllowed` must pass the correct id or it fails for the wrong reason (M6.f) |
| `IMultiAdapter.SessionNotConfigured` | `MultiAdapter.blockSession` | session never configured, or already blocked with its config stashed (B1) |
| `IMultiAdapter.SessionNotBlocked` | `MultiAdapter.unblockSession` | session not currently blocked (B2) |
| `IAdapterEntrypoint.NotEnoughVotes` | `MultiAdapter.execute` | positive votes below threshold (V2) |
| `IMultiAdapter.EmptyAdapterSet` | `MultiAdapter.send/estimate` | no active adapters for (cId, pool): unconfigured cId, or the active session is blocked (G6) |
| `Auth.NotAuthorized` | `_resolve` / `onlyAuthOrManager` | caller is neither the named adapter, nor a ward, nor a pool manager |

## References

- Source under test: `src/core/messaging/{Gateway,MultiAdapter}.sol`, `src/misc/libraries/ArrayLib.sol`
- Unit tests for the same contracts: `test/core/unit/Gateway.t.sol`, `test/core/unit/MultiAdapter.t.sol`
- Recon framework docs: https://book.getrecon.xyz/writing_invariant_tests/chimera_framework.html
- Recon reproducer scraper: https://getrecon.xyz/tools/echidna
