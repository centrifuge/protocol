# Out-of-scope list

`cantina-bug-bounty.md` is the single out-of-scope list for the Cantina bug bounty (https://cantina.xyz/code/6cc9d51a-ac1e-4385-a88a-a3924e40c00e/overview), covering the live deployed code. Its header tracks the latest deployed version. It is published to the public mirror from the live branch, since the bounty is scoped against it. This README stays internal via `.publicignore`.

The audit report PDFs in the parent `docs/audits/` directory stay public.

## Lifecycle

A release under a targeted audit may carry a draft `vX.Y.Z.md` for the items specific to it. Once that release is deployed and enters the bug bounty, its still-relevant items fold into `cantina-bug-bounty.md`, the header version is bumped, and the draft is deleted.
