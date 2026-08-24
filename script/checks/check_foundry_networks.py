#!/usr/bin/env python3
"""
foundry.toml network tables checker.

`env/<environment>/<network>.json` is the source of truth for every network fact. Two of those facts also have to be
reachable from forge's Rust side, which cannot read the env files: the RPC URL, so `--rpc-url <network>`
resolves, and the verification key, so `--verify` needs no flags. Those live in foundry.toml's
`[rpc_endpoints]` and `[etherscan]`, which makes them derived copies rather than a second source.

This keeps the copies honest: it regenerates both tables from `env/*.json` and, in check mode, fails if what
is in foundry.toml differs. So adding a network stays a single edit — write `env/<environment>/<network>.json`, run
`--fix` — and a forgotten table entry is caught by CI instead of surfacing later as a confusing forge error
or a verification failure in the middle of a deployment.

Usage:
    python3 script/checks/check_foundry_networks.py          # check, non-zero exit on drift
    python3 script/checks/check_foundry_networks.py --fix    # regenerate both tables

What is derived, and how:
    [rpc_endpoints] <name> = "<.network.baseRpcUrl>${<API key>}"
        The key is chosen by what the base URL points at, the same rule the deploy scripts used to apply by
        hand: alchemy -> ALCHEMY_API_KEY, plume -> PLUME_API_KEY, pharos -> PHAROS_API_KEY, otherwise none.
    [etherscan] <name> = { key = "${ETHERSCAN_API_KEY}", chain = <.network.chainId>, url = <.network.verifierUrl> }
        `chain` is required because our names are not the ones foundry knows (`ethereum`, not `mainnet`), and
        `url` only appears for the chains that are not on Etherscan. A network that verifies through a
        verifier this table cannot express gets no entry at all -- see NON_ETHERSCAN_VERIFIERS.
"""

import argparse
import json
import pathlib
import re
import sys
import tomllib

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
FOUNDRY_TOML = REPO_ROOT / "foundry.toml"
ENV_DIR = REPO_ROOT / "env"

# Which API key a base URL needs, in match order
API_KEYS = (("alchemy", "ALCHEMY_API_KEY"), ("plume", "PLUME_API_KEY"), ("pharos", "PHAROS_API_KEY"))

# Not derived from a config field: the local chains script/anvil/anvil.sh brings up answer on fixed ports,
# and nothing in env/anvil/*.json says which. Everything else about them is derived like any other network.
LOCAL_CHAINS = {"local-a": "http://localhost:8545", "local-b": "http://localhost:8546"}

# The local chains are described by fixtures next to the script that brings them up, not under env/: env/
# holds what a deployment writes, and a run of anvil.sh copies these in before writing to them
ANVIL_FIXTURES = REPO_ROOT / "script" / "anvil" / "env"

# Verifiers that [etherscan] cannot express. The table describes one thing — an Etherscan-style key and URL
# per chain — so it fits Etherscan itself and Blockscout, whose /api speaks the same dialect. Sourcify does
# not: it takes no key, and forge reaches it through `--verifier sourcify`, so an entry here would only give
# `--verify` an Etherscan endpoint to fail against on a chain Etherscan does not serve. Those chains carry
# the flag on the command line instead, passed from `.network.verifier`.
NON_ETHERSCAN_VERIFIERS = {"sourcify"}

BARE_KEY = re.compile(r"^[A-Za-z0-9_-]+$")


def toml_key(name: str) -> str:
    """TOML bare keys allow only [A-Za-z0-9_-]; anvil/<net> needs quoting."""
    return name if BARE_KEY.match(name) else f'"{name}"'


def networks() -> list[tuple[str, dict]]:
    """Every env/<environment>/<network>.json, mainnets first then testnets, alphabetical within each.

    Configs are filed under the environment they declare, so the directory is not part of the name: the
    alias a run reaches with `--rpc-url` is the network, not the path. Anything under env/ that is not a
    chain — the connections files, and env/spell/ — has no `network` key and drops out here.
    """
    found = []
    for path in sorted(ENV_DIR.glob("*/*.json")) + sorted(ANVIL_FIXTURES.glob("*.json")):
        config = json.loads(path.read_text())
        if "network" not in config:
            continue
        found.append((path.stem, config["network"]))

    return sorted(found, key=lambda item: (item[1].get("environment") != "mainnet", item[0]))


def rpc_url(network: dict) -> str:
    base = network.get("baseRpcUrl", "")
    for marker, key in API_KEYS:
        if marker in base:
            return f"{base}${{{key}}}"
    return base


def expected_tables() -> tuple[dict[str, str], dict[str, dict]]:
    rpc: dict[str, str] = {}
    etherscan: dict[str, dict] = {}

    for name, network in networks():
        rpc[name] = rpc_url(network)

        # A local chain has no explorer to verify against, and `--verify` is never passed to a run on one
        if name in LOCAL_CHAINS:
            continue

        if network.get("verifier") in NON_ETHERSCAN_VERIFIERS:
            continue

        entry: dict[str, object] = {"key": "${ETHERSCAN_API_KEY}", "chain": network["chainId"]}
        if network.get("verifierUrl"):
            entry["url"] = network["verifierUrl"]
        etherscan[name] = entry

    rpc.update(LOCAL_CHAINS)
    return rpc, etherscan


