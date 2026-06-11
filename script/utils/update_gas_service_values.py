#!/usr/bin/env python3
import json, re, sys, pathlib

# Safety margin added to each raw benchmarked value before writing to GasService.
# The benchmark runs in a controlled test environment where storage slots accessed during
# protocol setup are already warm. In production, the first execution of a message type
# may encounter cold slots (2,100 gas each vs ~100 gas warm). This offset absorbs that
# variance so the Gateway's `require(gasleft() >= gasLimit, NotEnoughGas())` check does
# not spuriously fail and cause messages to be dropped.
OFFSET = 25_000

def main(json_path, sol_path):
    data = json.loads(pathlib.Path(json_path).read_text(encoding="utf-8"))
    src  = pathlib.Path(sol_path).read_text(encoding="utf-8")

    # For each key, replace the whole assignment line while preserving indentation and trailing comments
    # Pattern captures: indent + 'key = ' + optional prefix (e.g. CONSTANT + ) + _gasValue(<number>) + ';' + trailing
    missing = []
    for k, v in data.items():
        if k == "BENCHMARKING_RUN_ID": continue
        pat = re.compile(
            rf'^(\s*{re.escape(k)}\s*=\s*)'          # indent + "<name> = "
            rf'([A-Z_]+\s*\+\s*)?'                   # optional constant prefix (e.g. "RECOVERY_TOKEN_EXTRA_COST + ")
            rf'_gasValue\(\s*([0-9_]+)\s*\)'         # _gasValue(<number>)
            rf'(\s*;)([^\n]*)?',                     # semicolon + trailing comment
            re.M,
        )
        new_src, n = pat.subn(rf'\1\2_gasValue({int(v) + OFFSET})\4\5', src, count=1)
        if n == 0:
            missing.append((k, v))
        else:
            src = new_src

    pathlib.Path(sol_path).write_text(src, encoding="utf-8")

    if missing:
        for k, v in missing:
            print(f"// ERROR: Key {k}: {v} not found in Solidity file", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <values.json> <GasService.sol>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
