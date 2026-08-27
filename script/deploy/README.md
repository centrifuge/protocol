# Centrifuge Protocol – Deployment

Launching the protocol on a chain that does not have one. Changing a chain that already runs it is not done
from this branch — those scripts live on `live`; for a map of the script directories here, see
[`../README.md`](../README.md).

There is no wrapper: **every intent is one forge command**. `--rpc-url <network>` is the only input that
selects a network: it decides where the run connects, and `Chains.detect()` matches that chain id against
`env/<environment>/*.json` to decide which config it reads, so the two cannot disagree. There is no override. The RPC URL
itself and the verification key come from `foundry.toml` (`[rpc_endpoints]`, `[etherscan]`). The signer is always passed explicitly, so a
testnet run and a mainnet run have the same shape and differ only in who signs. The one thing that cannot be
a forge command — bringing up local forks, which needs anvil processes — has a dedicated script here:
`anvil.sh`.

**Run everything from the repository root.**

---

## Prerequisites

```bash
./script/setup/setup.sh           # tools: git, jq, curl, Foundry, gcloud
gcloud auth login                 # needs access to the centrifuge-production-x project
```

Then, where the deployment configs are, `./script/setup/load-secrets.sh` puts the API keys and the testnet
deployer key into `.env`. It ships with those configs, so main — which has none — has no such file.

---

## Cookbook

### Deploy the protocol (testnet)

```bash
set -a; . ./.env; set +a    # once per shell: forge loads .env for itself, not for your shell
KEY="--private-key $PRIVATE_KEY"

EXECUTORS=<address> forge script script/deploy/LaunchDeployer.s.sol --sig 'commit()' --rpc-url <network> $KEY --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'deploy()'  --rpc-url <network> $KEY --broadcast --verify
forge script script/testnet/TestData.s.sol --rpc-url <network> $KEY --broadcast # optional test data
```

`LaunchDeployer` writes the addresses, versions and block numbers into `env/<environment>/<network>.json` itself,
as it deploys. There is no follow-up step and nothing to remember.

### Deploy the protocol (mainnet)

On mainnet the namespace comes from the config, `network.namespace`, like every other thing about the chain.
It is what every mainnet address derives from and it can never be replaced, so it has to outlive any single
key and be the same account on every chain the protocol runs on. Which account that is — a Safe, a Ledger
that delegates to a Safe, a key that delegates to another — is the config's and the gate's business, not this
script's: `LaunchDeployer` supports any of those arrangements without knowing which one it is in.

Each phase **acts as `--sender`**, and how the phase is signed follows from what that account is. Deploying,
it is an executor key. Committing, it is the namespace or a delegate the namespace named through the gate's
`setDelegate`: a key is broadcast from; a Safe cannot sign a forge broadcast, so it is **proposed to** instead,
and the proposal is signed by whoever holds the Ledger, an owner or a proposer of the Safe — the run asks the
device for that account, so nothing names it. `commit()` checks the sender against the gate before anything is
signed; whether the Ledger's account may propose is the Safe transaction service's call, once the proposal is
posted. `deploy()` is an ordinary broadcast from an executor keystore whatever committed: an
executor can only deploy what was already committed, and one transaction per contract is a long sequence to
confirm on a device.

**Committing from a key** — the namespace, or a delegate it named — is one signed transaction:

```bash
EXECUTORS=0xabc...,0xdef... forge script script/deploy/LaunchDeployer.s.sol --sig 'commit()' \
    --rpc-url ethereum --ledger --sender <namespace-or-delegate-address> --slow --broadcast
```

**Committing from a Safe** — one that holds the namespace, or one the namespace delegated to — ends in a
proposal its owners sign and execute afterwards. Nothing is broadcast and no key is passed: the run walks the
deployment, prints the table, and posts the proposal.

```bash
PROPOSER="--sender <safe-address> --ffi"
EXECUTOR="--account <keystore-name> --sender <executor-address> --slow"

# The Safe holds the namespace or was delegated to by it; the Ledger holds one of its owners or proposers
EXECUTORS=0xabc...,0xdef... forge script script/deploy/LaunchDeployer.s.sol --sig 'commit()' --rpc-url ethereum $PROPOSER

# Once that proposal has executed on chain, an executor deploys what it committed
forge script script/deploy/LaunchDeployer.s.sol --sig 'deploy()' --rpc-url ethereum $EXECUTOR --broadcast --verify
```

