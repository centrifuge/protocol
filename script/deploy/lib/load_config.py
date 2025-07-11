#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Configuration Loader

Handles network configuration loading, GCP Secret Manager integration,
and environment variable setup for different deployment networks.
"""

import json
import subprocess
import pathlib
import shutil
from .formatter import *
import os
import argparse

class EnvironmentLoader:
    def __init__(self, network_name: str, root_dir: pathlib.Path, args: argparse.Namespace):
        self.network_name = network_name
        self.root_dir = root_dir
        self.config_file = root_dir / "env" / f"{network_name}.json"
        # Initialize private attributes that will be set during loading
        self._rpc_url = None
        self._private_key = None
        self._etherscan_api_key = None
        self._admin_address = None
        print_subsection("Loading network configuration")
        self._load_config()
        self.args = args

    def dump_config(self):
        print_info("Dumping config to .env")
        import os

        env_file = ".env"
        backup_file = ".env.back"

        # Backup existing .env if it exists
        if os.path.exists(env_file):
            print_warning("Existing .env found, backing up to .env.back")
            shutil.copy(env_file, backup_file)
            # Load existing .env into a dict
            with open(env_file, "r") as f:
                lines = f.readlines()
            env_vars = {}
            for line in lines:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    env_vars[k] = v
        else:
            env_vars = {}

        # Update or add the relevant keys
        env_vars["ETHERSCAN_API_KEY"] = self.etherscan_api_key
        env_vars["ADMIN"] = self.admin_address
        env_vars["PRIVATE_KEY"] = self.private_key
        env_vars["RPC_URL"] = self.rpc_url

        # Write back to .env (preserving order if possible, otherwise sorted)
        with open(env_file, "w") as f:
            for k, v in env_vars.items():
                f.write(f"{k}={v}\n")
        print_success("Config written to .env")

    def _check_env_file(self, variable_name: str):
        if os.path.exists(".env"):
            with open(".env", "r") as f:
                for line in f:
                    if line.startswith(f"{variable_name}="):
                        print_warning(f"Using {variable_name} from .env")
                        return line.split("=")[1].strip()
                    
    def _load_config(self):
        if not self.config_file.exists():
            raise FileNotFoundError(f"Network config file {self.config_file} not found")
        else:
            with open(self.config_file, 'r') as f:
                self.config = json.load(f)
    @property
    def etherscan_api_key(self) -> str:
        if self.args.catapulta or "--verifier-url" in self.args.forge_args:
            return None
        if self._etherscan_api_key is None:
            print_info("Loading Etherscan API Key")
            self._etherscan_api_key = self._get_secret("etherscan_api")
            print_success("Etherscan API key loaded")
        return self._etherscan_api_key
    
    @property
    def rpc_url(self) -> str:
        if self.args.catapulta:
            return None
        if self._rpc_url is None:
            if not self._check_env_file("RPC_URL"):
                self._rpc_url = self._setup_rpc()
            else:
                self._rpc_url = self._check_env_file("RPC_URL")
        return self._rpc_url
    
    @property
    def private_key(self) -> str:
        if  self._private_key is None:
            # If it's ledger property.private_key==null
            if self.args.ledger:
                self._private_key = None
            # Otherwise try to load from .env
            elif private_key := self._check_env_file("PRIVATE_KEY"):
                if not self.is_testnet and not "tenderly" in self.rpc_url:
                    print_warning("Are you sure you want to deploy to mainnet with the PRIVATE_KEY from .env?")
                    response = input("Do you want to continue? [y/N]: ").strip().lower()
                    if response not in ("y", "yes"):
                        print_info("Please remove the PRIVATE_KEY from .env and try again.")
                        print_error("Aborted by user.")
                        raise SystemExit(1)
                self._private_key = private_key
            # Finally load from GCP secrets
            else:
                if not self.is_testnet:
                    print_error("Aborting deployment. Testnet private key cannot be used for mainnet")
                    raise ValueError(f"Tried to access testnet private key. This should not happen when deploying to {self.network_name}")
                print_step("Loading Testnet Private Key")
                self._private_key = self._get_secret("testnet-private-key")
                print_success("Private key loaded")
        return self._private_key
    
    @property
    def admin_address(self) -> str:
        if self._admin_address is None:
            self._admin_address = self._get_admin_address()
        return self._admin_address

    @property
    def chain_id(self) -> str:
        return str(self.config["network"]["chainId"])

    @property
    def is_testnet(self) -> bool:
        return self.config["network"]["environment"] == "testnet"

    def _get_admin_address(self) -> str:
        """Get admin address based on network type"""
        print_step("Loading Admin Address")

        if admin_address := self._check_env_file("ADMIN"):
            return admin_address
        
        if self.is_testnet:
            admin_address = "0x423420Ae467df6e90291fd0252c0A8a637C1e03f"
        else:
            admin_address = self.config["network"]["safeAdmin"]

        print_success(f"Admin address loaded: {format_account(admin_address)}")
        return admin_address

    def _setup_rpc(self) -> str:
        """Setup and test RPC URL"""
        if rpc_url := self._check_env_file("RPC_URL"):
            return rpc_url
        
        print_step("Guessing RPC URL")
        
        # Special case for Plume
        if self.network_name == "plume":
            if self.is_testnet:
                rpc_url = "https://testnet-rpc.plume.org"
            else:
                rpc_url = "https://mainnet-rpc.plume.org"
            print_info("Using Plume RPC endpoint")
        else:
            # Use Alchemy for other networks
            rpc_url = self.get_alchemy_rpc_url(self.network_name)
            print_info("Using Alchemy RPC endpoint")
        
        # Test the connection
        try:
            subprocess.run([
                "cast", "block", "latest", "--rpc-url", rpc_url
            ], capture_output=True, check=True, timeout=10)
            print_success(f"RPC connection verified")
            return rpc_url
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            raise RuntimeError(f"RPC connection failed. URL: {rpc_url}.")


    def get_alchemy_rpc_url(self, network_name: str) -> str:
        """Get Alchemy RPC URL for the network"""
        api_key = self._get_secret("alchemy_api")

        # Load network mapping from config file
        network_mapping_file = self.root_dir / "script" / "deploy" / "config" / "alchemy_networks.json"
        
        if not network_mapping_file.exists():
            raise FileNotFoundError(f"Network mapping file not found: {network_mapping_file}")
        
        with open(network_mapping_file, 'r') as f:
            config = json.load(f)
        
        # Determine which mapping to use
        if self.is_testnet:
            network_mapping = config.get("testnet", {})
        else:
            network_mapping = config.get("mainnet", {})
        
        # Get the Alchemy network identifier
        if network_name not in network_mapping:
            raise ValueError(f"Unknown network: {network_name} (testnet: {self.is_testnet})")
        
        alchemy_network = network_mapping[network_name]
        return f"https://{alchemy_network}.g.alchemy.com/v2/{api_key}"

    def _get_secret(self, secret_name: str) -> str:
        """Get secret from GCP Secret Manager"""
        # Try to import gcloud library, fall back to subprocess if not available
        try:
            from google.cloud import secretmanager
            use_gcloud_library = True
        except ImportError:
            use_gcloud_library = False

        if use_gcloud_library:
            return self._get_secret_with_library(secret_name)
        else:
            return self._get_secret_with_cli(secret_name)

    def _get_secret_with_library(self, gcp_secret: str) -> str:
        """Get secret using Google Cloud Secret Manager library"""
        print_info(f"Retrieving {gcp_secret} from Google Secrets using Gcloud library")
        try:
            from google.cloud import secretmanager
            client = secretmanager.SecretManagerServiceClient()
            name = f"projects/centrifuge-production-x/secrets/{gcp_secret}/versions/latest"
            response = client.access_secret_version(request={"name": name})
            return response.payload.data.decode("UTF-8")
        except Exception as e:
            raise RuntimeError(f"Could not fetch {gcp_secret} from Secret Manager: {e}")

    def _get_secret_with_cli(self, gcp_secret: str) -> str:
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
            return result.stdout.strip()
        except subprocess.CalledProcessError:
            raise RuntimeError(f"Could not fetch {gcp_secret} from Secret Manager") 