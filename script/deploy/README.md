# Centrifuge Protocol – Deployment

Launching the protocol on a chain that does not have one. For changing a chain that already runs it, see
`script/ops/`; for a map of all the script directories, see [`../README.md`](../README.md).

There is no wrapper: **every intent is one forge command**. `--rpc-url <network>` is the only input that
selects a network: it decides where the run connects, and `Env.detect()` matches that chain id against
`env/*.json` to decide which config it reads, so the two cannot disagree. There is no override. The RPC URL
itself and the verification key come from `foundry.toml` (`[rpc_endpoints]`, `[etherscan]`). The signer is always passed explicitly, so a
testnet run and a mainnet run have the same shape and differ only in who signs. The two things that cannot be
a forge command — bringing up local forks, and a test that spans networks and waits for relays — have one
dedicated script each: `anvil.sh` here and `../testnet/crosschaintest.sh`.

**Run everything from the repository root.**

---

## Prerequisites

```bash
./script/setup/setup.sh           # tools: git, jq, curl, Foundry, gcloud
gcloud auth login                 # needs access to the centrifuge-production-x project
./script/setup/load-secrets.sh    # API keys + testnet deployer key -> .env
```

---

## Cookbook

### Deploy the protocol (testnet)

```bash
set -a; . ./.env; set +a    # once per shell: forge loads .env for itself, not for your shell
export SUFFIX=vXYZ          # off mainnet, isolates the deployment onto its own addresses
KEY="--private-key $PRIVATE_KEY"

EXECUTORS=<address> forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url sepolia $KEY --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url sepolia $KEY --broadcast --verify
forge script script/testnet/TestData.s.sol --rpc-url sepolia $KEY --broadcast   # optional test data
```

`LaunchDeployer` writes the addresses, versions and block numbers into `env/sepolia.json` itself, as it
deploys. There is no follow-up step and nothing to remember.

### Deploy the protocol (mainnet)

On mainnet the **validator is the protocol Safe**. It is what every mainnet address derives from and it can
never be replaced, so it has to outlive any single key — and it is at the same address on every chain the
protocol runs on, which is what a validator has to be.

A Safe cannot sign a forge broadcast, so the two phases are signed differently, and `LaunchDeployer` picks
which by looking at the validator: a contract is proposed to, a key is broadcast from. On mainnet that makes
`validate()` a **Safe proposal** the owners sign afterwards, and `execute()` an ordinary broadcast from an
executor keystore. Nothing is lost by the split — an executor can only deploy what was already committed, and
one transaction per contract is a long sequence to confirm on a device.

```bash
PROPOSER="--sender <safe-owner-address> --ffi"
EXECUTOR="--account <keystore-name> --sender <executor-address> --slow"

# The commitment, proposed to the Safe. Nothing is broadcast and no key is passed: the run walks the
# deployment, prints the table, and posts the proposal for the Safe owners to sign and execute.
# EXECUTORS is read by validate, which is what names them: the gate holds no executor outside a commitment
EXECUTORS=0xabc...,0xdef... forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url ethereum $PROPOSER

# Once that proposal has executed on chain, an executor deploys what it committed
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()' --rpc-url ethereum $EXECUTOR --broadcast --verify
```

The proposal is still signed on a Ledger, but by safe-utils over ffi rather than by forge, so **`--ffi` is
required and `--ledger` must not be passed**: forge would hold the device transport and the ffi signing call
would then fail. `--sender` has to be the address the Ledger derives — the proposal is rejected otherwise —
and `LEDGER_DERIVATION_PATH` overrides the default path. Pick the account with
`cast wallet address --ledger --mnemonic-index <n>`.

An executor key is imported once with `cast wallet import <keystore-name> --interactive`, and forge asks for
its password on every run; the address it holds has to be one the validate phase named through `EXECUTORS`.
Name that address in `--sender` as well: left to itself forge simulates as its own default sender, and a run
that simulates as one account and broadcasts from another is how a salt or a namespace ends up belonging to
the wrong one.

The proposing run is the same walk as the testnet one, and prints the same table and digest, so what you
rehearse on a testnet is what the Safe owners are shown. Only the last step differs, and only because the
validator is a Safe. It also cannot bring a missing gate up beside the proposal — a run that both proposed and
broadcast would post the proposal over ffi and then fail to send the deferred transaction — so on a chain with
no gate the gate's own deployment is batched into the same Safe transaction. `revoke()` follows the validator
the same way; `execute()` never does.

