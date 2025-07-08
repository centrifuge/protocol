#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Anvil Local Network Support

Self-contained Anvil deployment that handles everything internally.
Replaces the functionality of deploy-anvil.sh bash script.
"""

import os
import subprocess
import time
import json
import urllib.request
from datetime import datetime
from pathlib import Path
from .formatter import Formatter
from .load_config import EnvironmentLoader


class AnvilManager:
    def __init__(self, root_dir: Path):
        self.root_dir = root_dir
        self.anvil_url = "http://localhost:8545"
        self.chain_id = "31337"
        self.admin_address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # 2nd Anvil account
        self.private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # 1st account
        
    def deploy_full_protocol(self) -> bool:
        """Deploy full protocol to Anvil - handles everything"""
        Formatter.print_section("Anvil Protocol Deployment")
        
        # 1. Get Sepolia RPC for forking
        sepolia_rpc = self._get_sepolia_rpc()
        
        # 2. Setup Anvil
        Formatter.print_step("Loading Sepolia RPC for forking")
        # Use EnvironmentLoader to get properly configured Sepolia RPC
        sepolia_loader = EnvironmentLoader(
            network_name="sepolia",
            root_dir=self.root_dir,
            use_ledger=False,
            catapulta_mode=False 
        )
        rpc_url = sepolia_loader.env_vars["RPC_URL"]
        self._setup_anvil(rpc_url)
        
        # 3. Deploy protocol
        if not self._deploy_contracts("FullDeployer"):
            return False
            
        # 4. Deploy adapters  
        if not self._deploy_contracts("Adapters"):
            return False
            
        # 5. Verify deployments
        return self._verify_deployments()


    def _setup_anvil(self, fork_url: str) -> None:
        """Setup and start Anvil"""
        Formatter.print_subsection("Setting up Anvil local network")
        
        # Stop existing Anvil
        subprocess.run(["pkill", "anvil"], capture_output=True)
        time.sleep(1)
        
        # Start Anvil
        Formatter.print_step("Starting Anvil")
        cmd = [
            "anvil",
            "--chain-id", self.chain_id,
            "--gas-limit", "50000000", 
            "--code-size-limit", "50000",
            "--fork-url", fork_url
        ]
        
        with open("anvil.log", "w") as log_file:
            subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        
        time.sleep(3)
        
        # Verify it's running
        if subprocess.run(["pgrep", "anvil"], capture_output=True).returncode == 0:
            Formatter.print_success(f"Anvil started on {self.anvil_url}")
        else:
            raise RuntimeError("Anvil failed to start")
    
    def _deploy_contracts(self, script_name: str) -> bool:
        """Deploy contracts using forge script"""
        Formatter.print_subsection(f"Deploying {script_name}")
        
        # Generate unique version
        timestamp = int(datetime.now().timestamp())
        version = f"anvil-{timestamp}"
        
        # Set environment variables
        env = os.environ.copy()
        env.update({
            "NETWORK": "anvil",
            "ADMIN": self.admin_address,
            "VERSION": version
        })
        
        # Build forge command
        script_path = self.root_dir / "script" / f"{script_name}.s.sol"
        cmd = [
            "forge", "script", str(script_path),
            "--tc", script_name,
            "--rpc-url", self.anvil_url,
            "--private-key", self.private_key,
            "--broadcast", "--skip-simulation", "-vvvv"
        ]
        
        Formatter.print_step(f"Running: forge script {script_name}")
        
        try:
            result = subprocess.run(cmd, check=True, env=env)
            Formatter.print_success(f"{script_name} deployed successfully")
            return True
        except subprocess.CalledProcessError:
            Formatter.print_error(f"Failed to deploy {script_name}")
            return False
    
    def _verify_deployments(self) -> bool:
        """Verify contracts are deployed by checking code"""
        Formatter.print_subsection("Verifying deployments on Anvil")
        
        try:
            # Read deployment output
            latest_file = self.root_dir / "env" / "latest" / f"{self.chain_id}-latest.json"
            with open(latest_file, 'r') as f:
                deployment = json.load(f)
            
            contracts = deployment.get("contracts", {})
            if not contracts:
                Formatter.print_error("No contracts found in deployment")
                return False
            
            verified_count = 0
            for name, address in contracts.items():
                if self._has_contract_code(address):
                    Formatter.print_success(f"{name}: {address} ✓")
                    verified_count += 1
                else:
                    Formatter.print_error(f"{name}: {address} ✗ (no code)")
            
            Formatter.print_info(f"Verified {verified_count}/{len(contracts)} contracts")
            return verified_count == len(contracts)
            
        except Exception as e:
            Formatter.print_error(f"Verification failed: {e}")
            return False
    
    def _has_contract_code(self, address: str) -> bool:
        """Check if address has contract code"""
        payload = {
            "jsonrpc": "2.0",
            "method": "eth_getCode", 
            "params": [address, "latest"],
            "id": 1
        }
        
        try:
            req = urllib.request.Request(
                self.anvil_url,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req) as response:
                result = json.loads(response.read().decode())
                code = result.get("result", "0x")
                return code != "0x" and len(code) > 2
        except Exception:
            return False 