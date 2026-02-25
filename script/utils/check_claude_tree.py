#!/usr/bin/env python3
"""
CLAUDE.md Directory Tree Checker

Verifies that every file and directory listed in the CLAUDE.md directory tree
actually exists in the repository. The tree is curated (not exhaustive), so this
only checks one direction: listed paths must exist.

Usage:
    python3 script/utils/check_claude_tree.py [--fix]

Options:
    --fix   Remove entries from the tree that no longer exist on disk.

Exit codes:
    0 - All listed paths exist
    1 - One or more listed paths are missing
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CLAUDE_MD = REPO_ROOT / "CLAUDE.md"

# Tree-drawing characters used in the directory structure block
TREE_CHARS = {"├", "└", "│", "─", "─", " "}


def extract_tree_block(content: str) -> tuple[int, int, list[str]]:
    """Extract the directory tree code block from CLAUDE.md.

    Returns (start_line, end_line, lines) where start/end are the line indices
    of the opening/closing ``` markers (0-indexed).
    """
    lines = content.splitlines()
    in_structure_section = False
    block_start = None
    block_end = None

    for i, line in enumerate(lines):
        if "### Directory Structure" in line:
            in_structure_section = True
            continue
        if in_structure_section and line.strip() == "```":
            if block_start is None:
                block_start = i
            else:
                block_end = i
                break

    if block_start is None or block_end is None:
        print("ERROR: Could not find directory tree block in CLAUDE.md")
        sys.exit(1)

    return block_start, block_end, lines[block_start + 1 : block_end]


def parse_tree_line(line: str) -> tuple[int, str] | None:
    """Parse a single tree line into (depth, name).

    Returns None for blank lines or lines that can't be parsed.
    """
    if not line.strip():
        return None

    # Root-level entries have no tree prefix (e.g., "src/", "test/")
    stripped = line.strip()
    if not any(c in line for c in "├└│"):
        # Plain directory/file name at root of tree
        name = stripped.split("#")[0].strip().rstrip("/")
        if name:
            return (0, stripped.split("#")[0].strip())
        return None

    # Find the position of ├ or └ to determine depth
    branch_pos = None
    for i, c in enumerate(line):
        if c in "├└":
            branch_pos = i
            break

    if branch_pos is None:
        return None

    # Each indent level is 4 characters ("│   " or "    ")
    depth = branch_pos // 4

    # Extract the name after "── "
    match = re.search(r"[├└]── (.+)", line)
    if not match:
        return None

    raw_name = match.group(1)
    # Strip inline comments (e.g., "# Cross-chain message routing")
    name = raw_name.split("#")[0].strip()

    return (depth, name)


def build_paths(tree_lines: list[str]) -> list[tuple[str, int]]:
    """Convert parsed tree lines into full relative paths.

    The tree has root entries (e.g., ``src/``, ``test/``) without tree-drawing
    characters.  Their children use ``├──`` / ``└──`` starting at column 0.
    We treat root entries at depth 0 and bump all tree-char entries by +1 so
    they nest correctly under their root.

    Returns list of (path, line_offset) tuples where line_offset is the
    index within tree_lines.
    """
    paths = []
    dir_stack: list[str] = []

    for line_idx, line in enumerate(tree_lines):
        parsed = parse_tree_line(line)
        if parsed is None:
            # Blank lines reset the root context (separate tree sections)
            if not line.strip():
                dir_stack = []
            continue

        depth, name = parsed
        is_root_entry = not any(c in line for c in "├└│")

        if is_root_entry:
            # Root-level entry like "src/" or "env/"
            dir_stack = [name.rstrip("/")]
            paths.append((name.rstrip("/"), line_idx))
            continue

        # Tree-char entries are children of the current root, so depth + 1
        effective_depth = depth + 1

        # Trim stack to current depth
        dir_stack = dir_stack[:effective_depth]

        # Build the full path
        full_path = "/".join(dir_stack + [name.rstrip("/")])

        # Determine if this is a directory
        is_dir = name.endswith("/")
        if not is_dir:
            # Check if subsequent lines are indented deeper
            for next_line in tree_lines[line_idx + 1 :]:
                next_parsed = parse_tree_line(next_line)
                if next_parsed is None:
                    if not next_line.strip():
                        break  # blank line = new section
                    continue
                next_depth, _ = next_parsed
                is_dir = next_depth > depth
                break

        if is_dir:
            dir_stack = dir_stack[:effective_depth] + [name.rstrip("/")]

        paths.append((full_path, line_idx))

    return paths


def check_paths(paths: list[tuple[str, int]]) -> list[tuple[str, int]]:
    """Check which listed paths don't exist. Returns list of (path, line_offset) for missing."""
    missing = []
    for rel_path, line_offset in paths:
        full = REPO_ROOT / rel_path
        # Accept if it exists as either file or directory
        if not full.exists():
            # Also try with trailing slash stripped (directory check)
            if not full.with_suffix("").exists() and not (REPO_ROOT / rel_path.rstrip("/")).exists():
                missing.append((rel_path, line_offset))
    return missing


def fix_tree(content: str, block_start: int, block_end: int, tree_lines: list[str], missing: list[tuple[str, int]]) -> str:
    """Remove missing entries from the tree block and return updated content."""
    missing_offsets = {line_offset for _, line_offset in missing}
    new_tree_lines = [line for i, line in enumerate(tree_lines) if i not in missing_offsets]

    all_lines = content.splitlines()
    new_lines = all_lines[: block_start + 1] + new_tree_lines + all_lines[block_end:]
    return "\n".join(new_lines) + "\n"


def main() -> None:
    fix_mode = "--fix" in sys.argv

    if not CLAUDE_MD.exists():
        print("ERROR: CLAUDE.md not found at", CLAUDE_MD)
        sys.exit(1)

    content = CLAUDE_MD.read_text()
    block_start, block_end, tree_lines = extract_tree_block(content)
    paths = build_paths(tree_lines)

    if not paths:
        print("ERROR: No paths parsed from directory tree")
        sys.exit(1)

    missing = check_paths(paths)

    if not missing:
        print(f"OK: All {len(paths)} paths in CLAUDE.md directory tree exist.")
        sys.exit(0)

    if fix_mode:
        updated = fix_tree(content, block_start, block_end, tree_lines, missing)
        CLAUDE_MD.write_text(updated)
        print(f"FIXED: Removed {len(missing)} stale entries from CLAUDE.md:")
        for path, _ in missing:
            print(f"  - {path}")
        sys.exit(0)

    print(f"FAIL: {len(missing)} paths in CLAUDE.md directory tree do not exist:\n")
    for path, _ in missing:
        print(f"  MISSING: {path}")
    print(f"\nRun with --fix to auto-remove stale entries, or update CLAUDE.md manually.")
    sys.exit(1)


if __name__ == "__main__":
    main()
