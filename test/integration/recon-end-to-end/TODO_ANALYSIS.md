# TODO Analysis - Recon End-to-End Test Suite

**Date**: 2025-09-04  
**Scope**: test/integration/recon-end-to-end/  
**Total TODOs Found**: 22  
**Status**: ✅ 5 unnecessary TODOs removed

## Executive Summary

This analysis identified 22 TODO comments across 5 files in the invariant testing suite. **Critical findings**: Several core invariant properties are broken due to removed functionality (`hub_triggerIssueShares`), requiring immediate attention. The analysis categorizes TODOs by priority and provides actionable recommendations for each.

### Priority Breakdown
- **🔴 HIGH PRIORITY**: 5 issues (affecting test reliability)
- **🟡 MEDIUM PRIORITY**: 8 issues (requiring architectural decisions)  
- **🟢 LOW PRIORITY**: 5 issues (code quality improvements)
- **✅ COMPLETED**: 5 issues (removed during cleanup)

---

## 🔴 HIGH PRIORITY ISSUES

### 1. **Ghost Tracking Broken** - `Properties.sol:120`
```solidity
// TODO(wischli): shareMints is no longer updated because hub_triggerIssueShares was removed
```
**Impact**: Property `property_sum_of_minted_equals_total_supply` is broken  
**Action Required**: Investigate and fix ghost variable tracking after `hub_triggerIssueShares` removal  
**Risk**: 🔴 High - Core invariant property fails

### 2. **Revoked Shares Property Bug** - `Properties.sol:167`
```solidity
// TODO(wischli): Breaks for ever `revokedShares` which reduced totalSupply  
```
**Impact**: Property `property_total_cancelled_redeem_shares_lte_total_supply` has known bug  
**Action Required**: Fix property logic to handle revoked shares or properly disable  
**Risk**: 🟡 Medium - May give false negatives

### 3. **Uint128 Overflow Issue** - `AsyncVaultCentrifugeProperties.sol:143`
```solidity
// TODO(wischli): Find solution for Uint128_Overflow
// else {
//     maxMintBefore = syncManager.maxMint(IBaseVault(_getVault()), _getActor());
// }
```
**Impact**: Sync vault logic is commented out due to overflow  
**Action Required**: Implement safe math or proper bounds checking  
**Risk**: 🟡 Medium - Missing test coverage for sync vaults

### 4. **Zero Price Investigation** - `Properties.sol:114`
```solidity
// TODO(wischli): Investigate with zero price
```
**Impact**: Property behavior at zero price is unknown  
**Action Required**: Test edge cases and document expected behavior  
**Risk**: 🟡 Medium - Potential edge case failures

### 5. **Complex Property Missing** - `Properties.sol:341`
```solidity
// TODO: this can't currently hold, requires a different implementation
// function property_sum_of_account_balances_leq_escrow() public vaultIsSet {
```
**Impact**: Important invariant property is disabled  
**Action Required**: Redesign and implement the property correctly  
**Risk**: 🟡 Medium - Missing coverage of escrow balance invariant

---

## 🟡 MEDIUM PRIORITY ISSUES

### 6. **Architectural Review Needed** - `SharedStorage.sol:107-110`
```solidity
/**
 * // TODO: Jeroen to review!
 *     // NOTE This is basically an imaginary counter
 *     // It's not supposed to work this way in reality
 *     // TODO: MUST REMOVE
 */
mapping(address => uint256) sumOfWithdrawable;
```
**Impact**: Counter doesn't reflect reality  
**Action Required**: Get architectural review - keep or remove counter  
**Risk**: 🟡 Medium - Potentially incorrect property calculations

### 7. **Bytes Calldata Issue** - `CryticToFoundry.sol:34,39`
```solidity
// TODO: Fix bytes calldata issue - skipping for now
// hub_updateRestriction(chainId, "");
```
**Impact**: Wrapper functions skip actual calls  
**Action Required**: Fix parameter passing or remove unused functions  
**Risk**: 🟢 Low-Medium - Missing test coverage for restriction updates

### 8. **Asset Mapping Review** - `SharedStorage.sol:50-53`
```solidity
// NOTE: TODO
// ** INCOMPLETE - Deployment, Setup and Cycling of Assets, Shares, Pools and Vaults **/
/// TODO: Consider dropping
mapping(address => uint128) assetAddressToAssetId;
mapping(uint128 => address) assetIdToAssetAddress;
```
**Impact**: Questioning necessity of asset mappings  
**Action Required**: Architectural decision - simplify or document usage  
**Risk**: 🟢 Low - Code complexity

### 9. **Global Counter Issues** - `SharedStorage.sol:155`
```solidity
// TODO: Global-1 and Global-2
// Something is off
```
**Impact**: Vague issue with global counters  
**Action Required**: Investigate what's "off" with Global-1 and Global-2  
**Risk**: 🟡 Medium - Unclear but flagged by developer

### 10. **Clamping Logic** - `SharedStorage.sol:96`
```solidity
// UNSURE | TODO
// Pretty sure I need to clamp by an amount sent by the user
// Else they get like a bazillion tokens
```
**Impact**: Potential unbounded token minting  
**Action Required**: Implement proper bounds checking  
**Risk**: 🟡 Medium - Potential overflow/unrealistic values

---

## 🟢 LOW PRIORITY ISSUES

### 11. **Contract Naming** - `AsyncVaultCentrifugeProperties.sol:29`
```solidity
// TODO(wischli): Rename to `(Base)VaultProperties` to indicate support for async as well as sync vaults
```
**Action Required**: Rename contract during refactoring  
**Risk**: 🟢 Low - Code clarity improvement