The Safe can also name a **delegate** at any point (`ProposeSetDelegate`, itself a Safe proposal) — an
optional step that turns the validator-signed phases back into ordinary broadcasts: a run signed by a
delegate is not proposed, it commits to the gate directly from its own key, `validate()` and `revoke()`
alike — one transaction, no owner round-trip, which is also the fast path for dropping or replacing a
commitment in a hurry. Runs signed by anyone else keep following the validator and end in a proposal.

```bash
# Optional, once per chain: name a delegate. Afterwards it signs the phases as ordinary broadcasts
DELEGATE_ADDR=<delegate-address> forge script script/ops/ProposeSetDelegate.s.sol --sig 'grant()' \
    --rpc-url ethereum --sender <safe-owner-address> --ffi

EXECUTORS=0xabc...,0xdef... forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' \
    --rpc-url ethereum --ledger --sender <delegate-address> --slow --broadcast
```

### Resume an execute phase that stopped partway

```bash
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()' --rpc-url <network> $KEY --broadcast --resume
```

### If verification failed on the execute run

```bash
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()' --rpc-url <network> --resume --verify
```

### Local forks / every testnet / cross-chain test

```bash
./script/deploy/anvil.sh                       # two local forks, deployed exactly the way mainnet is
./script/testnet/crosschaintest.sh base-sepolia # cross-chain adapter isolation test
```

Deploying **all** testnets in one go is a CI concern and lives in `.github/workflows/deploy-testnets.yml` as
a network matrix running the cookbook commands above. That workflow is manual (`workflow_dispatch`) only, and
testnets only: the sole signing key CI can reach is the testnet one, and mainnet is signed on a Ledger, so a
mainnet deployment never runs there.

It does no wiring of its own, because `LaunchDeployer` already wires the adapters from the action batchers —
pointing each remote peer at the address its own adapter landed on, which is right because CREATE3 puts them
at the same address on every chain given the same validator and `SUFFIX`. That only holds if every connected
network is deployed in the same run, so the workflow does not hard-code which networks those are: it reads
them out of `env/connections/testnet.json` when it starts. Adding a network to the connections file is
therefore the entire change needed to have it deployed and wired.

### Trying a deployment before committing to it

Use `anvil.sh`. Dropping `--broadcast` to "simulate" against a real network does run: a chain with no gate at
`DEPLOY_GATE_ADDRESS` gets one in the simulated state, so the walk completes and prints its table either way.
What a dry run cannot rehearse is the signature — `validate()` checks the sender against the namespace it
commits in, so it only passes for a sender the namespace answers to: the validator, when it is a key, or one
of its delegates. Where the validator is a Safe and no delegate signs, the run ends in a proposal instead,
which needs a Ledger rather than a broadcast. `anvil.sh` sidesteps that: it brings up its own gate on a fork and rehearses the whole
sequence, which is also what ci.yml runs on every pull request.

### Network quirks

- **base-sepolia**: add `--gas-price 100000000000 --slow`, or receipts stay pending forever.
- **CI**: always add `--slow` — one transaction at a time costs minutes, a nonce race costs a redeploy.

### Environment variables

| Variable | Meaning |
|---|---|
| `EXECUTORS` | Accounts allowed to run the execute phase. **Required** by `validate()`, at least one. Read nowhere else |
| `VALIDATOR` | Namespace the addresses derive from. Off mainnet only, defaulting to the signer; pinned to the protocol Safe on mainnet. Two phases signed by different keys have to pass it to **both**, or the second reads another namespace |
| `DELEGATE_ADDR` | Account `ProposeSetDelegate` names, or drops. Required by that script, read nowhere else |
| `LEDGER_DERIVATION_PATH` | Where on the Ledger the signer is. Optional, defaulting to the first account |
| `SUFFIX` | Isolates a deployment onto its own addresses. Optional, and ignored on mainnet |
| `PRIVATE_KEY` | The testnet key `.env` holds, for you to pass as `--private-key`. No script reads it |

---

## Deployments go through the DeployGate

The protocol deployment is gated: the contracts are not deployed by the sender, they are deployed by a
`DeployGate`, in two phases. A **validator** commits the `(salt, init code hash)` of every contract, and the
executors allowed to deploy them, in a single transaction; any of those **executors** then deploys them one
by one.

