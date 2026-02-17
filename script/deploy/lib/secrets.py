#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Secrets Module

Handles GCP Secret Manager integration and .env secret management.
Can be used standalone (no network required) or by EnvironmentLoader.
"""

import pathlib
import shutil
import subprocess
from .formatter import *


# ---------------------------------------------------------------------------
# GCP secret helpers
# ---------------------------------------------------------------------------

def get_secret(secret_name: str) -> str:
    """Get secret from GCP Secret Manager"""
    try:
        from google.cloud import secretmanager
        use_gcloud_library = True
    except ImportError:
        use_gcloud_library = False

    if use_gcloud_library:
        return _get_secret_with_library(secret_name)
    else:
        return _get_secret_with_cli(secret_name)


def _get_secret_with_library(gcp_secret: str) -> str:
    """Get secret using Google Cloud Secret Manager library"""
    print_info(f"Retrieving {gcp_secret} from Google Secrets using Gcloud library")
    try:
        from google.cloud import secretmanager
        client = secretmanager.SecretManagerServiceClient()
        name = f"projects/centrifuge-production-x/secrets/{gcp_secret}/versions/latest"
        response = client.access_secret_version(request={"name": name})
        secret_value = response.payload.data.decode("UTF-8")
        secret_value = secret_value.replace('\n', '').replace('\r', '').strip()
        return secret_value
    except Exception as e:
        raise RuntimeError(f"Could not fetch {gcp_secret} from Secret Manager: {e}")


def _get_secret_with_cli(gcp_secret: str) -> str:
    """Get secret using gcloud CLI"""
    try:
        subprocess.run(["gcloud", "auth", "list"],
                      capture_output=True, check=True)
        print_info(f"Loading {gcp_secret} from Google Secrets using gcloud CLI")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print_error("GCP CLI not configured or not available")
        raise
    try:
        result = subprocess.run([
            "gcloud", "secrets", "versions", "access", "latest",
            "--project", "centrifuge-production-x",
            "--secret", gcp_secret
        ], capture_output=True, check=True, text=True)
        secret_value = result.stdout.strip()
        secret_value = secret_value.replace('\n', '').replace('\r', '').strip()
        return secret_value
    except subprocess.CalledProcessError:
        raise RuntimeError(f"Could not fetch {gcp_secret} from Secret Manager")


# ---------------------------------------------------------------------------
# dump:secrets (no network required)
# ---------------------------------------------------------------------------

def dump_secrets_to_env(root_dir: pathlib.Path):
    """Fetch secrets from GCP and write them to .env (no network required).

    Preserves any manually-set values already present in .env.
    Does NOT write NETWORK or RPC_URL — those are derived at deploy time.
    """
    print_section("Dumping secrets to .env")

    env_file = root_dir / ".env"
    backup_file = root_dir / ".env.back"

    # Backup existing .env if present
    env_vars: dict[str, str] = {}
    if env_file.exists():
        print_warning("Existing .env found, backing up to .env.back")
        shutil.copy(env_file, backup_file)
        with open(env_file, "r") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    env_vars[k] = v

    # Secrets to fetch: env-var-name → GCP secret name
    secrets = {
        "ETHERSCAN_API_KEY": "etherscan_api",
        "ALCHEMY_API_KEY": "alchemy_api",
        "PLUME_API_KEY": "plume_api",
        "PRIVATE_KEY": "testnet-private-key",
    }

    for env_key, gcp_name in secrets.items():
        if env_key in env_vars:
            print_info(f"{env_key} already in .env, keeping existing value")
            continue
        try:
            print_step(f"Fetching {env_key}")
            env_vars[env_key] = get_secret(gcp_name)
            print_success(f"{env_key} loaded")
        except Exception as e:
            print_warning(f"Could not fetch {env_key}: {e}")

    # Remove stale keys that are no longer written by this tool
    for stale_key in ("NETWORK", "RPC_URL"):
        if stale_key in env_vars:
            print_info(f"Removing stale {stale_key} from .env")
            del env_vars[stale_key]

    with open(env_file, "w") as f:
        for k, v in env_vars.items():
            f.write(f"{k}={v}\n")

    print_success("Secrets written to .env")
