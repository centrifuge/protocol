#!/bin/bash
set -euo pipefail

# Rehearses the PoolHooks script against a local fork of one network. No signer: the sender is impersonated
# on the fork, so nothing here can reach a real chain.
#
#   ./script/ops/test-pool-hooks-fork.sh <network>  # any name in env/, e.g. ethereum

set -a; source .env; set +a # auto-export all sourced vars

NETWORK=${1:?Usage: $0 <network>}
[ -f "env/$NETWORK.json" ] || { echo "No env/$NETWORK.json. The network is the name of an env config" >&2; exit 1; }

mock_addr() {
    cast rpc anvil_impersonateAccount "$1" \
        --rpc-url "$LOCAL_RPC_URL"

    cast rpc anvil_setBalance "$1" $(cast --to-hex 1000000000000000000000) \
        --rpc-url "$LOCAL_RPC_URL"
}

echo ""
echo "##########################################################################"
echo "#                   STEP 0: Start anvil in fork mode"
echo "##########################################################################"
echo ""

# anvil is the one tool that cannot take a network name, so its URL is read out of foundry.toml's
# [rpc_endpoints] — the same table forge resolves `--rpc-url <network>` against, so which API key a network
# needs is not guessed here. forge reports the entry with its `${..._API_KEY}` intact, leaving it to expand.
# Done before backgrounding, so a missing key says so instead of becoming an empty --fork-url
FORK_URL="$(forge config --json | jq -r --arg n "$NETWORK" '.rpc_endpoints[$n] // empty')"
[ -n "$FORK_URL" ] || { printf '✗ No [rpc_endpoints] entry for %s in foundry.toml\n' "$NETWORK" >&2; exit 1; }

if [[ "$FORK_URL" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
    KEY="${BASH_REMATCH[1]}"
    [ -n "${!KEY:-}" ] || { printf '✗ %s is needed for %s. Run ./script/setup/load-secrets.sh\n' "$KEY" "$NETWORK" >&2; exit 1; }
    FORK_URL="${FORK_URL/\$\{$KEY\}/${!KEY}}"
fi

anvil --fork-url "$FORK_URL" &
ANVIL_PID=$!
trap "kill $ANVIL_PID" EXIT

LOCAL_RPC_URL="http://127.0.0.1:8545" #anvil

sleep 3.0 # Wait ensuring Anvil is up

SENDER="0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb"
mock_addr "$SENDER"

echo ""
echo "##########################################################################"
echo "#                    STEP 1: Run PoolHooks script"
echo "##########################################################################"
echo ""

# The fork keeps the forked chain's id, so PoolHooks detects the network from it
forge script script/ops/PoolHooks.s.sol:PoolHooks \
    --rpc-url "$LOCAL_RPC_URL" \
    --unlocked --sender "$SENDER" \
    --broadcast \
    -vv

echo ""
echo "##########################################################################"
echo "#                           Done!"
echo "##########################################################################"
echo ""