def render(rpc: dict[str, str], etherscan: dict[str, dict]) -> tuple[str, str]:
    """The body of each table, without its header, matching how the file is grouped by hand."""
    by_env = {name: net.get("environment") for name, net in networks()}

    def grouped(names, line):
        out = []
        for label, wanted in (("# Mainnets", "mainnet"), ("# Testnets", "testnet")):
            section = [n for n in names if by_env.get(n) == wanted]
            if section:
                out.append(label)
                out.extend(line(n) for n in section)
        return out

    rpc_lines = grouped(rpc, lambda n: f"{toml_key(n)} = {json.dumps(rpc[n])}")
    rpc_lines.append("# Local chains brought up by script/anvil/anvil.sh, one per chain")
    rpc_lines.extend(f"{toml_key(n)} = {json.dumps(url)}" for n, url in LOCAL_CHAINS.items())

    def etherscan_line(name: str) -> str:
        entry = etherscan[name]
        fields = [f"key = {json.dumps(entry['key'])}", f"chain = {entry['chain']}"]
        if "url" in entry:
            fields.append(f"url = {json.dumps(entry['url'])}")
        return f"{toml_key(name)} = {{ {', '.join(fields)} }}"

    return "\n".join(rpc_lines), "\n".join(grouped(etherscan, etherscan_line))


def table_span(lines: list[str], header: str) -> tuple[int, int]:
    """Line range of a table's body: after its header, up to the next top-level table."""
    try:
        start = lines.index(header)
    except ValueError:
        sys.exit(f"foundry.toml has no {header} table. Add it (even empty) and run --fix.")

    end = start + 1
    while end < len(lines) and not lines[end].startswith("["):
        end += 1

    # A comment block sitting just above the next table documents that table, not this one, so it is left
    # out of the span. Trailing blank lines stay in, and the caller re-emits exactly one, which is what keeps
    # a rewrite from stacking them up.
    while end - 1 > start and lines[end - 1].startswith("#"):
        end -= 1

    return start + 1, end


def apply_fix(rpc_body: str, etherscan_body: str) -> bool:
    lines = FOUNDRY_TOML.read_text().split("\n")

    # Rewrite the later table first, so the earlier one's line numbers stay valid
    for header, body in (("[etherscan]", etherscan_body), ("[rpc_endpoints]", rpc_body)):
        start, end = table_span(lines, header)
        # One blank line before whatever follows, be that the next table or its comment block
        trailing = [""] if end < len(lines) else []
        lines[start:end] = body.split("\n") + trailing

    updated = "\n".join(lines)
    if updated == FOUNDRY_TOML.read_text():
        return False

    FOUNDRY_TOML.write_text(updated)
    return True


def check(rpc: dict[str, str], etherscan: dict[str, dict]) -> list[str]:
    config = tomllib.loads(FOUNDRY_TOML.read_text())
    actual_rpc = config.get("rpc_endpoints", {})
    actual_etherscan = config.get("etherscan", {})
    problems = []

    for name, url in rpc.items():
        if name not in actual_rpc:
            problems.append(f'[rpc_endpoints] is missing "{name}"')
        elif actual_rpc[name] != url:
            problems.append(f'[rpc_endpoints] "{name}" is {actual_rpc[name]!r}, expected {url!r}')

    for name in actual_rpc:
        if name not in rpc:
            problems.append(f'[rpc_endpoints] has "{name}", which no env/<environment>/<network>.json declares')

    for name, entry in etherscan.items():
        if name not in actual_etherscan:
            problems.append(f'[etherscan] is missing "{name}"')
            continue
        found = actual_etherscan[name]
        # foundry resolves `chain` to a name for the chains it knows, so compare on the id it means
        if found.get("chain") not in (entry["chain"], name):
            problems.append(f'[etherscan] "{name}".chain is {found.get("chain")!r}, expected {entry["chain"]}')
        if found.get("url") != entry.get("url"):
            problems.append(
                f'[etherscan] "{name}".url is {found.get("url")!r}, expected {entry.get("url")!r}'
                " (from .network.verifierUrl)"
            )

    for name in actual_etherscan:
        if name not in etherscan:
            problems.append(f'[etherscan] has "{name}", which no env/<environment>/<network>.json declares')

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fix", action="store_true", help="regenerate both tables from env/*.json")
    args = parser.parse_args()

    rpc, etherscan = expected_tables()

    if args.fix:
        if apply_fix(*render(rpc, etherscan)):
            print(f"Regenerated [rpc_endpoints] and [etherscan] from env/ for {len(rpc)} endpoints")
        else:
            print("foundry.toml already matches env/; nothing to do")
        return 0

    problems = check(rpc, etherscan)
    if problems:
        print("foundry.toml disagrees with env/<environment>/<network>.json:\n", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print(
            "\nenv/<environment>/<network>.json is the source of truth. Fix it there, then run:"
            "\n  python3 script/checks/check_foundry_networks.py --fix",
            file=sys.stderr,
        )
        return 1

    print(f"OK: foundry.toml matches env/ for {len(rpc)} RPC endpoints and {len(etherscan)} explorers.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
