#!/usr/bin/env python3
"""
Ward/File Relationship Coverage Checker for Centrifuge V3

This script automatically verifies that:
1. Every file("x", address) call has a corresponding rely() in deployment scripts
2. Every ward relationship in deployment has a corresponding test assertion
3. No orphaned ward grants exist (wards without file() calls)

Usage:
    python script/check_ward_coverage.py

Exit codes:
    0 - All checks pass
    1 - Missing ward grants or test coverage
"""

import re
import sys
from pathlib import Path
from typing import Dict, Set, Tuple, List
from dataclasses import dataclass, field
from collections import defaultdict

def normalize_name(name: str) -> str:
    """
    Normalize variable names for comparison by removing underscores and converting to lowercase.
    This handles both camelCase (adminSafe) and UPPER_SNAKE_CASE (ADMIN_SAFE) conventions.

    Examples:
        adminSafe -> adminsafe
        ADMIN_SAFE -> adminsafe
        admin_safe -> adminsafe
    """
    return name.replace('_', '').lower()

@dataclass
class FileCall:
    """Represents a file() function call"""
    contract: str
    param_name: str
    target_contract: str  # The type/contract being filed
    location: str

@dataclass
class WardGrant:
    """Represents a rely() call granting ward permissions"""
    target: str  # Contract receiving the ward
    granter: str  # Contract being granted permissions
    location: str

@dataclass
class TestAssertion:
    """Represents a ward test assertion"""
    target: str
    expected_ward: str
    location: str

@dataclass
class FileParameter:
    """Represents a possible file() parameter"""
    contract: str
    param_name: str
    var_name: str  # Variable name in the contract (e.g., "requestManager")
    target_type: str
    location: str

@dataclass
class FileInitialization:
    """Represents a file() call in deployment scripts"""
    contract: str
    param_name: str
    value: str  # The actual concrete contract being passed (e.g., "messageProcessor")
    location: str

@dataclass
class AnalysisResult:
    """Results of the ward coverage analysis"""
    file_calls: List[FileCall] = field(default_factory=list)
    ward_grants: List[WardGrant] = field(default_factory=list)
    test_assertions: List[TestAssertion] = field(default_factory=list)
    file_parameters: List[FileParameter] = field(default_factory=list)
    file_initializations: List[FileInitialization] = field(default_factory=list)
    missing_wards: List[Tuple[str, str, str]] = field(default_factory=list)  # (target, granter, reason)
    missing_tests: List[Tuple[str, str, str]] = field(default_factory=list)  # (target, granter, location)
    orphaned_wards: List[Tuple[str, str, str]] = field(default_factory=list)  # (target, granter, location)
    uninitialized_parameters: List[Tuple[str, str, str, str]] = field(default_factory=list)  # (contract, param_name, target_type, location)


