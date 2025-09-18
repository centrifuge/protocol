# Solidity Import Management Script

A comprehensive Python script for managing Solidity imports with automatic relative path conversion, unused import detection, and intelligent import organization.

## 🎯 Overview

This script transforms your Solidity codebase to use clean, relative import paths making it dependency-ready while maintaining perfect organization and removing unused imports.

### Key Features

- ✅ **Bidirectional Path Conversion**: Convert between relative ↔ absolute imports seamlessly
- ✅ **File Reorganization Workflow**: Safe file moving with automatic import path management
- ✅ **Absolute → Relative Path Conversion**: Converts `src/`, `script/`, `test/` imports to proper relative paths
- ✅ **Relative → Absolute Path Conversion**: Convert relative paths to absolute for file reorganization
- ✅ **Same-Directory Import Detection**: `src/misc/interfaces/IERC165.sol` → `./IERC165.sol`
- ✅ **Smart Cross-Directory Imports**: `src/hub/Hub.sol` importing `src/misc/Auth.sol` → `../misc/Auth.sol`
- ✅ **Test-to-Source Imports**: Preserves `src/` prefix when needed (e.g., test files importing source)
- ✅ **Priority-Based Organization**: Groups imports by logical categories with proper spacing
- ✅ **Advanced Subgrouping**: Organizes imports by base directory (`../`, `src`, `test`, `script`)
- ✅ **Roundtrip Idempotency**: Ensures relative ↔ absolute conversions are lossless
- ✅ **Unused Import Detection**: Identifies and removes unused imports
- ✅ **Multi-line Import Support**: Handles complex import statements across multiple lines
- ✅ **Local Import Prefixing**: Adds `./` to local subdirectory imports
- ✅ **Path Optimization**: Removes redundant `/src/` components in paths

## 🚀 Quick Start

### Basic Usage

```bash
# Default: Check for unused imports
python3 script/utils/fix_imports.py

# Organize imports AND convert to relative paths (recommended)
python3 script/utils/fix_imports.py --organize

# Check if imports are properly ordered (CI-friendly)
python3 script/utils/fix_imports.py --check-order

# Check if all imports use relative paths (CI-friendly) 
python3 script/utils/fix_imports.py --check-relative
```

## 🔄 **File Reorganization Workflow**

When you need to move/reorganize files in your repository, use this **safe workflow** to avoid breaking import paths:

### Step 1: Convert to Absolute Imports
```bash
python3 script/utils/fix_imports.py --fix-absolute
```
This converts all relative imports (`./`, `../`) to absolute paths (`src/`, `test/`, `script/`), making them immune to file moves.

### Step 2: Move Your Files
Move, rename, or reorganize your files as needed. The absolute imports won't break.

### Step 3: Update Absolute Paths (if needed) 
If you moved files to different base directories, update the absolute paths:
```bash
# Example: If you moved src/hub/Hub.sol to src/core/Hub.sol
find . -name "*.sol" -exec sed -i 's|src/hub/Hub.sol|src/core/Hub.sol|g' {} \;
```

### Step 4: Convert Back to Relative Imports
```bash
python3 script/utils/fix_imports.py --fix-relative
```
This converts all absolute imports back to clean relative paths.

### 🧪 **Idempotency Testing**
```bash
# Test that relative ↔ absolute ↔ relative conversion is lossless
python3 script/utils/fix_imports.py --test-roundtrip
```
Perfect for CI to ensure conversion reliability!

### Process Specific Files

```bash
# Fix imports in a specific file
python3 script/utils/fix_imports.py --organize --file src/hub/Hub.sol

# Check unused imports in a specific file
python3 script/utils/fix_imports.py --check-unused --file src/misc/Auth.sol
```

## 📋 Command Reference

