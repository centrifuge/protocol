#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Configuration Loader

Handles network configuration loading, GCP Secret Manager integration,
and environment variable setup for different deployment networks.
"""

import json
import subprocess
import pathlib

from .formatter import Formatter


class EnvironmentLoader:
    def __init__(self, network_name: str, root_dir: pathlib.Path):
        self.network_name = network_name
        self.root_dir = root_dir
        self.config_file = root_dir / "env" / f"{network_name}.json"
        # Initialize private attributes that will be set during loading
        self._rpc_url = None
        self._private_key = None
        self._etherscan_api_key = None
        self._admin_address = None
        Formatter.print_subsection("Loading network configuration")
        self._load_config()

    def _load_config(self):
        if not self.config_file.exists():
            raise FileNotFoundError(f"Network config file {self.config_file} not found")
        else:
            with open(self.config_file, 'r') as f:
                self.config = json.load(f)
    @property
    def etherscan_api_key(self) -> str:
        if self._etherscan_api_key is None:
            Formatter.print_info("Loading Etherscan API Key")
            self._etherscan_api_key = self._get_secret("etherscan_api")
            Formatter.print_success("Etherscan API key loaded")
        return self._etherscan_api_key
    
    @property
    def rpc_url(self) -> str:
        if self._rpc_url is None:
            self._rpc_url = self._setup_rpc()
        return self._rpc_url
    
    @property
    def private_key(self) -> str:
        if not self.is_testnet:
            raise ValueError("Private key is not needed for non-testnet networks")
        if self._private_key is None:
            Formatter.print_step("Loading Testnet Private Key")
            self._private_key = self._get_secret("testnet-private-key")
            Formatter.print_success("Private key loaded")
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
        Formatter.print_step("Loading Admin Address")
        if self.is_testnet:
            admin_address = "0x423420Ae467df6e90291fd0252c0A8a637C1e03f"  # Testnet Safe
        else:
            # Mainnet addresses
            mainnet_admins = {
                "ethereum": "0xD9D30ab47c0f096b0AA67e9B8B1624504a63e7FD",
                "base": "0x8b83962fB9dB346a20c95D98d4E312f17f4C0d9b",
                "celo": "0x2464f95F6901233bF4a0130A3611d5B4CBd83195",
                "arbitrum": "0xa36caE0ACd40C6BbA61014282f6AE51c7807A433"
            }
            
            if self.network_name not in mainnet_admins:
                raise ValueError(f"Unknown mainnet network: {self.network_name}")
            admin_address = mainnet_admins[self.network_name]

        Formatter.print_success(f"Admin address loaded: {admin_address}")
        return admin_address

    def _setup_rpc(self) -> str:
        """Setup and test RPC URL"""
        Formatter.print_step("Guessing RPC URL")
        
        # Special case for Plume
        if self.network_name == "plume":
            if self.is_testnet:
                rpc_url = "https://testnet-rpc.plume.org"
            else:
                rpc_url = "https://mainnet-rpc.plume.org"
            Formatter.print_info("Using Plume RPC endpoint")
        else:
            # Use Alchemy for other networks
            rpc_url = self.get_alchemy_rpc_url(self.network_name)
            Formatter.print_info("Using Alchemy RPC endpoint")
        
        # Test the connection
        try:
            subprocess.run([
                "cast", "block", "latest", "--rpc-url", rpc_url
            ], capture_output=True, check=True, timeout=10)
            Formatter.print_success(f"RPC connection verified")
            return rpc_url
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            raise RuntimeError(f"RPC connection failed. URL: {rpc_url}.")


    def get_alchemy_rpc_url(self, network_name: str) -> str:
        """Get Alchemy RPC URL for the network"""
        api_key = self._get_secret("alchemy_api")

        # Map network names to Alchemy identifiers
        network_mapping = {
            "ethereum": "eth",
            "arbitrum": "arb",
            "base": "base",
            "celo": "celo"
        }        
        if self.is_testnet:
            if network_name == "sepolia":
                prefix = "ethereum"
            elif network_name == "celo":
                 return f"https://{alchemy_network}-alfajores.g.alchemy.com/v2/{api_key}"
            else:
                prefix = network_name.removesuffix("-sepolia")
            alchemy_network = network_mapping[prefix]
            return f"https://{alchemy_network}-sepolia.g.alchemy.com/v2/{api_key}"
        else:
            alchemy_network = network_mapping[network_name]
            return f"https://{alchemy_network}-mainnet.g.alchemy.com/v2/{api_key}"

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
        Formatter.print_info(f"Retrieving {gcp_secret} from Google Secrets using Gcloud library")
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
            Formatter.print_info(f"Loading {gcp_secret} from Google Secrets using gcloud CLI")
        except (subprocess.CalledProcessError, FileNotFoundError):
            Formatter.print_error("GCP CLI not configured or not available")
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