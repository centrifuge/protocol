#!/usr/bin/env python3

import os
import re
import subprocess
from typing import List, Dict, Set, Tuple
import argparse
import sys
from pathlib import Path

# Priority order for imports (relative paths only)
IMPORT_PRIORITY = [
    ".",        # Current directory (highest priority)
    "misc",
    "common", 
    "hub",
    "spoke",
    "vaults",
    "hooks",
    "managers",
    "script",
    "test",
    "mocks",
    "forge-std"
]

def get_all_solidity_files() -> List[str]:
    """Get all Solidity files excluding lib, out, cache, and broadcast directories"""
    result = subprocess.run(
        ["find", ".", "-name", "*.sol", "-type", "f", "-not", "-path", "./lib/*", "-not", "-path", "./out/*", "-not", "-path", "./cache/*", "-not", "-path", "./broadcast/*"],
        capture_output=True,
        text=True
    )
    return result.stdout.strip().split('\n') if result.stdout.strip() else []

def extract_imports(content: str) -> List[str]:
    """Extract all import statements from file content"""
    # Updated pattern to handle multi-line imports
    import_pattern = r'import\s+.*?;'
    imports = re.findall(import_pattern, content, re.MULTILINE | re.DOTALL)
    
    # Clean up whitespace and normalize multi-line imports to single lines
    cleaned_imports = []
    for import_stmt in imports:
        # Remove extra whitespace and newlines, but preserve structure
        cleaned = re.sub(r'\s+', ' ', import_stmt.strip())
        cleaned_imports.append(cleaned)
    
    return cleaned_imports

def parse_import_statement(import_stmt: str) -> Tuple[List[str], str]:
    """Parse an import statement to extract imported symbols and path"""
    # Handle different import formats:
    # import "path";
    # import {Symbol} from "path";
    # import {Symbol1, Symbol2} from "path";

    path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
    if not path_match:
        path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
        if path_match:
            return [], path_match.group(1)  # Direct import without symbols
        return [], ""

    path = path_match.group(1)

    # Extract symbols
    symbols_match = re.search(r'import\s+\{([^}]+)\}', import_stmt)
    if symbols_match:
        symbols_str = symbols_match.group(1)
        # Split by comma and clean up whitespace
        symbols = [s.strip() for s in symbols_str.split(',')]
        # Handle aliases (e.g., "Symbol as Alias")
        clean_symbols = []
        for symbol in symbols:
            if ' as ' in symbol:
                clean_symbols.append(symbol.split(' as ')[1].strip())
            else:
                clean_symbols.append(symbol.strip())
        return clean_symbols, path

    return [], path

def find_unused_imports(file_path: str, content: str) -> List[str]:
    """Find unused imports in a Solidity file"""
    imports = extract_imports(content)
    unused_imports = []

    # Remove import statements from content for analysis
    content_without_imports = content
    for import_stmt in imports:
        content_without_imports = content_without_imports.replace(import_stmt, '')

    for import_stmt in imports:
        symbols, path = parse_import_statement(import_stmt)

        if not symbols:
            # Direct import without symbols - harder to detect usage
            continue

        unused_symbols = []
        for symbol in symbols:
            # Check if symbol is used in the code
            # Look for the symbol as a standalone word (not part of another word)
            pattern = r'\b' + re.escape(symbol) + r'\b'
            if not re.search(pattern, content_without_imports):
                unused_symbols.append(symbol)

        if unused_symbols:
            if len(unused_symbols) == len(symbols):
                # Entire import is unused
                unused_imports.append(import_stmt)
            else:
                # Some symbols are unused
                unused_imports.append(f"Partially unused in '{import_stmt}': {', '.join(unused_symbols)}")

    return unused_imports

def remove_unused_symbols_from_import(import_stmt: str, unused_symbols: List[str]) -> str:
    """Remove unused symbols from an import statement"""
    symbols, path = parse_import_statement(import_stmt)

    if not symbols:
        return import_stmt

    # Remove unused symbols
    used_symbols = [s for s in symbols if s not in unused_symbols]

    if not used_symbols:
        # All symbols are unused, remove entire import
        return ""

    # Reconstruct import statement with only used symbols
    symbols_str = ", ".join(used_symbols)
    return f'import {{{symbols_str}}} from "{path}";'