| Command                    | Description                                         | Exit Code on Issues |
| -------------------------- | --------------------------------------------------- | ------------------- |
| `--check-unused`           | Check for unused imports (default)                  | ❌                   |
| `--fix-unused`             | Remove unused imports                               | ➖                   |
| `--organize`               | **Organize imports + convert to relative paths**    | ➖                   |
| `--organize --no-relative` | Organize imports only (skip relative conversion)    | ➖                   |
| `--check-order`            | Check import organization (dry-run)                 | ❌                   |
| `--check-relative`         | Check for absolute imports                          | ❌                   |
| `--fix-relative`           | Convert absolute to relative imports only           | ➖                   |
| `--check-absolute`         | Check for relative imports                          | ❌                   |
| `--fix-absolute`           | **Convert relative to absolute imports**            | ➖                   |
| `--test-roundtrip`         | **Test relative ↔ absolute conversion is lossless** | ❌                   |
| `--file <path>`            | Process specific file                               | ➖                   |

**Legend**: ❌ = Exits with error code for CI, ➖ = Always exits successfully

## 📄 Examples

### Complete Workflow
```bash
# 1. Check current state
python3 script/utils/fix_imports.py --check-relative
python3 script/utils/fix_imports.py --check-order

# 2. Fix everything
python3 script/utils/fix_imports.py --organize

# 3. Verify changes
forge build
python3 script/utils/fix_imports.py --check-relative

# 4. Clean up unused imports
python3 script/utils/fix_imports.py --fix-unused
```

### File Reorganization Workflow
```bash
# 1. Convert to absolute paths for safe file moving
python3 script/utils/fix_imports.py --fix-absolute

# 2. Move/reorganize files as needed
# ... move your files ...

# 3. Update absolute paths if needed (example)
find . -name "*.sol" -exec sed -i 's|src/old/path|src/new/path|g' {} \;

# 4. Convert back to relative paths
python3 script/utils/fix_imports.py --fix-relative

# 5. Verify everything is back to original state
python3 script/utils/fix_imports.py --test-roundtrip
```

### Specific File Processing
```bash
# Check specific file
python3 script/utils/fix_imports.py --check-unused --file src/hub/Hub.sol

# Fix specific file  
python3 script/utils/fix_imports.py --organize --file src/hub/Hub.sol
```

## 🔄 Import Transformations

### Absolute → Relative Path Conversion

**Same Directory:**
```solidity
// Before
import {IERC165} from "src/misc/interfaces/IERC165.sol";

// After  
import {IERC165} from "./IERC165.sol";
```

**Cross Directory:**
```solidity
// Before
import {Auth} from "src/misc/Auth.sol";

// After (from src/hub/Hub.sol)
import {Auth} from "../misc/Auth.sol";
```

**Script Imports:**
```solidity
// Before
import {CommonInput} from "script/CommonDeployer.s.sol";

// After (from script/SpokeManagersDeployer.s.sol)
import {CommonInput} from "./CommonDeployer.s.sol";
```

**Test-to-Source Imports:**
```solidity
// Before  
import {Hub} from "src/hub/Hub.sol";

// After (from test/hub/unit/Hub.t.sol)
import {Hub} from "../../../src/hub/Hub.sol";
```

### Local Import Prefixing

```solidity
// Before
import {IHub} from "interfaces/IHub.sol";

// After
import {IHub} from "./interfaces/IHub.sol";
```

### Path Optimization

```solidity
// Before
import {Auth} from "../../../src/misc/Auth.sol";

// After (when both files are in src/)
import {Auth} from "../../misc/Auth.sol";
```

## 📊 Import Priority System

Imports are automatically organized into priority groups with **subgroup separation** for enhanced clarity:

```python
IMPORT_PRIORITY = [
    ".",        # Current directory (highest priority)
    "misc",     # Utilities, base contracts
    "common",   # Shared components  
    "hub",      # Hub contracts
    "spoke",    # Spoke contracts
    "vaults",   # Vault contracts
    "hooks",    # Hook contracts
    "managers", # Manager contracts
    "script",   # Deployment scripts
    "test",     # Test files
    "mocks",    # Mock contracts
    "forge-std" # Forge standard library
]
```

