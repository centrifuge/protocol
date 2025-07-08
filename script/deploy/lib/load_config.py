#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Configuration Loader

Handles network configuration loading, GCP Secret Manager integration,
and environment variable setup for different deployment networks.
"""

import json
import subprocess
import pathlib
from typing import Dict
from .formatter import Formatter


class EnvironmentLoader:
    def __init__(self, network_name: str, root_dir: pathlib.Path, use_ledger: bool, catapulta_mode: bool):
        self.network_name = network_name
        self.root_dir = root_dir
        self.config_file = root_dir / "env" / f"{network_name}.json"
        self.env_vars: Dict[str, str] = {}
        
        Formatter.print_section("Loading network configuration")
        
        # Try to import gcloud library, fall back to subprocess if not available
        try:
            from google.cloud import secretmanager
            self.secret_client = secretmanager.SecretManagerServiceClient()
            self.use_gcloud_library = True
            Formatter.print_info("Using Google Cloud Secret Manager library")
        except ImportError:
            self.secret_client = None
            self.use_gcloud_library = False
            Formatter.print_info("Using gcloud CLI for secret management")
        
        # Load network configuration immediately
        if not self.config_file.exists():
            raise FileNotFoundError(f"Network config file {self.config_file} not found")
        
        with open(self.config_file, 'r') as f:
            self.config = json.load(f)
        # Set up basic network variables and admin address
        self.env_vars.update({
            "CHAIN_ID": self.chain_id,
            "IS_TESTNET": str(self.is_testnet).lower(),
            "ADMIN": self.get_admin_address(),
            "NETWORK": self.network_name
        })

        # If not using ledger, load private key from GCP
        if not use_ledger and self.is_testnet:
            Formatter.print_step("Loading Testnet Private Key")
            self.env_vars["PRIVATE_KEY"] = self._get_secret("testnet-private-key")
            Formatter.print_success("Private key loaded")
        
        # If not using catapulta, load etherscan and RPC
        if not catapulta_mode:
            self._setup_rpc() 
            
        Formatter.print_step("Loading Etherscan API Key")
        self.env_vars["ETHERSCAN_API_KEY"] = self._get_secret("etherscan_api")
        Formatter.print_success("Etherscan API key loaded")

    @property
    def chain_id(self) -> str:
        return str(self.config["network"]["chainId"])

    @property
    def is_testnet(self) -> bool:
        return self.config["network"]["environment"] == "testnet"

    @property
    def contracts(self) -> Dict[str, str]:
        return self.config.get("contracts", {})

    def get_admin_address(self) -> str:
        """Get admin address based on network type"""
        if self.is_testnet:
            return "0x423420Ae467df6e90291fd0252c0A8a637C1e03f"  # Testnet Safe
        
        # Mainnet addresses
        mainnet_admins = {
            "ethereum": "0xD9D30ab47c0f096b0AA67e9B8B1624504a63e7FD",
            "base": "0x8b83962fB9dB346a20c95D98d4E312f17f4C0d9b",
            "celo": "0x2464f95F6901233bF4a0130A3611d5B4CBd83195",
            "arbitrum": "0xa36caE0ACd40C6BbA61014282f6AE51c7807A433"
        }
        
        network_id = self.config["network"]["network"]
        if network_id not in mainnet_admins:
            raise ValueError(f"Unknown mainnet network: {network_id}")
        
        return mainnet_admins[network_id]

    def _setup_rpc(self):
        """Setup and test RPC URL"""
        Formatter.print_step("Setting up RPC Connection")
        
        # Special case for Plume
        if self.network_name == "plume":
            if self.is_testnet:
                rpc_url = "https://testnet-rpc.plume.org"
            else:
                rpc_url = "https://mainnet-rpc.plume.org"
            Formatter.print_info("Using Plume RPC endpoint")
        else:
            # Use Alchemy for other networks
            rpc_url = self._get_alchemy_rpc_url()
            Formatter.print_info("Using Alchemy RPC endpoint")
        
        # Test the connection
        if self._test_rpc_connection(rpc_url):
            self.env_vars["RPC_URL"] = rpc_url
            Formatter.print_success("RPC connection verified")
        else:
            raise RuntimeError(f"RPC connection failed for {rpc_url}")

    def _get_alchemy_rpc_url(self) -> str:
        """Get Alchemy RPC URL for the network"""
        api_key = self._get_secret("alchemy_api")
        network_id = self.config["network"]["network"]
        
        # Map network names to Alchemy identifiers
        network_mapping = {
            "ethereum": "eth",
            "arbitrum": "arb", 
            "base": "base",
            "celo": "celo"
        }
        
        if network_id not in network_mapping:
            raise ValueError(f"Unsupported network for Alchemy: {network_id}")
        
        alchemy_network = network_mapping[network_id]
        
        if self.is_testnet:
            if alchemy_network == "celo":
                return f"https://{alchemy_network}-alfajores.g.alchemy.com/v2/{api_key}"
            else:
                return f"https://{alchemy_network}-sepolia.g.alchemy.com/v2/{api_key}"
        else:
            return f"https://{alchemy_network}-mainnet.g.alchemy.com/v2/{api_key}"

    def _test_rpc_connection(self, rpc_url: str) -> bool:
        """Test RPC connection"""
        try:
            subprocess.run([
                "cast", "block", "latest", "--rpc-url", rpc_url
            ], capture_output=True, check=True, timeout=10)
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return False

    def _get_secret(self, secret_name: str) -> str:
        """Get secret from GCP Secret Manager"""
        if not secret_name:
            raise ValueError(f"Unknown secret: {secret_name}")

        if self.use_gcloud_library:
            return self._get_secret_with_library(secret_name)
        else:
            return self._get_secret_with_cli(secret_name)

    def _get_secret_with_library(self, gcp_secret: str) -> str:
        """Get secret using Google Cloud Secret Manager library"""
        try:
            name = f"projects/centrifuge-production-x/secrets/{gcp_secret}/versions/latest"
            response = self.secret_client.access_secret_version(request={"name": name})
            return response.payload.data.decode("UTF-8")
        except Exception as e:
            raise RuntimeError(f"Could not fetch {gcp_secret} from Secret Manager: {e}")

    def _get_secret_with_cli(self, gcp_secret: str) -> str:
        """Get secret using gcloud CLI"""
        try:
            subprocess.run(["gcloud", "auth", "list"], 
                         capture_output=True, check=True)
            Formatter.print_success(f"Loading {gcp_secret} from Secret Manager")
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