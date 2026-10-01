---
paths:
  - "src/**"
  - "src-ir/**"
  - "script/**"
  - "test/**"
  - "env/**"
  - ".github/**"
  - "foundry.toml"
---

# Docs and comments a change made false

Sessions and reviewers trust a comment or a README over re-deriving the code, so one that still describes the old behaviour misleads the next reader. When a change is complete, before committing or opening the PR, sweep once for what it made false:

1. In every changed file, re-read the natspec, `@dev`, TODO, NOTE, SAFETY and INVARIANT comments, and the inline comments on and around what changed. Each should still be true.
2. List the names the change touches: changed files, contracts, functions, structs and fields, errors and revert strings, config keys, and the data files the code reads or writes. Search for each with `git grep -n -F -w '<name>' -- '*.md' '*.sol' '*.py' '*.sh'`.
3. For every hit, check whether the diff made it false: a behaviour it describes, a schema it lists, a rule it states, an example it gives. A note that two copies must stay in sync applies both ways, so editing one means checking the other.
4. Check test names and test comments against the behaviour the change removed.
5. Re-read the PR description against the code after each fix round, since the squash commit carries it.

For example, changing which keys `script/utils/ConnectionsConfig.s.sol` accepts makes the schema in `env/README.md` stale, and step 2 finds it because the README names that file.

Correct each false claim in the same change, or delete the comment if it no longer earns its place (see `comments.md`). Keep the edits to claims the diff made false, and leave historical records as written (`docs/audits/`, `env/spell/`, dated reports). Anything you leave stale, including when the user asked you not to touch docs, goes in the PR description or your final message.
