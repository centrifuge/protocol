#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Deployment Runner

Handles deployment execution using Forge or Catapulta, including build process,
authentication setup, and command execution with proper error handling.

This module coordinates the deployment process by:
- Managing authentication (private key vs Ledger hardware wallet)
- Building and executing deployment commands
- Handling deployment failures with helpful diagnostics
"""

import os
import subprocess
import multiprocessing
import argparse
from typing import List
from .formatter import Formatter
from .load_config import EnvironmentLoader
from .ledger import LedgerManager


class DeploymentRunner:
    def __init__(self, env_loader: EnvironmentLoader, args: argparse.Namespace):
        self.env_loader = env_loader
        self.args = args

    def run_deploy(self, script_name: str, use_catapulta: bool = False, 
                   forge_args: List[str] = None) -> bool:
        """Run a forge script deployment"""
        if forge_args is None:
            forge_args = []

        Formatter.print_step(f"Script: {script_name}")
        Formatter.print_info(f"Network: {self.env_loader.network_name}")
        Formatter.print_info(f"Chain ID: {self.env_loader.chain_id}")

        auth_args = self._setup_auth()
        
        if use_catapulta:
            return self._run_catapulta(script_name, auth_args, forge_args)
        else:
            return self._run_forge(script_name, auth_args, forge_args)
        
    def _setup_auth(self) -> List[str]:
        """Setup authentication arguments for forge/catapulta"""
        is_testnet = self.env_loader.env_vars.get("IS_TESTNET", "false") == "true"
        
        if self.args.ledger:
            return LedgerManager(self.args).get_ledger_args()
        elif is_testnet and self.env_loader.env_vars.get("PRIVATE_KEY"):
            Formatter.print_info("Using private key authentication")
            return ["--private-key", self.env_loader.env_vars["PRIVATE_KEY"]]
        elif not is_testnet:
            raise ValueError("No authentication method specified. Use --ledger or --private-key.")


    def _run_forge(self, script_name: str, auth_args: List[str], forge_args: List[str]) -> bool:
        """Run deployment with Forge"""
        script_path = self.env_loader.root_dir / "script" / f"{script_name}.s.sol"
        
        cmd = [
            "forge", "script", str(script_path),
            "--tc", script_name,
            "--optimize",
            "--rpc-url", self.env_loader.env_vars["RPC_URL"],
            "--verify",
            "--broadcast", 
            "--chain-id", self.env_loader.chain_id,
            *auth_args,
            *forge_args
        ]

        # Set up environment variables
        env = os.environ.copy()
        env.update(self.env_loader.env_vars)
        env["NETWORK"] = self.env_loader.network_name
        env["VERSION"] = os.environ.get("VERSION", "")

        Formatter.print_step("Deployment Command")
        debug_cmd = " ".join(cmd)
        # Mask secrets in debug output
        if "PRIVATE_KEY" in self.env_loader.env_vars:
            debug_cmd = debug_cmd.replace(self.env_loader.env_vars["PRIVATE_KEY"], "$PRIVATE_KEY")
        # Mask Alchemy API key in RPC URL
        if "RPC_URL" in self.env_loader.env_vars and "alchemy" in self.env_loader.env_vars["RPC_URL"]:
            alchemy_key = self.env_loader.env_vars["RPC_URL"].split("/")[-1]
            debug_cmd = debug_cmd.replace(alchemy_key, "$ALCHEMY_API_KEY")
        
        # Show relative path in debug output for readability, but use full path in actual command
        relative_script_path = Formatter.format_path(script_path, self.env_loader.root_dir)
        debug_cmd_display = debug_cmd.replace(str(script_path), relative_script_path)
        
        # Print command on its own line for easy copy/paste
        print(f"{debug_cmd_display}")

        if not self.args.dry_run:
            Formatter.print_info("Using Forge deployment")
            Formatter.print_info(f"Running: forge script {script_name} ...")
    
            try:
                result = subprocess.run(cmd, check=True, env=env)
                Formatter.print_success("Script execution completed successfully")
                return True
            except subprocess.CalledProcessError as e:
                Formatter.print_error(f"Failed to run {script_name} with Forge")
                self._handle_forge_failure(script_name, auth_args)
                return False
        else:
            Formatter.print_info("Dry run mode, skipping forge execution")
            return True

    def _run_catapulta(self, script_name: str, auth_args: List[str], forge_args: List[str]) -> bool:
        """Run deployment with Catapulta"""
        script_path = self.env_loader.root_dir / "script" / f"{script_name}.s.sol"
        
        cmd = [
            "catapulta", "script", str(script_path),
            "--tc", script_name,
            "--network", self.env_loader.chain_id,
            *auth_args,
            *forge_args
        ]

        # Set up environment variables
        env = os.environ.copy()
        env.update(self.env_loader.env_vars)
        env["NETWORK"] = self.env_loader.network_name
        env["VERSION"] = os.environ.get("VERSION", "")

        Formatter.print_step("Deployment Command")
        debug_cmd = " ".join(cmd)
        # Mask secrets in debug output
        if "PRIVATE_KEY" in self.env_loader.env_vars:
            debug_cmd = debug_cmd.replace(self.env_loader.env_vars["PRIVATE_KEY"], "$PRIVATE_KEY")
        # Mask Alchemy API key in RPC URL
        if "RPC_URL" in self.env_loader.env_vars and "alchemy" in self.env_loader.env_vars["RPC_URL"]:
            alchemy_key = self.env_loader.env_vars["RPC_URL"].split("/")[-1]
            debug_cmd = debug_cmd.replace(alchemy_key, "$ALCHEMY_API_KEY")
        
        # Show relative path in debug output for readability, but use full path in actual command
        relative_script_path = Formatter.format_path(script_path, self.env_loader.root_dir)
        debug_cmd_display = debug_cmd.replace(str(script_path), relative_script_path)
        
        # Print command on its own line for easy copy/paste
        print(f"{debug_cmd_display}")

        if not self.args.dry_run:
            Formatter.print_info("Using Catapulta deployment")
            Formatter.print_info(f"Running: catapulta script {script_name} ...")

            try:
                result = subprocess.run(cmd, check=True, env=env)
                Formatter.print_success("Script execution completed successfully")
                return True
            except subprocess.CalledProcessError:
                Formatter.print_error(f"Failed to run {script_name} with Catapulta")
                return False
        else:
            Formatter.print_info("Dry run mode, skipping catapulta execution")
            return True

    def _handle_forge_failure(self, script_name: str, auth_args: List[str]):
        """Handle forge script failure with helpful error messages"""
        latest_deployment = self.env_loader.root_dir / "env" / "latest" / f"{self.env_loader.chain_id}-latest.json"
        
        if latest_deployment.exists():
            Formatter.print_warning("Forge script failed, but deployment succeeded")
            Formatter.print_warning("This often happens when contracts deploy successfully but verification fails")
            Formatter.print_info(f"To update the env file manually, run:")
            Formatter.print_info(f"  python3 deploy.py {self.env_loader.network_name} verify:protocol")
            Formatter.print_warning(f"IMPORTANT: Your env/{self.env_loader.network_name}.json file is NOT up to date until all contracts are verified")
        else:
            Formatter.print_error(f"ERROR: Failed to run {script_name} with Forge")
            Formatter.print_step("Try these steps:")
            Formatter.print_info(f"1. Run python3 deploy.py {self.env_loader.network_name} deploy:protocol --resume")

    def build_contracts(self):
        """Build contracts with forge"""
        Formatter.print_subsection("Building contracts")
        
        # Clean first
        subprocess.run(["forge", "clean"], check=True)
        
        # Build with parallel jobs
        cpu_count = multiprocessing.cpu_count()
        cmd = ["forge", "build", "--jobs", str(cpu_count), "--skip", "test", "--deny-warnings"]
        Formatter.print_info(f"Build command:")
        print(f"{' '.join(cmd)}")
        if not self.args.dry_run:
            if subprocess.run(cmd, check=True):
                Formatter.print_success("Contracts built successfully")
            else:
                Formatter.print_error("Failed to build contracts")
        else:
            Formatter.print_info("Dry run mode, skipping build")