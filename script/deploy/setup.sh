#!/bin/bash
set -euo pipefail

# =============================================================================
# Centrifuge Protocol Deployment Setup Script
# =============================================================================

# Version requirements
REQUIRED_PYTHON_VERSION="3.10"
REQUIRED_FORGE_VERSION="1.2.3"
REQUIRED_NODE_VERSION="20"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Platform detection
PLATFORM=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    PLATFORM="mac"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    PLATFORM="linux"
else
    echo -e "${RED}❌ Unsupported platform: $OSTYPE${NC}"
    exit 1
fi

# Global variables
ISSUES_FOUND=0
AUTO_FIX=${AUTO_FIX:-false}
PYTHON_CMD=""
PIP_CMD=""

# =============================================================================
# Utility Functions
# =============================================================================

print_header() {
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${NC}        ${CYAN}Centrifuge Protocol Deployment Setup${NC}        ${BLUE}${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo -e "${CYAN}▶ $1${NC}"
}

print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

print_fixed() {
    echo -e "  ${GREEN}✓${NC} $1 (fixed)"
    ISSUES_FOUND=$((ISSUES_FOUND - 1))
}

print_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

install_package() {
    local command="$1"

    if [[ -n "$command" ]]; then
        print_info "Command to run: $command"
    fi

    if [[ "$PLATFORM" == "mac" && "$AUTO_FIX" != "true" ]]; then
        echo -e "${YELLOW}Would you like to install this package? (y/N):${NC} "
        read -r response
        case "$response" in
        [yY][eE][sS] | [yY])
            if [[ -n "$command" ]]; then
                echo -e "${CYAN}Installing: $command${NC}"
                eval "$command"
                return $?
            fi
            return 0
            ;;
        *) return 1 ;;
        esac
    else
        # Auto-install on Linux or when AUTO_FIX=true
        if [[ -n "$command" ]]; then
            echo -e "${CYAN}Auto-installing: $command${NC}"
            # Run the command and capture both stdout and stderr
            eval "$command" 2>&1
            return $?
        fi
        return 0
    fi
}

version_compare() {
    printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1
}

# =============================================================================
# Dependency Checkers
# =============================================================================

scan_python_mac() {
    echo "🔍 Scanning Python installeds on macOS..."

    # Check for Homebrew Python
    if [[ -f "/opt/homebrew/bin/python3" ]]; then
        HOMEBREW_VERSION=$(/opt/homebrew/bin/python3 --version 2>&1 | cut -d' ' -f2)
        echo "  ✓ Homebrew Python3: $HOMEBREW_VERSION at /opt/homebrew/bin/python3"
    fi

    # Check for system Python
    if [[ -f "/usr/bin/python3" ]]; then
        SYSTEM_VERSION=$(/usr/bin/python3 --version 2>&1 | cut -d' ' -f2)
        echo "  ⚠ System Python3: $SYSTEM_VERSION at /usr/bin/python3"
    fi

    # Check for Command Line Tools Python
    if [[ -f "/Library/Developer/CommandLineTools/usr/bin/python3" ]]; then
        CLT_VERSION=$(/Library/Developer/CommandLineTools/usr/bin/python3 --version 2>&1 | cut -d' ' -f2)
        echo "  ⚠ Command Line Tools Python3: $CLT_VERSION at /Library/Developer/CommandLineTools/usr/bin/python3"
    fi

    # Check which python3 is in PATH
    if type python3 &>/dev/null; then
        PYTHON3_PATH=$(python3 -c "import sys; print(sys.executable)" 2>/dev/null || echo "unknown")
        PYTHON3_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)

        echo "📍 Current PATH python3: $PYTHON3_VERSION at $PYTHON3_PATH"

        # Determine the type of Python in PATH
        if [[ "$PYTHON3_PATH" == *"homebrew"* ]]; then
            echo "  ✓ PATH points to Homebrew Python (good!)"
        elif [[ "$PYTHON3_PATH" == "/usr/bin/python3" ]]; then
            echo "  ⚠ PATH points to System Python (may be outdated)"
        elif [[ "$PYTHON3_PATH" == "/Library/Developer/CommandLineTools/usr/bin/python3" ]]; then
            echo "  ⚠ PATH points to Command Line Tools Python (may be outdated)"
        else
            echo "  ? PATH points to custom Python installed"
        fi
    else
        echo "❌ No python3 found in PATH"
    fi

}

