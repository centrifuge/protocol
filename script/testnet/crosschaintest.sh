#!/usr/bin/env bash
#
# Drives the cross-chain adapter isolation test (TestAdapterIsolation.s.sol) across a hub and every spoke it
# connects to. This is the one flow that spans several networks and has to wait for messages to relay, which
# is why it is a shell script and not a forge run.
#
#   ./script/testnet/crosschaintest.sh [hub] [full|spoke|hub|test] [spoke]
#
#   hub    The hub network (default base-sepolia)
#   mode   full  - the 4 steps below, in order
#          spoke - step 1 only: register assets on every connected spoke
#          hub   - step 2 only: pool + adapter setup on the hub
#          test  - step 4 only: the repeatable share class test
#   spoke  The spoke to test against (default: the hub's first connected network). Must be connected to the
#          hub in env/connections/. Only one spoke is tested per run: the point is isolating each adapter,
#          not covering the topology, so a second spoke multiplies cost without adding signal.
#
# The 4 steps: register assets on each spoke, set up pools and adapters on the hub, wait for the messages to
# relay, then notify a share class. Testnet-only, like the forge script it drives; signs with PRIVATE_KEY.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

HUB="${1:-base-sepolia}"
MODE="${2:-full}"
SPOKE="${3:-}"
SCRIPT=script/testnet/TestAdapterIsolation.s.sol

section() { printf '\n══ %s ══\n' "$*"; }
say() { printf '▸ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi
[ -f "env/$HUB.json" ] || die "No env/$HUB.json"
[ -n "${PRIVATE_KEY:-}" ] || die "PRIVATE_KEY is needed. Run ./script/setup/load-secrets.sh"

ENVIRONMENT="$(jq -r '.network.environment' "env/$HUB.json")"
[ "$ENVIRONMENT" = "testnet" ] || die "The adapter isolation test is testnet-only; $HUB is $ENVIRONMENT"

run_sig() {
    local network="$1" sig="$2"
    forge script "$SCRIPT" --tc TestAdapterIsolation --sig "$sig" \
        --rpc-url "$network" --private-key "$PRIVATE_KEY" --broadcast
}

# Asks EnvConnections.connectionsWith, so the rules in env/connections/ are interpreted in exactly one
# place. Resolving aliases, letting the last matching rule win and dropping adapter-less pairs is fiddly
# enough that a second implementation here would eventually disagree with the deploy and wiring scripts.
resolve_spokes() {
    SPOKES="$(forge script script/testnet/Connections.s.sol --tc Connections \
        --sig 'spokesOf(string)' "$HUB" --json \
        | jq -r 'if .logs then .logs[] else empty end' | tr '\n' ' ')"
    [ -n "$SPOKES" ] || die "No connected networks for $HUB in env/connections/$ENVIRONMENT.json"
}

# One spoke is tested per run. Validated against the connections config rather than trusted, so a typo or a
# spoke that is not actually connected to this hub fails here instead of producing a meaningless test — and
# so the hub can never end up testing against itself.
choose_spoke() {
    local candidate
    if [ -z "$SPOKE" ]; then
        SPOKE="${SPOKES%% *}"
        return 0
    fi
    for candidate in $SPOKES; do
        [ "$candidate" = "$SPOKE" ] && return 0
    done
    die "$SPOKE is not connected to $HUB. Connected: $SPOKES"
}

register_spokes() {
    section "Step 1/4 — Register assets on spokes"
    local spoke
    for spoke in $SPOKES; do
        say "Registering the asset on $spoke"
        HUB_NETWORK="$HUB" run_sig "$spoke" 'registerAssetOnly()'
    done
}

setup_hub() {
    section "Step 2/4 — Hub pool setup + adapter configuration ($HUB -> $SPOKE)"
    say "Pool setup on $HUB"
    SPOKE_NETWORK="$SPOKE" run_sig "$HUB" 'runPoolSetup()'
    say "Adapter setup on $HUB"
    SPOKE_NETWORK="$SPOKE" run_sig "$HUB" 'runAdapterSetup()'
}

# Where to watch the messages land. Only the callers that send hub -> spoke messages print this, so the
# Axelar route is the pair under test rather than every connected network.
print_explorer_links() {
    section "Monitor cross-chain messages ($HUB -> $SPOKE)"
    local sender hub_axelar spoke_axelar
    sender="$(jq -r '.network.opsAdmin' "env/$HUB.json")"
    hub_axelar="$(jq -r '.adapters.axelar.axelarId // empty' "env/$HUB.json")"
    spoke_axelar="$(jq -r '.adapters.axelar.axelarId // empty' "env/$SPOKE.json")"

    if [ -n "$hub_axelar" ] && [ -n "$spoke_axelar" ]; then
        say "Axelar:    https://testnet.axelarscan.io/gmp/search?sourceChain=$hub_axelar&destinationChain=$spoke_axelar&senderAddress=$sender"
    fi
    say "LayerZero: https://testnet.layerzeroscan.com/address/$sender"
    say "Chainlink: https://ccip.chain.link/address/$sender"
}

wait_for_relay() {
    section "Step 3/4 — Wait for cross-chain relay"
    print_explorer_links

    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        say "CI: waiting ${XC_RELAY_WAIT:-600}s for the relay"
        sleep "${XC_RELAY_WAIT:-600}"
    else
        printf '⚠ Relaying takes about 5-10 minutes. Follow the links above.\n'
        read -r -p "  Press Enter once the messages have relayed (Ctrl+C to stop)... "
    fi
}

share_class_test() {
    section "Step 4/4 — Share class test (NotifyShareClass, $HUB -> $SPOKE)"
    SPOKE_NETWORK="$SPOKE" run_sig "$HUB" 'runShareClassTest()'
}

case "$MODE" in
    full | spoke | hub | test) ;;
    *) die "Unknown mode: $MODE (full, spoke, hub or test)" ;;
esac

# Every mode resolves the spokes: the registration loops over them, and the others report where to watch the
# messages they send. A hub with no deployment is reported by Env.load in the first forge run, which requires
# every contract this test drives.
resolve_spokes
choose_spoke
say "Hub network: $HUB"
say "Connected spokes: $SPOKES"
say "Spoke under test: $SPOKE"

case "$MODE" in
    full)
        register_spokes
        setup_hub
        wait_for_relay
        share_class_test
        section "Cross-chain test complete"
        say "Re-run with the 'test' mode to repeat the share class test with new share classes."
        ;;
    spoke) register_spokes ;;
    hub)
        setup_hub
        print_explorer_links
        ;;
    test)
        share_class_test
        print_explorer_links
        ;;
esac
