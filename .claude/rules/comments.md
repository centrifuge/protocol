---
paths:
  - "**/*.sol"
---

# Code comments

A comment must earn its place; the default is none. Write one only for a non-obvious *why* that a competent reader cannot get from the code, the names or the interface natspec, and that stays true beyond the current PR. Comment why, never what.

Never:

1. Restate the next lines of code, above all as narration before a `require` or a branch.
2. Announce what a test covers (`// xyz is tested`, `// reverts when …`); the test name says it.
3. Justify the change to a reviewer: why this diff exists, what it fixes. That is PR context. Keep a terse form only if the reason matters beyond the PR.
4. Cite line numbers or line ranges of this repo's code; they go stale with the next edit. A permalink pinned to a commit of an external source is fine.
5. Reference audit-finding, plan or ticket IDs (`G5`, `B24`, `yA1`).
6. Run long. A comment is a clause or one line; anything needing a paragraph belongs in the interface natspec or a doc, or nowhere.
7. Repeat the interface natspec in the contract body. Implementations get `@inheritdoc` and at most a terse `@dev`.

A terse comment is earned by a non-obvious ordering or security reason (send before install), a subtle invariant or assumption not visible locally, or a genuine gotcha (repricing, rounding).

The invariant suites, `test/integration/recon-end-to-end/` and `test/integration/recon-messaging/`, may explain more: the intuition behind a property, the reasoning behind a ghost variable. The Never list still applies there.
