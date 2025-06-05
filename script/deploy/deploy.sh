#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# cd "$SCRIPT_DIR" || exit

# Get the root directory (one level up)
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the helper scripts
source "$SCRIPT_DIR/formathelper.sh"

# Usage: ./deploy.sh <network> <step> [--catapulta] [forge_args...]
# Example: ./deploy.sh eth-sepolia deploy:full
# Example: ./deploy.sh base-sepolia deploy:adapters --catapulta --priority-gas-price 2
# Example: ./deploy.sh eth-sepolia test --nonce 4765

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: ./deploy.sh <network> <step> [--catapulta] [forge_args...]"
    echo "Network options: sepolia, base-sepolia, etc. (must match env/<network>.json)"
    echo "Step options:"
    echo "  deploy:full      - Deploy everything (hub, spoke, adapters)"
    echo "  deploy:adapters  - Deploy only adapters"
    echo "  wire:adapters    - Wire adapters to hub/spoke"
    echo "  deploy:test      - Deploy test data"
    echo
    echo "Examples:"
    echo "  ./deploy.sh sepolia deploy:full"
    echo "  ./deploy.sh base-sepolia deploy:adapters --catapulta --priority-gas-price 2"
    echo "  ./deploy.sh sepolia test --nonce 4765"
    exit 1
fi

# Set arguments
CI_MODE=${CI_MODE:-false}
NETWORK=$1
STEP=$2
shift 2 # Remove the first two arguments

# Check for --catapulta flag
USE_CATAPULTA=false
FORGE_ARGS=()

# Process remaining arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
    --catapulta)
        USE_CATAPULTA=true
        shift
        ;;
    *)
        FORGE_ARGS+=("$1")
        shift
        ;;
    esac
done

# Validate step
case "$STEP" in
"deploy:full" | "deploy:adapters" | "wire:adapters" | "test") ;;
*)
    echo "Invalid step: $STEP"
    echo "Valid steps are: deploy:full, deploy:adapters, wire:adapters, test"
    exit 1
    ;;
esac

# Function to run a forge script
run_forge_script() {
    local script=$1
    print_step "Script: $script"
    print_info "Network: $NETWORK"
    print_info "Chain ID: $CHAIN_ID"

    # Construct the forge command
    FORGE_CMD="NETWORK=$NETWORK forge script \
        \"$ROOT_DIR/script/$script.s.sol\" \
        --optimize \
        --rpc-url \"$RPC_URL\" \
        --private-key \"$PRIVATE_KEY\" \
        --verify \
        --broadcast \
        --chain-id \"$CHAIN_ID\" \
        --etherscan-api-key \"$ETHERSCAN_API_KEY\" \
        ${FORGE_ARGS[*]}"

    CATAPULTA_CMD="NETWORK=$NETWORK DEPLOYMENT_SALT=$DEPLOYMENT_SALT catapulta script $script \"$ROOT_DIR/script/$script.s.sol\" --network ${CATAPULTA_NET:-$NETWORK} --private-key $PRIVATE_KEY"

    print_step "Executing Command"

    # Execute the appropriate command
    if [ "$USE_CATAPULTA" = true ]; then
        print_info "Using Catapulta deployment"
        if ! eval "$CATAPULTA_CMD"; then
            print_error "Failed to run $script with Catapulta"
            print_info "Command: $CATAPULTA_CMD"
            exit 1
        fi
    else
        print_info "Using Forge deployment"
        if ! eval "$FORGE_CMD"; then
            print_error "Failed to run $script with Forge"
            print_info "Command: $FORGE_CMD"
            exit 1
        fi
    fi
    print_section "Deployment Complete"
}

# Function to update network config with deployment output
update_network_config() {
    local latest_deployment="$ROOT_DIR/deployments/latest/${CHAIN_ID}-latest.json"
    local network_config="$ROOT_DIR/env/$NETWORK.json"

    if [[ ! -f "$latest_deployment" ]]; then
        print_error "Deployment output file not found at $latest_deployment"
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
        print_error "Failed to update network config"
        mv "${network_config}.bak" "$network_config"
        return 1
    fi

    # Move the temporary file to the final location
    mv "${network_config}.tmp" "$network_config"
    rm "${network_config}.bak"

    print_success "Deployed contracts added to $network_config (.contracts section)"
    return 0
}

# Load environment variables
if ! source "$SCRIPT_DIR/load_vars.sh" "$NETWORK"; then
    print_error "Failed to load environment variables"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ] || [ -z "$ETHERSCAN_API_KEY" ] || [ -z "$ADMIN" ]; then
    print_error "Error: loading variables failed"
    print_error "Run ./load_vars.sh $NETWORK to load variables and check for errors before running this script"
    exit 1
fi

# Run the requested step
print_section "Running Deployment"
case "$STEP" in
"deploy:full")
    print_step "Starting full deployment for $NETWORK"
    run_forge_script "FullDeployer"

    # Update network config after hub/spoke deployment
    if ! update_network_config; then
        print_error "Failed to update network config after hub/spoke deployment"
        exit 1
    fi

    run_forge_script "Adapters"

    ;;
"deploy:adapters")
    print_step "Deploying adapters for $NETWORK"
    run_forge_script "Adapters"

    # Update network config with adapter addresses
    if ! update_network_config; then
        print_error "Failed to update network config with adapter addresses"
        exit 1
    fi
    ;;
"wire:adapters")
    print_step "Wiring adapters for $NETWORK"
    run_forge_script "WireAdapters"
    ;;
"deploy:test")
    print_step "Deploying test data for $NETWORK"
    run_forge_script "TestData"
    ;;
esac