The proposal is still signed on a Ledger, but by safe-utils over ffi rather than by forge, so **`--ffi` is
required and `--ledger` must not be passed**: forge would hold the device transport and the ffi calls would
then fail. The run reads the signer's address off the device (`cast wallet address --ledger`) and posts the
proposal as it, so the two can never disagree; `LEDGER_DERIVATION_PATH` says where on the device that account
sits when it is not the first one.

An executor key is imported once with `cast wallet import <keystore-name> --interactive`, and forge asks for
its password on every run; the address it holds has to be one the commit phase named through `EXECUTORS`.
Name that address in `--sender` as well: left to itself forge simulates as its own default sender, and a run
that simulates as one account and broadcasts from another is how a salt or a namespace ends up belonging to
the wrong one.

The proposing run is the same walk as the broadcast one, and prints the same table and digest, so what you
rehearse on a testnet is what the Safe owners are shown. Only the last step differs, and only because the
committing account is a Safe. It also cannot bring a missing gate up beside the proposal — a run that both proposed and
broadcast would post the proposal over ffi and then fail to send the deferred transaction — so on a chain with
no gate the gate's own deployment is batched into the same Safe transaction. On such a chain only the namespace
can commit, there being no gate yet for a delegate to be named in. `revoke()` acts as the same account
`commit()` would; `deploy()` never does.

**Delegates** are named at any point through the gate's `setDelegate`, by the namespace, and change nothing
about the deployment except who may sign its commit phase: a Safe that delegates to a key turns the proposal
into a plain broadcast, a Ledger that delegates to a Safe turns the broadcast into a proposal, and what a
delegate commits waits out the namespace's `setDelay` before it can be deployed. No branch ships a script for
that call: the deployment does not need a delegate, and until it does, the namespace sends `setDelegate`
through its own tooling.

### Deploy onto a chain that already has a Root

Nothing to pass: a launch keeps whatever `contracts.root` the network's config records, rather than standing
a second contract holding the same authority beside it. The commands are the ordinary ones, and the entry
survives the run unchanged — same address, same block number — since a `REPLACE` write only drops the
contracts a run does not register. **To give a chain a fresh Root, delete `contracts.root` from
`env/<environment>/<network>.json` first** — and a config with no `contracts` at all, which is what the anvil
fixtures are, always gets one.

Read off the config rather than an env var on purpose. Root is a constructor argument of nearly everything
wired to it, so the two gate phases have to agree on it exactly — a file both of them read cannot differ
between them the way an environment variable can, and disagreeing costs the whole commitment
("Deployment does not match what was committed"). It is also why the anvil fixtures under `script/anvil/env/`
hold the input half only: a chain config that describes no deployment cannot hand a rehearsal a Root it has no
way to wire.

The deployment is then **not finished**. The action batchers wire the protocol from their constructors, which
works because a Root deployed alongside them wards them from its own — an existing Root wards nobody new, so
the wards it grants and the addresses it endorses cannot be set while deploying, whatever signs the run. The
run deploys a `RootFixes` for it instead and governance casts it over the ordinary timelock. Its address is
recorded nowhere: like the action batchers it is deploy-time only, so it stays out of
`env/<environment>/<network>.json`, which keeps to the contracts still part of the protocol. Both phases print
it as their last line — the committing one carries the address across the rollback that discards the rest of
its walk, so the follow-up is known before the deployment is signed. Keep that line:

```bash
ROOT=$(jq -r '.contracts.root.address' env/<environment>/<network>.json)
ROOT_FIXES=<the address the run printed>

# 1. schedule, from the guardian; 2. wait out root.delay(); 3. execute the rely; 4. cast, from anyone
cast send $ROOT 'scheduleRely(address)' $ROOT_FIXES ...
cast send $ROOT 'executeScheduledRely(address)' $ROOT_FIXES ...
cast send $ROOT_FIXES 'cast()' ...
```

`cast()` is permissionless because the authority is the ward, not the caller: until Root grants it there is
nothing it can do, and afterwards it does one fixed thing and gives the ward back. Until it has run, the
protocol has no path from Root into the new contracts — no pausing, no recovery, no scheduled upgrades — and
`spoke`, `asyncRequestManager`, `vaultRouter` and `tokenBridge` are unendorsed, so the vaults do not work.

### Resume an deploy phase that stopped partway

```bash
forge script script/deploy/LaunchDeployer.s.sol --sig 'deploy()' --rpc-url <network> $KEY --broadcast --resume
```