check_python() {
    print_section "Checking Python Installation"

    # On macOS, provide detailed Python diagnostics
    if [[ "$PLATFORM" == "mac" ]]; then
        scan_python_mac
    fi

    # Check for python or python3 command (use PATH version)
    PYTHON_CMD=""
    PYTHON_VERSION=""

    if type python3 &>/dev/null; then
        PYTHON_CMD="python3"
        PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
    fi

    if [[ -z "$PYTHON_CMD" ]]; then
        print_error "Python3 command not found"
        print_info "Install Python from https://python.org or use your package manager"

        if [[ "$PLATFORM" == "mac" ]]; then
            print_info "Installing Python $REQUIRED_PYTHON_VERSION via Homebrew..."
            if install_package "brew install python@$REQUIRED_PYTHON_VERSION"; then
                print_fixed "Python installed"
            else
                print_info "Install Python manually: brew install python@$REQUIRED_PYTHON_VERSION"
                return 1
            fi
        else
            print_info "Installing Python3 via apt..."
            if install_package "sudo apt-get update && sudo apt-get install -y python3 python3-pip"; then
                print_fixed "Python installed"
            else
                print_info "Install Python manually: sudo apt-get install python3 python3-pip"
                return 1
            fi
        fi
    fi

    print_success "Found $PYTHON_CMD $PYTHON_VERSION"

    # Check version requirement
    PYTHON_MAJOR_MINOR=$(echo "$PYTHON_VERSION" | cut -d'.' -f1,2)

    if [[ $(version_compare "$PYTHON_MAJOR_MINOR" "$REQUIRED_PYTHON_VERSION") == "$PYTHON_MAJOR_MINOR" && "$PYTHON_MAJOR_MINOR" != "$REQUIRED_PYTHON_VERSION" ]]; then
        print_error "Python version $PYTHON_VERSION found, but $REQUIRED_PYTHON_VERSION+ required"

        if [[ "$PLATFORM" == "mac" ]]; then
            echo "🔧 Python PATH Fix Options:"

            # Check if we have a better Python installed available
            if [[ -f "/opt/homebrew/bin/python3" ]]; then
                HOMEBREW_VERSION=$(/opt/homebrew/bin/python3 --version 2>&1 | cut -d' ' -f2)
                HOMEBREW_MAJOR_MINOR=$(echo "$HOMEBREW_VERSION" | cut -d'.' -f1,2)

                if [[ $(version_compare "$HOMEBREW_MAJOR_MINOR" "$REQUIRED_PYTHON_VERSION") != "$HOMEBREW_MAJOR_MINOR" ]]; then
                    echo "  ✓ Homebrew Python $HOMEBREW_VERSION is available and meets requirements!"
                    echo "  💡 To use Homebrew Python, add to your shell config (~/.zshrc or ~/.bash_profile):"
                    echo "     export PATH=\"/opt/homebrew/bin:\$PATH\""
                    echo "     alias python3=\"/opt/homebrew/bin/python3\""
                    echo "  🔄 Or run: source ~/.zshrc && ./script/deploy/setup.sh"
                else
                    echo "  ⚠ Homebrew Python $HOMEBREW_VERSION also needs upgrading"
                fi
            else
                echo "📦 Installation Options:"
                echo "  1. Upgrade current Python via Homebrew..."
                if install_package "brew upgrade python@$REQUIRED_PYTHON_VERSION"; then

                    print_fixed "Python version upgrade"
                else
                    echo "  2. Install manually: brew install python@$REQUIRED_PYTHON_VERSION"
                    echo "  3. Fix PATH manually and re-run this script"
                    return 1
                fi
            fi

        fi
        print_error "Please upgrade Python to version $REQUIRED_PYTHON_VERSION or higher"
        return 1
    fi

    # Check pip
    PIP_CMD=""
    if command -v pip3 &>/dev/null; then
        PIP_CMD="pip3"
    elif command -v pip &>/dev/null; then
        PIP_CMD="pip"
    fi

    if [[ -z "$PIP_CMD" ]]; then
        print_error "Neither 'pip' nor 'pip3' command found"
        print_info "Install pip for your Python installed"
        return 1
    fi

    print_success "Found $PIP_CMD"
    return 0
}