| Step | Command | Signer | Transactions |
|---|---|---|---|
| Validate | `EXECUTORS=<addrs> forge script ... LaunchDeployer.s.sol --sig 'validate()' ...` | the validator — a key broadcasts it, a Safe is proposed to | **1**, whatever the contract count (~2.9M gas) |
| Execute | `forge script ... LaunchDeployer.s.sol --sig 'execute()' ...` | an executor | one per contract |
| Revoke | `forge script ... LaunchDeployer.s.sol --sig 'revoke()' ...` | the validator, same either way | 1, only to drop a commitment |

The phases are separate entry points and **always separate forge runs**, on every network — testnets, CI and
anvil included; `run()` refuses to exist precisely so nobody runs both in one. That is how a deployment
separates the two in time — sign the commitment, look at it, come back for the execute phase later — and it
is the only thing that proves the two agree: the execute phase rebuilds every init code in a fresh process
and has to land on exactly what the validate phase committed, so anything phase-dependent in a constructor
argument (`msg.sender` is the classic) makes it abort with `NotValidated` instead of deploying something
else. The addresses are identical either way: the phases are about when things are signed for, never about
where contracts land.

### Reading the commitment before signing it

`validate` sends two `bytes32[]` arrays, which is nothing a hardware wallet can show you, so the phase prints
what it is about to commit to: one row per contract, and a digest of the whole set.

```
Validator 0x2e234DAe75C793f67A35089C9d99245E1C58470b
contract-version          address                                     initCodeHash
root-v3.1                 0x3640891e8fe34b03c4f78E5f147BDBdD94946F29  0x50c5b849f3f7432f8b76dbd1c65791c...
...
Validated 56 contracts in 1 transaction
Commitment digest 0x3f7a2e0c6402c5b06d8599279a7c89798db91a210e14d244239908152224f594
```

The table is generated by the run that builds the commitment, so on its own it only tells you what that run
did — it cannot vouch for itself. What makes it worth having is that **a second person can reproduce it**: the
validate phase deploys nothing, so anyone can run it against the same `--rpc-url` and `SUFFIX` **without
`--broadcast`** and compare. Matching digests mean both machines built the same 56 contracts at the same
addresses from the same code; if they differ, the table says which row moved. That catches the realistic
failures — wrong network, wrong suffix, stale `out/`, an unexpected contract in the set, a local edit nobody
mentioned.

The commitment is also readable on chain afterwards: `validate` emits a single
`Validate(validator, id, nonce, salts, initCodeHashes, executors)`, so the whole set reads back from one log.
And since nothing is deployed until the execute phase, a commitment found to be wrong costs one re-validation,
not a redeployment.

Wiring is unaffected: the action batchers still do it, and they are deployed like every other contract.

### If a run stops halfway

`validate` is a single transaction, so it either lands or it does not: if it did not, run it again. To revoke
what a commitment allows, run it again as well: it starts a new generation, so whatever the new run does not
mention becomes undeployable, and with no salts at all nothing is deployable. Dropping a *single* salt once
part of the set is on chain means calling `validate` on the gate directly with the salts you still want —
`LaunchDeployer` walks the whole deployment, so it cannot rebuild a commitment whose addresses are taken.
`execute` is one transaction per contract, so it can stop partway through, and the way to pick it up is
`--resume`.

Forge replays the broadcast sequence it saved instead of simulating the script again, so the transactions that
never landed are sent exactly as they were, and the gate still holds their validations: `deploy` consumes one
salt at a time, so the contracts that did not go through are untouched by the ones that did. It needs the
executor's nonce to be where the interrupted run left it, and the `broadcast/` sequence file to still be there.

Because each phase is its own entry point, forge keys their broadcasts separately —
`broadcast/LaunchDeployer.s.sol/<chainId>/validate-latest.json` and `execute-latest.json` — so `--resume`
always picks up the phase you name and cannot accidentally replay the other one. (That was a real hazard when
both phases went through `run()` and shared a single `run-latest.json`.)

What cannot be done is re-running a phase **from scratch** over a partial deployment. Without `--resume` the
script is simulated again, and it aborts on the first contract whose validation was already spent
(`Deployment does not match what was validated`). Re-validating does not get around that either: its local walk
redeploys the whole protocol, and those addresses are now taken, so CreateX reverts. So if the broadcast
sequence is gone, the executor's nonce has moved, or the simulation itself is what failed, recovery means
moving the deployment to fresh addresses — a new `SUFFIX` off mainnet, a version bump on it.