### If verification failed on the deploy run

```bash
forge script script/deploy/LaunchDeployer.s.sol --sig 'deploy()' --rpc-url <network> --resume --verify
```

### Local forks / every testnet

```bash
./script/anvil/anvil.sh                        # two local chains, deployed exactly the way mainnet is
```

Deploying a whole environment in one go is a CI concern, and lives on the `live` branch with the configs it
deploys against — every deployment that outlives a process is made from there. The base branch deploys only
the local pair above.

That matters for one reason worth knowing here. `LaunchDeployer` wires the adapters itself, from the action
batchers, pointing each remote peer at the address its own adapter landed on — right only because CREATE3
puts them at the same address on every chain given the same namespace and deployment id. That holds only if every
connected network is deployed in the same run, which is why the run reads its network list out of the
environment's connections file rather than being told one.

### Trying a deployment before committing to it

Use `anvil.sh`. Dropping `--broadcast` to "simulate" against a real network does run: a chain with no gate at
`DEPLOY_GATE_ADDRESS` gets one in the simulated state, so the walk completes and prints its table either way.
What a dry run cannot rehearse is the signature — `commit()` checks the sender against the namespace it
commits in, so it only passes for the namespace or one of its delegates; and a Safe sender ends in a proposal
instead, which needs a Ledger rather than a broadcast — and there is no dry run of a proposal: the run posts
it over ffi as soon as it is signed, `--broadcast` or not. `anvil.sh` sidesteps that: it brings up its own gate on a fork and rehearses the whole
sequence, which is also what ci.yml runs on every pull request.

### Network quirks

- **CI**: always add `--slow` — one transaction at a time costs minutes, a nonce race costs a redeploy.

Per-chain quirks — a chain that needs an explicit `--gas-price`, or anything else true of one network and
not the rest — are deployment data, kept beside the configs.

### Environment variables

| Variable | Meaning |
|---|---|
| `DEPLOY_ENVIRONMENT` | Which deployment to read, when a chain is described by more than one — `env/testnet/` beside `env/testnet-rev2/`. Unnecessary until that happens, and the run fails naming both candidates rather than picking one. It hides only the other deployments of its own environment: under `DEPLOY_ENVIRONMENT=testnet-rev2`, `env/mainnet/` is still read. A value naming no directory under `env/` is refused |
| `EXECUTORS` | Accounts allowed to run the deploy phase. **Required** by `commit()`, at least one. Read nowhere else |
| `LEDGER_DERIVATION_PATH` | Where on the Ledger the signer is. Defaults to the first account (`m/44'/60'/0'/0/0`), which is only a default: the Safe accepts a proposal from an owner or proposer, and the one you hold may sit at another path. Check before the run that it names such an account: `cast wallet address --ledger --mnemonic-derivation-path <path>` is exactly what the run asks the device. A proposal from any other is refused by the transaction service, so the cost of a wrong path is a rerun, not a bad commitment |
| `PRIVATE_KEY` | The testnet key `.env` holds, for you to pass as `--private-key`. No script reads it |

---

## Deployments go through the DeployGate