check_gcp_library() {
    print_section "Checking Google Cloud Python Library"

    # Use the detected Python command
    if [[ -n "$PYTHON_CMD" ]]; then
        if $PYTHON_CMD -c "import google.cloud.secretmanager" 2>/dev/null; then
            print_success "Google Cloud Secret Manager library found"
            return 0
        else
            print_error "Google Cloud Secret Manager library not found"

            if [[ "$PLATFORM" == "mac" ]]; then
                # Check which Python is being used to give targeted advice
                PYTHON3_PATH=$(python3 -c "import sys; print(sys.executable)" 2>/dev/null || echo "unknown")

                if [[ "$PYTHON3_PATH" == "/opt/homebrew/bin/python3" ]]; then
                    print_info "Homebrew Python detected - installing Google Cloud SDK (includes Python libraries)..."
                    if install_package "brew install google-cloud-sdk"; then
                        print_fixed "Google Cloud Secret Manager library installed"
                        return 0
                    else
                        print_info "Install manually: brew install google-cloud-sdk"
                        return 1
                    fi
                else
                    [[ "$PYTHON3_PATH" == "/usr/bin/python3" ]] || [[ "$PYTHON3_PATH" == "/Library/Developer/CommandLineTools/usr/bin/python3" ]]
                    print_info "System Python detected - trying pip with --user flag..."
                    PIP_INSTALL_CMD="pip3 install --user google-cloud-secret-manager"
                    if install_package "$PIP_INSTALL_CMD"; then

                        print_fixed "Google Cloud Secret Manager library installed"
                        return 0
                    else
                        print_info "Install manually: $PIP_INSTALL_CMD"
                        print_info "Or install Google Cloud SDK: brew install google-cloud-sdk"
                        return 1
                    fi
                fi
            else
                PIP_INSTALL_CMD="pip3 install google-cloud-secret-manager"
                print_info "Installing Google Cloud Secret Manager library..."
                if install_package "$PIP_INSTALL_CMD"; then

                    print_fixed "Google Cloud Secret Manager library installed"
                    return 0
                else
                    print_info "Install manually: $PIP_INSTALL_CMD"
                    return 1
                fi
            fi
        fi
    else
        print_error "No Python command available"
        return 1
    fi
}

check_gcloud() {
    print_section "Checking Google Cloud CLI"

    if ! command -v gcloud &>/dev/null; then
        print_error "gcloud CLI not found"
        print_info "Install from: https://cloud.google.com/sdk/docs/install"

        if [[ "$PLATFORM" == "mac" ]]; then
            if command -v brew &>/dev/null; then
                print_info "Installing gcloud CLI via Homebrew..."
                if install_package "brew install google-cloud-sdk"; then
                    print_fixed "gcloud CLI installed"
                else
                    print_info "Install gcloud manually: brew install google-cloud-sdk"
                    return 1
                fi
            else
                print_error "Homebrew not found. Please install manually."
                return 1
            fi
        else
            print_info "Installing gcloud CLI..."
            if install_package "curl https://sdk.cloud.google.com | bash"; then
                print_fixed "gcloud CLI installed"
            else
                print_info "Install gcloud manually: curl https://sdk.cloud.google.com | bash"
                return 1
            fi
        fi
    fi

    print_success "gcloud CLI found"

    # Check authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        print_warning "gcloud not authenticated"

        print_info "Opening gcloud authentication..."
        if install_package "gcloud auth login"; then
            print_fixed "gcloud authentication"
        else
            print_info "Please run: gcloud auth login"
            return 1
        fi
    else
        ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
        print_success "gcloud authenticated as: $ACTIVE_ACCOUNT"
    fi

    return 0
}