def fix_unused_imports_in_file(file_path: str) -> Tuple[bool, int]:
    """Remove unused imports from a single file"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        imports = extract_imports(content)
        if not imports:
            return False, 0

        # Remove import statements from content for analysis
        content_without_imports = content
        for import_stmt in imports:
            content_without_imports = content_without_imports.replace(import_stmt, '')

        new_imports = []
        removed_count = 0

        for import_stmt in imports:
            symbols, path = parse_import_statement(import_stmt)

            if not symbols:
                # Direct import without symbols - keep as is
                new_imports.append(import_stmt)
                continue

            unused_symbols = []
            for symbol in symbols:
                # Check if symbol is used in the code
                pattern = r'\b' + re.escape(symbol) + r'\b'
                if not re.search(pattern, content_without_imports):
                    unused_symbols.append(symbol)

            if unused_symbols:
                if len(unused_symbols) == len(symbols):
                    # Entire import is unused, remove it
                    removed_count += 1
                    continue
                else:
                    # Some symbols are unused, remove only unused ones
                    new_import = remove_unused_symbols_from_import(import_stmt, unused_symbols)
                    if new_import:
                        new_imports.append(new_import)
                        removed_count += len(unused_symbols)
            else:
                # No unused symbols, keep import as is
                new_imports.append(import_stmt)

        # Replace old imports with new ones
        new_content = content
        for old_import in imports:
            new_content = new_content.replace(old_import + '\n', '')
            new_content = new_content.replace(old_import, '')

        # Add new imports back
        if new_imports:
            # Find where to insert imports (after pragma/license)
            lines = new_content.split('\n')
            pragma_end_idx = 0

            for i, line in enumerate(lines):
                if line.strip().startswith('pragma ') or line.strip().startswith('// SPDX-License-Identifier'):
                    pragma_end_idx = i + 1
                elif line.strip() == '' and i <= 5:
                    pragma_end_idx = i + 1
                elif line.strip() and not line.strip().startswith('//'):
                    break

            # Organize the cleaned imports
            categorized, other_imports = categorize_imports(new_imports)
            organized_imports_str = organize_imports(categorized, other_imports)

            # Insert organized imports
            new_lines = lines[:pragma_end_idx] + [''] + organized_imports_str.split('\n') + [''] + lines[pragma_end_idx:]

            # Clean up multiple consecutive empty lines
            cleaned_lines = []
            prev_empty = False
            for line in new_lines:
                if line.strip() == '':
                    if not prev_empty:
                        cleaned_lines.append(line)
                    prev_empty = True
                else:
                    cleaned_lines.append(line)
                    prev_empty = False

            new_content = '\n'.join(cleaned_lines)

        # Write back if content changed
        if new_content != content:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return True, removed_count

        return False, 0

    except Exception as e:
        print(f"Error processing {file_path}: {e}")
        return False, 0

def get_import_category(path: str) -> str:
    """Determine the category of an import path"""
    # Handle forge-std first
    if 'forge-std' in path:
        return 'forge-std'
    
    # Handle absolute paths (convert them for categorization)
    if path.startswith('centrifuge-v3/'):
        # Extract the directory from absolute path for categorization
        if path.startswith('centrifuge-v3/src/'):
            dir_part = path.split('/')[2]  # Get 'misc', 'common', etc.
            if dir_part in IMPORT_PRIORITY:
                return dir_part
        elif path.startswith('centrifuge-v3/script'):
            return 'script'
        elif path.startswith('centrifuge-v3/test'):
            return 'test'
    
    # Handle relative paths by checking directory components
    if path.startswith('./') or path.startswith('../'):
        # Check if it's a current directory import after cleaning
        cleaned_path = path
        while cleaned_path.startswith('../') or cleaned_path.startswith('./'):
            if cleaned_path.startswith('../'):
                cleaned_path = cleaned_path[3:]  # Remove '../'
            elif cleaned_path.startswith('./'):
                cleaned_path = cleaned_path[2:]  # Remove './'
        
        # If path originally started with ./ then it's a current directory import
        if path.startswith('./'):
            return '.'
        
        # Split the cleaned path and find the most specific relevant directory
        path_parts = cleaned_path.split('/')
        
        # Find all matching parts and return the one with highest priority (lowest index)
        matches = []
        for part in path_parts:
            if part in IMPORT_PRIORITY:
                matches.append(part)
        
        if matches:
            # Return the match with highest priority (lowest index in IMPORT_PRIORITY)
            return min(matches, key=lambda x: IMPORT_PRIORITY.index(x))
            
        return None
    
    # Handle relative paths without ./ prefix (also current directory or subdirectories)
    elif not path.startswith('/') and not path.startswith('centrifuge-v3/') and not path.startswith('src/'):
        # If it's just a filename or starts with a subdirectory name, treat as current directory
        path_parts = path.split('/')
        
        # Check if first part is a known subdirectory or if it's just a file
        if len(path_parts) == 1 or path_parts[0] in ['interfaces', 'types', 'libraries', 'factories', 'mocks', 'utils']:
            return '.'
        
        # Otherwise check for known directories - find the one with highest priority
        matches = []
        for part in path_parts:
            if part in IMPORT_PRIORITY:
                matches.append(part)
        
        if matches:
            # Return the match with highest priority (lowest index in IMPORT_PRIORITY)
            return min(matches, key=lambda x: IMPORT_PRIORITY.index(x))
    
    return None

def get_import_subgroup(path: str) -> str:
    """Determine the subgroup for an import path within its category"""
    if '/src/' in path:
        return 'src'
    elif '/test/' in path:
        return 'test'  
    elif '/script/' in path:
        return 'script'
    else:
        return '../'  # Default for relative paths without specific base directory

def categorize_imports(imports: List[str]) -> Tuple[Dict[str, Dict[str, List[str]]], List[str]]:
    """Categorize imports by their path prefix and subgroup"""
    # Create nested dictionary: {category: {subgroup: [imports]}}
    categorized = {priority: {'../': [], 'src': [], 'test': [], 'script': []} for priority in IMPORT_PRIORITY}
    other_imports = []

    for import_stmt in imports:
        # Extract the path from import statement
        path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
        if not path_match:
            # Handle imports without 'from' keyword
            path_match = re.search(r'import\s+"([^"]+)"', import_stmt)

        if path_match:
            path = path_match.group(1)
            category = get_import_category(path)
            
            if category and category in categorized:
                subgroup = get_import_subgroup(path)
                categorized[category][subgroup].append(import_stmt)
            else:
                other_imports.append(import_stmt)
        else:
            other_imports.append(import_stmt)

    return categorized, other_imports

def organize_imports(categorized: Dict[str, Dict[str, List[str]]], other_imports: List[str]) -> str:
    """Organize imports according to priority with subgroups, separated by empty lines"""
    organized_imports = []
    subgroup_order = ['../', 'src', 'test', 'script']

    for priority in IMPORT_PRIORITY:
        category_has_imports = False
        
        for subgroup in subgroup_order:
            if categorized[priority][subgroup]:
                # Remove duplicates and sort by length (ascending), then alphabetically
                unique_imports = list(set(categorized[priority][subgroup]))
                sorted_imports = sorted(unique_imports, key=lambda x: (len(x), x))
                organized_imports.extend(sorted_imports)
                organized_imports.append("")  # Empty line after each subgroup
                category_has_imports = True

    # Add other imports at the end
    if other_imports:
        unique_other = list(set(other_imports))
        sorted_other = sorted(unique_other, key=lambda x: (len(x), x))
        organized_imports.extend(sorted_other)
        organized_imports.append("")

    # Remove trailing empty lines
    while organized_imports and organized_imports[-1] == "":
        organized_imports.pop()

    return '\n'.join(organized_imports)

def fix_file_imports(file_path: str, convert_to_relative: bool = True) -> bool:
    """Fix imports in a single file"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Find the pragma and license lines
        lines = content.split('\n')
        pragma_end_idx = 0

        for i, line in enumerate(lines):
            if line.strip().startswith('pragma ') or line.strip().startswith('// SPDX-License-Identifier'):
                pragma_end_idx = i + 1
            elif line.strip() == '' and i <= 5:  # Allow empty lines after pragma
                pragma_end_idx = i + 1
            elif line.strip().startswith('import '):
                break
            elif line.strip() and not line.strip().startswith('//'):
                break

        # Extract imports
        imports = extract_imports(content)
        if not imports:
            return False  # No imports to fix

        # Remove all imports using regex pattern (handles both single-line and multi-line)
        import_removal_pattern = r'import\s+.*?;'
        content_without_imports = re.sub(import_removal_pattern, '', content, flags=re.MULTILINE | re.DOTALL)
        
        # Convert to relative imports if requested
        if convert_to_relative:
            relative_imports = []
            for import_stmt in imports:
                relative_import = convert_import_to_relative(import_stmt, file_path)
                relative_imports.append(relative_import)
            imports = relative_imports

        # Categorize and organize imports
        categorized, other_imports = categorize_imports(imports)
        organized_imports_str = organize_imports(categorized, other_imports)

        if not organized_imports_str:
            return False

        # Reconstruct the file
        lines = content_without_imports.split('\n')

        # Find where to insert imports (after pragma/license)
        insert_idx = pragma_end_idx

        # Remove empty lines after pragma to avoid too many empty lines
        while insert_idx < len(lines) and lines[insert_idx].strip() == '':
            insert_idx += 1

        # Insert organized imports
        new_lines = lines[:pragma_end_idx] + [''] + organized_imports_str.split('\n') + [''] + lines[insert_idx:]

        # Clean up multiple consecutive empty lines
        cleaned_lines = []
        prev_empty = False
        for line in new_lines:
            if line.strip() == '':
                if not prev_empty:
                    cleaned_lines.append(line)
                prev_empty = True
            else:
                cleaned_lines.append(line)
                prev_empty = False

        new_content = '\n'.join(cleaned_lines)

        # Only write if content changed
        if new_content != content:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return True

        return False

    except Exception as e:
        print(f"Error processing {file_path}: {e}")
        return False