The protocol deployment is gated: the contracts are not deployed by the sender, they are deployed by a
`DeployGate` ([centrifuge/create3-gate](https://github.com/centrifuge/create3-gate), a dependency of this
repository under `lib/`), in two phases. A **namespace** commits the `(salt, init code hash)` of every contract, and the
executors allowed to deploy them, in a single transaction; any of those **executors** then deploys them one
by one.

| Step | Command | Signer | Transactions |
|---|---|---|---|
| Commit | `EXECUTORS=<addrs> forge script ... LaunchDeployer.s.sol --sig 'commit()' ...` | the namespace or a delegate of it — a key broadcasts it, a Safe is proposed to | **1**, whatever the contract count (~2.9M gas) |
| Deploy | `forge script ... LaunchDeployer.s.sol --sig 'deploy()' ...` | an executor | one per contract |
| Revoke | `forge script ... LaunchDeployer.s.sol --sig 'revoke()' ...` | the same as `commit()` | 1, only to drop a commitment |

The phases are separate entry points and **always separate forge runs**, on every network — testnets, CI and
anvil included; `run()` refuses to exist precisely so nobody runs both in one. That is how a deployment
separates the two in time — sign the commitment, look at it, come back for the deploy phase later — and it
is the only thing that proves the two agree: the deploy phase rebuilds every init code in a fresh process
and has to land on exactly what the commit phase committed, so anything phase-dependent in a constructor
argument (`msg.sender` is the classic) makes it abort with `NotCommitted` instead of deploying something
else. The addresses are identical either way: the phases are about when things are signed for, never about
where contracts land.

### Reading the commitment before signing it

`commit` sends two `bytes32[]` arrays, which is nothing a hardware wallet can show you, so the phase prints
what it is about to commit to: one row per contract, and a digest of the whole set.

```
Namespace 0x2e234DAe75C793f67A35089C9d99245E1C58470b
contract-version          address                                     initCodeHash
root-v3.1                 0x3640891e8fe34b03c4f78E5f147BDBdD94946F29  0x50c5b849f3f7432f8b76dbd1c65791c...
...
Committed 56 contracts in 1 transaction
Commitment digest 0x3f7a2e0c6402c5b06d8599279a7c89798db91a210e14d244239908152224f594
```

The table is generated by the run that builds the commitment, so on its own it only tells you what that run
did — it cannot vouch for itself. What makes it worth having is that **a second person can reproduce it**: the
commit phase deploys nothing, so anyone can run it against the same `--rpc-url` and config **without
`--broadcast`** and compare. Matching digests mean both machines built the same 56 contracts at the same
addresses from the same code; if they differ, the table says which row moved. That catches the realistic
failures — wrong network, wrong deployment id, stale `out/`, an unexpected contract in the set, a local edit nobody
mentioned.

The commitment is also readable on chain afterwards: `commit` emits a single
`Commit(namespace, id, indexed nonce, term, deployableAt, salts, initCodeHashes, executors)`, so the whole set
reads back from one log. And since nothing is deployed until the deploy phase, a commitment found to be wrong
costs one re-commit, not a redeployment.

Wiring is unaffected: the action batchers still do it, and they are deployed like every other contract.

### If a run stops halfway

`commit` is a single transaction, so it either lands or it does not: if it did not, run it again. To revoke
what a commitment allows, run it again as well: it starts a new generation, so whatever the new run does not
mention becomes undeployable, and with no salts at all nothing is deployable. Dropping a *single* salt once
part of the set is on chain means calling `commit` on the gate directly with the salts you still want —
`LaunchDeployer` walks the whole deployment, so it cannot rebuild a commitment whose addresses are taken.
`deploy` is one transaction per contract, so it can stop partway through, and the way to pick it up is
`--resume`.

Forge replays the broadcast sequence it saved instead of simulating the script again, so the transactions that
never landed are sent exactly as they were, and the gate still holds their commitments: `deploy` consumes one
salt at a time, so the contracts that did not go through are untouched by the ones that did. It needs the
executor's nonce to be where the interrupted run left it, and the `broadcast/` sequence file to still be there.

Because each phase is its own entry point, forge keys their broadcasts separately —
`broadcast/LaunchDeployer.s.sol/<chainId>/commit-latest.json` and `deploy-latest.json` — so `--resume`
always picks up the phase you name and cannot accidentally replay the other one. (That was a real hazard when
both phases went through `run()` and shared a single `run-latest.json`.)

What cannot be done is re-running a phase **from scratch** over a partial deployment. Without `--resume` the
script is simulated again, and it aborts on the first contract whose commitment was already spent
(`Deployment does not match what was committed`). Re-committing does not get around that either: its local walk
redeploys the whole protocol, and those addresses are now taken, so CreateX reverts. So if the broadcast
sequence is gone, the executor's nonce has moved, or the simulation itself is what failed, recovery means
moving the deployment to fresh addresses — a new `env/<environment>-<id>/`, or a version bump.

### Why the executors need no trust

A committed `(salt, init code)` pair leaves an executor no freedom. The salt fully determines the CREATE3
address and the hash fully determines the code, so an executor can only put the intended code at the
intended addresses, or revert. Authorizing several therefore costs no more trust than authorizing one: none of
them can produce anything the namespace did not commit to. Committing the init code alone would **not** be safe: the executor could then
deploy committed code at an address of its choosing, consume the commitment, and strand the intended address.

Deployment order is enforced outright: a commitment binds each contract to its position, and the gate keeps a
cursor per commitment, so a contract deployed out of turn reverts rather than landing early. The wiring would
catch it a second time — the action batchers wire from their constructors, and a call to a contract that does
not exist yet reverts — but that is a consequence, not the mechanism.

Neither does a superseded commitment linger. Every commit starts a new generation and only the live one can
be deployed from, so a set the namespace replaced cannot be spent afterwards — including the salts the replacement
dropped, which would otherwise stay deployable and let an executor strand a canonical address. Committing
with no salts at all is how a pending commitment is revoked outright, which is what `--sig 'revoke()'` sends.
It reaches the gate on its own rather than walking the deployment, since a commitment worth revoking is
usually one whose addresses are wrong or already half taken, and a walk over a taken address reverts inside
CreateX before it could revoke anything. What was already deployed stays deployed: revoking drops what is
left, it does not roll anything back.

### Roles

Nothing brings the gate up beforehand: the first run that needs one deploys it, in the same run, the way a
deployment makes sure CreateX is there. It takes no arguments and grants its deployer nothing, so there is
nothing to configure and no order to get right. Everything else lives in a **namespace** inside the gate,
named after an account. The gate has no roles of its own — no wards, no owner, no admin — only these two:

- **namespace** — the account every address derives from, alongside the gate and the salt. `network.namespace`
  in the chain's config names it, and it is mandatory there: a namespace can never be replaced, so a run that
  guessed it would put a whole protocol at addresses nobody meant. What kind of account it is — a Safe, a
  Ledger, a testnet key — is the config's business; two chains configured with two namespaces stay out of
  each other's addresses. Two namespaces can neither reach nor block each other.
- **delegates** — accounts the namespace lets sign `commit` on its behalf, through
  `setDelegate(delegatee, isValid)`. This is how a cold namespace key can be the thing addresses derive from
  while another account signs the phase — a warmer key, or a Safe whose owners do. The deployment does not
  depend on one, but naming one stays open at any point as an optional step, after which a run commits as
  the delegate — broadcast from it when it is a key, proposed to it when it is a Safe. What a
  delegate commits waits out the namespace's `setDelay`, and `clear` withdraws every delegation along with
  everything they committed. Delegation goes one way and one level deep: `setDelegate` always writes
  to the *caller's own* namespace, so a delegate naming one names it in its own, and there is no call that
  takes a namespace from the account it is named after. A leaked delegate key can commit, and can be revoked
  in one transaction; it can never be walked outwards or used to lock the namespace out.
- **executors** — named *by* the commitment, in the same transaction, any member of which may `deploy` what
  the live commitment holds and nothing else. They are interchangeable: none is confined to part of the
  commitment, so the phase can be split between keys or picked up by another when one becomes unavailable, and
  the deployment that comes out is the same whoever signed which part.

A namespace can hold several commitments at once, told apart by an **id** it picks: committing under an id
that already holds one replaces it, committing under a fresh one leaves the rest alone. Each id carries its
own generation and its own deployment cursor, so one commitment can be signed while another is still being
executed. This deployment does not use that — `GatedDeployer` passes a fixed `DEFAULT_COMMITMENT_ID`, so committing
again always replaces what came before. The id scopes permission and never an address: two commitments naming
the same salt still point at the same contract, and whichever deploys first takes it.

Two things follow from that shape, and both are deliberate. Revoking a leaked **executor** key means
committing again rather than sending one call — the commitment is replaced whole, executors included, and
committing nothing revokes them along with the salts. Revoking a **delegate** is one call, since delegation
sits beside the commitment rather than in it, and `clear()` is the same call for all of them at once: it
empties the namespace — every delegation, and every commitment made under any id — without needing to know
which ids a leaked key used. Addresses are untouched by it, so what was going to be deployed still can be.
`setDelay(seconds)` bounds a delegation before it is granted: what a delegate commits is not deployable until
that long has passed, which is the window a `clear()` has to land in. What the namespace commits itself never
waits. But the **namespace** itself cannot be replaced: it is what every address derives from, so there is
deliberately no way to move a namespace to another account. That key is what has to be looked after.

### Addresses

The gate performs CREATE3 itself — a CREATE2 proxy it deploys, whose only job is to `CREATE` the contract —
so an address derives from the gate and from a salt of the gate's own making, `keccak256(namespace, salt)`:

- Addresses differ from any deployment made before this contract existed, when the sender was the caller.
  Chains already running the protocol cannot be redeployed onto their current addresses.
- Addresses stay equal across chains, and the gate is what enforces it rather than the script. The deployer
  is the gate, and CREATE2 scopes the proxy to whoever deploys it, so no address the gate hands out is
  reachable from outside it: handing the same salt to CreateX, or to any other deployer, lands somewhere
  else. Nothing chain-specific enters the derivation, and the salt is a whole 32 bytes — nothing spent on a
  guardian or a redeploy flag — so what separates two namespaces is the full width of a hash. Whatever 32
  bytes a script passes, all of that holds.
- The gate itself is at the same address on every chain, and **anyone** can put it there. Its salt names no
  sender and no chain id, so CreateX derives it from the salt alone. It is deployed through `deployCreate2`,
  not `deployCreate3`, which is what makes that safe: a CREATE2 address covers the init code, so the only
  contract anyone can deploy at the gate's address is the gate. That is the one transaction CreateX is needed
  for — everything the gate goes on to deploy uses its own CREATE3, where the address ignores the init code,
  which is what keeps addresses still when a patch release changes a contract.
- The set deploys only in the order it was committed: a commitment binds each contract to its position, so an
  executor cannot deploy one before the contracts it is wired against have been. Order was the one thing left
  for it to choose, and it is not inert — a constructor reading a dependency the deployment itself wires would
  otherwise see a different value depending on when it ran.
- Nothing is ever deployed over, and nothing already deployed is reused. This script launches a protocol on a
  chain that does not have one; it is not how a release is layered onto a live chain. Rerunning it over an
  existing deployment aborts on the first contract whose address is taken, in either phase, and that is
  deliberate: the contracts of an earlier release are warded by that release's action batchers, which denied
  themselves once they were done, so a later run could not wire them even if it were allowed to redeploy
  around them. Shipping a change to a live chain is a dedicated script plus a spell, both on the `live`
  branch.
- The standalone scripts there still salt with `msg.sender`, so
  their addresses do not derive from the gate and no longer collide with the protocol's. **Their versions must
  never overlap with `FullDeployer`'s**: a name and version those scripts share with a gated deployment now
  lands on a second, unwired address instead of reverting on a taken one, and the config would record that one
  over the address that is actually wired in. Moving them onto the gate as well is the real fix.

### Keys

- The gate to deploy through is `DEPLOY_GATE_ADDRESS` in `create3-gate/script/DeployGate.d.sol`, the same on every
  chain, so there is nothing to look up, nothing to pass by hand and no env file to keep in step with it.
  A chain that has no gate yet gets one from the run that needs it, so there is nothing to deploy first. The
  constant follows the gate's bytecode, so any change to `DeployGate.sol` — or to the compiler settings it is built
  with — moves it; `testConstantsMatchTheBytecode`, in the gate's own repository, fails with the value to put
  into `DeployGate.d.sol` when that happens.
- The gate's address depends on nothing but its code, so no key stands behind it and nothing has to run
  first: `commit()` brings it up on a chain that has none, and finds it on a chain that has. Changing the
  contract is what would move it, which is why its code is frozen once a chain has one.
- Nobody can put other code at that address. The address is
  `keccak256(0xff ‖ CreateX ‖ keccak256(abi.encode(salt)) ‖ keccak256(initCode))[12:]`, so different init code
  is a different address; reaching the gate's from any other init code, factory or `CREATE` nonce means
  finding a 160-bit preimage. Two things narrow that to something worth checking rather than assuming:
  a constructor that reads state can return different runtime code from the same init code, which is why the
  gate has no immutables and reads nothing — its own repository pins `DEPLOY_GATE_EXTCODEHASH` against
  `type(DeployGate).runtimeCode`, and Solidity refusing that expression for a contract with immutables is what
  keeps it true. And the derivation
  belongs to the chain: a chain that derives addresses its own way is the one place an address stops speaking
  for the code behind it. So every run that touches the gate checks its runtime code against
  `DEPLOY_GATE_EXTCODEHASH` before deploying through it, rather than trusting the address.
- `network.namespace` is what needs the continuity instead. Every protocol address derives from it, so it has
  to be the same account on every chain, and there is no recovery if it is lost, since nothing can commit in a
  namespace on its behalf — a delegate commits *for* it and only while it says so. Whether that account is a
  Safe or a key kept cold behind a delegate is a choice the scripts take no side on. Changing the field moves
  every address the chain would deploy to, so it is set once, when the config is written.
- `EXECUTORS` names the accounts allowed to run the deploy phase, a comma-separated list read by the commit
  phase, which grants them in the namespace: `EXECUTORS=0xabc...,0xdef... forge script ... --sig 'commit()'`. They can
  be the namespace's keys or keys with no privilege anywhere else. They are **part** of the commitment, so
  changing the set means committing again, and an executor holds no privilege beyond deploying what has been
  committed. Required by `commit()` on every network, and at least one — naming nobody would sign a
  commitment no key can spend, so it refuses rather than letting it through. `deploy()` never reads it.
- A deployment id does **not** move the gate: one gate serves every deployment on a chain, and an id isolates a
  deployment inside it, by salt, the way a namespace isolates one from another. The isolation is of
  addresses, not of the commitment slot: `GatedDeployer` pins a single id, so a namespace holds one live
  commitment whatever the id, and committing a new deployment replaces what the namespace still had
  pending — what that one already executed stays deployed, what it had not needs committing again. Two
  deployments in flight at once take two namespaces, which off mainnet is just two signers.
- The `DeployGate` holds **no** protocol permissions at any point, so it cannot touch a live deployment.

---

## How a deployment reaches `env/<environment>/<network>.json`

One step: **the deploy script records itself, as it deploys.** `JsonRegistry` (`startDeploymentOutput()` +
`register()`, which `reportedSalt()` already calls, + `saveDeploymentOutput(path)`) merges the names,
addresses, versions and block numbers straight into `env/<environment>/<network>.json`. Every script that deploys does this
for what it produces, because the running script is the only thing that knows those addresses. Nothing has to
be run afterwards.

**`startBlock` is the earliest block any contract in the config carries**, recomputed on every write rather
than set to the current run's block. A redeployment that reuses contracts leaves older ones in place, and an
indexer starting after one of them would miss its history.

### On the block numbers being approximate

The write happens during forge's simulation pass, before the broadcast lands. For addresses that is exact —
they are deterministic, CREATE3 from the gate, the salt and the deployment id, so what is written is what will be
deployed, including after a later `--resume`.

For block numbers it is an **underestimate**: `block.number` during simulation is the block the script read,
and the transactions land a few blocks later — measured at 1 on a local fork and up to ~183 on a fast chain.
Every contract in a run therefore shares one block number, since simulation does not advance.

That is deliberate, and it is the safe direction. These feed indexers, which must not begin *after* a
contract exists; beginning a little before costs some scanning and nothing else. Getting exact per-contract
numbers would mean reading them back from a block explorer afterwards, which is a second command, on a
machine with an API key, for chains whose explorers can answer — and the value of that over "a few blocks
early" did not justify it.

Only an abandoned deployment leaves entries for contracts that never landed, and re-running fixes it.

`env/` stays read-only in `fs_permissions`, so a test or a stray script still cannot rewrite a config through
a cheatcode. The write goes through jq behind ffi, which also keeps the diff down to what actually changed.

Making a new address readable back is: `register()` it in the deploy script, and add the field to
`ContractsConfig` in `script/utils/EnvConfig.s.sol`.

A run that deploys nothing (`commit()`) must not call `startDeploymentOutput()` /
`saveDeploymentOutput()` at all. Registrations made during a walk that is rolled back with `vm.revertToState`
disappear with it, since the registry keeps its state in storage.

---

## Secrets

Secrets are fetched from Google Secret Manager into `.env` by `script/setup/load-secrets.sh`, and added or
rotated with `script/setup/add-gcp-secret.sh`. Both ship with the deployment configs, since the keys they hold
are the networks' and the deployments that spend them are theirs — main, carrying no configs, reaches no
network: it has no `[etherscan]` entries, interpolates no API key, and its only chains are the two bare anvil
aliases. Which secret becomes which variable is documented beside the configs.

What is masked where is below, and that half is main's, because it is a property of the runner rather than
of any network.

## Keeping secrets out of CI logs

Nothing in the deploy path prints a secret on purpose, but the tools do: **forge, cast and anvil put the
resolved RPC URL — API key and all — into their connection errors**, which is exactly what a failing CI job
produces. Two mechanisms cover that, and they cover different things.

- **The live log** is handled by `load-secrets.sh`, which registers every value it puts in `.env` with the
  runner (`::add-mask::`) whenever `GITHUB_ACTIONS` is set. Any workflow that calls it is covered without
  doing anything.
- **Files** are not covered by masking, which only rewrites the log stream. Anything uploaded as an artifact
  goes through `./script/setup/redact-secrets.sh` first. `weekly-validation.yml` here is a trigger: the live
  branch's entrypoint redacts its forge output before writing it where the upload step reads, and the
  `report-failures` job that pastes that output into a GitHub issue masks anything shaped like a keyed RPC URL
  again, as defence in depth.

Two details worth knowing:

- Deploy commands never carry a key: `--rpc-url <network>` passes an `[rpc_endpoints]` **alias** and
  `--verify` reads `[etherscan]`, both resolved by forge internally. The local chains carry none at all —
  `script/anvil/anvil.sh` starts bare anvil, no fork, no URL, no key, and its `anvil-*.log` is gitignored.

GitHub only auto-masks `${{ secrets.* }}`. Values from Secret Manager arrive at runtime, so nothing masks
them unless the loader does.

---

## Network config and RPC endpoints

Per-network config lives in **`env/<environment>/<network>.json`**: chain id, environment, admins, adapter config, and the
deployed `contracts` section. **RPC URLs live in `foundry.toml`** under `[rpc_endpoints]`, one alias per
network, API key interpolated from the environment; **verification keys live next to them** under
`[etherscan]`. The command line and Solidity reach the same endpoint through the same alias (`--rpc-url
<network>` / `vm.rpcUrl(<network>)`).

`env/<environment>/<network>.json` is the source of truth for all of it. The two `foundry.toml` tables are
derived from it, because forge's Rust side cannot read the env files, so **adding a network is one edit plus
one command** — `check_foundry_networks.py --fix`, which ships beside the deployment configs it derives
from. Main's tables hold nothing but the two anvil aliases, written by hand.

`.network.baseRpcUrl` feeds that generator and nothing else — deliberately. Solidity does not parse it, and
no shell script composes a URL from it: everything goes through the alias, so there is one way to reach a
network and one place its API key is named.

### The two explorer URLs

A network can name **two** explorer endpoints, because on some chains they are two different services:

| field | what it is | who uses it |
|---|---|---|
| `.network.verifierUrl` | where source is **submitted** for verification | `forge verify-contract`, and `[etherscan]` in `foundry.toml` |
| `.network.explorerApiUrl` | where an Etherscan-compatible **read** goes | asking whether a contract is verified already |

Both default to Etherscan's multichain v2 endpoint for the network's chain id, so most networks set neither.
Set `verifierUrl` when verification goes somewhere else; set `explorerApiUrl` only when reads do.

They coincide on Etherscan, and on Blockscout instances exposing an Etherscan-compatible `/api`. They
diverge where an explorer's submission endpoint rejects reads, which is why the two fields exist at all.
Which chains are in which case is a property of the deployment, so the roll call lives with the configs on
the live branch.

Getting this wrong is quiet rather than loud: nothing fails, the verification run just reports every
contract on the chain as unverified and re-submits it.

### Chains that verify somewhere other than Etherscan

`.network.verifier` names the verifier forge is told to use, and it has to be one forge knows:
`etherscan`, `sourcify` or `blockscout`. A config that leaves it unset goes to Etherscan.

Where a chain has no `[etherscan]` entry, that absence *is* the mechanism: finding no key for the chain,
forge falls back to the verifier named on the command line. So `check_foundry_networks.py` omitting an entry
and `--verifier` naming one are two halves of the same decision — see `NON_ETHERSCAN_VERIFIERS` there. Which
chains need that, and which explorers cannot answer a verification read at all, is deployment data,
documented beside the configs.

### What a run does to `env/<environment>/<network>.json`

Every deploy script records what it deployed, and the write is a **merge**: a contract the run does not
mention keeps whatever the config said, so a script that adds to an existing deployment can write to a file without
erasing each other.

`LaunchDeployer` is the exception: it opens its run with `startDeploymentOutput(REPLACE)`. It launches a
protocol on a chain that has none, so the set it deploys is the whole of that chain's contracts and it
**replaces** them — anything the config held belonged to a
deployment this one supersedes, and leaving it there would keep unreachable addresses beside live ones with
nothing marking them dead. A contract re-reported at the address it already had keeps its block number, so
finishing a partial run with `--resume` does not redate what the first attempt landed.

## Logs and state

- Forge's broadcast sequences: `broadcast/<script>.s.sol/<chainId>/`. `--resume` replays these; nothing else
  reads them.
- anvil output from `anvil.sh`: `anvil-<network>.log` (gitignored — it contains the fork URL, API key
  included).
