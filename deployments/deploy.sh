#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

# Get the root directory (one level up)
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Usage: ./deploy.sh <network> <step> [forge_args...]
# Example: ./deploy.sh sepolia fulldeploy
# Example: ./deploy.sh base-sepolia adapters --priority-gas-price 2
# Example: ./deploy.sh sepolia testdata --nonce 4765

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: ./deploy.sh <network> <step> [forge_args...]"
    echo "Network options: sepolia, base-sepolia, etc. (must match env/<network>.json)"
    echo "Step options:"
    echo "  fulldeploy    - Deploy everything (hub, spoke, adapters, wiring)"
    echo "  adapters      - Deploy only adapters"
    echo "  adapterwiring - Wire adapters to hub/spoke"
    echo "  testdata      - Deploy test data"
    echo
    echo "Examples:"
    echo "  ./deploy.sh sepolia fulldeploy"
    echo "  ./deploy.sh base-sepolia adapters --priority-gas-price 2"
    echo "  ./deploy.sh sepolia testdata --nonce 4765"
    exit 1
fi

NETWORK=$1
STEP=$2
shift 2 # Remove the first two arguments, leaving any additional forge args

# Capture any additional forge arguments
FORGE_ARGS=("$@")

# Validate step
case "$STEP" in
"fulldeploy" | "adapters" | "adapterwiring" | "testdata") ;;
*)
    echo "Invalid step: $STEP"
    echo "Valid steps are: fulldeploy, adapters, adapterwiring, testdata"
    exit 1
    ;;
esac

# Check if network config exists
NETWORK_CONFIG="$ROOT_DIR/env/$NETWORK.json"
if [[ ! -f "$NETWORK_CONFIG" ]]; then
    echo "Network config file $NETWORK_CONFIG not found"
    exit 1
fi

# Get chain ID from network config
CHAIN_ID=$(jq -r ".network.chainId" "$NETWORK_CONFIG")
if [[ "$CHAIN_ID" == "null" ]]; then
    echo "Chain ID not found in $NETWORK_CONFIG"
    exit 1
fi

# Function to run a forge script
run_forge_script() {
    local script=$1
    echo "================================================"
    echo "Running $script..."
    echo "Network: $NETWORK"
    echo "Chain ID: $CHAIN_ID"
    echo "================================================"

    set -a
    export NETWORK="$NETWORK"
    export CHAIN_ID="$CHAIN_ID"
    source "$ROOT_DIR/.env.$NETWORK"
    set +a

    # Construct the forge command
    FORGE_CMD="cd \"$ROOT_DIR\" && forge script \
        \"script/$script.s.sol\" \
        --optimize \
        --rpc-url \"$RPC_URL\" \
        --private-key \"$PRIVATE_KEY\" \
        --verify \
        --broadcast \
        --chain-id \"$CHAIN_ID\" \
        --etherscan-api-key \"$ETHERSCAN_API_KEY\" \
        ${FORGE_ARGS[*]}"

    # Show the command that will be executed
    echo "Executing:"
    echo "$FORGE_CMD"
    echo "================================================"

    # Execute the command
    if ! eval "$FORGE_CMD"; then
        echo "Failed to run $script"
        exit 1
    fi

    echo "================================================"
    echo "$script completed successfully!"
    echo "================================================"
    echo
}

# Function to update network config with deployment output
update_network_config() {
    local latest_deployment="$ROOT_DIR/deployments/latest/${CHAIN_ID}-latest.json"
    local network_config="$ROOT_DIR/env/$NETWORK.json"

    if [[ ! -f "$latest_deployment" ]]; then
        echo "Deployment output file not found at $latest_deployment"
        return 1
    fi

    # Create a backup of the current config
    cp "$network_config" "${network_config}.bak"

    # Merge the contracts section, preserving existing entries
    if ! jq -s '
        .[0] as $config |
        .[1].contracts as $new_contracts |
        $config | .contracts = ($config.contracts + $new_contracts)
    ' "$network_config" "$latest_deployment" >"${network_config}.tmp"; then
        echo "Failed to update network config"
        mv "${network_config}.bak" "$network_config"
        return 1
    fi

    # Move the temporary file to the final location
    mv "${network_config}.tmp" "$network_config"
    rm "${network_config}.bak"

    echo "Deployed contracts added to $network_config (.contracts section)"
    return 0
}

# Run the requested step
case "$STEP" in
"fulldeploy")
    echo "Starting full deployment for $NETWORK"
    run_forge_script "FullDeployer"

    # Update network config after hub/spoke deployment
    if ! update_network_config; then
        echo "Failed to update network config after hub/spoke deployment"
        exit 1
    fi

    run_forge_script "TestData"
    ;;
"adapters")
    echo "Deploying adapters for $NETWORK"
    run_forge_script "Adapters"

    # Update network config with adapter addresses
    if ! update_network_config; then
        echo "Failed to update network config with adapter addresses"
        exit 1
    fi
    ;;
"adapterwiring")
    echo "Wiring adapters for $NETWORK"
    run_forge_script "WireAdapters"

    ;;
"testdata")
    echo "Deploying test data for $NETWORK"
    run_forge_script "TestData"
    ;;
esac

echo "================================================"
echo "Deployment completed successfully!"
echo "================================================"
