#!/usr/bin/env bash
set -euo pipefail

# Wire Monad and Pharos bidirectionally to all mainnet networks.
#
# Part 1: 8 existing chains → monad + pharos (adapter wiring + DVN config)
# Part 2: monad → all 9 chains (pharos adapter wiring + DVN config)
# Part 3: pharos → all 9 chains (DVN config only, adapters already wired at deployment)
#
# Required env vars:
#   ALCHEMY_API_KEY   - Alchemy API key (used by most chains)
#   PHAROS_API_KEY    - Pharos (ZAN) API key
#
# The script uses the batched WireToNewNetwork contract which produces
# at most 2 Safe proposals per source chain (1 ops Safe, 1 protocol Safe).
#
# Usage:
#   export ALCHEMY_API_KEY=...
#   export PHAROS_API_KEY=...
#   bash script/wire-monad.sh

SCRIPT="script/WireToNewNetwork.s.sol"
COMMON_FLAGS="--broadcast --slow"

RPC_ETHEREUM="https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_BASE="https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_ARBITRUM="https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_AVALANCHE="https://avax-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_BNB="https://bnb-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_HYPEREVM="https://hyperliquid-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_OPTIMISM="https://opt-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_PLUME="https://rpc.plume.org/"
RPC_MONAD="https://monad-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
RPC_PHAROS="https://api.zan.top/node/v1/pharos/mainnet/${PHAROS_API_KEY}"

# ─────────────────────────────────────────────────────────────────────────────
# Part 1: Existing chains → Monad + Pharos
#         wireAll: adapter wiring + initAdapters (ops Safe)
#         configureLzDvnsAll: LZ DVN config (protocol Safe)
#         2 signing rounds per chain = 16 total
# ─────────────────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════════════════════════════"
echo " Part 1: Wire existing chains → monad,pharos"
echo "════════════════════════════════════════════════════════════════"

declare -A RPCS=(
  [ethereum]="$RPC_ETHEREUM"
  [base]="$RPC_BASE"
  [arbitrum]="$RPC_ARBITRUM"
  [avalanche]="$RPC_AVALANCHE"
  [bnb-smart-chain]="$RPC_BNB"
  [hyper-evm]="$RPC_HYPEREVM"
  [optimism]="$RPC_OPTIMISM"
  [plume]="$RPC_PLUME"
)

for network in ethereum base arbitrum avalanche bnb-smart-chain hyper-evm optimism plume; do
  echo ""
  echo "── ${network} → monad,pharos ──"
  NETWORK="$network" TARGETS="monad,pharos" \
    forge script "$SCRIPT" --rpc-url "${RPCS[$network]}" $COMMON_FLAGS
  echo "✓ ${network} done"
done

# ─────────────────────────────────────────────────────────────────────────────
# Part 2: Monad → all chains
#         wireAll: adapter wiring to pharos (ops Safe) — other targets already wired, skipped
#         configureLzDvnsAll: LZ DVN config for all 9 chains (protocol Safe)
#         2 signing rounds
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Part 2: Monad → all chains (pharos wiring + DVN config)"
echo "════════════════════════════════════════════════════════════════"
echo ""

NETWORK="monad" TARGETS="ethereum,base,arbitrum,plume,avalanche,bnb-smart-chain,hyper-evm,optimism,pharos" \
  forge script "$SCRIPT" --rpc-url "$RPC_MONAD" $COMMON_FLAGS

echo "✓ monad done"

# ─────────────────────────────────────────────────────────────────────────────
# Part 3: Pharos → all chains (DVN config only)
#         wireAll: adapters already wired at deployment, all targets skipped
#         configureLzDvnsAll: LZ DVN config for all 9 chains (protocol Safe)
#         1 signing round (protocol Safe only)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Part 3: Pharos → all chains (DVN config)"
echo "════════════════════════════════════════════════════════════════"
echo ""

NETWORK="pharos" TARGETS="ethereum,base,arbitrum,plume,avalanche,bnb-smart-chain,hyper-evm,optimism,monad" \
  forge script "$SCRIPT" --rpc-url "$RPC_PHAROS" $COMMON_FLAGS

echo "✓ pharos done"

# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " Complete. Total signing rounds: 19"
echo "   Part 1: 8 chains × 2 proposals (ops + protocol) = 16"
echo "   Part 2: 1 chain × 2 proposals (ops + protocol)  =  2"
echo "   Part 3: 1 chain × 1 proposal  (protocol only)   =  1"
echo "════════════════════════════════════════════════════════════════"