check_node_npm() {
    print_section "Checking Node.js and npm"

    if ! command -v node &>/dev/null; then
        print_error "Node.js not found"
        print_info "Install Node.js from https://nodejs.org or use your package manager"

        if [[ "$PLATFORM" == "mac" ]]; then
            if command -v brew &>/dev/null; then
                print_info "Installing Node.js $REQUIRED_NODE_VERSION via Homebrew..."
                if install_package "brew install node@$REQUIRED_NODE_VERSION"; then
                    print_fixed "Node.js installed"
                else
                    print_info "Install manually: brew install node@$REQUIRED_NODE_VERSION"
                    return 1
                fi
            else
                print_error "Homebrew not found. Please install manually."
                return 1
            fi
        else
            print_info "Installing Node.js $REQUIRED_NODE_VERSION..."
            if install_package "curl -fsSL https://deb.nodesource.com/setup_$REQUIRED_NODE_VERSION.x | sudo -E bash - && sudo apt-get install -y nodejs"; then
                print_fixed "Node.js installed"
            else
                print_info "Install manually: curl -fsSL https://deb.nodesource.com/setup_$REQUIRED_NODE_VERSION.x | sudo -E bash - && sudo apt-get install -y nodejs"
                return 1
            fi
        fi
    fi

    NODE_VERSION=$(node --version | sed 's/v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d'.' -f1)

    if ((NODE_MAJOR < REQUIRED_NODE_VERSION)); then
        print_error "Node.js version $NODE_VERSION found, but $REQUIRED_NODE_VERSION+ required"

        if [[ "$PLATFORM" == "mac" ]]; then
            print_info "Upgrading Node.js to version $REQUIRED_NODE_VERSION via Homebrew..."
            if install_package "brew upgrade node@$REQUIRED_NODE_VERSION"; then
                print_fixed "Node.js version upgrade"
            else
                print_info "Upgrade manually: brew upgrade node@$REQUIRED_NODE_VERSION"
                return 1
            fi
        else
            print_info "Please upgrade Node.js to version $REQUIRED_NODE_VERSION or higher"
            return 1
        fi
    fi

    print_success "Node.js $NODE_VERSION found"

    if ! command -v npm &>/dev/null; then
        print_error "npm not found (should come with Node.js)"
        return 1
    fi

    print_success "npm found"
    return 0
}

check_catapulta() {
    print_section "Checking Catapulta"

    if ! command -v catapulta &>/dev/null; then
        print_error "Catapulta not found"

        print_info "Installing Catapulta globally..."
        if install_package "npm install -g catapulta"; then
            print_fixed "Catapulta installed"
            return 0
        else
            print_info "Install manually: npm install -g catapulta"
            return 1
        fi
    fi

    print_success "Catapulta found"
    return 0
}

check_forge() {
    print_section "Checking Foundry/Forge"

    if ! command -v forge &>/dev/null; then
        print_error "Forge not found"
        if ! command -v foundryup &>/dev/null; then
            print_error "Foundryup not found"

            print_info "Installing Foundry..."
            if install_package "curl -L https://foundry.paradigm.xyz | bash"; then
                print_fixed "Foundry installed"

                # Manually add the foundry path to ensure it's available
                if [[ -d "$HOME/.config/.foundry/bin" ]]; then
                    export PATH="$PATH:$HOME/.config/.foundry/bin"
                    print_info "Added $HOME/.config/.foundry/bin to PATH"
                elif [[ -d "$HOME/.foundry/bin" ]]; then
                    export PATH="$PATH:$HOME/.foundry/bin"
                    print_info "Added $HOME/.foundry/bin to PATH"
                fi

                # Check that PATH contains 'foundry'
                if [[ ":$PATH:" != *"foundry"* ]]; then
                    print_warning "PATH does not contain 'foundry'. Foundry tools may not be available in your shell."
                    exit 1
                fi

                # Now try to run foundryup
                print_info "Running foundryup to install Foundry tools..."

                if install_package "foundryup --install $REQUIRED_FORGE_VERSION"; then
                    print_fixed "Foundryup installed"
                else
                    print_error "foundryup --install $REQUIRED_FORGE_VERSION failed"
                    return 1
                fi
            fi
            # Now check forge
            FORGE_VERSION=$(forge --version | head -n1 | awk '{print $3}' | cut -d'-' -f1)

            if [[ $(version_compare "$FORGE_VERSION" "$REQUIRED_FORGE_VERSION") == "$FORGE_VERSION" && "$FORGE_VERSION" != "$REQUIRED_FORGE_VERSION" ]]; then
                print_warning "Forge version $FORGE_VERSION found, but $REQUIRED_FORGE_VERSION+ recommended"
                print_info "Update with: foundryup"
                print_info "Updating Foundry..."
                if install_package "foundryup update && foundryup --install $REQUIRED_FORGE_VERSION"; then
                    FORGE_VERSION=$(forge --version | head -n1 | awk '{print $3}' | cut -d'-' -f1)
                    print_fixed "Forge version upgrade to $FORGE_VERSION"
                else
                    return 1
                fi
            else
                print_success "Forge $FORGE_VERSION found"
            fi

            if ! command -v cast &>/dev/null; then
                print_error "Cast not found (should come with Foundry)"
                print_info "Install Foundry from: https://book.getfoundry.sh/getting-started/installation"
                return 1
            fi

            print_success "Cast found"

        else
            print_info "Install Foundry manually:"
            print_info "  curl -L https://foundry.paradigm.xyz | bash && foundryup --install $REQUIRED_FORGE_VERSION"
            return 1
        fi
    fi

    return 0
}

check_git() {
    print_section "Checking Git"

    if ! command -v git &>/dev/null; then
        print_error "Git not found"
        print_info "Install Git from your package manager"

        if [[ "$PLATFORM" == "mac" ]]; then
            print_info "Installing Git via Homebrew..."
            if install_package "brew install git"; then
                print_fixed "Git installed"
            else
                print_info "Install manually: brew install git"
                return 1
            fi
        else
            print_info "Installing Git via apt..."
            if install_package "sudo apt-get update && sudo apt-get install -y git"; then
                print_fixed "Git installed"
            else
                print_info "Install manually: sudo apt-get install git"
                return 1
            fi
        fi
    fi

    print_success "Git found"
    return 0
}

# =============================================================================
# Package Manager Checks
# =============================================================================

check_package_managers() {
    print_section "Checking Package Managers"

    if [[ "$PLATFORM" == "mac" ]]; then
        if ! command -v brew &>/dev/null; then
            print_error "Homebrew not found (recommended for macOS)"
            print_info "Install from: https://brew.sh"
            print_info "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        else
            print_success "Homebrew found"
        fi
    fi
}

all_checks() {
    print_section "Checking Everything"

    check_package_managers
    check_python
    check_gcp_library
}
# =============================================================================
# Main Execution
# =============================================================================

main() {
    print_header

    echo -e "${YELLOW}Platform detected: $PLATFORM${NC}"
    echo -e "${YELLOW}Required Python version: $REQUIRED_PYTHON_VERSION+${NC}"
    echo -e "${YELLOW}Required Forge version: $REQUIRED_FORGE_VERSION+${NC}"
    echo -e "${YELLOW}Required Node.js version: $REQUIRED_NODE_VERSION+${NC}"
    echo

    if [[ "$PLATFORM" == "mac" ]]; then
        echo -e "${YELLOW}📋 On macOS, you'll be asked before installing anything${NC}"
    else
        echo -e "${YELLOW}📋 On Linux, suggested fixes will be displayed${NC}"
    fi
    echo

    # Check package managers first
    check_package_managers

    # Core dependency checks
    check_python
    if [[ "$PLATFORM" != "mac" ]]; then
        check_gcp_library
    fi
    check_gcloud
    check_node_npm
    check_catapulta
    check_forge
    check_git

    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

    if ((ISSUES_FOUND == 0)); then
        echo -e "${GREEN}🎉 All dependencies are satisfied!${NC}"
        echo -e "${GREEN}You're ready to use the Centrifuge deployment tool.${NC}"
        echo
        echo -e "${BLUE}Next steps:${NC}"
        echo -e "  ${BLUE}•${NC} Run: python3 script/deploy/deploy.py --help"
        echo -e "  ${BLUE}•${NC} Example: python3 script/deploy/deploy.py sepolia deploy:protocol"
    else

        echo -e "${RED}❌ Found $ISSUES_FOUND issue(s) that need attention${NC}"
        echo -e "${YELLOW}Please resolve the issues above before proceeding.${NC}"
        exit 1
    fi
}

# Handle command line arguments
if [[ "${1:-}" == "--auto-fix" ]]; then
    AUTO_FIX=true
    echo -e "${YELLOW}⚡ Auto-fix mode enabled${NC}"
fi

main "$@"
