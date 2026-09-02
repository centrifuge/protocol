# `env/`

What a chain is, and what is deployed on it. One file per network, filed under the environment it declares:

```
env/
├── <environment>/
│   ├── <network>.json         # one per network — chain id, admins, deploy namespace, adapters, addresses
│   └── connections.json       # which networks are wired to which, and through which adapters
├── spell/                     # governance spells, archived after execution
├── connections_viewer.html    # draws one environment's connections.json as a graph
└── connections_viewer.sh      # serves env/ and opens the viewer: ./env/connections_viewer.sh [environment] [port]
```

Which environments are populated depends on the branch. Deployment configs — `testnet/` and `mainnet/` —
exist only on the `live` branch, because every deployment that outlives a process is made from there; the
base branch carries none, and its only chains are the anvil pair described by the fixtures in
`script/anvil/env/`.

The directory restates what a config's own `.network.environment` says, so a glob can pick out one
environment without opening every file — and, because it is restated, the two are checked against each
other on every read: a directory renamed without its configs fails loudly instead of quietly moving every
address that chain deploys to.

An environment may carry a **deployment id** after its name — `env/testnet-rev2/` beside `env/testnet/` —
which is a second deployment of the same chains, at its own addresses and with its own record. The id is
the part of the name after the first `-`, and it is folded into every salt. `mainnet` is no exception — its
canonical addresses are the id-less ones, but nothing keeps a rev off it. Where two environments describe one
chain, a run says which it means with `DEPLOY_ENVIRONMENT=testnet-rev2`; with only one, the chain id still
answers on its own.

The network is named by the file, not by the path: a chain `<network>` lives at
`env/<environment>/<network>.json` and is still reached as `--rpc-url <network>`. `Chains.pathOf` resolves one
to the other, and `env/anvil-<id>/<network>.json` — written by `script/anvil/anvil.sh` from its fixtures,
gitignored — is where a local run records itself.

## Connections

Defines which networks are connected and through which adapters, one file per environment.

Interpreted in exactly one place: `EnvConnections.connectionsWith` in
`script/utils/ConnectionsConfig.s.sol`. Aliases and literal arrays are resolved, the last matching rule
wins, and a connection only counts when that rule still has adapters — fiddly enough that a second
implementation would eventually disagree with the first.

Anything that needs the list asks that function: the deploy and wiring scripts call it directly, and
the live branch's `deploy-testnet.sh` entrypoint derives its network matrix from the same file with jq,
mirroring what the function
does so the two cannot disagree.

`connections_viewer.html` is the other copy, and the warning above is why it is worth naming: it
re-implements the rule in JavaScript to draw the graph, so it can drift. Nothing deploys from it — it
reads `connections.json` and renders, never writes — but a change to how rules resolve belongs in both.

## Schema

```json
{
    "aliases": {
        "<name>": ["<network>", ...]
    },
    "connections": [
        {
            "chains": [<side>, <side>],
            "adapters": ["<adapter>", ...],
            "threshold": <number>
        }
    ]
}
```

### Aliases

Named groups of networks, reusable in connection rules:

```json
"aliases": {
    "ALL": ["A", "B", "C", "D"],
    "L2s": ["B", "C", "D"]
}
```

The full set of known networks is derived from the union of all alias values.

### Connection rules

Each rule defines a pair of sides, the adapters used between them, and the quorum threshold.

**`chains`** is a 2-element array (a pair). Each side can be:

| Format | Meaning | Example |
|--------|---------|---------|
| `"ALIAS"` | Reference to an alias | `"ALL"` |
| `["net1", "net2"]` | Literal list of networks | `["C", "D"]` |

The two sides are permuted (cartesian product), creating a connection for every pair across them. For example, `[["A", "B"], ["C", "D"]]` produces connections: (A,C), (A,D), (B,C), (B,D). Matching is also symmetric: both the A-to-B and B-to-A directions are covered.

A network never connects to itself. If the same network appears on both sides, the self-pair is skipped. For example, `[["A"], ["A", "B"]]` only produces (A,B).

**`adapters`** lists which messaging adapters to use (e.g. `"axelar"`, `"layerZero"`, `"chainlink"`). An empty array means no connection.

**`threshold`** is the minimum number of adapters that must confirm a message.

### Rule precedence

Rules are evaluated in order. **The last matching rule wins**, allowing general rules to be overridden by specific ones:

```json
"connections": [
    {
        "chains": ["ALL", "ALL"],
        "adapters": ["axelar", "layerZero"],
        "threshold": 2
    },
    {
        "chains": [["D"], "ALL"],
        "adapters": ["layerZero"],
        "threshold": 1
    }
]
```

Here, D connects to every other network via layerZero only (threshold 1), while all other pairs use both axelar and layerZero (threshold 2).

To disable connections for a network, override with an empty adapters array:

```json
{
    "chains": [["D"], "ALL"],
    "adapters": [],
    "threshold": 0
}
```

## Examples

Which networks an environment holds is deployment data, so these use placeholder names; the real files sit
beside the configs they connect, and `./env/connections_viewer.sh <environment>` draws one.

**Everything connected, one network on a single adapter** - all pairs via axelar + layerZero, D overridden to
layerZero only:

```json
{
    "aliases": {
        "ALL": ["A", "B", "C", "D"]
    },
    "connections": [
        { "chains": ["ALL", "ALL"], "adapters": ["axelar", "layerZero"], "threshold": 2 },
        { "chains": [["D"], "ALL"], "adapters": ["layerZero"], "threshold": 1 }
    ]
}
```

**One network disconnected** - all pairs via three adapters, D cut off:

```json
{
    "aliases": {
        "ALL": ["A", "B", "C", "D"]
    },
    "connections": [
        { "chains": ["ALL", "ALL"], "adapters": ["axelar", "layerZero", "chainlink"], "threshold": 1 },
        { "chains": [["D"], "ALL"], "adapters": [], "threshold": 0 }
    ]
}
```
