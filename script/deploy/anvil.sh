#!/usr/bin/env bash
#
# Brings up two local forks and deploys the protocol on both, exactly the way a real chain gets it: through
# the DeployGate, validate and execute as two separate forge runs. Each fork gets its own copy of the base
# network's config under env/anvil/, with the guardians pointed at an anvil account so the scripts can drive
# them. The deploy scripts write their addresses and block numbers into that copy themselves, so there is no
# recording step.
#
#   ./script/deploy/anvil.sh
#
# Needs ALCHEMY_API_KEY in .env (./script/setup/load-secrets.sh). The forge scripts find their network by
# chain id; the signer is passed explicitly, from the anvil keys below.
# Ports: 8545 (sepolia fork, chain 31337) and 8546 (arbitrum-sepolia fork, chain 31338).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Anvil's first two accounts. The deployer signs the protocol; the admin is what the guardians are given.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADMIN_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

FORKS="sepolia arbitrum-sepolia"

say() { printf '▸ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

port_of() { [ "$1" = "sepolia" ] && echo 8545 || echo 8546; }
chain_of() { [ "$1" = "sepolia" ] && echo 31337 || echo 31338; }
fork_host_of() { [ "$1" = "sepolia" ] && echo eth-sepolia || echo arb-sepolia; }

forge_deploy() {
    local script="$1" name="$2"
    shift 2
    forge script "$script" --tc "$name" --rpc-url "anvil/$BASE" \
        --private-key "$PRIVATE_KEY" --broadcast "$@"
}

# The fork's own chain id is what Env.detect matches on, and the guardians are pointed at an anvil account so
# the scripts can drive them. baseRpcUrl is dropped rather than repointed: the fork is reached through the
# `anvil/<network>` [rpc_endpoints] alias, and a copy of the real network's URL sitting in a fork's config
# would read as the endpoint these runs use
write_config() {
    mkdir -p env/anvil
    jq --arg admin "$ADMIN" --argjson chain "$(chain_of "$1")" '
        .network.chainId = $chain
        | .network.protocolAdmin = $admin
        | .network.opsAdmin = $admin
        | del(.network.baseRpcUrl)
    ' "env/$1.json" > "env/anvil/$1.json"
}

start_fork() {
    local port chain attempt
    port="$(port_of "$1")"
    chain="$(chain_of "$1")"

    say "Starting anvil for $1 on :$port (chain $chain)"
    # anvil is the one tool that cannot take a network name. Only these two Sepolia forks are ever started
    # here, both on Alchemy, so the URL is spelled out rather than resolved out of [rpc_endpoints]
    anvil --chain-id "$chain" --port "$port" --disable-block-gas-limit --code-size-limit 50000 \
        --fork-url "https://$(fork_host_of "$1").g.alchemy.com/v2/${ALCHEMY_API_KEY}" \
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

deploy_fork() {
    BASE="$1"

    # This fork has no gate. Nothing brings one up first: the validate phase does it, in the same run
    export PRIVATE_KEY="$DEPLOYER_KEY"

    # Two runs, validate then execute, exactly as a real deployment is signed. EXECUTORS is read by validate,
    # which is what names them. The execute phase records what it deployed itself
    say "LaunchDeployer: validate ($BASE)"
    EXECUTORS="$DEPLOYER" forge_deploy script/deploy/LaunchDeployer.s.sol LaunchDeployer --sig 'validate()'
    say "LaunchDeployer: execute ($BASE)"
    forge_deploy script/deploy/LaunchDeployer.s.sol LaunchDeployer --sig 'execute()'

    # Test data acts through the guardians, so it is signed by the admin they were given
    say "Test data ($BASE)"
    export PRIVATE_KEY="$ADMIN_KEY"
    forge_deploy script/testnet/TestData.s.sol TestData
}

# Only the fork URL comes from .env; the anvil keys exported below outrank whatever else it holds, because
# exported process env wins over forge's own .env loading
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi
[ -n "${ALCHEMY_API_KEY:-}" ] || die "ALCHEMY_API_KEY is needed to fork. Run ./script/setup/load-secrets.sh"

# A fresh salt each time, so repeated runs do not land on addresses the last one took
export SUFFIX="${SUFFIX:-anvil-$(date +%s)}"
say "Suffix $SUFFIX"

pkill anvil 2>/dev/null && sleep 1 || true

# Every config first: LaunchDeployer loads each network it connects to, so they all have to exist
for base in $FORKS; do write_config "$base"; done
for base in $FORKS; do start_fork "$base"; done
for base in $FORKS; do deploy_fork "$base"; done

if [ -n "${GITHUB_ACTIONS:-}" ]; then
    pkill anvil 2>/dev/null || true
    # anvil echoes its fork URL, API key included, into its log when a request fails
    for base in $FORKS; do
        [ -f "anvil-$base.log" ] && ./script/setup/redact-secrets.sh "anvil-$base.log" >/dev/null || true
    done
    ok "Both forks deployed; anvil stopped"
else
    ok "Both forks deployed, still running (:8545 sepolia, :8546 arbitrum-sepolia). Stop with 'pkill anvil'"
    printf '⚠ anvil-*.log holds the fork URL with your API key. Gitignored, but do not paste it anywhere\n'
fi
