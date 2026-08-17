#!/usr/bin/env bash
#
# Fetches the deploy secrets from Google Secret Manager into .env, which forge loads by itself. Values
# already in .env are kept, so a locally overridden key survives a re-run.
#
#   ./script/setup/load-secrets.sh
#
# Needs the gcloud CLI, authenticated (`gcloud auth login`) with access to the project below.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROJECT="${GCP_PROJECT:-centrifuge-production-x}"
ENV_FILE=".env"

# Local variable name, then the secret it comes from
SECRETS="
ETHERSCAN_API_KEY:protocol-etherscan-api
PRIVATE_KEY:protocol-testnet-private-key
ALCHEMY_API_KEY:protocol-alchemy-api
PLUME_API_KEY:protocol-plume-api
PHAROS_API_KEY:protocol-pharos-api
"

say() { printf '▸ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

command -v gcloud >/dev/null || die "gcloud is not installed. See https://cloud.google.com/sdk/docs/install"

# Asks for a token rather than just listing accounts: an account can be configured while its credentials
# have expired, and that only shows up as every secret mysteriously failing to fetch
gcloud auth print-access-token >/dev/null 2>&1 \
    || die "gcloud credentials are missing or expired. Run: gcloud auth login"

present() { [ -f "$ENV_FILE" ] && grep -q "^$1=" "$ENV_FILE"; }

for entry in $SECRETS; do
    name="${entry%%:*}"
    secret="${entry##*:}"

    if present "$name"; then
        say "$name is already in $ENV_FILE, keeping it"
        continue
    fi

    # gcloud's own error is left visible: "secret does not exist" and "credentials expired" need very
    # different fixes, and swallowing both behind one message sends people the wrong way
    if value="$(gcloud secrets versions access latest --project "$PROJECT" --secret "$secret")"; then
        # Secret payloads often carry a trailing newline, which would otherwise land inside the value
        printf '%s=%s\n' "$name" "$(printf '%s' "$value" | tr -d '\r\n')" >> "$ENV_FILE"
        say "$name loaded"
    else
        warn "Could not fetch $name from secret '$secret' (see the error above). Set it in $ENV_FILE by hand"
    fi
done

# Registers every value with the runner so it is starred out of the log from here on. Done here rather than
# in each workflow because this is the point where the values are known: a workflow that loads secrets then
# forgets to mask them leaks silently, and that had already happened once.
#
# Worth masking even though nothing here prints a secret: forge, cast and anvil put the resolved RPC URL,
# API key included, into their connection errors. Note that this only covers the log — it does nothing for a
# file an artifact upload might carry, which is what redact-secrets.sh is for.
mask_for_runner() {
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    [ -f "$ENV_FILE" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in '' | \#*) continue ;; esac
        [ -n "$value" ] && printf '::add-mask::%s\n' "$value"
    done < "$ENV_FILE"
}

mask_for_runner

printf '✓ Secrets are in %s\n' "$ENV_FILE"
