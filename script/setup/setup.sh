#!/usr/bin/env bash
#
# Checks the tools a deployment needs, and offers to install what is missing.
#
#   ./script/setup/setup.sh [--auto-fix]
#
# --auto-fix installs without asking, which is what CI wants. On Linux and in CI it is implied.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Read from what CI installs, rather than named again here: a second constant is a second thing to bump, and
# the one that gets forgotten is the one that lets a laptop meter gas differently from the pipeline. Empty if
# the file is not there, which check_foundry below reports.
REQUIRED_FORGE_VERSION="$(
    sed -n 's/^[[:space:]]*version:[[:space:]]*v\{0,1\}\([0-9][0-9.]*\).*/\1/p' \
        "$ROOT/.github/workflows/ci.yml" 2>/dev/null | head -n1
)"

# Not a convenience: JsonRegistry re-prints the whole network config through jq, and before 1.7 jq parses
# every number into a double, so a chainSelector like 5009297550715157269 comes back as 5009297550715157000
# — a silently wrong Chainlink route committed to env/<environment>/<network>.json. 1.7 keeps the literal it did not touch.
REQUIRED_JQ_VERSION="1.7"

case "${OSTYPE:-}" in
    darwin*) PLATFORM=mac ;;
    linux*) PLATFORM=linux ;;
    *) echo "Unsupported platform: ${OSTYPE:-unknown}" >&2; exit 1 ;;
esac

