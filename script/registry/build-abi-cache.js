#!/usr/bin/env node
/**
 * Warm the local Forge ABI cache for one or more git tags (worktree + build + copy out/).
 *
 * Usage (from repo root):
 *   node script/registry/build-abi-cache.js v3.1.0
 *   node script/registry/build-abi-cache.js v3.1.0 v3
 *
 * Cache layout: cache/abi-registry/<tag>/out/ (same as abi-registry.js).
 */

import { ensureAbiCache } from "./utils/abi-cache.js";

const tags = process.argv.slice(2).filter((a) => !a.startsWith("-"));

if (tags.length === 0) {
    console.error("Usage: node script/registry/build-abi-cache.js <git-tag> [git-tag ...]");
    console.error("Example: node script/registry/build-abi-cache.js v3.1.0 v3");
    process.exit(1);
}

const cwd = process.cwd();
for (const tag of tags) {
    ensureAbiCache(tag, { cwd });
}

console.log(`\nDone. Cached tags: ${tags.join(", ")}`);
