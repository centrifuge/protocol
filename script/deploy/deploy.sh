#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# cd "$SCRIPT_DIR" || exit

# Get the root directory (one level up)
ROOT_DIR="$(cd "$SCRIPT_DIR/../../" && pwd)"

# Source the helper scripts
source "$SCRIPT_DIR/formathelper.sh"

# Function to verify contracts - checks latest deployment or network config
verify_contracts() {
    local deployment_script=${1:-""}

    # Get etherscan URL from network config
    local network_config="$ROOT_DIR/env/$NETWORK.json"
    # Extract etherscanUrl field from network.etherscanUrl, return empty string if null/missing
    local etherscan_url
    etherscan_url=$(jq -r '.network.etherscanUrl // empty' "$network_config")

    if [[ -z "$etherscan_url" ]]; then
        print_error "No etherscanUrl found in $network_config"
        exit 1
    fi

    print_step "Using Etherscan API: $etherscan_url"

    # Start with network config, but check if latest deployment differs
    local contracts_file="$network_config"
    print_step "Verifying contracts from $contracts_file"

    if [[ ! -f "$contracts_file" ]]; then
        print_error "No contracts file found at $contracts_file"
        exit 1
    fi

    # Check if we need to sync latest deployment with network config
    local latest_deployment="$ROOT_DIR/env/latest/${CHAIN_ID}-latest.json"
    if [[ -f "$latest_deployment" ]]; then
        print_step "Checking if latest deployment differs from network config..."

        # Compare contract addresses between latest deployment and network config
        local addresses_differ=false

        # Extract and sort contract addresses from both files for comparison
        local latest_contracts
        latest_contracts=$(jq -r '.contracts | to_entries[] | "\(.key):\(.value)"' "$latest_deployment" 2>/dev/null | sort)
        local config_contracts
        config_contracts=$(jq -r '.contracts | to_entries[] | "\(.key):\(.value)"' "$network_config" 2>/dev/null | sort)

        # Compare the sorted contract lists
        if [[ "$latest_contracts" != "$config_contracts" ]]; then
            addresses_differ=true
        fi

        if [[ "$addresses_differ" == "true" ]]; then
            latest_deploy_file=/env/latest/$(basename "$latest_deployment")
            deploy_config=/env/$(basename "$network_config")
            print_warning "$latest_deploy_file has different contract addresses than $deploy_config"
            print_warning "This is usually a sign that the deployment was not successful and thus $deploy_config didn't update"
            # Check if latest deployment is recent (within 24 hours)
            local latest_file_age
            # Get file modification time - works on both Linux and macOS
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS
                latest_file_age=$(($(date +%s) - $(stat -f %m "$latest_deployment" 2>/dev/null || echo 0)))
                deploy_file_age=$(($(date +%s) - $(stat -f %m "$network_config" 2>/dev/null || echo 0)))
            else
                # Linux and other Unix-like systems
                latest_file_age=$(($(date +%s) - $(stat -c %Y "$latest_deployment" 2>/dev/null || echo 0)))
                deploy_file_age=$(($(date +%s) - $(stat -c %Y "$network_config" 2>/dev/null || echo 0)))
            fi
            local one_day_in_seconds=86400
            if [[ $latest_file_age -gt $one_day_in_seconds ]]; then
                print_warning "The latest deployment file is old (age: $((latest_file_age / 3600)) hours)"
                print_warning "Decide which contracts to verify:"
                print_info "1. Verify $latest_deploy_file) - it will override $deploy_config when finished"
                print_info "2. Verify $deploy_config - age: $((deploy_file_age / 3600)) hours"

                while true; do
                    read -p "Choose option (1/2): " -n 1 -r
                    echo
                    case $REPLY in
                    1)
                        print_info "Use /env/latest/$(basename "$latest_deployment") - it will update config"
                        contracts_file="$latest_deployment"
                        print_step "Now verifying contracts from $contracts_file"
                        break
                        ;;
                    2)
                        print_info "Use /env/$(basename "$network_config")"
                        # Continue with current network config
                        break
                        ;;
                    *)
                        print_info "Invalid choice, please try again"
                        ;;
                    esac
                done
            else

                print_info "Latest deployment contracts will be verified and network config will be updated"

                # Switch to using latest deployment for verification
                contracts_file="$latest_deployment"
                print_step "Now verifying contracts from $contracts_file"
            fi
        fi
    fi

    # Filter contracts based on deployment script type
    local jq_filter='.contracts | to_entries[]'

    # Determine which contracts to verify based on the deployment script
    if [[ "$deployment_script" == "Adapters" ]]; then
        # For Adapters deployment, only verify adapter contracts
        jq_filter='.contracts | to_entries[] | select(.key == "wormholeAdapter" or .key == "axelarAdapter")'
        print_info "Filtering for Adapters deployment: checking only wormholeAdapter and axelarAdapter"
    elif [[ "$deployment_script" == "FullDeployer" ]]; then
        # For FullDeployer, verify all contracts EXCEPT adapter contracts
        jq_filter='.contracts | to_entries[] | select(.key != "wormholeAdapter" and .key != "axelarAdapter")'
        print_info "Filtering for protocol deployment: checking all contracts except adapters"
    fi

    # Get contract addresses based on the filter
    local contract_addresses
    contract_addresses=$(jq -r "$jq_filter | \"\(.key):\(.value)\"" "$contracts_file")

    if [[ -z "$contract_addresses" ]]; then
        print_error "No contracts found to verify based on deployment script: $deployment_script"
        print_info "Available contracts in $contracts_file:"
        jq -r '.contracts | keys[]' "$contracts_file" | while read -r contract; do
            print_info "  - $contract"
        done
        exit 1
    fi

    local unverified_contracts=()
    local verified_count=0
    local total_count=0

    # Check each contract
    while IFS= read -r contract_entry; do
        if [[ -z "$contract_entry" ]]; then
            continue
        fi

        local contract_name
        contract_name=$(echo "$contract_entry" | cut -d':' -f1)
        local contract_address
        contract_address=$(echo "$contract_entry" | cut -d':' -f2)

        total_count=$((total_count + 1))

        # First, check if contract is deployed (has code at the address)
        local contract_code
        contract_code=$(curl -s -X POST -H "Content-Type: application/json" \
            --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$contract_address\",\"latest\"],\"id\":1}" \
            "$RPC_URL" | jq -r '.result')

        if [[ "$contract_code" == "0x" || "$contract_code" == "null" ]]; then
            print_error "$contract_name ($contract_address) is NOT deployed (no code at address)"
            unverified_contracts+=("$contract_name:$contract_address")
            continue
        else
            print_success "$contract_name ($contract_address) is deployed"
        fi

        # Now check if contract is verified on Etherscan (using API v2)
        print_info "Checking if $contract_name ($contract_address) is verified on Etherscan..."
        local result
        result=$(curl -s "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID&module=contract&action=getsourcecode&address=$contract_address&apikey=$ETHERSCAN_API_KEY")

        # Check if API result indicates contract is verified (positive verification check)
        # For verified contracts: SourceCode contains actual code, ContractName is set, CompilerVersion is set
        if echo "$result" | jq -e '(.result[0].SourceCode != null and .result[0].SourceCode != "" and .result[0].SourceCode != "Contract source code not verified") and (.result[0].ContractName != null and .result[0].ContractName != "")' >/dev/null 2>&1; then
            print_success "$contract_name ($contract_address) is verified on Etherscan"
            verified_count=$((verified_count + 1))
        else
            print_error "$contract_name ($contract_address) is deployed but NOT verified on Etherscan"
            unverified_contracts+=("$contract_name:$contract_address")
        fi

        # Small delay to avoid rate limiting
        sleep 0.5

    done <<<"$contract_addresses"

    print_info "Verification check complete: $verified_count/$total_count contracts verified"

    # Handle unverified contracts
    if [[ ${#unverified_contracts[@]} -gt 0 ]]; then

        # Handle retry logic for both standalone and deployment contexts
        if [[ "$CI_MODE" == "true" ]]; then
            print_info "CI mode detected. Automatically running forge --resume to verify contracts..."
            retry_deploy "$deployment_script"
        else
            print_info "If you run forge --resume, it will use the /broadcast data from the previous deployment, make sure this is what you want"
            read -p "Would you like to run forge --resume to verify contracts? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                retry_deploy "$deployment_script"
            else
                print_info "Retry using forge --resume cancelled by the user, run it again to retry"
                return 1
            fi
        fi
    else
        print_success "All contracts are verified!"

        # If we verified from latest deployment and all contracts are verified, update the network config
        if [[ "$contracts_file" == "$latest_deployment" ]]; then
            print_step "All contracts verified successfully - updating network config"
            update_network_config
        fi
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
    local broadcast_dir="$ROOT_DIR/broadcast/${deployment_script}.s.sol"

    # Check if broadcast directory exists
    if [[ ! -d "$broadcast_dir" ]]; then
        print_error "No broadcast directory found at $broadcast_dir"
        print_error "Cannot resume verification without a previous deployment"
        print_info "Please run a deployment first using deploy:protocol or deploy:adapters"
        print_info "If the deploy was run by someone else, unfortunately manual verification or redeployment will be needed"
        return 1
    fi

    while [[ $retry_count -lt $max_retries && "$resume_success" == "false" ]]; do
        retry_count=$((retry_count + 1))

        if [[ $retry_count -eq 1 ]]; then
            print_step "Running forge --resume to verify contracts..."
        else
            print_step "Retry attempt $retry_count/$max_retries for forge --resume..."
        fi

        # Save current FORGE_ARGS and add --resume
        local original_forge_args=("${FORGE_ARGS[@]}")
        FORGE_ARGS+=("--resume --delay 10")
        # Use the existing run_forge_script function
        if run_forge_script "$deployment_script"; then
            resume_success=true
            print_success "Forge --resume completed successfully"

            # Re-run verification check
            print_step "Re-checking verification status..."
            verify_contracts "$deployment_script"
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
                print_info "Env file $ROOT_DIR/env/$NETWORK.json will not be updated"
                exit 1
            fi
        fi
    done

    return 0
}

# Function to run a forge script
run_forge_script() {
    local script=$1
    print_step "Script: $script"
    print_info "Network: $NETWORK"
    print_info "Chain ID: $CHAIN_ID"

    # Construct the forge command
    FORGE_CMD="ADMIN=$ADMIN NETWORK=$NETWORK forge script \
        \"$ROOT_DIR/script/$script.s.sol\" \
        --optimize \
        --rpc-url \"$RPC_URL\" \
        --private-key \"$PRIVATE_KEY\" \
        --verify \
        --broadcast \
        --chain-id \"$CHAIN_ID\" \
        --verbosity 4 \
        # --delay 10 \
        # --slow \
        ${FORGE_ARGS[*]}"

    CATAPULTA_CMD="NETWORK=$NETWORK catapulta script \
        --private-key $PRIVATE_KEY \
        --network ${CATAPULTA_NET:-$NETWORK} \
        --chain-id \"$CHAIN_ID\" \
        \"$ROOT_DIR/script/$script.s.sol\" \
        --optimize \
        --rpc-url \"$RPC_URL\" \
        --private-key \"$PRIVATE_KEY\" \
        --verify \
        --broadcast \
        ${FORGE_ARGS[*]}"

    print_step "Executing Command"

    # Execute the appropriate command
    if [ "$USE_CATAPULTA" = true ]; then
        print_info "Using Catapulta deployment"
        print_info "Running: catapulta script $script ..."
        eval "$CATAPULTA_CMD"
        if [[ $? -ne 0 ]]; then
            print_error "Failed to run $script with Catapulta"
            exit 1
        fi
    else
        print_info "Using Forge deployment"
        print_info "Running: forge script $script ..."
        eval "$FORGE_CMD"
        if [[ $? -ne 0 ]]; then
            # Check if deployment succeeded but verification failed
            local latest_deployment="$ROOT_DIR/env/latest/${CHAIN_ID}-latest.json"
            if [[ -f "$latest_deployment" ]]; then
                print_warning "Forge script failed, but deployment succeeded"
                print_warning "This often happens when contracts deploy successfully but verification fails"
                print_warning "The env file will NOT be updated automatically due to verification failure"
                print_info "To update the env file manually, run:"
                print_info "  ./deploy.sh $NETWORK verify:[protocol|adapters]"
                print_info "Or manually copy from: env/latest/${CHAIN_ID}-latest.json"
                print_warning "IMPORTANT: Your env/$NETWORK.json file is NOT up to date with the latest deployment!"
                return 0 # Don't exit, let the script continue
            else
                print_error "ERROR: Failed to run $script with Forge"
                print_step "Try these steps:"
                print_info "1. Run ./deploy.sh $NETWORK $STEP --resume to pick up where this run left off"
                print_info "2. Run ./deploy.sh $NETWORK forge:clean for a new clean deployment (sometimes lingering old deploys conflict with new code)"
                print_info "3. Try running the command manually:"
                print_info "   ADMIN=\$ADMIN NETWORK=\$NETWORK forge script \"$ROOT_DIR/script/$script.s.sol\" --optimize --rpc-url \"\$RPC_URL\" --private-key \"\$PRIVATE_KEY\" --verify --broadcast --chain-id \"\$CHAIN_ID\" --verbosity 4 --delay 10 --slow --resume"
                print_info "   OR"
                print_info "   ADMIN=\$ADMIN NETWORK=\$NETWORK forge script \"$ROOT_DIR/script/$script.s.sol\" --optimize --rpc-url \"\$RPC_URL\" --private-key \"\$PRIVATE_KEY\" --verify --broadcast --chain-id \"\$CHAIN_ID\" --verbosity 4 --delay 10 --slow"
                print_info "NOTE: Do not forget to source the secrets using load_vars.sh first"
                exit 1
            fi
        fi
    fi

    print_success "Script execution completed successfully"
}

# Function to update network config with deployment output
update_network_config() {
    print_step "Adding contract addresses to /env/$NETWORK.json"
    local latest_deployment="$ROOT_DIR/env/latest/${CHAIN_ID}-latest.json"
    local network_config="$ROOT_DIR/env/$NETWORK.json"

    if [[ ! -f "$latest_deployment" ]]; then
        print_error "Deployment output file not found at $latest_deployment"
        exit 1
    fi

    # Create a backup of the current config
    cp "$network_config" "${network_config}.bak"

    # Get the current git commit hash
    local git_commit
    git_commit=$(git rev-parse --short HEAD)
    if [[ $? -ne 0 ]]; then
        print_error "Failed to get git commit hash"
        mv "${network_config}.bak" "$network_config"
        exit 1
    fi

    # Merge the contracts section and add git commit hash, preserving existing entries
    if ! jq -s --arg commit "$git_commit" '
        .[0] as $config |
        .[1].contracts as $new_contracts |
        $config | 
        .contracts = ($config.contracts + $new_contracts) |
        .deploymentInfo = {
            "gitCommit": $commit,
            "timestamp": (now | todate)
        }
    ' "$network_config" "$latest_deployment" >"${network_config}.tmp"; then
        print_error "Failed to update network config"
        mv "${network_config}.bak" "$network_config"
        exit 1
    fi

    # Move the temporary file to the final location
    mv "${network_config}.tmp" "$network_config"
    rm "${network_config}.bak"

    print_success "Deployed contracts added to $network_config (.contracts section)"
    return 0
}

# Usage: ./deploy.sh <network> <step> [--catapulta] [forge_args...]
# Example: ./deploy.sh eth-sepolia deploy:protocol
# Example: ./deploy.sh base-sepolia deploy:adapters --catapulta --priority-gas-price 2
# Example: ./deploy.sh eth-sepolia deploy:test --nonce 4765

if [[ -z "$1" ]] || [[ "$1" != "forge:clean" && -z "$2" ]]; then
    echo "Usage: ./deploy.sh <network> <step> [--catapulta] [forge_args...]"
    echo "Network options: sepolia, base-sepolia, etc. (must match env/<network>.json)"
    echo "Step options:"
    echo "  deploy:protocol  - Deploy core protocol contracts (hub, spoke)"
    echo "  deploy:adapters  - Deploy only adapters"
    echo "  wire:adapters    - Wire adapters to hub/spoke"
    echo "  deploy:test      - Deploy test data"
    echo "  verify:protocol  - Verify core protocol contracts"
    echo "  verify:adapters  - Verify Adapters contracts"
    echo
    echo "Options:"
    echo "  --catapulta     - Use Catapulta for deployment"
    echo
    echo "Examples:"
    echo "  ./deploy.sh sepolia deploy:protocol"
    echo "  ./deploy.sh base-sepolia deploy:adapters --catapulta --priority-gas-price 2"
    echo "  ./deploy.sh sepolia deploy:test --nonce 4765"
    echo "  ./deploy.sh sepolia verify:protocol"
    echo "  ./deploy.sh arbitrum-sepolia verify:adapters"
    echo "  ./deploy.sh forge:clean"
    exit 1
fi

# Set arguments
CI_MODE=${CI_MODE:-false}

if [[ "$1" == "forge:clean" || "$2" == "forge:clean" ]]; then
    NETWORK=""
    STEP="forge:clean"
    shift 1 # Remove the argument
else
    NETWORK=$1
    STEP=$2
    shift 2 # Remove the first two arguments
fi

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

# Load environment variables only if not forge:clean
if [[ "$STEP" != "forge:clean" ]]; then
    if ! source "$SCRIPT_DIR/load_vars.sh" "$NETWORK"; then
        print_error "Failed to load environment variables"
        exit 1
    fi
fi

# Run the requested step

case "$STEP" in
"deploy:protocol")
    print_section "Running Deployment"
    print_subtitle "Deploying core protocol contracts for $NETWORK"
    run_forge_script "FullDeployer"
    print_subtitle "Verifying deployment for $NETWORK"
    verify_contracts "FullDeployer"
    print_section "Deployment Complete"
    ;;
"deploy:adapters")
    print_section "Running Deployment"
    print_step "Deploying adapters for $NETWORK"
    run_forge_script "Adapters"
    print_subtitle "Check verification status for $NETWORK"
    verify_contracts "Adapters"
    print_section "Deployment Complete"
    ;;
