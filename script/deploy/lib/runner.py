#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Deployment Runner

Handles deployment execution using Forge or Catapulta, including build process,
authentication setup, and command execution with proper error handling.

This module coordinates the deployment process by:
- Managing authentication (private key vs Ledger hardware wallet)
- Building and executing deployment commands
- Handling deployment failures with helpful diagnostics

If you want to modify the command arguments you need to search in this order:
1. _build_command -> basic arguments for our CMD options
2. _setup_auth_args -> wallet arguments (--ledger --private-key, etc)
3. run_deploy -> additional arguments to deal with corner cases 
   (search for .append and .extend)
"""

import os
import subprocess
import multiprocessing
import argparse
from typing import List
from .formatter import *
from .load_config import EnvironmentLoader
from .ledger import LedgerManager


class DeploymentRunner:
    def __init__(self, env_loader: EnvironmentLoader, args: argparse.Namespace):
        self.env_loader = env_loader
        self.args = args
        # Set up environment variables
        env = os.environ.copy()
        env["NETWORK"] = self.env_loader.network_name
        env["VERSION"] = os.environ.get("VERSION", "")
        env["ETHERSCAN_API_KEY"] = self.env_loader.etherscan_api_key
        env["ADMIN"] = self.env_loader.admin_address
        self.env = env
        self.script_path = None # initialize

    def run_deploy(self, script_name: str) -> bool:
        """Run a forge script deployment"""
        self.script_path = self.env_loader.root_dir / "script" / f"{script_name}.s.sol"
        print_subsection(f"Deploying {script_name}.s.sol")
        print_step(f"Deployment Info:")
        print_info(f"Script: {script_name}")
        print_info(f"Network: {self.env_loader.network_name}")
        print_info(f"Chain ID: {self.env_loader.chain_id}")
        if os.environ.get("VERSION"):
            print_info(f"Version (for salt): {os.environ.get("VERSION")}")
        print_info(f"Admin Account: {format_account(self.env_loader.admin_address)}")
        base_cmd = self._build_command(script_name)
        if self.args.catapulta:
            print_step(f"Running catapulta")
            if not self._run_command(base_cmd):
                return False
            print_success("Catapulta finished successfully")
            print_info("Check catapulta dashboard: https://catapulta.sh/project/68317077d1b8de690e3569e9")
        else:
            # Assume forge
            print_step(f"Running forge script")
            # 1. Deploy without verification

            print_info(f"Deploying scripts (without verification)...")            
            if not self._run_command(base_cmd):
                return False
            print_success("Forge contracts deployed successfully")
            # 2. Verify
            if self.env_loader.network_name != "anvil":
                cmd = base_cmd.copy()
                cmd.append("--verify")
                if "--resume" not in cmd:
                    cmd.append("--resume")            
                # This doesn't really work:
                # cmd.extend(["--skip", "FullActionBatcher", "--skip", "HubActionBatcher", "--skip", "ExtendedSpokeActionBatcher"])
                print_step(f"Verifying contracts with forge")
                print_info(f"Logs will be written to a log file")
                print_info(f"This will take a while. Please wait...")
                if not self._run_command(cmd):
                    return False
                print_success("Forge contracts verified successfully")
            
        return True

        
    def _setup_auth_args(self) -> List[str]:
        """Setup authentication arguments for forge/catapulta"""
        is_testnet = self.env_loader.is_testnet
        
        if self.args.ledger:
            ledger = LedgerManager(self.args)
            print_info(f"Deployer address (Ledger): {format_account(ledger.get_ledger_account)}")
            return ledger.get_ledger_args
        elif is_testnet and not self.args.ledger:
            # Get the public key from the private key using 'cast'
            private_key = self.env_loader.private_key
            result = subprocess.run(["cast", "wallet", "address", "--private-key", private_key],
                capture_output=True, text=True, check=True)
            print_info(f"Deploying address (Testnet shared account): {format_account(result.stdout.strip())}")
            return ["--private-key", self.env_loader.private_key]
        elif not is_testnet and not self.args.ledger:
            raise ValueError("No authentication method specified. Use --ledger for mainnet.")

    def _build_command(self, script_name: str) -> List[str]:
        """Build a command for a given script and method"""
        auth_args = self._setup_auth_args()

        # Forge
        if not self.args.catapulta:
            base_cmd = [
                "forge", "script", str(self.script_path),
                "--tc", script_name,
                "--optimize",
                "--rpc-url", self.env_loader.rpc_url,
                "--chain-id", self.env_loader.chain_id,
                *auth_args,
                *self.args.forge_args
            ]
            if not self.args.dry_run:
                base_cmd.append("--broadcast")
            if not self.env_loader.is_testnet:
                base_cmd.append("--slow")

        # Catapulta
        elif self.args.catapulta:
            base_cmd = [
                "catapulta", "script", str(self.script_path),
                "--tc", script_name,
                "--network", self.env_loader.chain_id,
                *auth_args,
                *self.args.forge_args
            ]
        return base_cmd
    
    def _run_command(self, cmd: List[str]) -> bool:
        """Run a command"""
        print_step("Deployment Command")
        print_command(cmd, self.env_loader, self.script_path, self.env_loader.root_dir)
        is_verify = "--verify" in cmd

        try:
            # Remove check=True so we can handle the result manually
            result = subprocess.run(cmd, env=self.env, capture_output=True, text=True)
            
            # Always print output first (whether success or failure)
            if not is_verify:
                # For deployment, show output in real-time
                if result.stdout:
                    print("=== FORGE STDOUT ===")
                    print(result.stdout)
                if result.stderr:
                    print("=== FORGE STDERR ===")
                    print(result.stderr)
            else:
                # For verification, write to log file
                log_dir = self.env_loader.root_dir / "script" / "deploy" / "logs"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_file = log_dir / f"forge-validate-{self.env_loader.network_name}.log"
                
                with open(log_file, "w") as f:
                    if result.stdout:
                        f.write("=== FORGE STDOUT ===")
                        f.write(result.stdout)
                        f.write("\n")
                    if result.stderr:
                        f.write("=== FORGE STDERR ===")
                        f.write(result.stderr)
                        f.write("\n")
                print_warning(f"Verification output written to {log_file}")

            # Now check if the command succeeded
            if result.returncode == 0:
                return True
            else:
                # Command failed - raise the exception with the captured output
                raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
                
        except subprocess.CalledProcessError as e:
            print_error(f"Command failed:")
            print(format_command(cmd))
            print_error(f"Exit code: {e.returncode}")
            if e.stderr:
                print_error(f"stderr: {e.stderr}")
            return False

    def build_contracts(self):
        """Build contracts with forge"""
        print_subsection("Building contracts")
        
        # Clean first
        subprocess.run(["forge", "clean"], check=True)
        
        # Build with parallel jobs
        cpu_count = multiprocessing.cpu_count()
        cmd = ["forge", "build", "--threads", str(cpu_count), "--skip", "test", "--deny-warnings"]
        print_command(cmd)
        
        if not self.args.dry_run:
            if subprocess.run(cmd, check=True):
                print_success("Contracts built successfully")
            else:
                print_error("Failed to build contracts")
        else:
            print_info("Dry run mode, skipping build")