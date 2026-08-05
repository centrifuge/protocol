# Audit out-of-scope lists

Internal out-of-scope scoping for external security reviews. Excluded from the public mirror via `.publicignore`, because these reference assumptions and findings that are not public, including not-yet-released versions under audit.

The audit report PDFs in the parent `docs/audits/` directory stay public; only this `out-of-scope/` subfolder is internal.

## Files

* `cantina-bug-bounty.md` — rolling out-of-scope list for the ongoing Cantina bug bounty (https://cantina.xyz/code/6cc9d51a-ac1e-4385-a88a-a3924e40c00e/overview), covering the live deployed code. Header tracks the latest deployed version.
* `vX.Y.Z.md` — out-of-scope list for a targeted audit of an upcoming release, before it is live and covered by the bounty (e.g. `v3.3.0.md`). General scope follows the bounty; the file lists only the version-specific items.

## Lifecycle

A version's list starts as `vX.Y.Z.md` during its targeted audit. Once that version is deployed and enters the bug bounty, its still-relevant items fold into `cantina-bug-bounty.md` and its header version is bumped.
