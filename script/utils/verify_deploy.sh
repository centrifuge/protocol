#!/bin/bash
set -euo pipefail

set -a; source .env; set +a # auto-export all sourced vars

# ./script/utils/verify_deploy.sh eth-sepolia
# ./script/utils/verify_deploy.sh base-sepolia
# ./script/utils/verify_deploy.sh arb-sepolia

ALCHEMY_NAME="$1"
RPC_URL="https://$ALCHEMY_NAME.g.alchemy.com/v2/$ALCHEMY_API_KEY"
GUARDIAN_V3="0xa5ac766b22d9966c3e64cc44923a48cb8b052eda"
ADMIN="0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb" # The account of PRIVATE_KEY

export VERSION="v3.1"
export ROOT=$(cast call $GUARDIAN_V3 "root()(address)" --rpc-url "$RPC_URL")
export PROTOCOL_ADMIN=$ADMIN
export OPS_ADMIN=$ADMIN

forge script script/LaunchDeployer.s.sol:LaunchDeployer \
    --optimize \
    --rpc-url "$RPC_URL" \
    --resume \
    --verify \
    --private-key "$PRIVATE_KEY" \
    --etherscan-api-key $ETHERSCAN_API_KEY
