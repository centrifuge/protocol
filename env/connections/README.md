# Connection Configuration

Defines which networks are connected and through which adapters. One file per environment: `mainnet.json`, `testnet.json`.

Parsed by `script/utils/EnvConnectionsConfig.s.sol` (Solidity) and `script/deploy/lib/load_config.py` (Python).

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
    "ALL": ["ethereum", "base", "arbitrum", "plume"],
    "L2s": ["base", "arbitrum", "optimism"]
}
```

The full set of known networks is derived from the union of all alias values.

### Connection rules

Each rule defines a pair of sides, the adapters used between them, and the quorum threshold.

**`chains`** is a 2-element array (a pair). Each side can be:

| Format | Meaning | Example |
|--------|---------|---------|
| `"ALIAS"` | Reference to an alias | `"ALL"` |
| `["net1", "net2"]` | Literal list of networks | `["pharos", "monad"]` |

The two sides are permuted (cartesian product), creating a connection for every pair across them. For example, `[["A", "B"], ["C", "D"]]` produces connections: (A,C), (A,D), (B,C), (B,D). Matching is also symmetric: both the A-to-B and B-to-A directions are covered.

A network never connects to itself. If the same network appears on both sides, the self-pair is skipped. For example, `[["A"], ["A", "B"]]` only produces (A,B).

**`adapters`** lists which messaging adapters to use (e.g. `"axelar"`, `"layerZero"`, `"wormhole"`, `"chainlink"`). An empty array means no connection.

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
        "chains": [["pharos"], "ALL"],
        "adapters": ["layerZero"],
        "threshold": 1
    }
]
```

Here, pharos connects to every other network via layerZero only (threshold 1), while all other pairs use both axelar and layerZero (threshold 2).

To disable connections for a network, override with an empty adapters array:

```json
{
    "chains": [["hyper-evm-testnet"], "ALL"],
    "adapters": [],
    "threshold": 0
}
```

## Examples

**Mainnet** - all networks connected via axelar + layerZero, pharos overridden to layerZero only:

```json
{
    "aliases": {
        "ALL": ["ethereum", "base", "arbitrum", "plume", "avalanche", "bnb-smart-chain", "hyper-evm", "optimism", "monad", "pharos"]
    },
    "connections": [
        { "chains": ["ALL", "ALL"], "adapters": ["axelar", "layerZero"], "threshold": 2 },
        { "chains": [["pharos"], "ALL"], "adapters": ["layerZero"], "threshold": 1 }
    ]
}
```

**Testnet** - all networks connected via 4 adapters, hyper-evm-testnet disconnected:

```json
{
    "aliases": {
        "ALL": ["sepolia", "arbitrum-sepolia", "base-sepolia", "hyper-evm-testnet"]
    },
    "connections": [
        { "chains": ["ALL", "ALL"], "adapters": ["axelar", "wormhole", "layerZero", "chainlink"], "threshold": 1 },
        { "chains": [["hyper-evm-testnet"], "ALL"], "adapters": [], "threshold": 0 }
    ]
}
```