def check_unused_imports():
    """Check for unused imports in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Checking {len(files)} Solidity files for unused imports...\n")

    total_unused = 0
    files_with_unused = 0

    for file_path in files:
        if file_path.strip():
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()

                unused = find_unused_imports(file_path, content)
                if unused:
                    files_with_unused += 1
                    total_unused += len(unused)
                    print(f"\n📁 {file_path}")
                    for unused_import in unused:
                        print(f"  ❌ {unused_import}")
            except Exception as e:
                print(f"Error checking {file_path}: {e}")

    print(f"\n📊 Summary:")
    print(f"   Files checked: {len(files)}")
    print(f"   Files with unused imports: {files_with_unused}")
    print(f"   Total unused imports: {total_unused}")

    if total_unused > 0:
        sys.exit(1)

def fix_all_unused_imports():
    """Remove unused imports from all Solidity files"""
    files = get_all_solidity_files()
    print(f"Fixing unused imports in {len(files)} Solidity files...\n")

    total_files_fixed = 0
    total_imports_removed = 0

    for file_path in files:
        if file_path.strip():
            print(f"Processing: {file_path}")
            fixed, removed_count = fix_unused_imports_in_file(file_path)
            if fixed:
                total_files_fixed += 1
                total_imports_removed += removed_count
                print(f"  ✅ Removed {removed_count} unused import(s)")
            else:
                print(f"  ℹ️  No unused imports found")

    print(f"\n📊 Summary:")
    print(f"   Files processed: {len(files)}")
    print(f"   Files fixed: {total_files_fixed}")
    print(f"   Total unused imports removed: {total_imports_removed}")

def check_import_order_in_file(file_path: str) -> Tuple[bool, List[str]]:
    """Check if imports in a file are properly ordered"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()

        imports = extract_imports(content)
        if not imports:
            return True, []  # No imports, so order is correct

        # Get current import order
        current_imports = imports

        # Get expected import order
        categorized, other_imports = categorize_imports(imports)
        expected_imports_str = organize_imports(categorized, other_imports)
        expected_imports = [line for line in expected_imports_str.split('\n') if line.strip()]

        # Compare current vs expected order
        issues = []

        if len(current_imports) != len(expected_imports):
            issues.append("Number of imports doesn't match expected")
            return False, issues

        for i, (current, expected) in enumerate(zip(current_imports, expected_imports)):
            if current.strip() != expected.strip():
                issues.append(f"Line {i+1}: Expected '{expected}' but found '{current}'")

        return len(issues) == 0, issues

    except Exception as e:
        return False, [f"Error processing file: {e}"]

