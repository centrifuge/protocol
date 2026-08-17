#!/bin/bash
set -euo pipefail

set -a; source .env; set +a # auto-export all sourced vars

# Runs the PoolHooks script against one network.
#
# The signer is passed on the command line, the way the deploy scripts take it, rather than baked in here:
# what signs a mainnet run is never what signs a testnet one, and a script that picks for you is a script
# that picks wrong on the network where it matters.
#
#   ./script/ops/execute-pool-hooks.sh sepolia  --private-key "$PRIVATE_KEY"
#   ./script/ops/execute-pool-hooks.sh ethereum --ledger --sender <ledger-address> --slow
#   ./script/ops/execute-pool-hooks.sh base     --account <keystore-name> --sender <address> --slow
#
# The network name is an [rpc_endpoints] alias, which is where a base URL and its API key are composed, and
# an [etherscan] alias, which is what --verify needs.

NETWORK=${1:?Usage: $0 <network> <signer flags...>}
shift
SIGNER=("$@")

if [ ${#SIGNER[@]} -eq 0 ]; then
    echo "No signer given. Pass it explicitly, e.g. --private-key \$PRIVATE_KEY, or --ledger --sender <address>" >&2
    exit 1
fi

CONFIG="env/$NETWORK.json"
if [ ! -f "$CONFIG" ]; then
    echo "No $CONFIG. The network is the name of an env config, which is also its [rpc_endpoints] alias" >&2
    exit 1
fi

# PRIVATE_KEY in .env is the testnet deployer key and is never used on mainnet. Refuse it here rather than
# let it reach a mainnet as an unfunded or, worse, an authorized sender
if [ "$(jq -r '.network.environment' "$CONFIG")" = "mainnet" ]; then
    case " ${SIGNER[*]} " in
        *" --private-key "*)
            echo "$NETWORK is a mainnet: sign with --ledger or --account, never a raw key" >&2
            exit 1
            ;;
    esac
fi

echo ""
echo "##########################################################################"
echo "#                    STEP 1: Run PoolHooks script"
echo "##########################################################################"
echo ""

forge script script/ops/PoolHooks.s.sol:PoolHooks \
    --optimize \
    --rpc-url "$NETWORK" \
    --resume \
    --verify \
    --broadcast \
    "${SIGNER[@]}"

echo ""
echo "##########################################################################"
echo "#                           Done!"
echo "##########################################################################"
echo ""
