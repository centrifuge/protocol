#!/usr/bin/env bash
#
# Brings up two local chains and deploys the protocol on both, exactly the way a real chain gets it: through
# the DeployGate, commit and deploy as two separate forge runs, then test data on top. The deploy scripts
# write their addresses and block numbers into the chain's config themselves, so there is no recording step.
#
#   ./script/anvil/anvil.sh
#
# Nothing external is needed — no API key, no credentials, no network. The chains are bare anvil rather than
# forks: CreateX deploys itself when a chain has none (`setUpCreateXFactory`) and the gate deploys itself
# through CreateX, so the only thing a fork was ever providing was code at the messaging endpoints, which
# `FullDeployer` requires before it will deploy an adapter against them. Those are stubbed below.
#
# The chain configs are the fixtures next to this script, and they hold the input half only: network and
# adapters, no contracts. Copying them into env/anvil/ is what creates the output config a run produces —
# LaunchDeployer merges its addresses into the chain half sitting there, and TestData loads the result back.
# env/anvil/ is gitignored, so the record of a run stays out of the tree and the fixtures stay a description
# of two chains, never of a deployment.
#
# Ports: 8545 (local-a, chain 31337) and 8546 (local-b, chain 31338).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Anvil's first two accounts. The deployer signs the protocol; the admin is what the guardians are given,
# and is what env/anvil/*.json names as protocolAdmin and opsAdmin
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADMIN_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

CHAINS="local-a local-b"

# Returns a word of 1s to anything asked of it, which is all the deploy path wants from an endpoint it is
# only required to find code at. The same stub test/integration/Deployer.t.sol etches for the same reason
STUB=0x6001600160005260206000f3

# CreateX, read out of the bindings so there is one copy of it in the repo. `setUpCreateXFactory` can only
# `vm.etch` it, which lives and dies with the simulation — the real chain would then take a broadcast
# transaction to an address holding no code, so the chain gets it put there first, the way every public
# chain already has it
CREATEX_ADDRESS=0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
createx_bytecode() {
    python3 -c "
import re, sys
src = open('script/utils/createx/CreateX.d.sol').read()
print('0x' + re.search(r'CREATEX_BYTECODE\s*=\s*hex\"([0-9a-fA-F]+)\"', src).group(1))
"
}

say() { printf '▸ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

port_of() { [ "$1" = "local-a" ] && echo 8545 || echo 8546; }
chain_of() { [ "$1" = "local-a" ] && echo 31337 || echo 31338; }

forge_deploy() {
    local script="$1" name="$2"
    shift 2
    forge script "$script" --tc "$name" --rpc-url "$CHAIN" \
        --private-key "$PRIVATE_KEY" --broadcast "$@"
}

start_chain() {
    local port chain attempt
    port="$(port_of "$1")"
    chain="$(chain_of "$1")"

    say "Starting anvil for $1 on :$port (chain $chain)"
    anvil --chain-id "$chain" --port "$port" --disable-block-gas-limit --code-size-limit 50000 \
        > "anvil-$1.log" 2>&1 &

    for attempt in $(seq 1 30); do
        if cast block-number --rpc-url "http://localhost:$port" >/dev/null 2>&1; then
            ok "anvil is up on :$port"
            return 0
        fi
        sleep 1
    done
    die "anvil did not come up on :$port; see anvil-$1.log"
}

# Every messaging endpoint the config names, so that `FullDeployer`'s `code.length > 0` guard passes and the
# adapters are deployed and wired the way they are on a real chain. CreateX goes on with them, since without
# it the gate has nothing to deploy through
stub_endpoints() {
    local port addr
    port="$(port_of "$1")"

    cast rpc anvil_setCode "$CREATEX_ADDRESS" "$(createx_bytecode)" --rpc-url "http://localhost:$port" >/dev/null

    for addr in $(jq -r '.adapters | to_entries[] | .value
        | (.gateway // empty), (.gasService // empty), (.endpoint // empty), (.ccipRouter // empty), (.mailbox // empty)
    ' "env/anvil/$1.json"); do
        cast rpc anvil_setCode "$addr" "$STUB" --rpc-url "http://localhost:$port" >/dev/null
    done
    ok "CreateX and the endpoints placed on $1"
}

deploy_chain() {
    CHAIN="$1"

    export PRIVATE_KEY="$DEPLOYER_KEY"
    say "LaunchDeployer: commit ($CHAIN)"
    EXECUTORS="$DEPLOYER" forge_deploy script/deploy/LaunchDeployer.s.sol LaunchDeployer --sig 'commit()'
    say "LaunchDeployer: deploy ($CHAIN)"
    forge_deploy script/deploy/LaunchDeployer.s.sol LaunchDeployer --sig 'deploy()'

    say "Test data ($CHAIN)"
    export PRIVATE_KEY="$ADMIN_KEY"
    forge_deploy script/testnet/TestData.s.sol TestData

    ok "$CHAIN deployed"
}

# A fresh salt each time, so repeated runs do not land on addresses the last one took
export SUFFIX="${SUFFIX:-anvil-$(date +%s)}"
say "Suffix $SUFFIX"

pkill anvil 2>/dev/null && sleep 1 || true

# Every config first: LaunchDeployer loads each network it connects to, so they all have to be in place
# before the first one is deployed
mkdir -p env/anvil
cp script/anvil/env/*.json env/anvil/

for chain in $CHAINS; do start_chain "$chain"; done
for chain in $CHAINS; do stub_endpoints "$chain"; done
for chain in $CHAINS; do deploy_chain "$chain"; done

if [ -n "${GITHUB_ACTIONS:-}" ]; then
    pkill anvil 2>/dev/null || true
    ok "Both chains deployed; anvil stopped"
else
    ok "Both chains deployed, still running (:8545 local-a, :8546 local-b). Stop with 'pkill anvil'"
fi