def check_import_order():
    """Check import order in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Checking import order in {len(files)} Solidity files...\n")

    total_files_with_issues = 0
    total_issues = 0

    for file_path in files:
        if file_path.strip():
            is_ordered, issues = check_import_order_in_file(file_path)
            if not is_ordered:
                total_files_with_issues += 1
                total_issues += len(issues)
                print(f"\n📁 {file_path}")
                for issue in issues:
                    print(f"  ❌ {issue}")

    print(f"\n📊 Summary:")
    print(f"   Files checked: {len(files)}")
    print(f"   Files with import order issues: {total_files_with_issues}")
    print(f"   Total import order issues: {total_issues}")

    if total_files_with_issues > 0:
        print(f"\n💡 Run with --organize to fix these issues")
        return False  # Return False to indicate issues found (for CI)

    return True  # Return True if all files are properly ordered

def organize_all_imports(convert_to_relative: bool = True):
    """Organize imports in all Solidity files and optionally convert to relative paths"""
    files = get_all_solidity_files()
    action_description = "organize and convert to relative imports" if convert_to_relative else "organize imports"
    print(f"Found {len(files)} Solidity files to {action_description}")

    fixed_count = 0
    converted_count = 0
    other_import_paths = set()

    for file_path in files:
        if file_path.strip():  # Skip empty strings
            print(f"Processing: {file_path}")

            # Check for other import paths and count absolute imports before processing
            absolute_imports_before = 0
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                imports = extract_imports(content)
                for import_stmt in imports:
                    path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
                    if not path_match:
                        path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
                    if path_match:
                        path = path_match.group(1)
                        if path.startswith('centrifuge-v3/') or path.startswith('src/'):
                            absolute_imports_before += 1
                        if path.startswith('centrifuge-v3/src/'):
                            dir_part = path.split('/')[2] if len(path.split('/')) > 2 else ''
                            if dir_part not in IMPORT_PRIORITY:
                                other_import_paths.add(dir_part)
            except:
                pass

            if fix_file_imports(file_path, convert_to_relative):
                fixed_count += 1
                if convert_to_relative and absolute_imports_before > 0:
                    converted_count += 1

    if convert_to_relative:
        print(f"\nOrganized imports in {fixed_count} files")
        print(f"Converted absolute imports to relative in {converted_count} files")
    else:
        print(f"\nOrganized imports in {fixed_count} files")

    if other_import_paths:
        print(f"\nOther import paths found beyond the specified ones:")
        for path in sorted(other_import_paths):
            print(f"  - centrifuge-v3/src/{path}")

def convert_to_relative_path(current_file: str, import_path: str) -> str:
    """Convert an absolute import path to a relative path"""
    # Handle different absolute path formats
    if import_path.startswith('centrifuge-v3/'):
        # Remove the centrifuge-v3/ prefix to get the actual path
        actual_path = import_path[len('centrifuge-v3/'):]
    elif import_path.startswith('src/'):
        # Already starts with src/, use as is
        actual_path = import_path
    elif import_path.startswith('script/') or import_path.startswith('test/'):
        # Handle script/ and test/ absolute paths
        actual_path = import_path
    else:
        # Not an absolute path we recognize, return as is
        return import_path
    
    # Convert current file path to use forward slashes and remove leading ./
    current_file_clean = current_file.replace('\\', '/').lstrip('./')
    
    # Get the directory of the current file and target file
    current_dir = os.path.dirname(current_file_clean)
    target_dir = os.path.dirname(actual_path)
    target_filename = os.path.basename(actual_path)
    
    # Determine the base directories for current file and target
    current_in_src = current_file_clean.startswith('src/')
    current_in_script = current_file_clean.startswith('script/')
    current_in_test = current_file_clean.startswith('test/')
    
    target_in_src = actual_path.startswith('src/')
    target_in_script = actual_path.startswith('script/')
    target_in_test = actual_path.startswith('test/')
    
    # If both are in the same base directory (src/, script/, or test/), we can work with relative paths
    if (current_in_src and target_in_src) or (current_in_script and target_in_script) or (current_in_test and target_in_test):
        # Remove base directory prefix from both paths for cleaner calculation
        if current_dir == 'src':
            current_dir_rel = ''
        elif current_dir.startswith('src/'):
            current_dir_rel = current_dir[4:]  # Remove 'src/'
        elif current_dir == 'script':
            current_dir_rel = ''
        elif current_dir.startswith('script/'):
            current_dir_rel = current_dir[7:]  # Remove 'script/'
        elif current_dir == 'test':
            current_dir_rel = ''
        elif current_dir.startswith('test/'):
            current_dir_rel = current_dir[5:]  # Remove 'test/'
        else:
            current_dir_rel = current_dir
            
        if target_dir == 'src':
            target_dir_rel = ''
        elif target_dir.startswith('src/'):
            target_dir_rel = target_dir[4:]  # Remove 'src/'
        elif target_dir == 'script':
            target_dir_rel = ''
        elif target_dir.startswith('script/'):
            target_dir_rel = target_dir[7:]  # Remove 'script/'
        elif target_dir == 'test':
            target_dir_rel = ''
        elif target_dir.startswith('test/'):
            target_dir_rel = target_dir[5:]  # Remove 'test/'
        else:
            target_dir_rel = target_dir
        
        # Check if they're in the same directory
        if current_dir_rel == target_dir_rel:
            return f"./{target_filename}"
        
        # Check if target is in a subdirectory of current
        if current_dir_rel == "" and target_dir_rel != "":
            # Current file is at base directory root, target is in subdirectory
            return f"./{target_dir_rel}/{target_filename}"
        elif target_dir_rel.startswith(current_dir_rel + '/'):
            subdir = target_dir_rel[len(current_dir_rel) + 1:]
            return f"./{subdir}/{target_filename}"
        
        # Check if current is in a subdirectory of target
        if current_dir_rel.startswith(target_dir_rel + '/'):
            levels_up = current_dir_rel[len(target_dir_rel):].count('/')
            return f"{'../' * levels_up}{target_filename}"
        
        # Calculate full relative path within src/
        try:
            relative_path = os.path.relpath(target_dir_rel, current_dir_rel)
            relative_path = relative_path.replace('\\', '/')
            if relative_path == '.':
                return f"./{target_filename}"
            else:
                return f"{relative_path}/{target_filename}"
        except ValueError:
            # Fallback
            return f"./{target_filename}"
    
    # If current file is in different base directory than target, keep full prefix
    elif (not current_in_src and target_in_src) or (not current_in_script and target_in_script) or (not current_in_test and target_in_test):
        try:
            current_path = Path(current_dir)
            target_path = Path(target_dir)
            relative_path = os.path.relpath(target_path, current_path)
            relative_path = relative_path.replace('\\', '/')
            return f"{relative_path}/{target_filename}"
        except ValueError:
            return import_path
    
    # Other cases - fallback to original calculation
    try:
        current_path = Path(current_dir)
        target_path = Path(target_dir)
        relative_path = os.path.relpath(target_path, current_path)
        relative_path = relative_path.replace('\\', '/')
        if relative_path == '.':
            return f"./{target_filename}"
        else:
            return f"{relative_path}/{target_filename}"
    except ValueError:
        return import_path

def convert_relative_to_absolute_path(current_file: str, relative_path: str) -> str:
    """Convert a relative import path to an absolute path"""
    # Skip if already absolute or library import
    if (relative_path.startswith('centrifuge-v3/') or 
        relative_path.startswith('src/') or
        relative_path.startswith('test/') or
        relative_path.startswith('script/') or
        'forge-std' in relative_path or
        relative_path.startswith('createx-forge/') or
        not (relative_path.startswith('./') or relative_path.startswith('../'))):
        return relative_path
    
    # Convert current file path to use forward slashes and remove leading ./
    current_file_clean = current_file.replace('\\', '/').lstrip('./')
    current_dir = os.path.dirname(current_file_clean)
    
    # Resolve the relative path to absolute
    try:
        # Join current directory with relative path and normalize
        absolute_path = os.path.normpath(os.path.join(current_dir, relative_path))
        absolute_path = absolute_path.replace('\\', '/')  # Ensure forward slashes
        return absolute_path
    except Exception:
        # Fallback to original path if resolution fails
        return relative_path

def convert_import_to_absolute(import_stmt: str, current_file: str) -> str:
    """Convert an import statement to use absolute paths"""
    # Extract the path from the import statement
    path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
    if not path_match:
        path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
    
    if not path_match:
        return import_stmt
    
    current_path = path_match.group(1)
    
    # Convert relative paths to absolute
    if current_path.startswith('./') or current_path.startswith('../'):
        absolute_path = convert_relative_to_absolute_path(current_file, current_path)
        new_import = import_stmt.replace(f'"{current_path}"', f'"{absolute_path}"')
        return new_import
    
    # Already absolute or library import - return as is
    return import_stmt

def convert_import_to_relative(import_stmt: str, current_file: str) -> str:
    """Convert an import statement to use relative paths"""
    # Extract the path from the import statement
    path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
    if not path_match:
        path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
    
    if not path_match:
        return import_stmt
    
    current_path = path_match.group(1)
    
    # Handle absolute paths
    if current_path.startswith('centrifuge-v3/') or current_path.startswith('src/'):
        relative_path = convert_to_relative_path(current_file, current_path)
        new_import = import_stmt.replace(f'"{current_path}"', f'"{relative_path}"')
        return new_import
    
    # Handle relative paths that contain redundant /src/ components  
    if (current_path.startswith('./') or current_path.startswith('../')) and '/src/' in current_path:
        current_file_clean = current_file.replace('\\', '/').lstrip('./')
        
        # If both current file and target are in src/, we can remove /src/
        if current_file_clean.startswith('src/'):
            optimized_path = current_path.replace('/src/', '/')
            new_import = import_stmt.replace(f'"{current_path}"', f'"{optimized_path}"')
            return new_import
        
        # If current file is in test/ or script/, check if removing /src/ gives us a valid path
        elif current_file_clean.startswith(('test/', 'script/')):
            # Try removing /src/ and see if the target file exists
            current_dir = os.path.dirname(current_file_clean)
            test_path_without_src = current_path.replace('/src/', '/')
            
            try:
                target_path = os.path.normpath(os.path.join(current_dir, test_path_without_src))
                if os.path.exists(target_path):
                    # File exists without /src/, so remove it
                    new_import = import_stmt.replace(f'"{current_path}"', f'"{test_path_without_src}"')
                    return new_import
            except:
                pass
    
    # Handle potentially incorrect relative imports - but be much more careful
    if current_path.startswith('../'):
        current_file_clean = current_file.replace('\\', '/').lstrip('./')
        current_file_in_src = current_file_clean.startswith('src/')
        
        # Only add src/ if current file is outside src/ and the path doesn't already have src/
        if not current_file_in_src and '/src/' not in current_path:
            # Try to resolve what the import is actually trying to import
            # by checking if the file exists with or without src/
            current_dir = os.path.dirname(current_file_clean)
            
            try:
                # Try to resolve the relative path
                target_path_without_src = os.path.normpath(os.path.join(current_dir, current_path))
                target_path_with_src = current_path
                
                # Check if target file exists without src/ (i.e., as a test/script file)
                if os.path.exists(target_path_without_src):
                    # File exists without src/, so this is correct as-is
                    return import_stmt
                
                # If we're in test/ or script/ and importing what looks like src/ structure,
                # only add src/ if we're going up to project root level (3+ levels)
                path_parts = current_path.split('/')
                up_levels = current_path.count('../')
                
                for i, part in enumerate(path_parts):
                    if part in ['misc', 'common', 'hub', 'spoke', 'vaults', 'hooks', 'managers']:
                        # Only add src/ if we're going up 3+ levels (suggesting we're going to project root)
                        if up_levels >= 3:
                            # This might be a cross-directory import to src/
                            corrected_parts = path_parts[:i] + ['src'] + path_parts[i:]
                            corrected_path = '/'.join(corrected_parts)
                            new_import = import_stmt.replace(f'"{current_path}"', f'"{corrected_path}"')
                            return new_import
                        break
            except:
                # If path resolution fails, leave as-is
                pass
    
    # Handle project-absolute paths that should be converted to relative (script/, test/)
    if (current_path.startswith('script/') or current_path.startswith('test/')):
        relative_path = convert_to_relative_path(current_file, current_path)
        new_import = import_stmt.replace(f'"{current_path}"', f'"{relative_path}"')
        return new_import
    
    # Handle local imports that need ./ prefix (only for same-directory or immediate subdirectories)
    if (not current_path.startswith('./') and 
        not current_path.startswith('../') and 
        not current_path.startswith('/') and
        not 'forge-std' in current_path and
        not current_path.startswith('centrifuge-v3/') and
        not current_path.startswith('src/') and
        not current_path.startswith('script/') and
        not current_path.startswith('test/')):
        
        # Check if this is a true local import (within current directory structure)
        # by examining if the import path starts with known subdirectory names that would be local
        current_file_clean = current_file.replace('\\', '/').lstrip('./')
        current_dir = os.path.dirname(current_file_clean)
        
        path_parts = current_path.split('/')
        first_part = path_parts[0]
        
        # Only add ./ if the first part looks like a local subdirectory
        # Common local subdirectories: interfaces, types, libraries, factories, mocks, utils
        if first_part in ['interfaces', 'types', 'libraries', 'factories', 'mocks', 'utils']:
            prefixed_path = f"./{current_path}"
            new_import = import_stmt.replace(f'"{current_path}"', f'"{prefixed_path}"')
            return new_import
    
    # Skip if already properly formatted relative or is a library import
    return import_stmt

def check_relative_imports_in_file(file_path: str) -> Tuple[bool, List[str]]:
    """Check if all imports in a file use relative paths"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        imports = extract_imports(content)
        issues = []
        
        for import_stmt in imports:
            # Extract the path from the import statement
            path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
            if not path_match:
                path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
            
            if path_match:
                path = path_match.group(1)
                # Check if it's an absolute path that should be relative
                if path.startswith('centrifuge-v3/') or path.startswith('src/'):
                    issues.append(f"Absolute import found: {import_stmt}")
        
        return len(issues) == 0, issues
    
    except Exception as e:
        return False, [f"Error processing file: {e}"]

