#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# cd "$SCRIPT_DIR" || exit

# Get the root directory (one level up)
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the helper scripts
source "$SCRIPT_DIR/formathelper.sh"

# Function to verify contracts - checks latest deployment or network config
verify_contracts() {
    local deployment_script=${1:-""}
    local is_standalone=${2:-true}

    # Get etherscan URL from network config
    local network_config="$ROOT_DIR/env/$NETWORK.json"
    # Extract etherscanUrl field from network.etherscanUrl, return empty string if null/missing
    local etherscan_url=$(jq -r '.network.etherscanUrl // empty' "$network_config")

    if [[ -z "$etherscan_url" ]]; then
        print_error "No etherscanUrl found in $network_config"
        return 1
    fi

    print_info "Using Etherscan API: $etherscan_url"

    # Determine which file to check based on context
    local contracts_file
    local file_description

    if [[ "$is_standalone" == "true" ]]; then
        contracts_file="$network_config"
        file_description="network config"
        print_step "Verifying contracts from network configuration"
    else
        contracts_file="$ROOT_DIR/env/latest/${CHAIN_ID}-latest.json"
        file_description="latest deployment"
        print_step "Verifying recent deployment contracts"
    fi

    if [[ ! -f "$contracts_file" ]]; then
        print_error "No contracts file found at $contracts_file"
        return 1
    fi

    print_info "Checking contracts from: $file_description"

    # Get all contract addresses from file
    # Convert contracts object to array of "name:address" strings
    local contract_addresses=$(jq -r '.contracts | to_entries[] | "\(.key):\(.value)"' "$contracts_file")

    if [[ -z "$contract_addresses" ]]; then
        print_error "No contracts found in $contracts_file"
        return 1
    fi

    local unverified_contracts=()
    local verified_count=0
    local total_count=0

    print_info "Checking verification status for contracts..."

    # Check each contract
    while IFS= read -r contract_entry; do
        if [[ -z "$contract_entry" ]]; then
            continue
        fi

        local contract_name=$(echo "$contract_entry" | cut -d':' -f1)
        local contract_address=$(echo "$contract_entry" | cut -d':' -f2)

        total_count=$((total_count + 1))

        print_info "Checking $contract_name ($contract_address)..."

        # Check if contract is verified on Etherscan
        local result=$(curl -s "$etherscan_url?module=contract&action=getabi&address=$contract_address&apikey=$ETHERSCAN_API_KEY")

        # Check if API result indicates contract is verified (result field != "Contract source code not verified")
        if echo "$result" | jq -e '.result != "Contract source code not verified"' >/dev/null 2>&1; then
            print_success "$contract_name is verified"
            verified_count=$((verified_count + 1))
        else
            print_error "$contract_name is NOT verified"
            unverified_contracts+=("$contract_name:$contract_address")
        fi

        # Small delay to avoid rate limiting
        sleep 0.5

    done <<<"$contract_addresses"

    print_info "Verification check complete: $verified_count/$total_count contracts verified"

    # Handle unverified contracts
    if [[ ${#unverified_contracts[@]} -gt 0 ]]; then
        print_error "Found ${#unverified_contracts[@]} unverified contracts:"
        for contract in "${unverified_contracts[@]}"; do
            local name=$(echo "$contract" | cut -d':' -f1)
            local addr=$(echo "$contract" | cut -d':' -f2)
            print_error "  - $name ($addr)"
        done

        # Only offer retry for deployment context (not standalone)
        if [[ "$is_standalone" == "true" ]]; then
            print_info "To verify these contracts, run the original deployment command with --resume"
            return 1
        elif [[ -n "$deployment_script" ]]; then
            local should_resume=false

            if [[ "$CI_MODE" == "true" ]]; then
                print_info "CI mode detected. Automatically running forge --resume to verify contracts..."
                should_resume=true
            else
                read -p "Would you like to run forge --resume to verify contracts? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    should_resume=true
                else
                    print_info "Skipping verification. You can manually run: ./deploy.sh $NETWORK verify"
                fi
            fi

            if [[ "$should_resume" == "true" ]]; then
                retry_deploy "$deployment_script"
            fi
        else
            print_info "No deployment script context. Use forge script --resume manually if needed."
        fi
    else
        print_success "All contracts are verified!"
    fi

    return 0
}

# Function to handle forge --resume with retry logic
retry_deploy() {
    local deployment_script=$1

    # Retry logic for verification
    local max_retries=5
    local retry_count=0
    local resume_success=false

    while [[ $retry_count -lt $max_retries && "$resume_success" == "false" ]]; do
        retry_count=$((retry_count + 1))

        if [[ $retry_count -eq 1 ]]; then
            print_step "Running forge --resume to verify contracts..."
        else
            print_step "Retry attempt $retry_count/$max_retries for forge --resume..."
        fi

        # Save current FORGE_ARGS and add --resume
        local original_forge_args=("${FORGE_ARGS[@]}")
        FORGE_ARGS+=("--resume")

        # Use the existing run_forge_script function
        if run_forge_script "$deployment_script"; then
            resume_success=true
            print_success "Forge --resume completed successfully"

            # Re-run verification check
            print_step "Re-checking verification status..."
            verify_contracts "$deployment_script" false
        else
            # Restore original FORGE_ARGS
            FORGE_ARGS=("${original_forge_args[@]}")

            if [[ $retry_count -lt $max_retries ]]; then
                local wait_time=$((retry_count * 10))
                print_error "Forge --resume failed (attempt $retry_count/$max_retries)"
                print_info "Waiting ${wait_time} seconds before retry..."
                sleep $wait_time
            else
                print_error "Forge --resume failed after $max_retries attempts"
                return 1
            fi
        fi
    done

    return 0
}

# Usage: ./deploy.sh <network> <step> [--catapulta] [forge_args...]
# Example: ./deploy.sh eth-sepolia deploy:full
# Example: ./deploy.sh base-sepolia deploy:adapters --catapulta --priority-gas-price 2
# Example: ./deploy.sh eth-sepolia deploy:test --nonce 4765

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
    echo "  ./deploy.sh sepolia deploy:test --nonce 4765"
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
}

# Function to update network config with deployment output
update_network_config() {
    print_step "Adding contract addresses to /env/$NETWORK.json"
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
    print_subtitle "Deploying core protocol contracts for $NETWORK"
    run_forge_script "FullDeployer"
    update_network_config
    print_subtitle "Verifying deployment for $NETWORK"
    verify_contracts "FullDeployer" false
    # print_subtitle "Deploying adapters for $NETWORK"
    # run_forge_script "Adapters"
    # update_network_config

    ;;
"deploy:adapters")
    print_step "Deploying adapters for $NETWORK"
    run_forge_script "Adapters"
    update_network_config
    verify_contracts "Adapters" false
    ;;
"wire:adapters")
    print_step "Wiring adapters for $NETWORK"
    run_forge_script "WireAdapters"
    ;;
"deploy:test")
    print_step "Deploying test data for $NETWORK"
    run_forge_script "TestData"
    ;;
"verify")
    print_step "Verifying contracts for $NETWORK"
    verify_contracts
    ;;
*)
    echo "Invalid step: $STEP"
    echo "Valid steps are: deploy:full, deploy:adapters, wire:adapters, deploy:test, verify"
    exit 1
    ;;
esac
print_section "Deployment Complete"