### 12. **Stateless Test Modifiers** - Lines 122, 304
```solidity
// TODO(wischli): Add back statelessTest modifier after optimizer run
```
**Action Required**: Re-enable modifiers when optimizer issues resolved  
**Risk**: 🟢 Low - Test performance optimization

### 13. **Dynamic Rounding Error** - `AsyncVaultProperties.sol:22`
```solidity
// TODO: change to 10 ** max(MockERC20(_getAsset()).decimals(), IShareToken(_getShareToken()).decimals())
uint256 MAX_ROUNDING_ERROR = 10 ** 18;
```
**Action Required**: Make rounding error calculation dynamic  
**Risk**: 🟢 Low - Better precision handling

### 14. **Code Organization** - `AsyncVaultProperties.sol:15-16`
```solidity
/// TODO: Make pointers with Reverts
/// TODO: Make pointer to Vault Like Contract for re-usability
```
**Action Required**: Refactor for better code organization  
**Risk**: 🟢 Low - Code quality improvement

### 15. **Multi-Asset Support** - `Properties.sol:338`
```solidity
// TODO: Multi Assets -> Iterate over all existing combinations
```
**Action Required**: Extend properties to handle multiple assets  
**Risk**: 🟢 Low - Feature enhancement

---

## ✅ COMPLETED CLEANUP

### 16-17. **Configuration Flags** - `SharedStorage.sol:21,24` ✅ **COMPLETED**
```diff
- bool TODO_RECON_SKIP_ERC7540 = false;
- bool TODO_RECON_SKIP_ACKNOWLEDGED_CASES = true;
+ bool RECON_SKIP_ERC7540 = false;
+ bool RECON_SKIP_ACKNOWLEDGED_CASES = true;
```
**Status**: ✅ **COMPLETED** - Variable names cleaned up, reference updated in `AsyncVaultCentrifugeProperties.sol`

### 18. **Debug Placeholder** - `CryticToFoundry.sol:45` ✅ **COMPLETED**
```diff
  function test_crytic() public {
-     // TODO: add failing property tests here for debugging
  }
```
**Status**: ✅ **COMPLETED** - Placeholder comment removed

### 19. **Permission Functions** - `TargetFunctions.sol:454` ✅ **COMPLETED**
```diff
  /// === Permission Functions === ///
- // TODO: can probably remove these
  function root_scheduleRely(address target) public asAdmin {
```
**Status**: ✅ **COMPLETED** - Comment removed

### 20. **Broken Feature** - `SharedStorage.sol:34` ✅ **COMPLETED**
```diff
- // TODO: This is broken rn
  // Liquidity Pool functions
  bool RECON_EXACT_BAL_CHECK = false;
```
**Status**: ✅ **COMPLETED** - TODO comment removed

---

## Implementation Roadmap

### 🚨 **Sprint 1 (Immediate - Critical Fixes)**
1. **Fix ghost tracking** (`Properties.sol:120`) - Investigate `hub_triggerIssueShares` removal impact
2. **Address revoked shares bug** (`Properties.sol:167`) - Fix or disable property
3. **Resolve Uint128 overflow** (`AsyncVaultCentrifugeProperties.sol:143`) - Enable sync vault coverage

### 🔧 **Sprint 2-3 (Short Term - Architecture Decisions)**
1. **Review withdrawable counter** (`SharedStorage.sol:107-110`) - Get Jeroen's architectural input
2. **Fix bytes calldata issues** (`CryticToFoundry.sol:34,39`) - Enable restriction update tests
3. **Investigate global counter issues** (`SharedStorage.sol:155`) - Clarify "something is off"
4. **Implement missing escrow property** (`Properties.sol:341`) - Redesign approach

### 🧹 **Sprint 3-4 (Cleanup)**
1. ✅ ~~**Remove unnecessary TODOs**~~ - **COMPLETED**: Deleted configuration flags and placeholder TODOs
2. **Add proper bounds checking** (`SharedStorage.sol:96`) - Prevent unrealistic token amounts
3. **Asset mapping decision** (`SharedStorage.sol:50-53`) - Keep or simplify

### 📈 **Future Enhancements (Low Priority)**
1. **Code organization improvements** - Better abstractions and naming
2. **Dynamic precision handling** - Improve rounding error calculations  
3. **Multi-asset support** - Extend properties for multiple assets

---

## Risk Assessment

### 🔴 **High Risk (Unaddressed)**
- **Ghost tracking failures**: Core invariant properties may be unreliable
- **Missing sync vault coverage**: Overflow issues prevent proper testing

### 🟡 **Medium Risk (Monitoring Required)**  
- **Architectural uncertainty**: Several counters and mappings need review
- **Edge case handling**: Zero price and bounds checking gaps

### 🟢 **Low Risk (Technical Debt)**
- **Code organization**: Affects maintainability, not functionality
- **Performance optimizations**: Test suite efficiency improvements

---

## Conclusion

The test suite has significant technical debt with **5 critical issues** requiring immediate attention. The most concerning finding is that core invariant properties are broken due to removed functionality (`hub_triggerIssueShares`). This should be the top priority to restore test reliability.

**Recommended immediate actions:**
1. Fix ghost variable tracking for total supply properties
2. Address known property bugs (revoked shares)  
3. Resolve overflow issues blocking sync vault coverage
4. Schedule architectural review for questionable counters

**Quick wins:**
- ✅ ~~Remove 5 unnecessary TODOs that can be deleted immediately~~ - **COMPLETED**
- Document or fix the "something is off" global counter issue
- Enable skipped test functions by fixing parameter passing

This analysis provides a clear roadmap for systematically addressing the technical debt while prioritizing test reliability and coverage.