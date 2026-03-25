# Executor - script-based execution engine

## 1. Problem

The current MerkleProofManager has several limitations:

1. **Custom decoders per protocol.** Each integration (VaultDecoder, CircleDecoder, etc.) requires a dedicated contract that mirrors target function signatures to extract address arguments for Merkle leaf verification. Every new protocol means deploying a new decoder.

2. **No script-level authorization.** Each call is authorized independently, so a strategist with N approved calls can combine them in any order, count, or subset. There is no way to whitelist a specific sequence of actions as a single workflow, which means individually safe calls can become dangerous in combination.

3. **No onchain data as inputs.** Calls cannot read on-chain state (e.g. oracle prices, vault balances) and feed results into subsequent calls. All inputs must be known off-chain before submission.

4. **No onchain accounting for arbitrary integrations or cross-chain bridging.** There is no way to track in-flight assets on-chain — whether pending async vault requests, tokens mid-bridge, or positions in external protocols — leaving accounting gaps that break NAV accuracy.

5. **No slippage protection.** There is no mechanism to bound value loss across swaps and rebalances within a strategy execution.

6. **No flash loan support.** There is no way to execute a callback mid-script, so strategies that require flash loans (e.g. leveraged looping, atomic collateral swaps) cannot be expressed.

---

## 2. Weiroll VM & Executor

### 2.1 Weiroll VM

