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
            args = ledger.get_ledger_args
            args.extend(["--sender", ledger.get_ledger_account])
            return args
        elif is_testnet and not self.args.ledger:
            # Get the public key from the private key using 'cast'
            private_key = self.env_loader.private_key
            result = subprocess.run(["cast", "wallet", "address", "--private-key", private_key],
                capture_output=True, text=True, check=True)
            print_info(f"Deploying address (Testnet shared account): {format_account(result.stdout.strip())}")
            if self.args.catapulta:
                #--sender Optional, specify the sender address (required when using --private-key)
                return ["--private-key", self.env_loader.private_key, "--sender", result.stdout.strip()]
            else:
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
            if self.env_loader.network_name == "base-sepolia":
                # Issue with base-sepolia where Tx receipts will get stuck forever
                base_cmd.extend(["--gas-price", "100000000000"])
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
        print_info("Deployment Command")
        print_command(cmd, self.env_loader, self.script_path, self.env_loader.root_dir)
        is_verify = "--verify" in cmd

        try:
            if not is_verify:
                # For deployment, show output in real-time
                print_info("Running deployment (output will be shown in real-time)...")
                print("==== FORGE LOGS ====\n")
                result = subprocess.run(cmd, env=self.env, text=True)
                print("\n==== END OF LOGS ====\n")
                # Show any captured output if there was an error
                if result.returncode != 0:
                    print_error(f"Command failed with exit code: {result.returncode}")
                    return False
                return True
            else:
                # For verification, always capture output and write to log file
                print_info("Running verification (output will be written to log file)...")
                print_info(f"This will take a while. Please wait...")
                # Use Popen with explicit stdout/stderr redirection to force capture
                process = subprocess.Popen(
                    cmd, 
                    env=self.env, 
                    stdout=subprocess.PIPE, 
                    stderr=subprocess.PIPE, 
                    text=True,
                    bufsize=1
                )
                stdout, stderr = process.communicate()
                result = subprocess.CompletedProcess(cmd, process.returncode, stdout, stderr)
                
                # Write output to log file (even in verbose mode for debugging)
                log_dir = self.env_loader.root_dir / "script" / "deploy" / "logs"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_file = log_dir / f"forge-{self.args.step}-{self.env_loader.network_name}.log"
                
                with open(log_file, "w") as f:
                    f.write(f"Command: {' '.join(cmd)}\n")
                    f.write(f"Exit code: {result.returncode}\n")
                    f.write(f"Timestamp: {subprocess.run(['date'], capture_output=True, text=True).stdout.strip()}\n")
                    f.write("\n" + "="*50 + "\n")
                    if result.stdout:
                        f.write("=== FORGE STDOUT ===\n")
                        f.write(result.stdout)
                        f.write("\n")
                    if result.stderr:
                        f.write("=== FORGE STDERR ===\n")
                        f.write(result.stderr)
                        f.write("\n")
                
                print_info(f"Verification output written to: {log_file}")
                
                if result.returncode == 0:
                    print_success("Verification completed successfully")
                    return True
                else:
                    print_error(f"Verification failed with exit code: {result.returncode}")
                    print_error(f"Check the log file for details: {log_file}")
                    return False
                
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