### 🎯 **Advanced Subgrouping**

Within each priority category, imports are further organized by their **base directory**:

1. **`../` imports** (direct relative paths)
2. **`src/` imports** (via src directory)  
3. **`test/` imports** (via test directory)
4. **`script/` imports** (via script directory)

**Each subgroup is separated by empty lines** for maximum clarity.

### Organized Output Example

**Simple organization:**
```solidity
pragma solidity ^0.8.28;

import {IHoldings} from "./interfaces/IHoldings.sol";
import {IHub} from "./interfaces/IHub.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {IGateway} from "../common/interfaces/IGateway.sol";

import "forge-std/Test.sol";
```

**Advanced subgrouping example:**
```solidity
pragma solidity ^0.8.28;

// Current directory imports
import {LocalInterface} from "./interfaces/ILocal.sol";

// Common category - '../' subgroup (direct relative)
import {SharedUtil} from "../common/SharedUtil.sol";

// Common category - 'src' subgroup (via src/)  
import {CommonType} from "../../src/common/types/CommonType.sol";

// Common category - 'test' subgroup (via test/)
import {MockCommon} from "../test/common/mocks/MockCommon.sol";

// Hub category - 'src' subgroup
import {IHub} from "../../src/hub/interfaces/IHub.sol";
```

## 📝 How It Works

### 1. Path Resolution
- **Same Directory Detection**: Files in the same directory use `./filename.sol`
- **Subdirectory Detection**: `./subdir/filename.sol` 
- **Parent Directory**: `../filename.sol`
- **Cross-Directory**: `../other/filename.sol`

### 2. Smart Source Detection
- **Test files** → **Source files**: Keeps `src/` prefix
- **Source files** → **Source files**: Removes `src/` prefix for cleaner paths
- **Script files** → **Source files**: Keeps `src/` prefix
- **Same-base imports** (test→test, script→script): Uses clean relative paths

### 3. File Existence Validation
The script validates paths by checking file existence to avoid:
- Creating invalid imports
- Adding unnecessary `src/` prefixes
- Breaking existing valid imports

### 4. Multi-line Import Handling
```solidity
// Handles complex imports like:
import {
    VeryLongInterfaceName,
    AnotherLongInterfaceName,
    YetAnotherLongName
} from "src/common/interfaces/IComplexInterface.sol";
```

## 🔧 Technical Details

### File Processing
- **Scanned Files**: All `*.sol` files excluding `lib/`, `out/`, `cache/`, `broadcast/`
- **Regex Patterns**: Handles both single and multi-line imports
- **Path Normalization**: Uses Python `pathlib` for cross-platform compatibility

### Import Categories
The script categorizes imports by analyzing the import path structure:
- **Current directory** (`.`): Same directory or immediate subdirectories
- **Project directories**: Based on first directory component in path
- **Library imports**: `forge-std` and similar external libraries

### Error Handling
- **Graceful failures**: Invalid imports are left unchanged
- **Validation**: Checks file existence before modifications
- **Backup safety**: Only writes files when changes are needed

## 🐛 Troubleshooting

### Common Issues

**Import not being converted:**
- Check if file actually exists at the target path
- Verify the import syntax is standard Solidity format
- Check that file isn't in excluded directories (`lib/`, `out/`, etc.)

**Wrong relative path generated:**
- Ensure both source and target files are in expected locations
- Check for symbolic links or unusual file system setups

**Imports being incorrectly grouped:**
- Path-based grouping may group similar paths from different base directories
- This is aesthetic only and doesn't affect compilation

### Debug Mode
Add debug prints by modifying the script temporarily:
```python
print(f"Converting: {current_file} -> {import_path}")
print(f"Result: {result}")
```
