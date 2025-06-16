#!/usr/bin/env python3

import os
import re
import subprocess
from typing import List, Dict, Set, Tuple
import argparse
import sys

# Priority order for imports
IMPORT_PRIORITY = [
    "src/misc",
    "src/common", 
    "src/vaults",
    "src/hub",
    "src/spoke",
    "src/hooks",
    "src/managers",
    "script",
    "test"
]

def get_all_solidity_files() -> List[str]:
    """Get all Solidity files excluding lib directory"""
    result = subprocess.run(
        ["find", ".", "-name", "*.sol", "-not", "-path", "./lib/*"],
        capture_output=True,
        text=True
    )
    return result.stdout.strip().split('\n') if result.stdout.strip() else []

def extract_imports(content: str) -> List[str]:
    """Extract all import statements from file content"""
    import_pattern = r'^import\s+.*?;$'
    imports = re.findall(import_pattern, content, re.MULTILINE)
    return imports

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

def categorize_imports(imports: List[str]) -> Tuple[Dict[str, List[str]], List[str]]:
    """Categorize imports by their path prefix"""
    categorized = {priority: [] for priority in IMPORT_PRIORITY}
    other_imports = []
    
    for import_stmt in imports:
        # Extract the path from import statement
        path_match = re.search(r'from\s+"([^"]+)"', import_stmt)
        if not path_match:
            # Handle imports without 'from' keyword
            path_match = re.search(r'import\s+"([^"]+)"', import_stmt)
        
        if path_match:
            path = path_match.group(1)
            categorized_flag = False
            
            for priority in IMPORT_PRIORITY:
                if path.startswith(priority):
                    categorized[priority].append(import_stmt)
                    categorized_flag = True
                    break
            
            if not categorized_flag:
                other_imports.append(import_stmt)
        else:
            other_imports.append(import_stmt)
    
    return categorized, other_imports

def organize_imports(categorized: Dict[str, List[str]], other_imports: List[str]) -> str:
    """Organize imports according to priority with empty lines between categories, sorted by ascending length within each category"""
    organized_imports = []
    
    for priority in IMPORT_PRIORITY:
        if categorized[priority]:
            # Remove duplicates and sort by length (ascending), then alphabetically
            unique_imports = list(set(categorized[priority]))
            sorted_imports = sorted(unique_imports, key=lambda x: (len(x), x))
            organized_imports.extend(sorted_imports)
            organized_imports.append("")  # Empty line after each category
    
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

def fix_file_imports(file_path: str) -> bool:
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
        
        # Remove existing import lines from content
        content_without_imports = content
        for import_stmt in imports:
            content_without_imports = content_without_imports.replace(import_stmt + '\n', '')
            content_without_imports = content_without_imports.replace(import_stmt, '')
        
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

def organize_all_imports():
    """Organize imports in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Found {len(files)} Solidity files to process")
    
    fixed_count = 0
    other_import_paths = set()
    
    for file_path in files:
        if file_path.strip():  # Skip empty strings
            print(f"Processing: {file_path}")
            
            # Check for other import paths
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
                        if path.startswith('src/') and not any(path.startswith(p) for p in IMPORT_PRIORITY):
                            other_import_paths.add(path.split('/')[1] if '/' in path else path)
            except:
                pass
            
            if fix_file_imports(file_path):
                fixed_count += 1
    
    print(f"\nFixed imports in {fixed_count} files")
    
    if other_import_paths:
        print(f"\nOther import paths found beyond the specified ones:")
        for path in sorted(other_import_paths):
            print(f"  - src/{path}")

def main():
    """Main function"""
    parser = argparse.ArgumentParser(description='Solidity import organizer and unused import detector')
    parser.add_argument('--check-unused', action='store_true', help='Check for unused imports')
    parser.add_argument('--fix-unused', action='store_true', help='Remove unused imports from all files')
    parser.add_argument('--organize', action='store_true', help='Organize imports according to priority')
    parser.add_argument('--file', type=str, help='Process a specific file instead of all files')
    
    args = parser.parse_args()
    
    if not args.check_unused and not args.organize and not args.fix_unused:
        # Default behavior: check for unused imports
        args.check_unused = True
    
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
            if fix_file_imports(args.file):
                print(f"✅ Organized imports in {args.file}")
            else:
                print(f"ℹ️  No changes needed in {args.file}")
    else:
        # Process all files
        if args.check_unused:
            check_unused_imports()
        
        if args.fix_unused:
            fix_all_unused_imports()
        
        if args.organize:
            organize_all_imports()

if __name__ == "__main__":
    main() 