def fix_relative_imports_in_file(file_path: str) -> bool:
    """Convert all absolute imports to relative imports in a file"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        imports = extract_imports(content)
        if not imports:
            return False
        
        new_content = content
        changes_made = False
        
        for import_stmt in imports:
            # Convert import to relative
            new_import = convert_import_to_relative(import_stmt, file_path)
            if new_import != import_stmt:
                new_content = new_content.replace(import_stmt, new_import)
                changes_made = True
        
        if changes_made:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return True
        
        return False
    
    except Exception as e:
        print(f"Error processing {file_path}: {e}")
        return False

def check_all_relative_imports():
    """Check if all imports use relative paths in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Checking relative imports in {len(files)} Solidity files...\n")
    
    total_files_with_issues = 0
    total_issues = 0
    
    for file_path in files:
        if file_path.strip():
            is_relative, issues = check_relative_imports_in_file(file_path)
            if not is_relative:
                total_files_with_issues += 1
                total_issues += len(issues)
                print(f"\n📁 {file_path}")
                for issue in issues:
                    print(f"  ❌ {issue}")
    
    print(f"\n📊 Summary:")
    print(f"   Files checked: {len(files)}")
    print(f"   Files with absolute imports: {total_files_with_issues}")
    print(f"   Total absolute imports: {total_issues}")
    
    if total_files_with_issues > 0:
        print(f"\n💡 Run with --fix-relative to convert these to relative imports")
        return False  # Return False to indicate issues found (for CI)
    
    return True

