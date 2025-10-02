#!/usr/bin/env python3
import json, re, sys, pathlib

def main(json_path, sol_path):
    data = json.loads(pathlib.Path(json_path).read_text(encoding="utf-8"))
    src  = pathlib.Path(sol_path).read_text(encoding="utf-8")

    # For each key, replace the whole assignment line while preserving indentation and trailing comments
    # Pattern captures: indent + 'key = BASE_COST + ' + number + ';' + optional trailing
    missing = []
    for k, v in data.items():
        if k == "BENCHMARKING_RUN_ID": continue
        pat = re.compile(rf'^(\s*{re.escape(k)}\s*=\s*BASE_COST\s*\+\s*)([0-9_]+)(\s*;)([^\n]*)?', re.M)
        new_src, n = pat.subn(rf'\g<1>{int(v)}\3\4', src, count=1)
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
