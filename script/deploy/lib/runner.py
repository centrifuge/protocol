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
        self.env = self._setup_env()
        self.script_path = None # initialize
    
    def _setup_env(self):
        env = os.environ.copy()
        env["NETWORK"] = self.env_loader.network_name
        env["VERSION"] = os.environ.get("VERSION", "")
        if self.env_loader.etherscan_api_key is not None:
            env["ETHERSCAN_API_KEY"] = self.env_loader.etherscan_api_key
        env["PROTOCOL_ADMIN"] = self.env_loader.protocol_admin_address
        env["OPS_ADMIN"] = self.env_loader.ops_admin_address
        # Also add the vars in .env (if .env is there)
        env_file = ".env"
        if os.path.exists(env_file):
            with open(env_file, "r") as f:
                for line in f:
                    if "=" in line and not line.strip().startswith("#"):
                        k, v = line.strip().split("=", 1)
                        # Only set if not already set in env (env file has lower priority)
                        if k not in env:
                            env[k] = v
        return env

    def run_deploy(self, script_name: str) -> bool:
        """Run a forge script deployment"""
        # Default location: script/<ScriptName>.s.sol
        self.script_path = self.env_loader.root_dir / "script" / f"{script_name}.s.sol"
        # Fallback for hidden helpers (adapters-only, etc.)
        if not self.script_path.exists():
            hidden_path = self.env_loader.root_dir / "script" / "deploy" / "solidityHelpers" / f"{script_name}.s.sol"
            if hidden_path.exists():
                self.script_path = hidden_path
        # Fallback for test scripts moved to test/e2e_testnets/
        if not self.script_path.exists() and script_name == "TestData":
            test_path = self.env_loader.root_dir / "test" / "e2e_testnets" / f"{script_name}.s.sol"
            if test_path.exists():
                self.script_path = test_path
        print_subsection(f"Deploying {script_name}.s.sol")
        print_step(f"Deployment Info:")
        print_info(f"Script: {script_name}")
        print_info(f"Network: {self.env_loader.network_name}")
        print_info(f"Chain ID: {self.env_loader.chain_id}")
        if os.environ.get("VERSION"):
            print_info(f"Version (for salt): {os.environ.get("VERSION")}")
        print_info(f"Protocol Admin: {format_account(self.env_loader.protocol_admin_address)}")
        print_info(f"Ops Admin: {format_account(self.env_loader.ops_admin_address)}")
        base_cmd = self._build_command(script_name)
        if self.args.catapulta:
            if self.args.dry_run:
                print_warning("Catapulta cannot run without --broadcast")
                print_info("Skipping running catapulta")
                return True
            print_step(f"Running catapulta")
            if not self._run_command(base_cmd):
                return False
            print_success("Catapulta finished successfully")
            print_info("Check catapulta dashboard: https://catapulta.sh/project/68317077d1b8de690e3569e9")
        else:
            print_step(f"Running forge script")
            
            # 1. Deploy without verification
            print_info(f"Deploying scripts (without verification)...")            
            if not self._run_command(base_cmd):
                return False
            print_success("Forge contracts deployed successfully")
            # 2. Verify (only for protocol and adapter scripts)
            if not self.env_loader.network_name.startswith("anvil") and script_name not in ["TestData"]:
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
        elif (is_testnet and not self.args.ledger) or "tenderly" in self.env_loader.rpc_url:
            # Only access private_key when actually needed (not using ledger)
            private_key = self.env_loader.private_key
            if self.args.catapulta:
                public_key = subprocess.run(["cast", "wallet", "address", "--private-key", private_key],
                capture_output=True, text=True, check=True)
                #--sender Optional, specify the sender address (required when using --private-key)
                return ["--private-key", private_key, "--sender", public_key.stdout.strip()]
            else:
                return ["--private-key", private_key]
            
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
                "--rpc-url", self.env_loader.rpc_url,
                "--chain-id", self.env_loader.chain_id,
                *auth_args,
                *self.args.forge_args
            ]
            if not self.args.dry_run:
                base_cmd.append("--broadcast")
            if not self.env_loader.is_testnet or os.environ.get('GITHUB_ACTIONS'):
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
                print_info("Running verification...")
                print("==== FORGE LOGS ====\n")
                result = subprocess.run(cmd, env=self.env, text=True)
                print("\n==== END OF LOGS ====\n")
                
                if result.returncode == 0:
                    print_success("Verification completed successfully")
                    return True
                else:
                    print_error(f"Verification failed with exit code: {result.returncode}")
                    return False
                
        except subprocess.CalledProcessError as e:
            print_error(f"Command failed:")
            # Use print_command to ensure secrets are masked
            print_command(cmd, self.env_loader, self.script_path, self.env_loader.root_dir)
            print_error(f"Exit code: {e.returncode}")
            if e.stderr:
                # Mask private key in stderr if present
                masked_stderr = e.stderr
                if self.env_loader.private_key:
                    masked_stderr = masked_stderr.replace(self.env_loader.private_key, "$PRIVATE_KEY")
                print_error(f"stderr: {masked_stderr}")
            if e.stdout:
                # Mask private key in stdout if present
                masked_stdout = e.stdout
                if self.env_loader.private_key:
                    masked_stdout = masked_stdout.replace(self.env_loader.private_key, "$PRIVATE_KEY")
                print_error(f"stdout: {masked_stdout}")
            return False
        except Exception as e:
            print_error(f"Unexpected error running command:")
            print_command(cmd, self.env_loader, self.script_path, self.env_loader.root_dir)
            print_error(f"Error: {str(e)}")
            import traceback
            print_error(f"Stack trace:")
            traceback.print_exc()
            return False

    def build_contracts(self):
        """Build contracts with forge"""
        print_subsection("Building contracts")
        
        
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