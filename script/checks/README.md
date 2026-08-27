# Checks

Repo-wide checks that CI enforces, kept here so they can be run locally before pushing. They all have the
same shape: a **check** mode that fails when the repo has drifted, and a **fix** mode that makes it right
again. Nothing here talks to a chain — every one of them reads the repository and compares it to itself.

**Run everything from the repository root.**

| Script | Asserts that | Check | Fix |
|---|---|---|---|
| `fix_imports.py` | Solidity imports are relative, ordered and actually used | `--check-order`, `--check-relative`, `--check-unused`, `--test-roundtrip` | `--organize`, `--fix-unused` |
| `check_ward_coverage.py` | every `file()` target has a matching `rely()` in the deployer, and every ward grant has a test asserting it | (default) | — fix by hand |
| `check_claude_tree.py` | every path listed in the CLAUDE.md directory tree still exists | (default) | `--fix` |
| `benchmarks.sh` | the gas limits in `GasService` match a fresh benchmark run | `check` | `apply` |

```bash
python3 script/checks/fix_imports.py --organize        # before opening a PR
python3 script/checks/check_ward_coverage.py           # after changing permissions
python3 script/checks/check_claude_tree.py --fix       # after moving files around
./script/checks/benchmarks.sh apply                    # after changing message handling
```

`check_foundry_networks.py` ships with the deployment configs it derives from: `foundry.toml`'s
`[rpc_endpoints]` and `[etherscan]` come out of those, so a branch carrying none — main, whose only chains are
the two anvil fixtures, written by hand — carries no checker and no CI job for it either.

There is deliberately **no** check that the testnet deployment covers every connected network. It reads its
matrix out of the connections file at run time, so the two cannot drift and there is nothing to
police. A check belongs here only where the copy is forced — `foundry.toml`'s tables exist because forge's
Rust side cannot read `env/`.

`fix_imports.py` is the one with real depth — bidirectional relative/absolute conversion, which is what makes
moving files around safe. It has its own guide: [`fix_imports.md`](fix_imports.md).

`benchmarks.sh` is the slow one, because it runs the `EndToEnd` tests to meter gas before diffing. Its
numbers only reproduce on the Foundry version pinned in `.github/workflows/ci.yml` — a floating version
meters gas differently and the check ends up demanding values nobody can regenerate.
`update_gas_service_values.py` is not run directly; it is how `benchmarks.sh` writes a benchmark snapshot
back into `src/admin/GasService.sol`.

A note on where things go: this is separate from [`../utils/`](../utils/) because the two are different kinds
of thing. `utils/` is Solidity that other scripts import (`ChainConfig`, `EnvConfig`, `JsonRegistry`, `CreateX`); `checks/`
is executables that CI runs.
