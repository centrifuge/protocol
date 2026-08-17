#!/usr/bin/env python3
import json, re, sys, pathlib

# Safety margin added to each raw benchmarked value before writing to GasService.
# The benchmark runs in a controlled test environment where storage slots accessed during
# protocol setup are already warm. In production, the first execution of a message type
# may encounter cold slots (2,100 gas each vs ~100 gas warm). This offset absorbs that
# variance so the Gateway's `require(gasleft() >= gasLimit, NotEnoughGas())` check does
# not spuriously fail and cause messages to be dropped.
OFFSET = 25_000

# One entry per benchmarked message, matching the layout GasService._chainColdAccessSurcharge indexes into.
# Indices 0..24 are the MessageType enum order, so this must stay in lockstep with MessageType in
# MessageLib.sol. Index 13 is unused because UpdateVault dispatches on VaultUpdateKind, whose three variants
# carry their own counts at 25..27 in enum order.
MESSAGE_TYPES = [
    None,  # _Invalid
    "scheduleUpgrade", "cancelUpgrade", "registerAsset", "setPoolAdapters",
    "notifyPool", "notifyShareClass", "notifyPricePoolPerShare", "notifyPricePoolPerAsset", "notifyShareMetadata",
    "initiateTransferShares", "executeTransferShares",
    "updateRestriction",
    None,  # UpdateVault, resolved to 25..27
    "updateAssets", "updateShares",
    "request", "requestCallback", "setRequestManager",
    "managerCallFromSpoke", "managerCallFromHub", "updateManager", "setPolicy",
    "authorizeSpokeCall", "unauthorizeSpokeCall",
    "updateVaultDeployAndLink", "updateVaultLink", "updateVaultUnlink",
]

def _counts(cold, suffix):
    values = []
    for entry in MESSAGE_TYPES:
        values.append(0 if entry is None else cold[f"{entry}{suffix}"])
    if any(v > 255 for v in values):
        raise SystemExit(f"// ERROR: a {suffix} count exceeds one byte, widen the packing")
    return values

def _write_packed(src, field, values):
    literal = "[uint8(%d), %s]" % (values[0], ", ".join(str(v) for v in values[1:]))
    pat = re.compile(rf'{field}\s*=\s*_pack\(\s*\[.*?\]\s*\)\s*;', re.S)
    # Kept on its own line so the counts stay one readable row; the slots array exceeds the line limit and
    # carries a forgefmt disable directive, which lives above the match and is preserved.
    new_src, n = pat.subn(f'{field} = _pack(\n            {literal}\n        );', src, count=1)
    if n == 0:
        raise SystemExit(f"// ERROR: {field} assignment not found in Solidity file")
    return new_src

def main(json_path, sol_path, cold_path):
    data = json.loads(pathlib.Path(json_path).read_text(encoding="utf-8"))
    cold = json.loads(pathlib.Path(cold_path).read_text(encoding="utf-8"))
    src  = pathlib.Path(sol_path).read_text(encoding="utf-8")

    src = _write_packed(src, "coldSlotsPerMessageType", _counts(cold, "Slots"))
    src = _write_packed(src, "coldAccountsPerMessageType", _counts(cold, "Accounts"))

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
    if len(sys.argv) not in (3, 4):
        print(f"Usage: {sys.argv[0]} <values.json> <GasService.sol> [coldAccesses.json]", file=sys.stderr)
        sys.exit(1)
    cold = sys.argv[3] if len(sys.argv) == 4 else str(
        pathlib.Path(sys.argv[1]).with_name("MessageColdAccesses.json")
    )
    main(sys.argv[1], sys.argv[2], cold)
