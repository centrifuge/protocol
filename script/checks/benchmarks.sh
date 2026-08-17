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
    # Cold-access counts need a separate pass: vm.startStateDiffRecording perturbs gas metering, so a
    # recorded run cannot also produce gas values. Do NOT merge these two passes. Enabling the cheatcode
    # around the measured call reads ~25% low (scheduleUpgrade 136574 -> 101887), which would silently
    # under-provision every message type on every chain.
    RAYON_NUM_THREADS=1 BENCHMARKING_RUN_ID="$(date +%s)" BENCHMARK_COLD_ACCESSES=1 forge test EndToEnd
    python3 script/checks/update_gas_service_values.py ./snapshots/MessageGasLimits.json ./src/admin/GasService.sol
    # Normalizes the rewritten packed-count arrays, whose wrapping depends on the digit widths
    forge fmt ./src/admin/GasService.sol
    ;;

  check)
    # Checks if GasService must be updated
    RAYON_NUM_THREADS=1 BENCHMARKING_RUN_ID="$(date +%s)" forge test EndToEnd
    RAYON_NUM_THREADS=1 BENCHMARKING_RUN_ID="$(date +%s)" BENCHMARK_COLD_ACCESSES=1 forge test EndToEnd

    tmp="$(mktemp ./src/admin/GasService_temp.XXXXXXX.sol)"
    cp ./src/admin/GasService.sol "$tmp"
    trap 'rm -f "$tmp"' EXIT

    python3 script/checks/update_gas_service_values.py ./snapshots/MessageGasLimits.json "$tmp"
    forge fmt "$tmp"

    sdiff -s ./src/admin/GasService.sol "$tmp"
    ;;

  *)
    echo "Unknown option: $1"
    echo "Usage: $0 {apply|check}"
    exit 1
    ;;

esac