def fix_absolute_imports_in_file(file_path: str) -> bool:
    """Convert all relative imports to absolute imports in a file"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        imports = extract_imports(content)
        if not imports:
            return False
        
        new_content = content
        changes_made = False
        
        for import_stmt in imports:
            # Convert import to absolute
            new_import = convert_import_to_absolute(import_stmt, file_path)
            if new_import != import_stmt:
                new_content = new_content.replace(import_stmt, new_import)
                changes_made = True
        
        if changes_made:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            return True
        
        return False
    
    except Exception as e:
        print(f"Error processing {file_path}: {e}")
        return False

def check_absolute_imports_in_file(file_path: str) -> Tuple[bool, List[str]]:
    """Check if all imports in a file use absolute paths"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        imports = extract_imports(content)
        issues = []
        
        for import_stmt in imports:
            # Extract the path from the import statement
            path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
            if not path_match:
                path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
            
            if path_match:
                path = path_match.group(1)
                # Check if it's a relative path that should be absolute
                if path.startswith('./') or path.startswith('../'):
                    issues.append(f"Relative import found: {import_stmt}")
        
        return len(issues) == 0, issues
    
    except Exception as e:
        return False, [f"Error processing file: {e}"]

def fix_all_relative_imports():
    """Convert all absolute imports to relative imports in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Converting to relative imports in {len(files)} Solidity files...\n")
    
    total_files_fixed = 0
    
    for file_path in files:
        if file_path.strip():
            print(f"Processing: {file_path}")
            if fix_relative_imports_in_file(file_path):
                total_files_fixed += 1
                print(f"  ✅ Converted to relative imports")
            else:
                print(f"  ℹ️  No absolute imports found")
    
    print(f"\n📊 Summary:")
    print(f"   Files processed: {len(files)}")
    print(f"   Files with imports converted: {total_files_fixed}")

def fix_all_absolute_imports():
    """Convert all relative imports to absolute imports in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Converting to absolute imports in {len(files)} Solidity files...\n")
    
    total_files_fixed = 0
    
    for file_path in files:
        if file_path.strip():
            print(f"Processing: {file_path}")
            if fix_absolute_imports_in_file(file_path):
                total_files_fixed += 1
                print(f"  ✅ Converted to absolute imports")
            else:
                print(f"  ℹ️  No relative imports found")
    
    print(f"\n📊 Summary:")
    print(f"   Files processed: {len(files)}")
    print(f"   Files with imports converted: {total_files_fixed}")