AUTO_FIX=false
[ "${1:-}" = "--auto-fix" ] && AUTO_FIX=true
[ "$PLATFORM" = linux ] && AUTO_FIX=true
[ -n "${CI_MODE:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] && AUTO_FIX=true

ISSUES=0

if [ -t 1 ]; then
    BLUE=$'\033[0;34m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; OFF=$'\033[0m'
else
    BLUE=""; GREEN=""; YELLOW=""; RED=""; OFF=""
fi

section() { printf '%s▶ %s%s\n' "$BLUE" "$*" "$OFF"; }
ok() { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$YELLOW" "$OFF" "$*"; }
bad() { printf '  %s✗%s %s\n' "$RED" "$OFF" "$*"; ISSUES=$((ISSUES + 1)); }
fixed() { printf '  %s✓%s %s (installed)\n' "$GREEN" "$OFF" "$*"; ISSUES=$((ISSUES - 1)); }

# True when the version in $2 is at least $1: sort -V puts the lower first, so the required one leading
# means we are at or above it
at_least() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# Runs an install command, asking first unless we are fixing automatically
install() {
    local what="$1" command="$2"
    printf '    %s\n' "$command"
    if ! $AUTO_FIX; then
        printf '  Install %s? (y/N): ' "$what"
        read -r answer
        case "$answer" in [yY] | [yY][eE][sS]) ;; *) return 1 ;; esac
    fi
    eval "$command"
}

# Anything installable by a one-liner on both platforms
check_tool() {
    local tool="$1" mac_pkg="$2" apt_pkg="$3"
    section "Checking $tool"

    if command -v "$tool" >/dev/null; then
        ok "$tool found"
        return 0
    fi

    bad "$tool not found"
    if [ "$PLATFORM" = mac ]; then
        install "$tool" "brew install $mac_pkg" && fixed "$tool"
    else
        install "$tool" "sudo apt-get update && sudo apt-get install -y $apt_pkg" && fixed "$tool"
    fi
}

check_homebrew() {
    [ "$PLATFORM" = mac ] || return 0
    section "Checking Homebrew"
    if command -v brew >/dev/null; then
        ok "Homebrew found"
    else
        bad "Homebrew not found. Install it from https://brew.sh, then run this again"
    fi
}

check_jq() {
    section "Checking jq"

    if ! command -v jq >/dev/null; then
        bad "jq not found"
        if [ "$PLATFORM" = mac ]; then
            install "jq" "brew install jq" && fixed "jq"
        else
            install "jq" "sudo apt-get update && sudo apt-get install -y jq" && fixed "jq"
        fi
        command -v jq >/dev/null || return 1
    fi

    local version
    # "jq-1.7.1-apple" -> 1.7.1
    version="$(jq --version | sed 's/^jq-//' | cut -d- -f1)"
    if [ -z "$version" ]; then
        warn "Could not read the jq version from: $(jq --version)"
        return 0
    fi

    if at_least "$REQUIRED_JQ_VERSION" "$version"; then
        ok "jq $version (>= $REQUIRED_JQ_VERSION)"
    else
        bad "jq $version loses precision on the large numbers in env/<environment>/<network>.json; $REQUIRED_JQ_VERSION or newer is required"
        if [ "$PLATFORM" = mac ]; then
            install "a newer jq" "brew upgrade jq" && fixed "jq"
        else
            install "a newer jq" "sudo apt-get update && sudo apt-get install -y jq" && fixed "jq"
        fi
    fi
}

check_foundry() {
    section "Checking Foundry"

    local missing=""
    for tool in forge anvil cast; do
        command -v "$tool" >/dev/null || missing="$missing $tool"
    done

    if [ -n "$missing" ]; then
        bad "Missing Foundry tools:$missing"
        if install "Foundry" "curl -L https://foundry.paradigm.xyz | bash && \"\$HOME/.foundry/bin/foundryup\""; then
            export PATH="$PATH:$HOME/.foundry/bin"
            fixed "Foundry"
        else
            return 1
        fi
    fi

    if [ -z "$REQUIRED_FORGE_VERSION" ]; then
        warn "Could not read the pinned version from .github/workflows/ci.yml; skipping the check"
        return 0
    fi

    local version
    # "forge Version: 1.4.4-v1.4.4" -> 1.4.4
    version="$(forge --version | head -n1 | awk '{print $3}' | cut -d- -f1 | tr -d 'v')"
    if [ -z "$version" ]; then
        warn "Could not read the forge version from: $(forge --version | head -n1)"
        return 0
    fi
    if at_least "$REQUIRED_FORGE_VERSION" "$version"; then
        ok "forge $version (>= $REQUIRED_FORGE_VERSION)"
    else
        warn "forge $version is older than the expected $REQUIRED_FORGE_VERSION"
        install "a Foundry update" "foundryup" && ok "forge updated"
    fi
}

check_gcloud() {
    section "Checking Google Cloud CLI"

    if ! command -v gcloud >/dev/null; then
        bad "gcloud not found"
        if [ "$PLATFORM" = mac ]; then
            install "gcloud" "brew install --cask gcloud-cli" && fixed "gcloud"
        else
            install "gcloud" "curl -sSL https://sdk.cloud.google.com | bash" && fixed "gcloud"
        fi
        command -v gcloud >/dev/null || return 1
    else
        ok "gcloud found"
    fi

    # An account can be configured while its credentials have expired, which only shows up later as every
    # secret failing to load, so ask for a token rather than just listing accounts
    if gcloud auth print-access-token >/dev/null 2>&1; then
        ok "gcloud authenticated as $(gcloud config get-value account 2>/dev/null)"
    elif $AUTO_FIX; then
        # CI authenticates through workload identity federation before it gets here
        warn "No usable gcloud credentials. In CI this comes from workload identity federation"
    else
        bad "gcloud credentials are missing or expired. Run: gcloud auth login"
    fi
}

section "Centrifuge deployment setup ($PLATFORM)"
echo

check_homebrew
check_tool git git git
check_tool curl curl curl
check_jq
check_foundry
check_gcloud

echo
if [ "$ISSUES" -le 0 ]; then
    printf '%sEverything needed is in place.%s\n\n' "$GREEN" "$OFF"
    echo "Next:"
    echo "  ./script/setup/load-secrets.sh              # fetch secrets into .env"
    echo "  EXECUTORS=<address> forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url sepolia --broadcast"
    echo "  # ...see script/deploy/README.md for the full cookbook"
else
    printf '%s%s issue(s) need attention.%s\n' "$RED" "$ISSUES" "$OFF"
    exit 1
fi