### Why the executors need no trust

A committed `(salt, init code)` pair leaves an executor no freedom. The salt fully determines the CREATE3
address and the hash fully determines the code, so an executor can only put the intended code at the
intended addresses, or revert. Authorizing several therefore costs no more trust than authorizing one: none of
them can produce anything the validator did not commit to. Committing the init code alone would **not** be safe: the executor could then
deploy validated code at an address of its choosing, consume the validation, and strand the intended address.

Deployment order is enforced outright: a commitment binds each contract to its position, and the gate keeps a
cursor per commitment, so a contract deployed out of turn reverts rather than landing early. The wiring would
catch it a second time — the action batchers wire from their constructors, and a call to a contract that does
not exist yet reverts — but that is a consequence, not the mechanism.

Neither does a superseded commitment linger. Every validation starts a new generation and only the live one can
be deployed from, so a set the validator replaced cannot be spent afterwards — including the salts the replacement
dropped, which would otherwise stay deployable and let an executor strand a canonical address. Validating
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

- **validator** — the account every address derives from, alongside the gate and the salt. On mainnet it is
  the protocol Safe (`PROTOCOL_SAFE`), which is the same address on all eleven mainnets and is the only
  account that can plausibly outlive the deployment, since a validator can never be replaced. Elsewhere
  `VALIDATOR` names it, defaulting to the sender, so two developers on one testnet stay out of each other's
  addresses without having to agree on anything. Two namespaces can neither reach nor block each other.
- **delegates** — accounts the validator lets sign `validate` on its behalf, through
  `setDelegate(delegatee, isValid)`. This is how a cold validator key can be the thing addresses derive from
  while a warmer key signs the phase. The deployment no longer depends on one — a Safe validator is proposed
  to instead, which needs no second account — but naming one stays open at any point as an optional step:
  `ProposeSetDelegate` proposes the call, and a run signed by the delegate afterwards broadcasts to the gate
  directly instead of being proposed. Delegation goes one way and one level deep: `setDelegate` always writes
  to the *caller's own* namespace, so a delegate naming one names it in its own, and there is no call that
  takes a namespace from the account it is named after. A leaked delegate key can commit, and can be revoked
  in one transaction; it can never be walked outwards or used to lock the validator out.
- **executors** — named *by* the commitment, in the same transaction, any member of which may `deploy` what
  the live commitment holds and nothing else. They are interchangeable: none is confined to part of the
  commitment, so the phase can be split between keys or picked up by another when one becomes unavailable, and
  the deployment that comes out is the same whoever signed which part.

A validator can hold several commitments at once, told apart by an **id** it picks: committing under an id
that already holds one replaces it, committing under a fresh one leaves the rest alone. Each id carries its
own generation and its own deployment cursor, so one commitment can be signed while another is still being
executed. This deployment does not use that — `GatedDeployer` passes a fixed `DEFAULT_COMMITMENT_ID`, so committing
again always replaces what came before. The id scopes permission and never an address: two commitments naming
the same salt still point at the same contract, and whichever deploys first takes it.

Two things follow from that shape, and both are deliberate. Revoking a leaked **executor** key means
committing again rather than sending one call — the commitment is replaced whole, executors included, and
committing nothing revokes them along with the salts. Revoking a **delegate** is one call, since delegation
sits beside the commitment rather than in it. But the **validator** itself cannot be replaced: it is what
every address derives from, so there is deliberately no way to move a namespace to another account. That key
is what has to be looked after.

### Addresses

CreateX derives a CREATE3 address from its caller and the salt, and the caller is now the `DeployGate`, so:

- Addresses differ from any deployment made before this contract existed, when the sender was the caller.
  Chains already running the protocol cannot be redeployed onto their current addresses.
- Addresses stay equal across chains, and the gate is what enforces it rather than the script. It builds its
  own CreateX salt, `bytes20(gate) ‖ 0x00 ‖ bytes11(keccak256(validator, salt))`, so a script cannot ask for
  one that names another guardian — which would put the address outside the gate, where anyone could take it —
  or one that turns the cross-chain redeploy protection on, which would fold the chain id in. Whatever 32
  bytes a script passes, both properties hold.
