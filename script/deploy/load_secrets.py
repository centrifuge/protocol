#!/usr/bin/env python3

# Fetch secrets from GCP and write them to .env (no network required)
import pathlib
from lib.secrets import dump_secrets_to_env

root_dir = pathlib.Path(__file__).parent.parent.parent
dump_secrets_to_env(root_dir)
