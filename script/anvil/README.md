# Local chains

Two anvil chains with the protocol deployed on both, the way a real chain gets it: through the DeployGate,
`commit()` and `deploy()` as separate forge runs, then test data on top.

```bash
./script/anvil/anvil.sh
```

Nothing external is needed — no API key, no credentials, no network. This is what `ci.yml` runs on every PR,
and it is the only deployment the base branch makes: everything that outlives a process is deployed from
`live`.

## Why it is not a fork

It used to fork Sepolia, which meant an Alchemy key, which meant credentials in CI. A fork was only ever
providing three things, and none of them need one:

| | On a bare chain |
| --- | --- |
| CreateX | `setUpCreateXFactory()` can only `vm.etch` it, which lives and dies with the simulation, so `anvil.sh` puts the real runtime code at its canonical address first |
| the DeployGate | deploys itself through CreateX, in the run |
| messaging endpoints | `FullDeployer` requires code at each one before it will deploy an adapter against it; `anvil.sh` stubs them with the same bytecode `test/integration/Deployer.t.sol` etches |

## Configs: what goes in, what comes out

An `env/<environment>/<network>.json` holds two halves. The chain half — `network` and `adapters` — is
input, written by hand. The `contracts` half is output, and a deploy script records itself into it as it
runs. Both live in one file, because `TestData` then reads the whole thing back through `Env.load()` to find
the protocol it is seeding.

The fixtures here are the input half only:

```
$ jq -c 'keys' script/anvil/env/local-a.json
["adapters","network"]
```

A run copies them into `env/anvil/` and deploys against the copies. That copy is what *creates* the output
config: `LaunchDeployer` merges its addresses into the chain half sitting there, and `TestData` loads the
result. Without it there would be no complete config for the run to produce — writing a contracts-only file
would fail the chain-half parse on the next read.

`env/anvil/` is gitignored, so the run's record stays out of the tree, and these fixtures come out of a
deployment byte-identical. That separation is not about churn in the addresses: with a fixed `SUFFIX` the
addresses are reproducible to the byte. It is about the rest — `timestamp` moves every run and `blockNumber`
is whatever block the deploy landed in — because a deployment record is about one run, and these files are
not.

Both directories are `Chains.configRoots()` entries, `env/anvil/` first, which is why a run reads its own
output and a fresh clone still finds two chains for the schema tests to walk.

| | |
| --- | --- |
| `local-a.json` | chain 31337 on :8545, centrifugeId 1 |
| `local-b.json` | chain 31338 on :8546, centrifugeId 2 |
| `connections.json` | both chains wired to each other over all three adapters |

The endpoint addresses in them are placeholders: nothing is deployed there, `anvil.sh` puts a stub at each,
and the adapters are deployed and wired against those. The admin is anvil's second account, so the guardians
can be driven from a key everyone has.