- The gate itself is at the same address on every chain, and **anyone** can put it there. Its salt names no
  sender and no chain id, so CreateX derives it from the salt alone. It is deployed through `deployCreate2`,
  not `deployCreate3`, which is what makes that safe: a CREATE2 address covers the init code, so the only
  contract anyone can deploy at the gate's address is the gate. Everything the gate goes on to deploy uses
  CREATE3, where the address ignores the init code, which is what keeps addresses still when a patch release
  changes a contract.
- The set deploys only in the order it was committed: a commitment binds each contract to its position, so an
  executor cannot deploy one before the contracts it is wired against have been. Order was the one thing left
  for it to choose, and it is not inert — a constructor reading a dependency the deployment itself wires would
  otherwise see a different value depending on when it ran.
- Nothing is ever deployed over, and nothing already deployed is reused. This script launches a protocol on a
  chain that does not have one; it is not how a release is layered onto a live chain. Rerunning it over an
  existing deployment aborts on the first contract whose address is taken, in either phase, and that is
  deliberate: the contracts of an earlier release are warded by that release's action batchers, which denied
  themselves once they were done, so a later run could not wire them even if it were allowed to redeploy
  around them. Shipping a change to a live chain is a dedicated script plus a spell, as in
  `DeployOnchainPMV2`.
- The standalone scripts (`DeployAdapters`, `DeployOnchainPMV2`) still salt with `msg.sender`, so
  their addresses do not derive from the gate and no longer collide with the protocol's. **Their versions must
  never overlap with `FullDeployer`'s**: a name and version those scripts share with a gated deployment now
  lands on a second, unwired address instead of reverting on a taken one, and the config would record that one
  over the address that is actually wired in. Moving them onto the gate as well is the real fix.

### Keys

- The gate to deploy through is `DEPLOY_GATE_ADDRESS` in `script/utils/gate/DeployGate.d.sol`, the same on every
  chain, so there is nothing to look up, nothing to pass by hand and no env file to keep in step with it.
  A chain that has no gate yet gets one from the run that needs it, so there is nothing to deploy first. The
  constant follows the gate's bytecode, so any change to `DeployGate.sol` — or to the compiler settings it is built
  with — moves it; `testConstantsMatchTheBytecode` fails with the value to paste in when that happens.
- The gate's address depends on nothing but its code, so no key stands behind it and nothing has to run
  first: `validate()` brings it up on a chain that has none, and finds it on a chain that has. Changing the
  contract is what would move it, which is why its code is frozen once a chain has one.
- Nobody can put other code at that address. The address is
  `keccak256(0xff ‖ CreateX ‖ keccak256(abi.encode(salt)) ‖ keccak256(initCode))[12:]`, so different init code
  is a different address; reaching the gate's from any other init code, factory or `CREATE` nonce means
  finding a 160-bit preimage. Two things narrow that to something worth checking rather than assuming:
  a constructor that reads state can return different runtime code from the same init code, which is why the
  gate has no immutables and reads nothing — `isDeployGateDeployed` compares against `type(DeployGate).runtimeCode`, and
  Solidity refusing that expression for a contract with immutables is what keeps it true. And the derivation
  belongs to the chain: a chain that derives addresses its own way is the one place an address stops speaking
  for the code behind it. So every run that touches the gate checks its runtime code against
  `DEPLOY_GATE_EXTCODEHASH` before deploying through it, rather than trusting the address.
- `VALIDATOR` is what needs the continuity instead. Every protocol address derives from it, so it has to be
  the same account on every chain — which on mainnet is the protocol Safe, for exactly that reason. It never
  signs a phase from a key: it is proposed to, and its owners sign. There is no recovery if the
  Safe is lost, since nothing can commit in a namespace on its behalf, which is why it is a Safe and not a
  key.
- `EXECUTORS` names the accounts allowed to run the execute phase, a comma-separated list read by the validate
  phase, which grants them in the namespace: `EXECUTORS=0xabc...,0xdef... forge script ... --sig 'validate()'`. They can
  be the validator's keys or keys with no privilege anywhere else. They are **part** of the commitment, so
  changing the set means committing again, and an executor holds no privilege beyond deploying what has been
  committed. Required by `validate()` on every network, and at least one — naming nobody would sign a
  commitment no key can spend, so it refuses rather than letting it through. `execute()` never reads it.
- `SUFFIX` does **not** move the gate: one gate serves every deployment on a chain, and a suffix isolates a
  deployment inside it, by salt, the way a validator isolates one from another. The isolation is of
  addresses, not of the commitment slot: `GatedDeployer` pins a single id, so a validator holds one live
  commitment whatever the suffix, and validating a new deployment replaces what the namespace still had
  pending — what that one already executed stays deployed, what it had not needs validating again. Two
  deployments in flight at once take two validators, which off mainnet is just two signers.
