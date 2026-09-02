---
paths:
  - "src/**"
---

# Coding style (`src/**`)

The reference aesthetic is MakerDAO's dss: small, flat, self-contained contracts where the entire system's core ledger (vat.sol) fits in ~250 lines. Core contracts are groomed like bonsai trees, every line earns its place and what remains is shaped deliberately. These principles apply to all new code and guide refactoring of existing code; `src/core` is held to them most strictly.

## Principles (enforced)

1. **Avoid inheritance for business logic.** Compose via injected interface references (constructor or `file()`), not base contracts.
   - Inheriting **generic** behavior is fine: mixins that fit in `src/misc` or similar (`Auth`, `Recoverable`, `ReentrancyProtection`, `BatchedMulticall`, `Escrow`), the contract's own interface(s), and token standards (e.g. `ShareToken is ERC20`).
   - What's not fine: inheriting behavior that is business logic related to the contract. Domain logic belongs in the contract itself or behind an injected interface, never in a shared base.
   - When extending a parent, call `super.<fn>()` rather than duplicating its logic, since copies diverge as the parent changes.
   - Constants or storage used by only one child belong in that child, not the shared base.

2. **Straightforward control flow.** A reader should follow any function top-to-bottom in one pass.
   - Guard clauses (`require`) first, then effects, then interactions (CEI).
   - Max ~2 levels of nesting. No `else` after a branch that reverts or returns.
   - No `try/catch` in core (the gateway's `excessivelySafeCall` boundary is the one sanctioned exception).
   - Dispatch chains (`if/else if` on message type or `file` param) are fine, being flat and auditable, but group them into internal helpers per module once they exceed ~10 branches.

3. **SSA (single static assignment).** Each local variable is assigned exactly once.
   - Resolve conditional values with a ternary at the declaration site, not by reassigning later.
   - Loop iterators and byte-slicing accumulators in explicit loops are exempt.
   - Storage struct mutation is what storage is for, so SSA applies to locals only; but if a storage pointer is mutated in 3+ branches (as in BalanceSheet's queue netting), extract the branching into a named pure helper that computes the new value once.

4. **Files ≤ 400 LOC (target).** Aim for contracts and libraries under 400 lines (interfaces exempt). Approaching it is a signal to split by concern or move convenience outward, not to compress formatting. But when splitting via composition isn't feasible (e.g. a vault implementation), one large contract beats splitting through inheritance; never trade file size for an inheritance hierarchy.

5. **YAGNI: keep core minimal, convenience lives in the periphery.** Core exposes one canonical, fully-parameterized function per operation. Wrappers, overloads with defaulted parameters, batched getters, and compatibility shims belong in facade/router/manager contracts (e.g. `SpokeV3_1_0`, `VaultRouter`), never in core.

6. **Aesthetics.** The shape of the file communicates the design.
   - Section headers: 3-line blocks for code sections (a `//----` divider line, `// <Label>`, then another `//----` divider line); 1-line `// <Label>` comments for state-variable groups (see Declaration Ordering). Order: Administration → main operations (grouped by flow direction or role) → view methods → internal methods. Small single-concern files (e.g. `Envoy`, `PoolEscrow`, the factories) omit headers entirely.
   - Errors and events declared in the interface, never in the contract body. Libraries are the exception: they declare their own errors locally (e.g. `PricingLib.DivisionByZero`, `MessageLib.UnknownMessageType`).
   - Documentation lives in the interface (natspec on functions, params, errors, events). In the contract itself: a top-level `@title`/`@notice` natspec block, `/// @inheritdoc` on implementations, and minimal inline comments reserved for non-obvious code.
   - State variables and modifiers almost never carry comments; a well-named `onlyManager`/`sender` explains itself. Only comment one when its purpose is genuinely non-obvious from the name and type.
   - Symmetry: paired operations (`deposit`/`withdraw`, `issue`/`revoke`, `rely`/`deny`) should mirror each other visually and structurally.
   - Names are short verbs and nouns; if a function name needs a conjunction, it does two things.
   - Follow the Declaration Ordering rules below for imports and state variables.

## Declaration Ordering (line-length sorting)

Both imports and contract-level declarations are sorted by **full line length, ascending** (shortest line first) within each blank-line-separated group. Sorting is by the whole line, so a shorter type with a longer variable name can sort *after* a longer type with a short name (e.g. `ISpokeMessageSender public sender;` before `ISpokeRegistry public spokeRegistry;`).

- **Imports**: grouped by source area (local `./`, then `../../misc`, then `../core`, then remote libs), each group separated by a blank line and sorted ascending by line length.
- **State variables / constants**: grouped by kind/purpose (constants & immutables, dependency references, mappings/storage), each group separated by a blank line and sorted ascending by line length within the group.
- **Section comments**: add a `// <Label>` above each state-variable group (e.g. `// Dependencies`, `// Assets & prices`, `// Vaults`) when the contract has several functionally-distinct storage groups whose purpose isn't self-evident (as in `MultiAdapter`, `Gateway`, `BatchRequestManager`, `SpokeRegistry`). A single dependency list uses blank-line separation without labels.
