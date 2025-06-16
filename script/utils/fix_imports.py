#!/usr/bin/env python3

import os
import re
import subprocess
from typing import List, Dict, Set

# Priority order for imports
IMPORT_PRIORITY = [
    "src/misc",
    "src/common", 
    "src/vaults",
    "src/hub",
    "src/spoke",
    "src/managers",
    "src/hooks",
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

def categorize_imports(imports: List[str]) -> Dict[str, List[str]]:
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
    """Organize imports according to priority with empty lines between categories"""
    organized_imports = []
    
    for priority in IMPORT_PRIORITY:
        if categorized[priority]:
            # Sort imports within each category
            sorted_imports = sorted(set(categorized[priority]))
            organized_imports.extend(sorted_imports)
            organized_imports.append("")
    
    # Add other imports at the end
    if other_imports:
        sorted_other = sorted(set(other_imports))
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
        
        # Handle pragma
        insert_idx = pragma_end_idx
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

def main():
    """Main function to fix imports in all Solidity files"""
    files = get_all_solidity_files()
    print(f"Found {len(files)} Solidity files to process")
    
    fixed_count = 0
    other_import_paths = set()
    
    for file_path in files:
        if file_path.strip():
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

if __name__ == "__main__":
    main() 