- The `DeployGate` holds **no** protocol permissions at any point, so it cannot touch a live deployment.

---

## How a deployment reaches `env/<network>.json`

One step: **the deploy script records itself, as it deploys.** `JsonRegistry` (`startDeploymentOutput()` +
`register()`, which `createSalt()` already calls, + `saveDeploymentOutput(network)`) merges the names,
addresses, versions and block numbers straight into `env/<network>.json`. The scripts that deploy —
`LaunchDeployer`, `DeployAdapters`, `DeployGasService` — each do this for what they
produce, because the running script is the only thing that knows those addresses. Nothing has to be run
afterwards.

**`startBlock` is the earliest block any contract in the config carries**, recomputed on every write rather
than set to the current run's block. A redeployment that reuses contracts leaves older ones in place, and an
indexer starting after one of them would miss its history.

### On the block numbers being approximate

The write happens during forge's simulation pass, before the broadcast lands. For addresses that is exact —
they are deterministic, CREATE3 from the gate, the salt and `SUFFIX`, so what is written is what will be
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

A run that deploys nothing (`validate()`) must not call `startDeploymentOutput()` /
`saveDeploymentOutput()` at all. Registrations made during a walk that is rolled back with `vm.revertToState`
disappear with it, since the registry keeps its state in storage.

---

## Secrets

`./script/setup/load-secrets.sh` fetches them from Google Secret Manager into `.env`, keeping any value
already present; `./script/setup/add-gcp-secret.sh` adds or rotates one. See `script/setup/` and the
"Keeping secrets out of CI logs" section below for what is masked where.

| Secret name | Becomes | Used for |
|-------------|---------|----------|
| `protocol-etherscan-api` | `ETHERSCAN_API_KEY` | `--verify`, and VerifyFactoryContracts' explorer lookups |
| `protocol-alchemy-api` | `ALCHEMY_API_KEY` | RPC for every Alchemy-hosted network |
| `protocol-plume-api` | `PLUME_API_KEY` | RPC for Plume |
| `protocol-pharos-api` | `PHAROS_API_KEY` | RPC for Pharos (via Zan) |
| `protocol-testnet-private-key` | `PRIVATE_KEY` | Testnet signer. Never used on mainnet |

## Keeping secrets out of CI logs

Nothing in the deploy path prints a secret on purpose, but the tools do: **forge, cast and anvil put the
resolved RPC URL — API key and all — into their connection errors**, which is exactly what a failing CI job
produces. Two mechanisms cover that, and they cover different things.

- **The live log** is handled by `load-secrets.sh`, which registers every value it puts in `.env` with the
  runner (`::add-mask::`) whenever `GITHUB_ACTIONS` is set. Any workflow that calls it is covered without
  doing anything.
- **Files** are not covered by masking, which only rewrites the log stream. Anything uploaded as an artifact
  goes through `./script/setup/redact-secrets.sh` first; `weekly-validation.yml` does this before uploading
  its forge output, whose `report-failures` job pastes that output into a GitHub issue.

Two details worth knowing:

- Deploy commands never carry a key: `--rpc-url <network>` passes an `[rpc_endpoints]` **alias** and
  `--verify` reads `[etherscan]`, both resolved by forge internally. The one exception is `anvil
  --fork-url`, which has no alias support and needs a real URL built for it: `anvil.sh` spells one out for
  the two Sepolia forks it starts, and `ops/test-pool-hooks-fork.sh`, which takes any network, reads the
  entry back out of `[rpc_endpoints]` with `forge config --json`. `anvil.sh` redacts `anvil-*.log` once
  anvil has stopped in CI, and the file is gitignored either way.

GitHub only auto-masks `${{ secrets.* }}`. These values come from Secret Manager at runtime, so nothing masks
them unless `load-secrets.sh` does.

---

## Network config and RPC endpoints

Per-network config lives in **`env/<network>.json`**: chain id, environment, admins, adapter config, and the
deployed `contracts` section. **RPC URLs live in `foundry.toml`** under `[rpc_endpoints]`, one alias per
network, API key interpolated from the environment; **verification keys live next to them** under
`[etherscan]`. The command line and Solidity reach the same endpoint through the same alias (`--rpc-url
<network>` / `vm.rpcUrl(<network>)`).

