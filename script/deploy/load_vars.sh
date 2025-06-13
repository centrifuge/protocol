#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get the root directory (one level up)
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the format helper
source "$SCRIPT_DIR/formathelper.sh"

# Function to cleanup environment variables
cleanup_env() {
    print_info "Cleaning up environment variables"
    unset RPC_URL
    unset ETHERSCAN_API_KEY
    unset ADMIN
    unset PRIVATE_KEY
}

# Function to check GCP configuration
check_gcp() {
    # Skip if in CI mode
    if [ "$CI_MODE" = "true" ]; then
        print_info "CI mode detected, skipping GCP checks"
        return 0
    fi
    # ... rest of check_gcp function ...
}

# Function to test RPC connection
test_rpc_connection() {
    local rpc_url=$1
    if cast block latest --rpc-url "$rpc_url" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to get secrets from Secret Manager
get_api_key() {
    local key_type=$1
    local key
    case "$key_type" in
    "ALCHEMY_API_KEY")
        key=$(gcloud secrets versions access latest --project centrifuge-production-x --secret=alchemy_api)
        ;;
    "ETHERSCAN_API_KEY")
        key=$(gcloud secrets versions access latest --project centrifuge-production-x --secret=etherscan_api)
        ;;
    "PRIVATE_KEY")
        if [ "$IS_TESTNET" = "true" ]; then
            key=$(gcloud secrets versions access latest --project centrifuge-production-x --secret=testnet-private-key)
        else
            print_error "Mainnet detected, no private key loaded"
        fi
        ;;
    *)
        print_error "Unknown key type: $key_type"
        return 1
        ;;
    esac

    if [ -z "$key" ]; then
        print_error "Could not fetch $key_type from Secret Manager"
        return 1
    fi
    export "$key_type"="$key"
}

# Function to get Alchemy RPC URL
get_alchemy_rpc_url() {
    local network_config=$1
    local api_key=$2

    # Get network identifier from config
    local network_id
    network_id=$(jq -r '.network.network' "$network_config")

    if [ "$network_id" = "null" ] || [ -z "$network_id" ]; then
        print_error "Network identifier not found in config"
        return 1
    fi

    # Map network names to Alchemy network identifiers
    case "$network_id" in
    "ethereum")
        network_id="eth"
        ;;
    "arbitrum")
        network_id="arb"
        ;;
    "base")
        network_id="base"
        ;;
    "celo")
        network_id="celo"
        ;;
    *)
        print_error "Unsupported network for Alchemy: $network_id"
        return 1
        ;;
    esac

    # Get environment from config
    local is_testnet
    is_testnet=$(jq -r '.network.environment == "testnet"' "$network_config")

    # Construct URL based on environment
    if [ "$is_testnet" = "true" ]; then
        # Special case for Celo testnet
        if [ "$network_id" = "celo" ]; then
            echo "https://${network_id}-alfajores.g.alchemy.com/v2/${api_key}"
        else
            echo "https://${network_id}-sepolia.g.alchemy.com/v2/${api_key}"
        fi
    else
        echo "https://${network_id}-mainnet.g.alchemy.com/v2/${api_key}"
    fi
}