class WardCoverageChecker:
    """Analyzes ward/file relationships and test coverage"""

    def __init__(self, repo_root: Path):
        self.repo_root = repo_root
        self.src_path = repo_root / "src"
        self.script_path = repo_root / "script"
        self.test_path = repo_root / "test" / "integration"

        # Contracts that should have wards (inheriting Auth and calling auth-protected methods)
        self.expected_ward_sources = {
            # Format: (target_contract, granter_contract): reason
            # Automatically populated from file() calls + auth method calls
        }

    def find_file_calls(self) -> List[FileCall]:
        """Find all file() function calls in src contracts"""
        file_calls = []

        # Pattern: function file(bytes32 what, address data) external auth {
        #   if (what == "contractName") contractName = IContractName(data);
        file_pattern = re.compile(
            r'if\s*\(\s*what\s*==\s*"(\w+)"\s*\)\s*(\w+)\s*=\s*I?(\w+)\s*\(',
            re.MULTILINE
        )

        for sol_file in self.src_path.rglob("*.sol"):
            content = sol_file.read_text()

            # Skip interfaces
            if "interface " in content and "contract " not in content:
                continue

            # Extract contract name (must be at start of line to avoid matching comments)
            contract_match = re.search(r'^\s*(?:abstract\s+)?contract\s+(\w+)', content, re.MULTILINE)
            if not contract_match:
                continue
            contract_name = contract_match.group(1)

            # Find file() function
            file_func_match = re.search(
                r'function\s+file\s*\([^)]*\)\s+external\s+auth\s*\{([^}]*)\}',
                content,
                re.DOTALL
            )

            if file_func_match:
                file_body = file_func_match.group(1)

                for match in file_pattern.finditer(file_body):
                    param_name = match.group(1)
                    var_name = match.group(2)
                    target_type = match.group(3)

                    file_calls.append(FileCall(
                        contract=contract_name,
                        param_name=param_name,
                        target_contract=target_type,
                        location=f"{sol_file.relative_to(self.repo_root)}"
                    ))

        return file_calls

    def find_ward_grants(self) -> List[WardGrant]:
        """Find all rely() calls in deployment scripts"""
        ward_grants = []

        # Pattern: report.targetContract.rely(address(report.granterContract));
        rely_pattern = re.compile(
            r'(?:report\.)?(?:core\.)?(\w+)\.rely\s*\(\s*address\s*\(\s*(?:report\.)?(?:core\.)?(\w+)\s*\)\s*\)',
            re.MULTILINE
        )

        for script_file in self.script_path.rglob("*.sol"):
            if "Deployer" not in script_file.name:
                continue

            content = script_file.read_text()

            for match in rely_pattern.finditer(content):
                target = match.group(1)
                granter = match.group(2)

                # Skip self-relies and root relies (those are always expected)
                if granter == "this" or target == granter:
                    continue

                ward_grants.append(WardGrant(
                    target=target,
                    granter=granter,
                    location=f"{script_file.relative_to(self.repo_root)}:{content[:match.start()].count(chr(10)) + 1}"
                ))

        return ward_grants

    def find_test_assertions(self) -> List[TestAssertion]:
        """Find all ward test assertions in Deployer.t.sol"""
        test_assertions = []

        # Pattern: assertEq(contractName.wards(address(otherContract)), 1);
        assert_pattern = re.compile(
            r'assertEq\s*\(\s*(\w+)\.wards\s*\(\s*address\s*\(\s*(\w+)\s*\)\s*\)\s*,\s*1\s*\)',
            re.MULTILINE
        )

        deployer_test = self.test_path / "Deployer.t.sol"
        if deployer_test.exists():
            content = deployer_test.read_text()

            for match in assert_pattern.finditer(content):
                target = match.group(1)
                expected_ward = match.group(2)

                test_assertions.append(TestAssertion(
                    target=target,
                    expected_ward=expected_ward,
                    location=f"{deployer_test.relative_to(self.repo_root)}:{content[:match.start()].count(chr(10)) + 1}"
                ))

        return test_assertions

    def find_all_file_parameters(self) -> List[FileParameter]:
        """Find ALL possible file() parameters defined in contracts"""
        file_parameters = []

        # Pattern: if (what == "paramName") varName = IContractType(data);
        # Updated to handle optional braces and various whitespace
        file_pattern = re.compile(
            r'(?:else\s+)?if\s*\(\s*what\s*==\s*"(\w+)"\s*\)(?:\s*\{)?\s*(?:_)?(\w+)\s*=\s*I?(\w+)\s*\(',
            re.MULTILINE
        )

        for sol_file in self.src_path.rglob("*.sol"):
            content = sol_file.read_text()

            # Skip interfaces
            if "interface " in content and "contract " not in content:
                continue

            # Extract contract name - match actual contract/abstract contract declarations
            contract_match = re.search(r'(?:abstract\s+)?contract\s+(\w+)(?:\s+is\s+|\s*\{)', content)
            if not contract_match:
                continue
            contract_name = contract_match.group(1)

            # Find file() function - updated regex to handle multiline and various formats
            file_func_match = re.search(
                r'function\s+file\s*\([^)]*\)\s+external\s+auth\s*\{(.*?)(?:^\s*\})',
                content,
                re.DOTALL | re.MULTILINE
            )

            if file_func_match:
                file_body = file_func_match.group(1)

                for match in file_pattern.finditer(file_body):
                    param_name = match.group(1)
                    var_name = match.group(2)
                    target_type = match.group(3)

                    file_parameters.append(FileParameter(
                        contract=contract_name,
                        param_name=param_name,
                        var_name=var_name,
                        target_type=target_type,
                        location=f"{sol_file.relative_to(self.repo_root)}"
                    ))

        return file_parameters

    def find_file_initializations(self) -> List[FileInitialization]:
        """Find all .file() calls in deployment scripts and extract concrete implementation names"""
        file_inits = []

        # Patterns:
        # 1. report.contractName.file("paramName", address(report.value));
        # 2. report.core.contractName.file("paramName", address(report.core.value));
        # 3. report.contractName.file(bytes32("paramName"), address(value));
        file_init_pattern = re.compile(
            r'(?:report\.)?(?:core\.)?(\w+)\.file\s*\(\s*(?:bytes32\s*\(\s*)?"(\w+)"\s*(?:\))?\s*,\s*address\s*\(\s*(?:report\.)?(?:core\.)?(\w+)\s*\)',
            re.MULTILINE
        )

        deployer_scripts = [
            self.script_path / "CoreDeployer.s.sol",
            self.script_path / "FullDeployer.s.sol",
            self.script_path / "LaunchDeployer.s.sol",
        ]

        for script_file in deployer_scripts:
            if not script_file.exists():
                continue

            content = script_file.read_text()

            for match in file_init_pattern.finditer(content):
                contract = match.group(1)
                param_name = match.group(2)
                value = match.group(3)  # The concrete contract being passed

                file_inits.append(FileInitialization(
                    contract=contract,
                    param_name=param_name,
                    value=value,
                    location=f"{script_file.relative_to(self.repo_root)}:{content[:match.start()].count(chr(10)) + 1}"
                ))

        return file_inits

    def find_constructor_initializations(self) -> Dict[str, Set[str]]:
        """Find variables initialized in constructors"""
        constructor_inits = defaultdict(set)

        for sol_file in self.src_path.rglob("*.sol"):
            content = sol_file.read_text()

            # Skip interfaces
            if "interface " in content and "contract " not in content:
                continue

            # Extract contract name
            contract_match = re.search(r'(?:abstract\s+)?contract\s+(\w+)(?:\s+is\s+|\s*\{)', content)
            if not contract_match:
                continue
            contract_name = contract_match.group(1)

            # Find constructor - match constructor body
            constructor_match = re.search(
                r'constructor\s*\([^)]*\)(?:[^{]*)\{(.*?)(?:^\s*\})',
                content,
                re.DOTALL | re.MULTILINE
            )

            if constructor_match:
                constructor_body = constructor_match.group(1)

                # Find assignments: varName = ...; or _varName = ...;
                # Pattern matches: hub = hub_; or _requestManager = requestManager_;
                assignment_pattern = re.compile(
                    r'(?:_)?(\w+)\s*=\s*\w+_?\s*;',
                    re.MULTILINE
                )

                for match in assignment_pattern.finditer(constructor_body):
                    var_name = match.group(1)
                    constructor_inits[contract_name].add(var_name)

        return constructor_inits

    def normalize_contract_name(self, name: str) -> str:
        """
        Normalize contract name for consistent matching.
        Examples:
            IBalanceSheet -> balancesheet
            BalanceSheet -> balancesheet
            Gateway -> gateway
        """
        # Strip leading "I" if present (interface prefix)
        if name.startswith("I") and len(name) > 1 and name[1].isupper():
            name = name[1:]

        return name.lower()

    def find_all_auth_methods(self) -> Dict[str, Set[str]]:
        """
        Automatically detect all auth-protected methods from source files.
        Returns: {contract_type: {method_names}}

        This eliminates the need for manual maintenance of auth method patterns.
        Scans all contracts/interfaces for functions with auth or authOrManager modifiers.
        """
        auth_methods = defaultdict(set)

        for sol_file in self.src_path.rglob("*.sol"):
            content = sol_file.read_text()

            # Extract contract/interface name
            # Matches: contract Foo, abstract contract Foo, interface IFoo
            contract_match = re.search(
                r'(?:interface|abstract\s+contract|contract)\s+(I?)(\w+)',
                content
            )
            if not contract_match:
                continue

            type_name = contract_match.group(2)  # e.g., "BalanceSheet"

            # Normalize: IBalanceSheet -> balancesheet, BalanceSheet -> balancesheet
            normalized_name = self.normalize_contract_name(type_name)

            # Find all functions with auth/authOrManager modifiers
            # Pattern matches:
            #   function send() external auth {
            #   function transferSharesFrom() external authOrManager(poolId) {
            #   function foo() public auth;  (interface)
            auth_func_pattern = re.compile(
                r'function\s+(\w+)\s*\([^)]*\)[^{;]*\b(auth(?:OrManager)?(?:\s*\([^)]*\))?)\s*(?:\{|;)',
                re.MULTILINE | re.DOTALL
            )

            for match in auth_func_pattern.finditer(content):
                method_name = match.group(1)

                # Exclude file() itself (it always has auth but that's not what we're looking for)
                if method_name == "file":
                    continue

                auth_methods[normalized_name].add(method_name)

        return auth_methods

    def analyze_auth_method_calls(self, file_calls: List[FileCall], file_initializations: List[FileInitialization]) -> Dict[Tuple[str, str], str]:
        """
        Analyze which contracts call auth-protected methods on their filed dependencies.
        Returns: {(target, caller): reason}

        Now uses AUTOMATIC detection instead of hardcoded patterns!
        Uses concrete implementation names from deployment scripts to avoid interface/implementation mismatches.
        """
        expected_wards = {}

        # Map of contract -> filed dependencies (from source code)
        filed_deps: Dict[str, Dict[str, str]] = defaultdict(dict)
        for fc in file_calls:
            filed_deps[fc.contract][fc.param_name] = fc.target_contract

        # Map of (contract, param_name) -> concrete implementation (from deployment scripts)
        # Example: (Gateway, processor) -> messageProcessor
        concrete_implementations: Dict[Tuple[str, str], str] = {}
        for fi in file_initializations:
            concrete_implementations[(fi.contract.lower(), fi.param_name.lower())] = fi.value

        # AUTOMATICALLY detect all auth-protected methods (no more manual patterns!)
        auth_method_patterns = self.find_all_auth_methods()

        # Scan source files for auth method calls
        for sol_file in self.src_path.rglob("*.sol"):
            content = sol_file.read_text()

            # Extract contract name (must be at start of line to avoid matching comments)
            contract_match = re.search(r'^\s*(?:abstract\s+)?contract\s+(\w+)', content, re.MULTILINE)
            if not contract_match:
                continue
            contract_name = contract_match.group(1)

            # Check if this contract has filed dependencies
            if contract_name not in filed_deps:
                continue

            # For each filed dependency, check if we call its auth-protected methods
            for dep_var, dep_type in filed_deps[contract_name].items():
                # Normalize the dependency type name (IBalanceSheet -> balancesheet)
                normalized_type = self.normalize_contract_name(dep_type)

                if normalized_type not in auth_method_patterns:
                    continue

                # Check if we call any auth methods on this dependency
                for auth_method in auth_method_patterns[normalized_type]:
                    pattern = rf'{dep_var}\.{auth_method}\s*\('
                    if re.search(pattern, content):
                        # IMPORTANT: Use concrete implementation from deployment if available
                        # This prevents false positives from interface vs implementation name mismatches
                        lookup_key = (contract_name.lower(), dep_var.lower())
                        if lookup_key in concrete_implementations:
                            # Use concrete implementation name (e.g., messageProcessor)
                            target_contract = concrete_implementations[lookup_key]
                            # Capitalize first letter to match deployment convention
                            target_contract = target_contract[0].upper() + target_contract[1:]
                        else:
                            # Fall back to interface type from source code
                            target_contract = dep_type

                        reason = f"{contract_name}.file('{dep_var}', {dep_type}) + calls {dep_var}.{auth_method}()"
                        expected_wards[(target_contract, contract_name)] = reason
                        break

        return expected_wards

    def check_coverage(self) -> AnalysisResult:
        """Perform comprehensive ward coverage analysis"""
        result = AnalysisResult()

        # Step 1: Find all file() calls and initializations
        result.file_calls = self.find_file_calls()
        result.file_parameters = self.find_all_file_parameters()
        result.file_initializations = self.find_file_initializations()

        # Step 2: Analyze which file() calls require ward grants
        # Pass file_initializations to resolve concrete implementations
        expected_wards = self.analyze_auth_method_calls(result.file_calls, result.file_initializations)

        # Step 3: Find all ward grants in deployment scripts
        result.ward_grants = self.find_ward_grants()
        ward_grant_set = {(wg.target, wg.granter) for wg in result.ward_grants}

        # Step 4: Find all test assertions
        result.test_assertions = self.find_test_assertions()
        test_assertion_set = {(ta.target, ta.expected_ward) for ta in result.test_assertions}

        # Step 5: Check for uninitialized parameters
        # Build a set of initialized (contract, param_name) pairs from deployment scripts
        initialized_set = {
            (fi.contract.lower(), fi.param_name.lower())
            for fi in result.file_initializations
        }

        # Find constructor initializations
        constructor_inits = self.find_constructor_initializations()

        for fp in result.file_parameters:
            # Check if this parameter is initialized in deployment script
            if (fp.contract.lower(), fp.param_name.lower()) in initialized_set:
                continue

            # Check if this parameter's variable is set in constructor
            if fp.contract in constructor_inits:
                # Check if the variable is initialized in the constructor
                # The var_name from file() (e.g., "requestManager") should match constructor assignment
                if fp.var_name in constructor_inits[fp.contract]:
                    continue
                # Also check with underscore prefix (common pattern: _requestManager)
                if f"_{fp.var_name}" in constructor_inits[fp.contract]:
                    continue

            # Not initialized in deployment or constructor - flag it!
            result.uninitialized_parameters.append((
                fp.contract,
                fp.param_name,
                fp.target_type,
                fp.location
            ))

        # Step 6: Check for missing ward grants
        for (target, granter), reason in expected_wards.items():
            # Normalize names (handle case differences and snake_case vs camelCase)
            found = any(
                normalize_name(wg.target) == normalize_name(target) and
                normalize_name(wg.granter) == normalize_name(granter)
                for wg in result.ward_grants
            )

            if not found:
                result.missing_wards.append((target, granter, reason))

        # Step 7: Check for missing test assertions
        for wg in result.ward_grants:
            # Skip root and deployer wards (tested elsewhere)
            if normalize_name(wg.granter) in ["root", "deployer", "this"]:
                continue

            # Check if this ward grant has a corresponding test
            # Use normalize_name to handle both camelCase and UPPER_SNAKE_CASE
            found = any(
                normalize_name(ta.target) == normalize_name(wg.target) and
                normalize_name(ta.expected_ward) == normalize_name(wg.granter)
                for ta in result.test_assertions
            )

            if not found:
                result.missing_tests.append((wg.target, wg.granter, wg.location))

        return result

    def print_report(self, result: AnalysisResult):
        """Print a comprehensive analysis report"""
        print("=" * 80)
        print("WARD COVERAGE ANALYSIS REPORT")
        print("=" * 80)
        print()

        # Summary statistics
        print("📊 SUMMARY")
        print("-" * 80)
        print(f"  File() parameters defined:       {len(result.file_parameters)}")
        print(f"  File() initializations found:    {len(result.file_initializations)}")
        print(f"  Ward grants in deployment:       {len(result.ward_grants)}")
        print(f"  Test assertions found:           {len(result.test_assertions)}")
        print()
        print(f"  ❌ Uninitialized parameters:      {len(result.uninitialized_parameters)} (not in deployment OR constructor)")
        print(f"  ❌ Missing ward grants:           {len(result.missing_wards)}")
        print(f"  ❌ Missing test coverage:         {len(result.missing_tests)}")
        print()

        # Uninitialized parameters
        if result.uninitialized_parameters:
            print("❌ UNINITIALIZED FILE() PARAMETERS")
            print("-" * 80)
            print("  The following file() parameters are NOT initialized in deployment OR constructor.")
            print("  These need to be added to deployment scripts for proper system configuration.")
            print()
            for contract, param_name, target_type, location in result.uninitialized_parameters:
                print(f"  📌 {contract}.file(\"{param_name}\", ...)")
                print(f"      Type: {target_type}")
                print(f"      Location: {location}")
                print(f"      Fix: Add to deployment script (CoreDeployer/FullDeployer/LaunchDeployer):")
                print(f"           report.{contract}.file(\"{param_name}\", address(report.{target_type.lower()}));")
                print(f"      Then ensure: {target_type}.wards({contract}) == 1 and add test assertion!")
                print()

        # Missing ward grants
        if result.missing_wards:
            print("❌ MISSING WARD GRANTS")
            print("-" * 80)
            for target, granter, reason in result.missing_wards:
                print(f"  ⚠️  {target}.wards({granter}) = 1")
                print(f"      Reason: {reason}")
                print(f"      Fix: Add to deployment script:")
                print(f"           report.{target}.rely(address(report.{granter}));")
                print()

        # Missing test coverage
        if result.missing_tests:
            print("❌ MISSING TEST COVERAGE")
            print("-" * 80)
            for target, granter, location in result.missing_tests:
                print(f"  ⚠️  assertEq({target}.wards(address({granter})), 1);")
                print(f"      Ward grant at: {location}")
                print(f"      Fix: Add to test/integration/Deployer.t.sol in test{target}() function")
                print()

        # Success message
        if not result.missing_wards and not result.missing_tests and not result.uninitialized_parameters:
            print("✅ ALL CHECKS PASSED")
            print("-" * 80)
            print("  All file() parameters are initialized (deployment or constructor)!")
            print("  All ward/file relationships are properly covered!")
            print("  All ward grants have corresponding test assertions!")
            print()

        print("=" * 80)

        # Fail if any issues found (now including uninitialized params since we filter out constructor-set ones)
        return len(result.missing_wards) == 0 and len(result.missing_tests) == 0 and len(result.uninitialized_parameters) == 0


def main():
    """Main entry point"""
    repo_root = Path(__file__).parent.parent.parent

    print("🔍 Analyzing ward/file relationships and test coverage...")
    print(f"📁 Repository root: {repo_root.resolve()}")
    print(f"📂 Checking directories:")
    print(f"   - src/: {'✓ exists' if (repo_root / 'src').exists() else '✗ NOT FOUND'}")
    print(f"   - script/: {'✓ exists' if (repo_root / 'script').exists() else '✗ NOT FOUND'}")
    print(f"   - test/: {'✓ exists' if (repo_root / 'test').exists() else '✗ NOT FOUND'}")
    print()

    checker = WardCoverageChecker(repo_root)
    result = checker.check_coverage()
    success = checker.print_report(result)

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
