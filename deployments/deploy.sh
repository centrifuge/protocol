#!/bin/bash

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root directory (parent of the script directory)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse arguments
ADAPTER=$1
CHAIN=$2

# Shift the first two arguments (adapter and chain)
shift 2

# Parse remaining arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --salt)
        SALT="$2"
        shift 2
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
done

# Check for required arguments
if [[ -z "$ADAPTER" ]] || [[ -z "$CHAIN" ]]; then
    echo "Usage: ./deploy.sh <adapter> <chain>"
    echo "Example: ./deploy.sh Localhost sepolia"
    exit 1
fi

# Check if the environment file exists
ENV_FILE="$PROJECT_ROOT/.env.${CHAIN}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Environment file $ENV_FILE not found"
    exit 1
fi

# Source the chain-specific environment file
echo "Using environment from $ENV_FILE"
set -a
source "$ENV_FILE"
set +a

# Check for PRIVATE_KEY environment variable
if [[ -z "$PRIVATE_KEY" ]]; then
    echo "PRIVATE_KEY environment variable is required in $ENV_FILE"
    exit 1
fi

# Set up deployment command
DEPLOY_CMD="forge script script/adapters/${ADAPTER}.s.sol:${ADAPTER}Deployer --optimize  --rpc-url ${RPC_URL} --verify --private-key ${PRIVATE_KEY} --broadcast"

# Run the deployment command
echo "Running deployment command:"
echo "$DEPLOY_CMD"
cd "$PROJECT_ROOT" && eval "$DEPLOY_CMD"
