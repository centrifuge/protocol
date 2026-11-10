# End-to-end invariant suite

A [Chimera](https://book.getrecon.xyz/writing_invariant_tests/chimera_framework.html) suite over the whole
protocol on one chain: hub, accounting, holdings, share classes, snapshot queue, spoke and escrow, share
token and transfer hook, manager roles, and the Vault Development Kit on top (vaults, OrderBook,
FeeRequestManager, request and instant policies, both liquidity routes). The same handlers and properties
run under Foundry, Echidna and Medusa.

Sister suite: [`test/integration/recon-messaging/`](../recon-messaging/) (Gateway and MultiAdapter).

## Running

```bash
# Foundry: the invariant (`StatefulInvariant`) plus the reachability test and reproducers. CI runs it under the `ci` profile.
forge test --match-path 'test/integration/recon-end-to-end/*'
FOUNDRY_PROFILE=ci forge test --match-contract 'CryticToFoundry|StatefulInvariant' -vv   # prints per-action ok/reverted counts

# Echidna (assertion mode; configuration in /echidna.yaml)
FOUNDRY_PROFILE=echidna echidna test/integration/recon-end-to-end/CryticE2ETester.sol \
  --contract CryticE2ETester --config echidna.yaml --test-limit 1000000

# Medusa (configuration in /medusa.json)
FOUNDRY_PROFILE=medusa medusa fuzz --config medusa.json
```

Corpora land in `echidna/` and `medusa/` at the repository root and are gitignored. The `Recon fuzzing`
workflow runs Echidna on pull requests (smoke), on a schedule and on demand.

A failing Echidna or Medusa sequence becomes a Foundry test by pasting its calls into a test function of
`CryticToFoundry` (the [Recon scraper](https://getrecon.xyz/tools/echidna) does the conversion) and ending
it with `assertProperties()`.

## Running a campaign

Settings and why (every value is in `echidna.yaml`, `medusa.json` or the workflow; run length, workers and seed are
command-line flags):

* **Profile.** Always `FOUNDRY_PROFILE=echidna`. The default profile drops the solc metadata and Echidna then
  attributes no coverage to the contracts the tester deploys (Hub, Spoke, Vault at 0%, "Unique codehashes" 109
  instead of about 45). The workflow checks `forge config` and the lcov of the run for this.
* **Mode.** Echidna `assertion`; Medusa `assertionTesting` only. Every property is a non-view `property_*`
  function that asserts, so Medusa's `propertyTesting` (bool-returning views) is off: it would match nothing.
* **Delays.** Profile A (the files' default): at most 1 h and 300 blocks per call. The oracle goes stale after a
  day (`ORACLE_MAX_AGE`), about 48 calls at the mean delay, so the instant lane stays mostly open. Profile B
  (scheduled run only): 2 days and 14400 blocks per call, so one jump can cross `maxAge`; run it for the stale-oracle
  and long-clock paths. Echidna has no flag for the delays, so the workflow rewrites them in a copy of the yaml.
* **Length and stopping.** `seqLen` 100. The PR smoke is 30000 calls, 4 workers, seed 12345, `stopOnFail`, about
  10 minutes. The scheduled run chains 3 x 500000 calls per profile over one cached corpus, each with its own seed
  (printed in the summary, kept in `seeds.txt`). Evidence from the 12 h cloud run: line coverage saturates within
  thousands of calls, the one failure was found at 2M calls, later yield was small, and 3 of 16 workers crashed
  (`BadJumpDestination`) and were never replaced, so chains of at most 2M calls beat one very long run. Measure the
  cold plateau once (empty corpus, 4 seeds) before moving these numbers.
* **Medusa.** `timeout` 3600 s (bounded; `--timeout` overrides), `stopOnFailedTest` false so one failure does not hide
  the rest, and `failOnArithmeticUnderflow`, `failOnDivideByZero`, `failOnOutOfBoundsArrayAccess` on: handlers swallow
  reverts with try/catch, so a panic that reaches the top frame comes from harness code (ghosts, clamps) and is a
  harness bug. Medusa is not in CI and has not been run against this suite here (not installed); `medusa.json` was
  checked against the documented keys only. Echidna's 300 ETH contract balance is mirrored in
  `targetContractsBalances`.
* **Slither.** Off (`disableSlither`): slither-analyzer 0.11.5 and 0.10.4 both crash on this repo, and Echidna then
  continues without it anyway. The cost (constants and function information for the generator) has not been measured.
* **Corpus.** Restored from the Actions cache and saved after scheduled runs; clear it when the senders, the
  deployer, `setup()` or a handler signature changes.

Reading a red run: the job summary lists the seed, each falsified test with its shrunk sequence, and any worker death
line. A test named in `KNOWN_FAILING` (workflow `env`) does not turn the job red, so a known break cannot hide a new
one. To reproduce, download the `echidna-*` artifact: Echidna writes a Foundry test per failure to
`<corpus>/foundry/`; move its calls into a `CryticToFoundry` test (or paste the log into the Recon scraper) and end
with `assertProperties()`, replaying each call's time and block delay. A worker death needs the seed from
`seeds.txt` rerun with `--workers 1`.

## Running another decimals profile

The asset's and the share token's decimals are two constants in `Setup.sol`; every amount in the targets, the
properties and the Foundry reproducers derives from `ONE_ASSET`, `ONE_SHARE`, `DUST_ASSETS` and `DUST_SHARES`. To run
the suite on other decimals (for a Recon dynamic replacement, replace these two lines and nothing else):

```solidity
uint8 internal constant SHARE_DECIMALS = 18;   // the pool currency's decimals, which is the share token's
uint8 internal constant USDC_DECIMALS = 6;     // the asset's decimals
```

The protocol takes 0 to 18 for both (`MAX_DECIMALS`), and the pool currency must have the share token's decimals.
The Foundry suite passes at 6/18 (default), 8/18, 18/18 and 6/8 (asset/share). A new literal such as `1e6` or `1e18`
in a handler or reproducer breaks the other profiles: write `n * ONE_ASSET` or `n * ONE_SHARE` instead.

## Layout

| File | Role |
|---|---|
| `Setup.sol` | Deploys and wires the protocol like `CoreActionBatcher`, then three pools (below) |
| `BeforeAfter.sol` | Ghost state and the before/after snapshot each handler takes |
| `properties/Properties.sol` | Standing `property_*` checks |
| `targets/*.sol` | Handlers, grouped by actor: vaults, hub manager, balance sheet, share token, oracle, doomsday, and whole request lifecycles (`FlowTargets`) |
| `CryticE2ETester.sol` | Echidna and Medusa entrypoint |
| `CryticToFoundry.sol` | Foundry entrypoint: `assertProperties`, the reachability test and reproducers |

**Pools.** Pool A is the one the fuzzer drives: USDC and pool C's share token as holdings, and four vaults,
per-request (transferable), per-period (one-hour windows, folded on claim), instant backed by
`VaultLiquidityRoute`, and per-investor instant backed by `BasinLiquidityRoute` over a mock venue, which books
each draw as a pool A liability (`property_basinDebtIsBooked`). Pool C is
the fund pool A invests in, through an instant vault the route redeems on demand. Pool B is configured with
live positions in setup and never targeted, so `property_poolBIsUntouched` catches any write that crosses a
pool boundary.

**Oracle.** Every pool A vault prices through one `SpokeOracle` (maximum age one day, maximum skew twelve
hours). The `oracle_*` handlers pause and unpause it through the Envoy, let both prices age past `maxAge`,
and notify one price more than `maxSkew` after the other; `oracle_pauseRoundTrip` checks that a pause closes
the instant lane, that unpausing reopens it exactly as it was, and that a whole async deposit cycle still
completes while paused. `property_oracleVerdict` holds the verdict to its pause, age and skew rules, and
`property_invalidPriceClosesInstantLane` checks that an invalid price zeroes the instant `max*` views and
makes the instant previews revert.

**Actors.** Three investors (`0x10000`, `0x20000`, `0x30000`, also the fuzzer senders), the pool manager,
the balance-sheet manager, an auxiliary manager whose role the fuzzer grants and revokes, and an outsider
who is never authorized and whose membership the fuzzer sets. Handlers prank the role they act as, using
only `prank`, `warp` and `deal`, so the suite needs no Foundry-only cheatcode.

## Conventions

* A handler bounds its inputs into the reachable range, swallows a revert and counts it, so a run reports
  how much of each flow happened (`afterInvariant` prints the counts). Checks that only make sense right
  after an action (exact escrow and queue deltas, issuance after a share submission, claim payouts) are
  made inline with the Chimera asserts.
* Inputs are clamped to what the state can take (shares held, claimable amounts, closed windows, the
  instant lane's capacity), except for one call in eight (`UNCLAMPED`), which keeps the raw input so the
  edges stay reachable: an open window flushed, a claim one unit past its maximum (which must revert in
  the unit the ledger keeps), an instant redemption above the shares held.
* The `flow_*` handlers run a whole lifecycle in one call (request, close the window and flush, settle or
  cancel, claim, and for a shared per-period window a fold per contributor) through the same internals as
  the single-step handlers, so claims, folds and refunds happen in proportion to the requests made. A full
  claim after a settlement is asserted to go through. The Foundry entrypoint lists them and the claim
  handlers more than once, since it picks uniformly among the listed selectors.
* Under Foundry a failed check is recorded instead of reverted, since Foundry drops a reverting handler
  call together with what it found; `assertProperties` fails on the first recorded reason.
* `testTheFlowsAreReachable` drives every flow once and asserts it went through, so a setup change that
  turns an action into a silent revert fails it rather than leaving the suite green and empty.

## Scope notes

* Hub and spoke share a chain, so messages apply synchronously; cross-chain delivery is the messaging
  suite's.
* Full-exit liveness (`vault_claimMax`) is asserted only while the escrow is not over-reserved: a manager
  may reserve ahead of arrival, and `withdrawReserved` pays a claim only out of the unreserved balance.
* The share-token recipient set excludes endorsed contracts, which the hook admits as recipients by design.
* `property_availableGtQueued` is not ported: it is a known break (out-of-band `noteDeposit` can queue
  increases not backed by held tokens), recorded as `n` in the specification.
* The `StdHubPolicy` share price guard (`_checkSharePrice`) is outside the scope of the vaults suite: the suite's
  policy leaves both price bounds at zero, so the guard returns early. It needs a policy of its own on its own pool,
  and is added later.
