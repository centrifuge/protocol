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

    def run_deploy(self, script_name: str) -> bool:
        """Run a forge script deployment"""
        Formatter.print_step(f"Script: {script_name}")
        Formatter.print_info(f"Network: {self.env_loader.network_name}")
        Formatter.print_info(f"Chain ID: {self.env_loader.chain_id}")

        auth_args = self._setup_auth()
        forge_args = self.args.forge_args
        
        if self.args.catapulta:
            return self._run_catapulta(script_name, auth_args, forge_args)
        else:
            return self._run_forge(script_name, auth_args, forge_args)
        
    def _setup_auth(self) -> List[str]:
        """Setup authentication arguments for forge/catapulta"""
        is_testnet = self.env_loader.is_testnet
        
        if self.args.ledger:
            return LedgerManager(self.args).get_ledger_args()
        elif is_testnet and not self.args.ledger:
            Formatter.print_info("Using private key authentication")
            return ["--private-key", self.env_loader.private_key]
        elif not is_testnet and not self.args.ledger:
            raise ValueError("No authentication method specified. Use --ledger for mainnet.")


    def _run_forge(self, script_name: str, auth_args: List[str], forge_args: List[str]) -> bool:
        """Run deployment with Forge"""
        script_path = self.env_loader.root_dir / "script" / f"{script_name}.s.sol"
        
        # Set up environment variables
        env = os.environ.copy()
        
        env["NETWORK"] = self.env_loader.network_name
        env["VERSION"] = os.environ.get("VERSION", "")
        env["ETHERSCAN_API_KEY"] = self.env_loader.etherscan_api_key
        env["ADMIN"] = self.env_loader.admin_address

        cmd = [
            "forge", "script", str(script_path),
            "--tc", script_name,
            "--optimize",
            "--rpc-url", self.env_loader.rpc_url,
            "--verify",
            "--broadcast", 
            "--chain-id", self.env_loader.chain_id,
            *auth_args,
            *forge_args
        ]

        if not self.args.dry_run:
            Formatter.print_info("Using Forge deployment")
            Formatter.print_info(f"Running: forge script {script_name} ...")
    
            try:
                # First run without --verify to get the contracts deployed
                # Show full log output
                # Fail if the script fails to deploy
                cmd.remove("--verify")
                Formatter.print_step("Deployment Command")
                Formatter.print_command(cmd, self.env_loader, script_path, self.env_loader.root_dir)
                Formatter.print_info(f"Deploying scripts (without verification)...")
                # Temporary: Capture output to debug GitHub Actions issue
                result = subprocess.run(cmd, env=env, capture_output=True, text=True)
                
                # Print captured output
                if result.stdout:
                    print("=== FORGE STDOUT ===")
                    print(result.stdout)
                if result.stderr:
                    print("=== FORGE STDERR ===")
                    print(result.stderr)
                
                if result.returncode != 0:
                    raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
            except subprocess.CalledProcessError as e:
                Formatter.print_error(f"Failed to run {script_name} with Forge")
                Formatter.print_error(f"Exit code: {e.returncode}")
                if e.stderr:
                    Formatter.print_error(f"stderr: {e.stderr}")
                # Also try to get more info about what went wrong
                Formatter.print_error("Forge command failed. Check the output above for details.")
                return False
            try:
                # Then run with --verify to verify the contracts without log output (too verbose)
                cmd.append("--verify")
                # Skip ActionBatcher verification since it's too large for Etherscan
                cmd.extend(["--skip", "FullActionBatcher", "--skip", "HubActionBatcher", "--skip", "ExtendedSpokeActionBatcher"])
                if "--resume" not in self.args.forge_args:
                    cmd.append("--resume")
                Formatter.print_step(f"Verifying contracts with forge...")
                Formatter.print_info(f"This will take a while. Please wait...")
                # Capture logs but do not show them in real time (too verbose)
                if self.env_loader.network_name != "anvil":
                    result = subprocess.run(cmd, check=True, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            except subprocess.CalledProcessError as e:
                # If verification fails
                # Write forge verification output to deploy/logs/forge-validate-$network.log
                log_dir = self.env_loader.root_dir / "script" / "deploy" / "logs"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_file = log_dir / f"forge-validate-{self.env_loader.network_name}-error.log"
                with open(log_file, "w") as f:
                    if e.stdout:
                        print(e.stdout)
                    if e.stderr:
                        f.write(e.stderr)
                        f.write("\n")
                Formatter.print_error(f"Forge verification failed. See {log_file} for details.")
                return False
            Formatter.print_success("Script execution completed successfully")
            return True
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
        env["NETWORK"] = self.env_loader.network_name
        env["VERSION"] = os.environ.get("VERSION", "")
        env["ADMIN"] = self.env_loader.admin_address

        Formatter.print_step("Deployment Command")
        Formatter.print_command(cmd, self.env_loader, script_path, self.env_loader.root_dir)

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

    def build_contracts(self):
        """Build contracts with forge"""
        Formatter.print_subsection("Building contracts")
        
        # Clean first
        subprocess.run(["forge", "clean"], check=True)
        
        # Build with parallel jobs
        cpu_count = multiprocessing.cpu_count()
        cmd = ["forge", "build", "--threads", str(cpu_count), "--skip", "test", "--deny-warnings"]
        Formatter.print_command(cmd)
        
        if not self.args.dry_run:
            if subprocess.run(cmd, check=True):
                Formatter.print_success("Contracts built successfully")
            else:
                Formatter.print_error("Failed to build contracts")
        else:
            Formatter.print_info("Dry run mode, skipping build")