The Executor uses [Weiroll](https://github.com/EnsoBuild/enso-weiroll), a minimal, battle-tested EVM scripting language. Weiroll takes two inputs — an array of `bytes32` **commands** and a `bytes[]` **state** array — and executes them sequentially, threading data between calls through the shared state.

#### Command encoding

Each command packs into a single `bytes32` word:

```
 Bytes 0-3:    selector     (4-byte function selector)
 Byte  4:      flags        (call type + extension bits)
 Bytes 5-10:   inputs       (6 x 1-byte state indices, compact form)
 Byte  11:     output       (1-byte state index for return value)
 Bytes 12-31:  target       (20-byte contract address)
```

**Flags byte:**

| Bit(s) | Name | Meaning |
|--------|------|---------|
| 0-1 | `CALLTYPE` | `0x01` = call, `0x02` = staticcall, `0x03` = valuecall |
| 5 | `DATA` | Use state element directly as raw calldata (skip ABI encoding) |
| 6 | `EXTENDED` | Next `bytes32` in commands array is an extended index list (up to 32 inputs) |
| 7 | `TUPLE_RETURN` | Write raw return data to state without ABI-decoding |

**Input/output indices** (1 byte each):

| Bit 7 | Bits 0-6 | Meaning |
|-------|----------|---------|
| 0 | index | Fixed-length (32-byte) state element |
| 1 | index | Variable-length state element |
| — | `0xFF` | End of arguments / no output |

#### State array

The `bytes[] state` array is the wiring mechanism between commands:

- **Initial state** is caller-provided: constants, token addresses, amounts, encoded calldata fragments.
- As commands execute, return values are written to state slots, making outputs available as inputs to later commands.
- Fixed-length values must be exactly 32 bytes; variable-length values must be multiples of 32 bytes.
- Maximum 128 state elements (limited by the `stateBitmap` which is a `uint128`).

#### Call types

| Type | Flag | Behavior |
|------|------|----------|
| **call** | `0x01` | State-changing external call |
| **staticcall** | `0x02` | Read-only call (oracle prices, balances) |
| **valuecall** | `0x03` | Call with ETH — `inputs[0]` is the ETH amount, remaining inputs are function arguments |

#### Extended commands and tuple returns

- **Extended commands:** When a function has more than 6 parameters, the `EXTENDED` flag (`0x40`) causes the next `bytes32` in the commands array to be read as a 32-byte index list, supporting up to 32 inputs per call.
- **Tuple returns:** The `TUPLE_RETURN` flag (`0x80`) writes raw return data directly to state without ABI-decoding. A helper library (`Tupler.extractElement`) can then extract individual 32-byte fields from the tuple in subsequent commands.

#### Error handling

When a call reverts, the VM wraps the error in `ExecutionFailed(uint256 command_index, address target, string message)`, preserving the original revert reason for debugging.

### 2.2 Execution flow

```
1. Look up policy[msg.sender] -> Merkle root
2. Compute scriptHash from commands, pinned state elements, and bitmap (pure, no external calls)
3. Verify Merkle proof against root — reject before executing anything
4. Copy calldata state to memory (weiroll mutates state in-place)
5. Execute commands via the weiroll VM
```

### 2.3 Multicall

The Executor inherits `BatchedMulticall`, allowing strategists to batch multiple script executions atomically:

```solidity
executor.multicall([
    abi.encodeCall(executor.execute, (commands1, state1, bitmap1, cbHashes1, cbCallers1, proof1)),
    abi.encodeCall(executor.execute, (commands2, state2, bitmap2, cbHashes2, cbCallers2, proof2))
]);
```

### 2.4 Example: multi-step strategy

Read USDC/ETH price from oracle, then supply USDC into a lending pool:

```
State (initial):
  [0] = abi.encode(USDC_ADDRESS)      <- pinned (bitmap bit 0 = 1)
  [1] = abi.encode(EXECUTOR_ADDRESS)  <- pinned (bitmap bit 1 = 1)
  [2] = abi.encode(0)                 <- pinned (bitmap bit 2 = 1)
  [3] = abi.encode(1000e6)            <- runtime (bitmap bit 3 = 0), strategist chooses amount
  [4] = (empty, will hold return)

stateBitmap: 0b0111 = 0x07   (bits 0, 1, 2 pinned)

Command 0: staticcall oracle.latestAnswer()
  flags:   0x02 (staticcall)
  inputs:  (none)
  output:  -> state[4]

Command 1: call lendingPool.supply(address, uint256, address, uint16)
  flags:   0x01 (call)
  inputs:  state[0], state[3], state[1], state[2]
           (USDC,     amount,   executor,  refCode)
  output:  -> 0xFF (ignored)

Proof: single Merkle proof for scriptHash
```

Both commands execute atomically in a single `execute()` call. Governance pins the target addresses and reference code; the strategist can only vary the amount.

---

## 3. Authorization: script-level Merkle hashing with state bitmap

### 3.1 Why script-level (not per-call)

Per-call authorization has a fundamental flaw: a strategist with N individually-authorized calls can combine them in any order, count, or subset. This enables reordering attacks where safe individual calls become dangerous in combination.

Script-level hashing authorizes entire workflows:

1. **Prevents reordering/mixing**: the command sequence is fixed
2. **Constrains read targets**: staticcall commands are part of the hash, preventing oracle substitution
3. **Verify-before-execute**: proof checked before any command runs; unauthorized scripts waste zero gas

### 3.2 State bitmap

The `stateBitmap` is a `uint128` where each bit controls whether the corresponding state element is included in the script hash:

- **Bit `i` = 1**: `state[i]` is **governance-pinned** — its value is hashed into the script hash. The strategist cannot change it without invalidating the proof. Use for: target addresses, selectors, token addresses, slippage bounds.
- **Bit `i` = 0**: `state[i]` is **runtime-variable** — its slot exists in the state array but its value is not hashed. The strategist can supply any value at execution time. Use for: amounts, deadlines, nonces.

This provides fine-grained control: governance locks down _what_ gets called and _where_ funds flow, while the strategist retains flexibility over _how much_ and _when_.

### 3.3 Script hash computation

```solidity
scriptHash = keccak256(
    keccak256(commands) ||              // exact command sequence
    hashFixedState ||                   // only pinned state elements
    stateBitmap ||                      // which elements are pinned
    state.length ||                     // number of state elements
    keccak256(callbackHashes) ||        // pre-committed callback script hashes
    keccak256(callbackCallers)          // expected msg.sender per callback slot
)

hashFixedState = keccak256(
    keccak256(state[i]) || keccak256(state[j]) || ...   // for each i where bitmap bit is set
)
```

The hash binds:
- **Commands**: exact sequence of selectors, targets, call types, and data flow wiring
- **Pinned state**: governance-approved values (addresses, parameters)
- **Bitmap**: which state slots are pinned vs runtime-variable
- **State length**: prevents calling an authorized script with extra state elements
- **Callback hashes**: an ordered array of pre-committed callback script hashes consumed sequentially by `executeCallback()` (see section 4). Scripts without callbacks pass an empty array
- **Callback callers**: a parallel array of expected `msg.sender` addresses for each callback slot (see section 4). Must match `callbackHashes` in length

### 3.4 Merkle tree structure

Each leaf is a complete script template:

```
Policy Root
├── leaf: scriptHash(oracle.latestAnswer -> lendingPool.supply, pinned=[USDC, executor], variable=[amount])
├── leaf: scriptHash(token.approve -> vault.deposit, pinned=[token, vault], variable=[amount])
├── leaf: scriptHash(slippageGuard.open -> balanceSheet.withdraw -> ... -> slippageGuard.close, pinned=[pool, assets, maxBps])
└── ...
```

Governance reviews and approves entire workflows. The strategist's Merkle tree contains all scripts they are authorized to run.

---

## 4. Callbacks & flash loans

The Executor supports mid-execution callbacks for flash loans via `executeCallback()`. Callback scripts are **pre-committed** in the outer script's `callbackHashes` array (see section 3.3), preventing mix-and-match of scripts that governance did not review together. Each callback slot also binds an expected `msg.sender` via the parallel `callbackCallers` array. Scripts without callbacks pass empty arrays for both.

### 4.1 Nested callbacks

Callbacks support arbitrary nesting depth. The outer `execute()` call receives an ordered array of all callback script hashes and their expected callers that may be invoked during execution. Each `executeCallback()` invocation consumes the next hash from the array, verifies `msg.sender` matches the corresponding `callbackCallers` entry, and proceeds only if both match. Every callback script is individually hashed and pre-committed in the `callbackHashes` and `callbackCallers` arrays, which are both included in the Merkle-proven outer script hash — an unauthorized callback script cannot execute even if it is called at the right nesting depth, and a callback cannot be consumed by an unexpected caller.

This enables composing multiple flash loan providers in a single transaction. Each provider has its own `FlashLoanHelper` contract. The outer script triggers the first provider, whose callback triggers the second, and so on:

```
callbackHashes  = [aaveCallbackHash, morphoCallbackHash]
callbackCallers = [aaveHelper,       morphoHelper]

Outer script:
  cmd 0: aaveHelper.requestFlashLoan(aavePool, USDC, 1M, executor, aaveCallbackData)
         └-> Aave sends USDC to aaveHelper
         └-> Aave calls aaveHelper.executeOperation(...)
             └-> aaveHelper transfers USDC to executor
             └-> aaveHelper calls executor.executeCallback(aaveCbScript)
                  ↓ consumes callbackHashes[0], verifies msg.sender == aaveHelper

  Aave callback script:
    cmd 0: morphoHelper.requestFlashLoan(morphoPool, WETH, 500, executor, morphoCallbackData)
           └-> Morpho sends WETH to morphoHelper
           └-> Morpho calls morphoHelper.executeOperation(...)
               └-> morphoHelper transfers WETH to executor
               └-> morphoHelper calls executor.executeCallback(morphoCbScript)
                    ↓ consumes callbackHashes[1], verifies msg.sender == morphoHelper

      Morpho callback script (innermost — has both USDC + WETH):
        cmd 0: ... actual strategy logic (swap, supply, etc.) ...
        cmd 1: WETH.transfer(morphoHelper, 500 + morphoPremium)
               └-> Morpho repayment

    cmd 1: USDC.transfer(aaveHelper, 1M + aavePremium)
           └-> Aave repayment

  cmd 1: balanceSheet.submitQueuedAssets(...)

Merkle tree:
  Policy Root
  └── outerScriptHash    (embeds [aaveCallbackHash, morphoCallbackHash] + [aaveHelper, morphoHelper])
```

Each helper is a small, provider-specific contract that bridges between the provider's callback interface and `executor.executeCallback()`. Adding a new provider only requires deploying a new helper — no Executor changes needed.

### 4.2 Example: leveraged looping

```
Callback script (the inner work):
  cmd 0: USDC.approve(swapRouter, 1M)
  cmd 1: swapRouter.swap(USDC, WETH, 1M)           -> state[5] = WETH received
  cmd 2: WETH.approve(lendingPool, state[5])
  cmd 3: lendingPool.supply(WETH, state[5])
  cmd 4: lendingPool.borrow(USDC, 1M + premium)
  cmd 5: USDC.transfer(helper, 1M + premium)        <- repay flash loan

Outer script (callbackHashes = [innerScriptHash], callbackCallers = [helper]):
  cmd 0: helper.requestFlashLoan(aavePool, USDC, 1M, executor, callbackData)
  cmd 1: balanceSheet.submitQueuedAssets(...)

Merkle tree:
  Policy Root
  └── outerScriptHash    (embeds [innerScriptHash] + [helper])
```

---

## 5. Accounting tokens, bridging & spoke-side valuations

### 5.1 Accounting tokens

Use a mintable/burnable ERC6909 multi-token as a "receipt" for in-flight assets. A **single AccountingToken deployment is shared across all pools**. The token ID encodes pool, asset, and a liability flag:

```
Token ID = (uint256(poolId) << 160) | uint256(uint160(assetAddress)) | (liability ? 1 << 255 : 0)
```

- **Bit 255 = 0**: Non-liability (accounting) token — a receipt for assets sent out (async requests, bridged-out tokens)
- **Bit 255 = 1**: Liability token — a record of tokens that arrived from elsewhere and must eventually be reconciled

This makes token IDs unique per pool, so pools cannot interfere with each other's receipts. The liability bit distinguishes sent-out receipts from arrived-asset liabilities within the same token contract.

**Access control:** Minter permissions are managed via `trustedCall` from the ContractUpdater, following the same hub governance flow as `updateBalanceSheetManager`. Both the Executor and OnOffRamp (or any other contract) can be registered as minters for a pool.

```solidity
contract AccountingToken is ERC6909, ITrustedContractUpdate {
    address public immutable contractUpdater;
    mapping(PoolId => mapping(address => bool)) public minters;

    function trustedCall(PoolId poolId, ShareClassId, bytes calldata payload) external {
        // Decode (who, canMint), update minters mapping
    }

    function mint(address to, uint256 id, uint256 amount, ShareClassId scId) external onlyMinter(id) { ... }
    function burn(address from, uint256 id, uint256 amount, ShareClassId scId) external onlyMinter(id) { ... }
}
```

**Metadata:** Non-liability tokens use `name = "Accounting - {assetName}"`, `symbol = "acc-{assetSymbol}"`. Liability tokens use `name = "Accounting (Liability) - {assetName}"`, `symbol = "liab-{assetSymbol}"`. Decimals match the underlying asset.

On the hub, accounting token IDs are registered with the same valuation as the underlying asset, keeping NAV accurate.

### 5.2 Scripts: async vault requests

**Deposit request:**
```
Call balanceSheet.withdraw(x assets)
Call asset.approve(vault, x)
Call vault.requestDeposit(x, executor, executor)
Call accountingToken.mint(executor, assetId, x, scId)
Call accountingToken.approve(balanceSheet, x)
Call balanceSheet.deposit(x accountingTokens)
Call balanceSheet.submitQueuedAssets(assets)
Call balanceSheet.submitQueuedAssets(accountingTokens)
```

**Deposit claim:**
```
Read vault.maxDeposit(executor) -> x
Call vault.deposit(x, executor)
Call balanceSheet.deposit(x shares)
Call balanceSheet.withdraw(x accountingTokens)
Call accountingToken.burn(executor, assetId, x, scId)
Call balanceSheet.submitQueuedAssets(shares)
Call balanceSheet.submitQueuedAssets(accountingTokens)
```

**Redeem request / claim:** Analogous flow in reverse (withdraw shares -> mint receipt -> claim assets -> burn receipt).

### 5.3 Cross-chain bridging via OnOffRamp

The OnOffRamp contract uses accounting tokens with the liability flag to track in-flight cross-chain transfers using a **double-entry pattern across chains**.

NOTE: this is not directly related to the Executor feature, but a new pattern that is enabled in the protocol through the new AccountingToken.

#### Source chain (tokens leaving)

The Executor runs a weiroll script that:

1. `onOffRamp.withdraw(USDC, x, executor)` — withdraws real tokens from BalanceSheet to the Executor, mints a **non-liability** accounting token (the "sent receipt") and deposits it to BalanceSheet
2. `USDC.approve(bridge)` + bridge send (e.g. CCTP `depositForBurn`)

After this, the source BalanceSheet holds: `-x USDC, +x accUSDC`.

#### Destination chain (tokens arriving)

The OnOffRamp is configured as the `mintRecipient` for the bridge (CCTP forwarding service mints directly to it). When tokens arrive:

1. `onOffRamp.deposit(poolId, scId, USDC, x)` — in a single call:
   - Deposits real USDC to BalanceSheet
   - Mints a **liability** accounting token and deposits it to BalanceSheet

After this, the destination BalanceSheet holds: `+x USDC, +x liabUSDC`.

#### Cross-chain accounting

| Chain           | Real USDC | Accounting (non-liability) | Accounting (liability) |
|-----------------|-----------|----------------------------|------------------------|
| Source          | -x        | +x                         | —                      |
| Destination     | +x        | —                          | +x                     |
| **Net**         | **0**     | **+x**                     | **+x**                 |

The non-liability token on source and liability token on destination represent opposite sides of the same in-flight transfer. On the hub, both are registered with the same valuation as USDC, so the total NAV across chains remains correct:
- Source NAV: lost x USDC, gained x accUSDC -> unchanged
- Destination NAV: gained x USDC, gained x liabUSDC (negative valuation) -> unchanged

### 5.4 Spoke-side valuation updates

Weiroll scripts can read any on-chain oracle via `staticcall`, then relay the price to the hub via `spoke.updateContract()` (the existing `UntrustedContractUpdate` message path). On the hub, OracleValuation validates the source (`msg.sender == contractUpdater` + `feeder[poolId][centrifugeId][sender]`) and applies the price. No new contracts are needed per oracle — only a new script leaf in the strategist's policy tree.

Since any `staticcall`-readable data source can be a weiroll command, this works for any integration: Chainlink feeds, Uniswap TWAPs, Aave rates, ERC4626 share prices, Morpho markets, etc.

Because the Executor inherits `BatchedMulticall`, the price update can be batched with other spoke-to-hub messages in the same transaction:

```
cmd 0: staticcall oracle.latestAnswer()              -> read price
cmd 1: spoke.updateContract(oracleValuation, price)  -> queue price update
cmd 2: balanceSheet.withdraw(assets)                  -> withdraw for rebalance
cmd 3: router.swap(...)                               -> execute strategy
cmd 4: balanceSheet.deposit(newAssets)                 -> deposit result
cmd 5: balanceSheet.submitQueuedAssets(...)            -> batch all messages
```

The price update and asset accounting flow through the gateway together, ensuring the hub sees consistent state.

---

## 6. Helpers & guards

### 6.1 ExecutorHelpers

Weiroll scripts can only call external contract functions — there is no way to perform inline arithmetic, comparisons, or type conversions within the VM itself. Without a helpers contract, every script that needs to subtract a fee, compare a balance to a threshold, or convert a `bytes32` return value to an `address` would require either:

1. A **dedicated contract** deployed for that specific operation, or
2. **Pre-computing** the value off-chain and passing it as a pinned state element, which removes the ability to react to on-chain state read during execution.

ExecutorHelpers is a single stateless contract that exposes common primitives as external functions, making them available as weiroll commands. Since weiroll uses `CALL` (not `DELEGATECALL`), these functions run in the helper's own context and cannot touch the Executor's storage — they are pure computation.

**Example: oracle-bounded swap**

```
cmd 0: staticcall oracle.latestAnswer()              -> state[4] = price
cmd 1: helpers.subBps(state[4], 50)                   -> state[5] = price * 99.5%
cmd 2: helpers.scaleDecimals(state[5], 8, 6)          -> state[6] = min output (6 decimals)
cmd 3: call router.swap(USDC, WETH, amount, state[6]) -> swap with on-chain slippage bound
```

Without helpers, the minimum output amount would have to be computed off-chain and pinned in state — making it stale by the time the transaction executes.

### 6.2 SlippageGuard

Bookend protection that bounds value loss across swaps and rebalances within a script. Guard calls are enforced by Merkle authorization — governance includes them in the script hash, so the strategist cannot remove them without invalidating the proof. No Executor changes required.

**How it works:** `open(poolId, scId, assets[])` snapshots `balanceSheet.availableBalanceOf` for each asset into transient storage. `close(poolId, scId, maxSlippageBps)` re-reads balances, converts deltas to pool denomination via `PricingLib.assetToPoolAmount` using `spoke.pricePoolPerAsset`, and verifies `loss <= totalWithdrawnValue * maxSlippageBps / 10_000`.

**Multi-asset:** All asset deltas are converted to pool denomination and aggregated. Deposit-only scripts pass trivially (totalWithdrawnValue = 0). Stale prices cause `pricePoolPerAsset` to revert, blocking execution.

**Period-based cumulative loss:** Per-script slippage bounds alone don't prevent death-by-a-thousand-cuts. SlippageGuard tracks cumulative loss over a configurable rolling period window. After each `close()`, the absolute loss is accumulated into `PeriodState.cumulativeLoss`. If the period has elapsed, the accumulator resets. Reverts if `cumulativeLoss > maxPeriodLoss` (configured as absolute pool-unit amount). Only losses accumulate — gains don't offset previous losses.

### 6.3 ApprovalGuard

Tail command that verifies the Executor has no dangling ERC20 approvals after script execution.

**How it works:** `checkZeroAllowances(ApprovalEntry[] entries)` iterates over token/spender pairs and reverts if any `allowance(msg.sender, spender) != 0`. Since weiroll uses `CALL`, `msg.sender` is the Executor — so it checks the Executor's outgoing approvals.

**Usage:** Scripts that `approve` tokens to external protocols (routers, lending pools, vaults) append a final `checkZeroAllowances` command listing every token/spender pair touched. The entries are governance-pinned state, ensuring the check cannot be weakened. If the protocol didn't consume the full allowance, execution reverts.

```
cmd N-1: router.swap(USDC, WETH, amount)
cmd N:   approvalGuard.checkZeroAllowances([(USDC, router)])   <- tail guard
```

### 6.4 CircuitBreakerGuard

Rolling-window rate limiter with two modes. State is scoped per-executor via `msg.sender`, so each Executor (i.e. each pool) has independent limits. The `key` parameter lets governance distinguish different tracked items (e.g. different assets being bridged). All parameters (`key`, `max`, `maxDeltaBps`, `window`) are governance-pinned state elements.

**`tally(key, amount, max, window)`** — Cumulative throughput limit. Adds `amount` to a rolling accumulator and reverts if the total exceeds `max` within `window` seconds. When the window expires, the accumulator resets. Use for bounding bridge outflows, withdrawal volumes, or any sum that should not exceed a threshold over time.

```
cmd 0: balanceSheet.withdraw(USDC, amount)
cmd 1: circuitBreaker.tally(usdcBridgeKey, amount, 1_000_000e6, 86400)   <- max 1M USDC per 24h
cmd 2: USDC.approve(bridge, amount)
cmd 3: bridge.send(USDC, amount, destination)
```

**`delta(key, currentValue, newValue, maxDeltaBps, window)`** — Per-window deviation limit. Anchors to `currentValue` (read from on-chain state in a prior weiroll command) when starting a new window or on first call. Within the window, all updates are compared to that fixed anchor — not to each other. This bounds total drift per window rather than per-update drift. Use for bounding share price updates, NAV changes, or any value that should stay within a band over a time period.

```
cmd 0: staticcall spoke.pricePoolPerAsset(poolId, scId, assetId)     -> state[4] = current price
cmd 1: circuitBreaker.delta(priceKey, state[4], newPrice, 500, 86400) <- max 5% from anchor per 24h
cmd 2: spoke.updateContract(oracleValuation, newPrice)
```
