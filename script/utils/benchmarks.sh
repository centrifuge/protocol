#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "No option provided."
  echo "Usage: $0 {apply|check}"
  exit 1
fi

case $1 in
  apply)
    # Computes new benchmarks and updates GasService with those values
    RAYON_NUM_THREADS=1 BENCHMARKING_RUN_ID="$(date +%s)" forge test EndToEnd
    python3 script/utils/update_gas_service_values.py ./snapshots/MessageGasLimits.json ./src/core/messaging/GasService.sol
    ;;

  check)
    # Checks if GasService must be updated
    RAYON_NUM_THREADS=1 BENCHMARKING_RUN_ID="$(date +%s)" forge test EndToEnd

    tmp="$(mktemp ./src/core/messaging/GasService_temp.XXXXXXX.sol)"
    cp ./src/core/messaging/GasService.sol "$tmp"
    trap 'rm -f "$tmp"' EXIT

    python3 script/utils/update_gas_service_values.py ./snapshots/MessageGasLimits.json "$tmp"

    sdiff -s ./src/core/messaging/GasService.sol "$tmp"
    ;;

  *)
    echo "Unknown option: $1"
    echo "Usage: $0 {apply|check}"
    exit 1
    ;;

esac

