#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Flexible multi-adapter / multi-network deploy script.
#
# Examples
#   ./deploy.sh --test --adapter Wormhole,Axelar --networks Ethereum,Base
#   ./deploy.sh --broadcast --adapter Wormhole --networks Ethereum,Base,Avalanche
#
# Requirements
#   • .env with global secrets (PRIVATE_KEY, ETHERSCAN_KEY, etc.)
#   • Per-network variables:  RPC_URL_<NET>, CHAIN_ID_<NET>
#       e.g. RPC_URL_ETHEREUM, CHAIN_ID_ETHEREUM
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

###############################################################################
# 0 ▸ Load secrets from .env (fail loud & clear if it is missing)
###############################################################################
if [[ ! -f .env ]]; then
  echo "❌  .env file not found in $(pwd)
      Create one (you can copy .env.example) and fill in:
        PRIVATE_KEY, ETHERSCAN_KEY, RPC_URL_<NETWORK>, CHAIN_ID_<NETWORK>, ..."
  exit 1
fi
source .env           # shellcheck source=/dev/null

# Verify required keys are set
: "${PRIVATE_KEY:?❌  PRIVATE_KEY is not set in .env}"
: "${ETHERSCAN_KEY:?❌  ETHERSCAN_KEY is not set in .env}"

################################################################################
# Defaults
################################################################################
TEST=false
BROADCAST=false
declare -a ADAPTERS
declare -a NETWORKS

################################################################################
# Help / usage
################################################################################
usage() {
  cat <<'EOF'
Usage: deploy.sh [--test] [--broadcast] --adapter <A,B,...> --networks <N1,N2,...>

Options
  --test          Use TestDeployer instead of FullDeployer
  --broadcast     Forward --broadcast and --verify to forge script
  --adapter  list Comma-separated adapters (e.g. Wormhole,Axelar)
  --networks list Comma-separated networks (e.g. Ethereum,Base,Avalanche)
  -h, --help      Show this help
EOF
  exit 1
}

################################################################################
# Flag parser
################################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)       TEST=true;       shift ;;
    --broadcast)  BROADCAST=true;  shift ;;
    --adapter)
      [[ -n ${2:-} ]] || usage
      IFS=',' read -ra ADAPTERS <<< "$2"; shift 2 ;;
    --networks)
      [[ -n ${2:-} ]] || usage
      IFS=',' read -ra NETWORKS <<< "$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "❌ Unknown option: $1"; usage ;;
  esac
done

[[ ${#ADAPTERS[@]} -eq 0 || ${#NETWORKS[@]} -eq 0 ]] && usage

################################################################################
# Helper: Resolve RPC URL and chain-ID for a network
################################################################################
network_params() {         # $1 = network name (case-insensitive)
  local net="${1^^}"       # upper-case: Ethereum → ETHEREUM
  local url="RPC_URL_${net}"
  local id="CHAIN_ID_${net}"
  [[ -n ${!url:-} && -n ${!id:-} ]] || {
    echo "❌ Missing \$${url} or \$${id} in .env" >&2; exit 1; }
  echo "${!url}|${!id}"
}

################################################################################
# 1 ▸ Export one environment variable per adapter  (USE_WORMHOLE=true …)
################################################################################
for AD in "${ADAPTERS[@]}"; do
  export "USE_${AD^^}"=true
done

################################################################################
# 2 ▸ Select the deployer Solidity script
################################################################################
DEPLOYER="FullDeployer"
[[ $TEST == true ]] && DEPLOYER="TestDeployer"

################################################################################
# 3 ▸ Compose broadcast-related flags
################################################################################
FORGE_FLAGS=""
if [[ $BROADCAST == true ]]; then
  FORGE_FLAGS="--broadcast --verify"
fi

################################################################################
# 4 ▸ House-keeping
################################################################################
mkdir -p deployments/latest
forge clean

################################################################################
# 5 ▸ Deployment loop (iterate only over networks)
################################################################################
for NET in "${NETWORKS[@]}"; do
  IFS='|' read -r RPCURL CHAINID <<< "$(network_params "$NET")"

  echo "🚀 Deploying adapters [${ADAPTERS[*]}] to [$NET]  (test=$TEST broadcast=$BROADCAST)"

  forge script "script/adapters/${DEPLOYER}.s.sol:${DEPLOYER}" \
        --optimize \
        --rpc-url "$RPCURL" \
        --private-key "$PRIVATE_KEY" \
        --chain-id "$CHAINID" \
        --etherscan-api-key "$ETHERSCAN_KEY" \
        $FORGE_FLAGS

  echo "✅ Completed → $NET"
done
