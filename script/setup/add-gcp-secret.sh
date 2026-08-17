#!/usr/bin/env bash
# Add or update a secret in Google Cloud Secret Manager (centrifuge-production-x).
# Used for deploy secrets such as plume_api, pharos_api, alchemy_api, etherscan_api, testnet-private-key.
#
# Usage:
#   ./add-gcp-secret.sh SECRET_NAME
#     (interactive: prompts for value with hidden input; Enter is fine, trailing \n is stripped)
#   echo "your-api-key" | ./add-gcp-secret.sh plume_api
#   ./add-gcp-secret.sh pharos_api < /path/to/key.txt
#   (Trailing newlines from stdin are always stripped.)
#
# Requires: gcloud CLI, authenticated and allowed to access project centrifuge-production-x.

set -euo pipefail

PROJECT="${GCP_PROJECT:-centrifuge-production-x}"
SECRET_NAME="${1:-}"

if [[ -z "$SECRET_NAME" ]]; then
  echo "Usage: $0 SECRET_NAME"
  echo "  Secret value is read from stdin. Example:"
  echo "  echo -n 'your-api-key' | $0 plume_api"
  exit 1
fi

if ! command -v gcloud &>/dev/null; then
  echo "Error: gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"
  exit 1
fi

# Create secret if it doesn't exist (ignore error if already exists)
if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT" &>/dev/null; then
  echo "Creating secret: $SECRET_NAME"
  gcloud secrets create "$SECRET_NAME" --project="$PROJECT" --replication-policy="automatic"
fi

# Strip trailing newline/carriage return so Enter or "echo key" never corrupts the secret
trim_secret() {
  local v="$1"
  v="${v%$'\n'}"
  v="${v%$'\r'}"
  printf '%s' "$v"
}

if [[ -t 0 ]]; then
  read -r -s -p "Enter secret value (input hidden): " secret_value
  echo
  if [[ -z "${secret_value:-}" ]]; then
    echo "Error: empty value. Aborting."
    exit 1
  fi
  trim_secret "$secret_value" | gcloud secrets versions add "$SECRET_NAME" --project="$PROJECT" --data-file=-
else
  echo "Adding new version to secret: $SECRET_NAME (project: $PROJECT)"
  secret_value=$(cat)
  trim_secret "$secret_value" | gcloud secrets versions add "$SECRET_NAME" --project="$PROJECT" --data-file=-
fi

echo "Done. Deploy scripts will use the latest version when fetching $SECRET_NAME."