`env/<network>.json` is the source of truth for all of it. The two `foundry.toml` tables are derived from it,
because forge's Rust side cannot read the env files, so **adding a network is one edit plus one command**:

```bash
# write env/<network>.json, then
python3 script/checks/check_foundry_networks.py --fix
```

That regenerates both tables — the RPC URL from `.network.baseRpcUrl` plus the right `${..._API_KEY}` for
whatever it points at, and the explorer entry from `.network.chainId` and `.network.verifierUrl`. CI runs the
same check without `--fix`, so a table that drifts from the env files fails there rather than surfacing later
as a confusing forge error or a verification failure mid-deployment.

`.network.baseRpcUrl` feeds that generator and nothing else — deliberately. Solidity does not parse it, and
no shell script composes a URL from it: everything goes through the alias, so there is one way to reach a
network and one place its API key is named.

### The two explorer URLs

A network can name **two** explorer endpoints, because on some chains they are two different services:

| field | what it is | who uses it |
|---|---|---|
| `.network.verifierUrl` | where source is **submitted** for verification | `forge verify-contract` via `VerifyFactoryContracts`, and `[etherscan]` in `foundry.toml` |
| `.network.explorerApiUrl` | where an Etherscan-compatible **read** goes | `VerifyFactoryContracts`, asking whether a contract is verified already |

Both default to Etherscan's multichain v2 endpoint for the network's chain id, so most networks set neither.
Set `verifierUrl` when verification goes somewhere else; set `explorerApiUrl` only when reads do.

They coincide on Etherscan, and on Blockscout instances exposing an Etherscan-compatible `/api` — plume sets
both to the same URL because its explorer serves both *and* it is not on Etherscan v2, so the default would
not work. They diverge on SocialScan: monad and pharos point `verifierUrl` at a `command_api/contract`
endpoint that accepts submissions and rejects every read with `"the action is error"`, so leaving their
`explorerApiUrl` unset sends reads to Etherscan v2 instead.

Getting this wrong is quiet rather than loud: nothing fails, `VerifyFactoryContracts` just reports every
contract on the chain as unverified and re-submits it.

### Chains that verify somewhere other than Etherscan

`.network.verifier` names the verifier forge is told to use, and it has to be one forge knows:
`etherscan`, `sourcify` or `blockscout`. Everything else in this repo leaves it unset and goes to Etherscan.

- **plume, monad, pharos** name `blockscout`, whose `/api` speaks the Etherscan dialect, so `[etherscan]`
  carries them and `--verify` needs no extra flag.
- **x-layer** (196) verifies through **Sourcify**, which covers the chain and takes no API key. Its explorer
  is OKLink, which forge cannot drive: OKLink wants its key in an `Ok-Access-Key` header, and `[etherscan]`
  only puts one in the query string — it answers `Ok-Access-Key can not be blank` either way, and we hold no
  OKLink key. So `check_foundry_networks.py` writes no `[etherscan]` entry for x-layer (see
  `NON_ETHERSCAN_VERIFIERS`), and **that absence is the mechanism**: finding no Etherscan key for the chain,
  forge falls back to Sourcify on its own — `Attempting to verify on Sourcify`. A plain `--verify` is
  therefore right on x-layer, and naming it (`--verifier sourcify --verifier-url https://sourcify.dev/server`)
  only makes the fallback explicit. `VerifyFactoryContracts` passes those two from `.network.verifier` and
  `.network.verifierUrl` already.

  An entry pointing at Etherscan would be worse than none: forge would aim at a chain Etherscan does not
  serve instead of at the verifier that works.

Reading verification back is a separate question, and two chains have no endpoint for it: Etherscan v2
serves neither 196 nor 1672 (`Missing or unsupported chainid parameter`), and SocialScan's pharos API
answers `the action is error` to a `getsourcecode` read on its `command_api` and `Not Found` on every other
path tried. So on those two, "is it verified already?" always answers no and `VerifyFactoryContracts`
re-submits — wasteful, not wrong. Sourcify covers both chains if we ever want to read from it too, but its
API is not Etherscan-shaped, so that is a change to `VerifyFactoryContracts` rather than a URL.
### What a run does to `env/<network>.json`

Every deploy script records what it deployed, and the write is a **merge**: a contract the run does not
mention keeps whatever the config said, so `DeployAdapters` and `DeployGasService` can add to a file without
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
