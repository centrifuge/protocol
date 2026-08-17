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

forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url sepolia $KEY --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url sepolia $KEY --broadcast --verify
forge script script/testnet/TestData.s.sol --rpc-url sepolia $KEY --broadcast   # optional test data
```

`LaunchDeployer` writes the addresses, versions and block numbers into `env/sepolia.json` itself, as it
deploys. There is no follow-up step and nothing to remember.

### Deploy the protocol (mainnet)

The same two phases, sent one transaction at a time, and signed by two different keys: the admin holds a
Ledger and signs the gate and the validate phase with it, while the execute phase is signed by an executor
from a keystore. Nothing is lost by that — an executor can only deploy what the admin already committed to,
and one transaction per contract is a long sequence to confirm on a device.

```bash
ADMIN="--ledger --sender <ledger-address> --slow"
EXECUTOR="--account <keystore-name> --sender <executor-address> --slow"

# Once per chain: the gate everything deploys through. It records its own address in env/ethereum.json,
# which is where the phases below read it back from
EXECUTORS=0xabc...,0xdef... forge script script/deploy/DeployGateDeployer.s.sol --rpc-url ethereum $ADMIN --broadcast

# The two phases, signed by the admin and by an executor — at different times if wanted
forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url ethereum $ADMIN --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url ethereum $EXECUTOR --broadcast --verify
```

Pick the Ledger account with `cast wallet address --ledger --mnemonic-index <n>`. An executor key is imported
once with `cast wallet import <keystore-name> --interactive`, and forge asks for its password on every run;
the address it holds has to be one the gate knows, either seeded through `EXECUTORS` above or added later with
`updateExecutor`. Name that address in `--sender` as well, for the same reason the Ledger line does: left to
itself forge simulates as its own default sender, and a run that simulates as one account and broadcasts from
another is how a salt or a ward ends up belonging to the wrong one.

Note this is the same command shape as the testnet block above, with `$ADMIN` and `$EXECUTOR` where `$KEY`
was — no script reads a key implicitly, on any network, so what you rehearse on a testnet is what you type on
mainnet.

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
at the same address on every chain given the same gate and `SUFFIX`. That only holds if every connected
network is deployed in the same run, so the workflow does not hard-code which networks those are: it reads
them out of `env/connections/testnet.json` when it starts. Adding a network to the connections file is
therefore the entire change needed to have it deployed and wired.

### Trying a deployment before committing to it

Use `anvil.sh`. Dropping `--broadcast` to "simulate" against a real network does not work on a chain that has
no `deployGate` yet — `LaunchDeployer` aborts before it simulates anything — and once a gate does exist, the
simulated `validate()` still checks the gate's auth against live state, so it only passes for an admin key.
`anvil.sh` sidesteps both: it brings up its own gate on a fork and rehearses the whole sequence, which is also
what ci.yml runs on every pull request.

### Network quirks

- **base-sepolia**: add `--gas-price 100000000000 --slow`, or receipts stay pending forever.
- **CI**: always add `--slow` — one transaction at a time costs minutes, a nonce race costs a redeploy.

### Environment variables (all optional)

| Variable | Meaning |
|---|---|
| `SUFFIX` | Isolates a deployment onto its own addresses. Ignored on mainnet |
| `EXECUTORS` | Accounts allowed to run the execute phase. Required by `DeployGateDeployer`, read nowhere else |
| `PRIVATE_KEY` | The testnet key `.env` holds, for you to pass as `--private-key`. No script reads it |

---

## Deployments go through the DeployGate

The protocol deployment is gated: the contracts are not deployed by the sender, they are deployed by a
`DeployGate`, in two phases. An **admin** commits the `(salt, init code hash)` of every contract in a single
transaction; any of the **executors** the gate holds then deploys them one by one.

| Step | Command | Signer | Transactions |
|---|---|---|---|
| Set up the gate | `EXECUTORS=<addrs> forge script script/deploy/DeployGateDeployer.s.sol ...` — it writes its own address into `env/<network>.json` | the admin | 1, once per chain |
| Validate | `forge script ... LaunchDeployer.s.sol --sig 'validate()' ...` | the admin | **1**, whatever the contract count (~2.9M gas) |
| Execute | `forge script ... LaunchDeployer.s.sol --sig 'execute()' ...` | an executor | one per contract |

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
Commitment for gate 0x2e234DAe75C793f67A35089C9d99245E1C58470b
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

The commitment is also readable on chain afterwards: `validate` emits one `Validate(salt, initCodeHash)`
per contract, both indexed. And since nothing is deployed until the execute phase, a commitment found to be
wrong costs one re-validation, not a redeployment.

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
them can produce anything the admin did not commit to. Committing the init code alone would **not** be safe: the executor could then
deploy validated code at an address of its choosing, consume the validation, and strand the intended address.

Deployment order needs no enforcing either. The action batchers wire from their constructors, and a call to a
contract that does not exist yet reverts, so deploying out of order reverts.

Neither does a superseded commitment linger. Every validation starts a new generation and only the live one can
be deployed from, so a set the admin replaced cannot be spent afterwards — including the salts the replacement
dropped, which would otherwise stay deployable and let an executor strand a canonical address. Validating
with no salts at all is how a pending commitment is revoked outright.

### Roles

`DeployGateDeployer` deploys the `DeployGate`, makes its sender the first admin, and seeds the executor set
from `EXECUTORS`, a required comma-separated list. The two roles are unrelated: the admin does not have to be
an executor, and an executor does not have to be an admin. The admin changes the set afterwards with
`updateExecutor(who, canDeploy)`, independently of what is committed.

- **admin** — a ward of the gate: may `validate`, and `rely`/`deny` other admins. Handing the role over
  does not move any address. The protocol `Root` is a ward too, from the gate's constructor, so governance
  can name a different admin through `relyContract` without the current one.
- **executors** — a set held on the gate, any member of which may `deploy` what the live generation
  validated, and nothing else, on any contract. They are interchangeable: none is confined to part of the
  commitment, so the phase can be split between keys or picked up by another when one becomes unavailable, and
  the deployment that comes out is the same whoever signed which part. Being separate from the commitment,
  a key is added or revoked with `updateExecutor` without disturbing what is pending, and a compromised one
  does not force a re-validation.

### Addresses

CreateX derives a CREATE3 address from its caller and the salt, and the caller is now the `DeployGate`, so:

- Addresses differ from any deployment made before this contract existed, when the sender was the caller.
  Chains already running the protocol cannot be redeployed onto their current addresses.
- Addresses stay equal across chains, because the `DeployGate` address is itself chain invariant: its salt
  embeds its deployer and no chain id. The gate enforces both properties rather than trusting the script for
  them: `validate` commits only to salts that name the gate as their guardian, which is what makes CreateX
  scope the address to it, and that leave the cross-chain redeploy protection off, which is what would
  otherwise fold the chain id in. A salt that breaks either would still deploy, and the deployment would still
  look like it worked, so it is refused at the transaction the admin signs.
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
  `DeployGasService`.
- The standalone scripts (`DeployAdapters`, `PoolHooks`, `DeployGasService`) still salt with `msg.sender`, so
  their addresses do not derive from the gate and no longer collide with the protocol's. **Their versions must
  never overlap with `FullDeployer`'s**: a name and version those scripts share with a gated deployment now
  lands on a second, unwired address instead of reverting on a taken one, and the config would record that one
  over the address that is actually wired in. Moving them onto the gate as well is the real fix.

### Keys

- The gate to deploy through is `contracts.deployGate` in `env/<network>.json`, written there by
  `DeployGateDeployer` itself as it deploys. Every gated phase reads it back from there, so there is nothing
  to pass by hand.
  It must be the same address on every chain, or protocol addresses will differ between them. Deploying
  without it in place aborts, since there is no gate to deploy through.
- The gate's own address embeds the account that ran `DeployGateDeployer`, so only that account could have taken
  it. Losing that key means losing address continuity for new chains.
- `EXECUTORS` seeds the accounts allowed to run the execute phase, read only by `DeployGateDeployer` and only
  at construction. It is required, and it does not default to the sender: name the keys that will run the
  execute phase, which can be the admin's or keys with no privilege anywhere else. It is not a commitment
  either — `updateExecutor` changes the set at any point, and an executor holds no privilege beyond deploying
  what has been validated.
- `SUFFIX` moves the gate too, and is ignored on mainnet, exactly as in `LaunchDeployer`. Both scripts must
  see the same one: an isolated testnet deployment gets its own gate, and that gate is built knowing the root
  it will deploy, so running them with different suffixes leaves the gate governed by a root that never
  exists.
- The `DeployGate` holds **no** protocol permissions at any point, so it cannot touch a live deployment.

---

## How a deployment reaches `env/<network>.json`

One step: **the deploy script records itself, as it deploys.** `JsonRegistry` (`startDeploymentOutput()` +
`register()`, which `createSalt()` already calls, + `saveDeploymentOutput(network)`) merges the names,
addresses, versions and block numbers straight into `env/<network>.json`. The four scripts that deploy —
`LaunchDeployer`, `DeployGateDeployer`, `DeployAdapters`, `DeployGasService` — each do this for what they
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

## Logs and state

- Forge's broadcast sequences: `broadcast/<script>.s.sol/<chainId>/`. `--resume` replays these; nothing else
  reads them.
- anvil output from `anvil.sh`: `anvil-<network>.log` (gitignored — it contains the fork URL, API key
  included).
