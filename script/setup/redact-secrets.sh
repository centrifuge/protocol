#!/usr/bin/env bash
#
# Replaces every secret value in .env with a placeholder, in the files given or on stdin.
#
#   ./script/setup/redact-secrets.sh test-output.txt      # rewrites the file in place
#   some-command | ./script/setup/redact-secrets.sh       # filters a stream
#
# The runner's ::add-mask:: only stars secrets out of the live log; it does nothing for a file. So anything
# that gets uploaded as an artifact has to be put through this first. What tends to end up in such a file is
# not a bare key but a whole RPC URL with the key in its path, which forge, cast and anvil print in their
# connection errors.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
    # Nothing to redact against: pass the input through rather than failing a job over it
    if [ "$#" -eq 0 ]; then cat; fi
    exit 0
fi

# awk's index() and substr() match literally, so a value containing regex or glob characters is no risk.
# Values shorter than 8 characters are skipped: too short to be a credential, long enough to appear by
# accident and turn the output into confetti.
redact() {
    awk '
        NR == FNR {
            if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                value = substr($0, index($0, "=") + 1)
                if (length(value) >= 8) values[++count] = value
            }
            next
        }
        {
            for (i = 1; i <= count; i++) {
                while ((at = index($0, values[i])) > 0) {
                    $0 = substr($0, 1, at - 1) "***REDACTED***" substr($0, at + length(values[i]))
                }
            }
            print
        }
    ' "$ENV_FILE" "${1:--}"
}

if [ "$#" -eq 0 ]; then
    redact -
    exit 0
fi

for file in "$@"; do
    [ -f "$file" ] || continue
    redact "$file" > "$file.redacted"
    mv "$file.redacted" "$file"
    printf 'Redacted secrets in %s\n' "$file"
done
