# Test data

Seeding a deployment with something to exercise. Run everything from the repository root.

Networks are named, not URLs: `--rpc-url local-a` resolves through `foundry.toml` `[rpc_endpoints]`, and the
script reads `env/anvil/local-a.json` because that config names the chain id the RPC answers with.

The base branch's only chains are the local pair `script/anvil/anvil.sh` brings up, which need no secrets.
Running this against a chain that outlives the process is done from `live`, where those configs are.

---

## TestData.s.sol

Deploys a pool and both async/sync vaults on a single network, and drives the full async and sync vault
flows through them. No cross-chain messaging, so it is the baseline sanity check that a fresh deployment
actually works. `script/anvil/anvil.sh` runs it on each local chain as the last step of a deployment, which
is what makes it the one thing on this branch that reads a deployment back through `Env`.

```bash
forge script script/testnet/TestData.s.sol:TestData \
  --rpc-url local-a \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvvv
```

The pool and vault setup it uses lives in `BaseTestData.s.sol`.

---

## Troubleshooting

`cast` resolves the same `[rpc_endpoints]` aliases as `forge script`, so these take a network name too.
Contract addresses come out of `env/<environment>/<network>.json` → `contracts`.

```bash
# Is this adapter wired to the remote centrifugeId?
cast call $AXELAR_ADAPTER "isWired(uint16)(bool)" 2 --rpc-url local-a

# Does a pool still have subsidies to pay for outgoing messages?
cast call $SUBSIDY_MANAGER "subsidies(uint64)(uint256)" 562949953512312 --rpc-url local-a

# What did a transaction actually do?
cast receipt <tx-hash> --rpc-url local-a
cast run <tx-hash> --rpc-url local-a
```

Cross-chain messages are relayed by the adapter's own network, so a message that left the hub is tracked in
that adapter's explorer, keyed by the sender address:

- **Axelar**: https://testnet.axelarscan.io/gmp/search?senderAddress=<sender>
- **LayerZero**: https://testnet.layerzeroscan.com/address/<sender>
- **Chainlink CCIP**: https://ccip.chain.link/address/<sender>
- **Hyperlane**: https://explorer.hyperlane.xyz/?search=<sender>