def check_all_absolute_imports():
    """Check if all imports use absolute paths in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Checking absolute imports in {len(files)} Solidity files...\n")
    
    total_files_with_issues = 0
    total_issues = 0
    
    for file_path in files:
        if file_path.strip():
            is_absolute, issues = check_absolute_imports_in_file(file_path)
            if not is_absolute:
                total_files_with_issues += 1
                total_issues += len(issues)
                print(f"\n📁 {file_path}")
                for issue in issues:
                    print(f"  ❌ {issue}")
    
    print(f"\n📊 Summary:")
    print(f"   Files checked: {len(files)}")
    print(f"   Files with relative imports: {total_files_with_issues}")
    print(f"   Total relative imports: {total_issues}")
    
    if total_files_with_issues > 0:
        print(f"\n💡 Run with --fix-absolute to convert these to absolute imports")
        return False  # Return False to indicate issues found (for CI)
    
    return True

def test_roundtrip_idempotency():
    """Test that relative -> absolute -> relative conversion is idempotent"""
    files = get_all_solidity_files()
    print(f"Testing roundtrip idempotency on {len(files)} Solidity files...\n")
    
    # Step 1: Save original state
    print("📝 Step 1: Saving original import state...")
    original_content = {}
    for file_path in files:
        if file_path.strip():
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    original_content[file_path] = f.read()
            except Exception as e:
                print(f"Error reading {file_path}: {e}")
                continue
    
    print(f"✅ Saved original state for {len(original_content)} files")
    
    try:
        # Step 2: Convert to absolute imports
        print("\n🔄 Step 2: Converting all imports to absolute paths...")
        converted_to_absolute = 0
        for file_path in original_content.keys():
            if fix_absolute_imports_in_file(file_path):
                converted_to_absolute += 1
        print(f"✅ Converted {converted_to_absolute} files to absolute imports")
        
        # Step 3: Convert back to relative imports
        print("\n🔄 Step 3: Converting back to relative paths...")
        converted_to_relative = 0
        for file_path in original_content.keys():
            if fix_relative_imports_in_file(file_path):
                converted_to_relative += 1
        print(f"✅ Converted {converted_to_relative} files back to relative imports")
        
        # Step 4: Compare with original state
        print("\n🔍 Step 4: Comparing with original state...")
        differences_found = 0
        files_with_differences = []
        
        for file_path, original in original_content.items():
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    current_content = f.read()
                
                if current_content != original:
                    differences_found += 1
                    files_with_differences.append(file_path)
                    
                    # Show first few lines of difference for debugging
                    orig_lines = original.split('\n')
                    curr_lines = current_content.split('\n')
                    print(f"\n❌ Difference in {file_path}:")
                    for i, (orig, curr) in enumerate(zip(orig_lines, curr_lines)):
                        if orig != curr:
                            print(f"  Line {i+1}:")
                            print(f"    Original: {orig}")
                            print(f"    Current:  {curr}")
                            break
                            
            except Exception as e:
                print(f"Error comparing {file_path}: {e}")
                differences_found += 1
                files_with_differences.append(file_path)
        
        # Step 5: Report results
        print(f"\n📊 Roundtrip Test Results:")
        print(f"   Files tested: {len(original_content)}")
        print(f"   Files converted to absolute: {converted_to_absolute}")
        print(f"   Files converted back to relative: {converted_to_relative}")
        print(f"   Files with differences: {differences_found}")
        
        if differences_found == 0:
            print("✅ PASSED: Roundtrip conversion is idempotent!")
            return True
        else:
            print("❌ FAILED: Roundtrip conversion is not idempotent!")
            print(f"   Files with differences: {', '.join(files_with_differences)}")
            return False
            
    finally:
        # Restore original content in case of errors or differences
        if differences_found > 0:
            print("\n🔧 Restoring original content...")
            restored = 0
            for file_path, original in original_content.items():
                try:
                    with open(file_path, 'w', encoding='utf-8') as f:
                        f.write(original)
                    restored += 1
                except Exception as e:
                    print(f"Error restoring {file_path}: {e}")
            print(f"✅ Restored {restored} files to original state")

def main():
    """Main function"""
    parser = argparse.ArgumentParser(
        description='Solidity import organizer, unused import detector, and path converter (relative/absolute)',
        epilog='''
Examples:
  %(prog)s --check-unused              # Check for unused imports (default)
  %(prog)s --fix-unused                # Remove unused imports
  %(prog)s --organize                  # Organize imports by priority AND convert to relative paths
  %(prog)s --organize --no-relative    # Organize imports by priority only (skip relative conversion)
  %(prog)s --check-order               # Check import order (CI-friendly)
  %(prog)s --check-relative            # Check for absolute imports (CI-friendly)
  %(prog)s --fix-relative              # Convert absolute to relative imports only
  %(prog)s --check-absolute            # Check for relative imports (CI-friendly)
  %(prog)s --fix-absolute              # Convert relative to absolute imports only
  %(prog)s --test-roundtrip            # Test that relative ↔ absolute conversion is idempotent (CI-friendly)
  %(prog)s --check-relative --file src/hub/Hub.sol  # Check specific file

WORKFLOW FOR FILE REORGANIZATION:
  1. %(prog)s --fix-absolute           # Convert all to absolute paths
  2. # Move/reorganize files
  3. # Update absolute paths (find/replace)
  4. %(prog)s --fix-relative           # Convert back to relative paths

The --organize command automatically converts to relative imports to ensure
the repository can be used as a dependency without import path conflicts.
Use --no-relative to disable this behavior if needed.
        ''',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument('--check-unused', action='store_true', help='Check for unused imports')
    parser.add_argument('--fix-unused', action='store_true', help='Remove unused imports from all files')
    parser.add_argument('--organize', action='store_true', help='Organize imports according to priority and convert to relative paths')
    parser.add_argument('--check-order', action='store_true', help='Check if imports are properly ordered (dry-run of --organize)')
    parser.add_argument('--check-relative', action='store_true', help='Check if all imports use relative paths (for CI)')
    parser.add_argument('--fix-relative', action='store_true', help='Convert absolute imports to relative imports')
    parser.add_argument('--check-absolute', action='store_true', help='Check if all imports use absolute paths (for CI)')
    parser.add_argument('--fix-absolute', action='store_true', help='Convert relative imports to absolute imports')
    parser.add_argument('--test-roundtrip', action='store_true', help='Test that relative ↔ absolute conversion is idempotent (for CI)')
    parser.add_argument('--no-relative', action='store_true', help='Skip relative path conversion when organizing (use with --organize)')
    parser.add_argument('--file', type=str, help='Process a specific file instead of all files')

    args = parser.parse_args()

    # Check for default behavior
    has_action = (args.check_unused or args.organize or args.fix_unused or args.check_order or 
                  args.check_relative or args.fix_relative or args.check_absolute or 
                  args.fix_absolute or args.test_roundtrip)
    
    if not has_action:
        # Default behavior: check for unused imports
        args.check_unused = True

    # Determine if we should convert to relative imports when organizing
    convert_to_relative = not args.no_relative

    if args.file:
        # Process specific file
        if args.check_unused:
            try:
                with open(args.file, 'r', encoding='utf-8') as f:
                    content = f.read()
                unused = find_unused_imports(args.file, content)
                if unused:
                    print(f"📁 {args.file}")
                    for unused_import in unused:
                        print(f"  ❌ {unused_import}")
                else:
                    print(f"✅ No unused imports found in {args.file}")
            except Exception as e:
                print(f"Error checking {args.file}: {e}")

        if args.fix_unused:
            fixed, removed_count = fix_unused_imports_in_file(args.file)
            if fixed:
                print(f"✅ Removed {removed_count} unused import(s) from {args.file}")
            else:
                print(f"ℹ️  No unused imports found in {args.file}")

        if args.organize:
            if fix_file_imports(args.file, convert_to_relative):
                action_msg = "organized imports and converted to relative paths" if convert_to_relative else "organized imports"
                print(f"✅ {action_msg.capitalize()} in {args.file}")
            else:
                print(f"ℹ️  No changes needed in {args.file}")

        if args.check_order:
            is_ordered, issues = check_import_order_in_file(args.file)
            if is_ordered:
                print(f"✅ Import order is correct in {args.file}")
            else:
                print(f"📁 {args.file}")
                for issue in issues:
                    print(f"  ❌ {issue}")
                print(f"\n💡 Run with --organize to fix these issues")

        if args.check_relative:
            is_relative, issues = check_relative_imports_in_file(args.file)
            if is_relative:
                print(f"✅ All imports are relative in {args.file}")
            else:
                print(f"📁 {args.file}")
                for issue in issues:
                    print(f"  ❌ {issue}")
                print(f"\n💡 Run with --fix-relative to convert these to relative imports")

        if args.fix_relative:
            if fix_relative_imports_in_file(args.file):
                print(f"✅ Converted to relative imports in {args.file}")
            else:
                print(f"ℹ️  No absolute imports found in {args.file}")

        if args.check_absolute:
            is_absolute, issues = check_absolute_imports_in_file(args.file)
            if is_absolute:
                print(f"✅ All imports are absolute in {args.file}")
            else:
                print(f"📁 {args.file}")
                for issue in issues:
                    print(f"  ❌ {issue}")
                print(f"\n💡 Run with --fix-absolute to convert these to absolute imports")

        if args.fix_absolute:
            if fix_absolute_imports_in_file(args.file):
                print(f"✅ Converted to absolute imports in {args.file}")
            else:
                print(f"ℹ️  No relative imports found in {args.file}")
    else:
        # Process all files
        if args.check_unused:
            check_unused_imports()

        if args.fix_unused:
            fix_all_unused_imports()

        if args.organize:
            organize_all_imports(convert_to_relative)

        if args.check_order:
            success = check_import_order()
            if not success:
                exit(1)  # Exit with error code for CI

        if args.check_relative:
            success = check_all_relative_imports()
            if not success:
                exit(1)  # Exit with error code for CI

        if args.fix_relative:
            fix_all_relative_imports()

        if args.check_absolute:
            success = check_all_absolute_imports()
            if not success:
                exit(1)  # Exit with error code for CI

        if args.fix_absolute:
            fix_all_absolute_imports()

        if args.test_roundtrip:
            success = test_roundtrip_idempotency()
            if not success:
                exit(1)  # Exit with error code for CI

if __name__ == "__main__":
    main()