load_env() {
    cleanup_env
    print_step "Network: $1"
    local network=$1
    local network_config="$ROOT_DIR/env/$network.json"

    if [[ ! -f "$network_config" ]]; then
        print_error "Network config file $network_config not found"
        return 1
    fi

    print_step "Checking GCP Configuration"
    check_gcp
    print_success "GCP configuration verified"

    print_step "Loading Network Configuration"
    CHAIN_ID=$(jq -r ".network.chainId" "$network_config")
    if [[ "$CHAIN_ID" == "null" ]]; then
        print_error "Chain ID not found in $network_config"
        return 1
    fi
    print_info "Chain ID: $CHAIN_ID"

    # Set ADMIN based on network type
    IS_TESTNET=$(jq -r '.network.environment == "testnet"' "$network_config")
    if [ "$IS_TESTNET" = "true" ]; then
        ADMIN="0x423420Ae467df6e90291fd0252c0A8a637C1e03f" # Testnet Safe
    else
        case "$network" in
        "ethereum") ADMIN="0xD9D30ab47c0f096b0AA67e9B8B1624504a63e7FD" ;;
        "base") ADMIN="0x8b83962fB9dB346a20c95D98d4E312f17f4C0d9b" ;;
        "celo") ADMIN="0x2464f95F6901233bF4a0130A3611d5B4CBd83195" ;;
        "arbitrum") ADMIN="0xa36caE0ACd40C6BbA61014282f6AE51c7807A433" ;;
        *)
            echo "Error: Unknown mainnet network $network"
            return 1
            ;;
        esac
    fi

    print_step "Setting up RPC Connection"
    if [ "$network" = "plume" ]; then
        print_info "Plume network detected"
        if [ "$IS_TESTNET" = "true" ]; then
            RPC_URL="https://testnet-rpc.plume.org"
        else
            RPC_URL="https://mainnet-rpc.plume.org"
        fi
        print_success "Plume RPC URL configured"
    fi

    print_step "Configuring Alchemy RPC"
    get_api_key "ALCHEMY_API_KEY"
    if [ -z "$RPC_URL" ] && [ -n "$ALCHEMY_API_KEY" ]; then
        RPC_URL=$(get_alchemy_rpc_url "$network_config" "$ALCHEMY_API_KEY")

        if test_rpc_connection "$RPC_URL"; then
            print_success "Alchemy RPC connection verified"
        else
            print_error "Alchemy RPC not responding"
            echo "RPC_URL: $RPC_URL"
            return 1
        fi
    fi

    # Check if we have a working RPC
    if [ -z "$RPC_URL" ]; then
        print_error "Error: No working RPC API found"
        return 1
    fi

    print_step "Loading Secrets"
    get_api_key "ETHERSCAN_API_KEY"
    print_success "Etherscan API key loaded"

    if [ "$IS_TESTNET" = "true" ]; then
        print_step "Loading Testnet Private Key"
        get_api_key "PRIVATE_KEY"
        print_success "Private key loaded"
    fi

    if [ -z "$PRIVATE_KEY" ]; then
        print_info "No PRIVATE_KEY found in GCP secrets - will try to use ledger instead"
    fi

    # Check etherscan API key
    if [ -z "$ETHERSCAN_API_KEY" ]; then
        print_error "ETHERSCAN_API_KEY not found in .env.$network"
        return 1
    else
        # Check if etherscan API key is valid by making a test request
        if ! curl -s "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID&module=account&action=balance&address=0x0000000000000000000000000000000000000000&tag=latest&apikey=$ETHERSCAN_API_KEY" >/dev/null; then
            print_error "Invalid ETHERSCAN_API_KEY or Etherscan API not responding"
            return 1
        fi
    fi
    # Check if catapulta_network exists in config and set CATAPULTA_NET
    if [ -n "$(jq -r '.network.catapultaNetwork // empty' "$network_config")" ]; then
        CATAPULTA_NET=$(jq -r '.network.catapultaNetwork' "$network_config")
        print_success "Catapulta network configured: $CATAPULTA_NET"
    fi

}

if [[ -z "$1" ]]; then
    print_error "Error: Network not provided"
    return 1
fi
if [[ "$2" == "skip_cleanup" ]]; then
    skip_cleanup=true
fi

# Check if script is being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    print_error "This script must be sourced to export variables to your shell"
    print_info "Please use: source ./load_vars.sh $1"
    return 1
else
    # First check if variables are already set in the current shell
    if [ -n "$RPC_URL" ] && [ -n "$ETHERSCAN_API_KEY" ] && [ -n "$ADMIN" ] && [ -n "$PRIVATE_KEY" ]; then
        print_section "Using Existing Environment Variables"
        print_info "Required variables are already set in the current shell"
    else
        # Then check if .env file exists and contains required variables
        if [ -f "$ROOT_DIR/.env" ] &&
            grep -q "RPC_URL" "$ROOT_DIR/.env" &&
            grep -q "ETHERSCAN_API_KEY" "$ROOT_DIR/.env" &&
            grep -q "ADMIN" "$ROOT_DIR/.env" &&
            grep -q "PRIVATE_KEY" "$ROOT_DIR/.env"; then
            print_section "Loading Environment from .env file"
            print_info "RPC_URL ETHERSCAN_API_KEY ADMIN PRIVATE_KEY are found in the .env file"
            print_info "Foundry should automatically load the environment variables from the .env file"
        else
            print_section "Loading Environment from Google Cloud"
            print_info ".env does not contain all required variables. Trying Google Cloud secrets retrieval"
            load_env "$1"
        fi
    fi
    # The folloging is needed to make any of these variables available to the Solidity scripts through forge
    set -a
    # shellcheck disable=SC2269
    ADMIN="$ADMIN"
    set +a

    # Only set up cleanup timer if not sourced from deploy.sh
    if [ "$skip_cleanup" != true ]; then
        print_info "Environment variables will be cleaned up in 30 minutes"
        # Run cleanup in background after 30 minutes
        (sleep 1800 && cleanup_env) &
    fi
fi
