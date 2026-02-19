#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Configuration Loader

Handles network configuration loading, GCP Secret Manager integration,
and environment variable setup for different deployment networks.
"""

import json
import subprocess
import pathlib
from .formatter import *
from .secrets import get_secret
import os
import argparse

class EnvironmentLoader:
    def __init__(self, network_name: str, root_dir: pathlib.Path, args: argparse.Namespace):
        self.network_name = network_name
        self.root_dir = root_dir
        self.config_file = root_dir / "env" / f"{network_name}.json"
        self._rpc_url = None
        self._private_key = None
        self._etherscan_api_key = None
        self._protocol_admin_address = None
        self._ops_admin_address = None
        self.args = args
        print_subsection("Loading network configuration")
        self._load_config()

    def _load_config(self):
        if not self.config_file.exists():
            raise FileNotFoundError(f"Network config file {self.config_file} not found")
        with open(self.config_file, 'r') as f:
            self.config = json.load(f)

    # -- Properties ----------------------------------------------------------

    @property
    def etherscan_api_key(self) -> str:
        if self.args.catapulta or "--verifier-url" in self.args.forge_args:
            return None
        if self._etherscan_api_key is None:
            env_val = os.environ.get("ETHERSCAN_API_KEY")
            if env_val:
                self._etherscan_api_key = env_val
            else:
                print_info("Loading Etherscan API Key from GCP")
                self._etherscan_api_key = get_secret("etherscan_api")
            print_success("Etherscan API key loaded")
        return self._etherscan_api_key

    @property
    def rpc_url(self) -> str:
        if self.args.catapulta:
            return None
        if self._rpc_url is None:
            self._rpc_url = self._setup_rpc()
        return self._rpc_url

    @property
    def private_key(self) -> str:
        if self._private_key is None:
            if self.args.ledger:
                self._private_key = None
            else:
                env_val = os.environ.get("PRIVATE_KEY")
                if env_val:
                    if not self.is_testnet and "tenderly" not in self.rpc_url:
                        print_warning("Are you sure you want to deploy to mainnet with the PRIVATE_KEY from env?")
                        response = input("Do you want to continue? [y/N]: ").strip().lower()
                        if response not in ("y", "yes"):
                            print_info("Please remove the PRIVATE_KEY and try again.")
                            print_error("Aborted by user.")
                            raise SystemExit(1)
                    self._private_key = env_val
                else:
                    if not self.is_testnet:
                        print_error("Aborting deployment. Testnet private key cannot be used for mainnet")
                        raise ValueError(
                            f"Tried to access testnet private key. "
                            f"This should not happen when deploying to {self.network_name}"
                        )
                    print_step("Loading Testnet Private Key from GCP")
                    self._private_key = get_secret("testnet-private-key")
                    print_success("Private key loaded")
        return self._private_key

    @property
    def protocol_admin_address(self) -> str:
        if self._protocol_admin_address is None:
            self._protocol_admin_address = self._get_protocol_admin_address()
        return self._protocol_admin_address

    @property
    def ops_admin_address(self) -> str:
        if self._ops_admin_address is None:
            self._ops_admin_address = self._get_ops_admin_address()
        return self._ops_admin_address

    @property
    def chain_id(self) -> str:
        return str(self.config["network"]["chainId"])

    @property
    def is_testnet(self) -> bool:
        return self.config["network"]["environment"] == "testnet"

    # -- Internals -----------------------------------------------------------

    def _get_protocol_admin_address(self) -> str:
        """Get protocol admin address based on network type"""
        print_step("Loading Protocol Admin Address")

        if "protocolAdmin" in self.config["network"]:
            protocol_admin_address = self.config["network"]["protocolAdmin"]

        print_success(f"Protocol Admin address loaded: {format_account(protocol_admin_address)}")
        return protocol_admin_address

    def _get_ops_admin_address(self) -> str:
        """Get ops admin address based on network type"""
        print_step("Loading Ops Admin Address")

        if "opsAdmin" in self.config["network"]:
            ops_admin_address = self.config["network"]["opsAdmin"]

        print_success(f"Ops Admin address loaded: {format_account(ops_admin_address)}")
        return ops_admin_address

    def _setup_rpc(self) -> str:
        """Setup and test RPC URL.

        Mirrors the logic in EnvConfig.s.sol: read baseRpcUrl from the
        network config and append the appropriate API key from env vars.
        """
        print_step("Setting up RPC URL")

        base_url = self.config["network"].get("baseRpcUrl")
        if not base_url:
            raise ValueError(f"No baseRpcUrl found in config for {self.network_name}")

        api_key = ""
        if "alchemy" in base_url:
            api_key = os.environ.get("ALCHEMY_API_KEY", "")
            if not api_key:
                raise ValueError("ALCHEMY_API_KEY env var is required")
            print_info("Using Alchemy RPC endpoint")
        elif "plume" in base_url:
            api_key = os.environ.get("PLUME_API_KEY", "")
            print_info("Using Plume RPC endpoint")
        elif "pharos" in base_url:
            api_key = os.environ.get("PHAROS_API_KEY", "")
            if not api_key:
                raise ValueError("PHAROS_API_KEY env var is required. ")
            print_info("Using Pharos RPC endpoint")
        else:
            print_info(f"Using RPC endpoint: {base_url}")

        rpc_url = f"{base_url}{api_key}"

        # Test the connection
        try:
            subprocess.run([
                "cast", "block", "latest", "--rpc-url", rpc_url
            ], capture_output=True, check=True, timeout=10)
            print_success("RPC connection verified")
            return rpc_url
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            raise RuntimeError(f"RPC connection failed. URL: {rpc_url}.")