"wire:adapters")
    print_step "Wiring adapters for $NETWORK"
    run_forge_script "WireAdapters"
    print_section "Wiring Complete"
    ;;
"deploy:test")
    print_section "Deploying test data for $NETWORK"
    run_forge_script "TestData"
    print_section "Test Data deployed"
    ;;
"verify:protocol")
    print_section "Verifying core protocol contracts for $NETWORK"
    verify_contracts "FullDeployer"
    print_section "Verification Complete"
    ;;
"verify:adapters")
    print_section "Verifying Adapters contracts for $NETWORK"
    verify_contracts "Adapters"
    print_section "Verification Complete"
    ;;
"forge:clean")
    print_subtitle "Cleaning up forge files and folders"
    print_step "rm -rf $ROOT_DIR/broadcast/ "
    rm -rf "$ROOT_DIR/broadcast/*"
    print_step "Removing out files"
    rm -rf "$ROOT_DIR/out/*"
    print_step "Removing cache files"
    rm -rf "$ROOT_DIR/cache/*"
    print_step "Running forge clean"
    forge clean
    print_subtitle "Forge files and folders cleaned"
    ;;
*)
    echo "Invalid step: $STEP"
    echo "Valid steps are: deploy:protocol, deploy:adapters, wire:adapters, deploy:test, verify:protocol, verify:adapters"
    exit 1
    ;;
esac
