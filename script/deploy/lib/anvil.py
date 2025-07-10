#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Anvil Local Network Support

Self-contained Anvil deployment that handles everything internally.
Replaces the functionality of deploy-anvil.sh bash script.
"""

import subprocess
import time
import json
import urllib.request
from os import environ
from pathlib import Path
import random
import string
from .formatter import *
from .runner import DeploymentRunner
from .load_config import EnvironmentLoader
from .verifier import ContractVerifier

class AnvilManager:
    def __init__(self, root_dir: Path):
        self.root_dir = root_dir
        self.anvil_url = "http://localhost:8545"
        self.chain_id = "31337"
        self.admin_address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # 2nd Anvil account
        self.private_key = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # 1st account
        self.anvil_config_file = self.root_dir / "env" / "anvil.json"
    
    def _create_anvil_env(self):
        """Create a minimal environment mock that works with DeploymentRunner"""
        # Set the random VERSION in environment variables
        # Generate a random 8-character string for Anvil to avoid collisions
        random_version = ''.join(random.choices(string.ascii_lowercase + string.digits, k=8))                
        environ["VERSION"] = random_version
        print_info(f"Using random VERSION for Anvil: {random_version}")
        
        class AnvilEnv:
            def __init__(self, manager):
                # Simple attributes - no need for properties since no logic required
                self.network_name = "anvil"
                self.chain_id = manager.chain_id
                self.root_dir = manager.root_dir
                self.rpc_url = manager.anvil_url
                self.private_key = manager.private_key
                self.etherscan_api_key = ""  # Not needed for anvil
                self.admin_address = manager.admin_address
                self.is_testnet = True
                self.config_file = manager.anvil_config_file
            
        return AnvilEnv(self)
    
    def _create_anvil_config(self) -> None:
        """Create temporary anvil.json config file for Solidity scripts"""
        if self.anvil_config_file.exists():
            self.anvil_config_file.unlink()
            print_step("Cleaned up existing anvil.json config")        
        anvil_config = {
            "network": {
                "chainId": int(self.chain_id),
                "centrifugeId": 9,  # Anvil's centrifuge ID
                "environment": "testnet",
                "connectsTo": [],
            },
            "contracts": {},  # Will be populated after FullDeployer runs
            "adapters": {
                "wormhole": {
                "wormholeId": "10002",
                "relayer": "0x7B1bD7a6b4E61c2a123AC6BC2cbfC614437D0470",
                "deploy": "true"
                },
                "axelar": {
                "axelarId": "ethereum-sepolia",
                "gateway": "0xe432150cce91c13a887f7D836923d5597adD8E31",
                "gasService": "0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6",
                "deploy": "true"
                }
            }
        }
        
        with open(self.anvil_config_file, 'w') as f:
            json.dump(anvil_config, f, indent=2)
        
        print_step("Created temporary anvil.json config")

        
    def deploy_full_protocol(self) -> bool:
        """Deploy full protocol to Anvil - handles everything"""
        print_section("Anvil Setup")
        # 1. Create temporary anvil.json config file
        self._create_anvil_config()
        
        # 2. Setup Anvil with proper RPC (try to get real one, fallback to public)
        temp_loader = EnvironmentLoader("sepolia", self.root_dir)
        api_key = temp_loader._get_secret("alchemy_api")
        fork_url = f"https://eth-sepolia.g.alchemy.com/v2/{api_key}"
        print_success("Using Alchemy RPC with API key")
        
        self._setup_anvil(fork_url)
        
        # 3. Create simple environment for DeploymentRunner
        env_mock = self._create_anvil_env()
        
        # 4. Create mock args for DeploymentRunner
        class Args:
            def __init__(self):
                self.catapulta = False
                self.ledger = False
                self.dry_run = False
                self.forge_args = []
                
        args = Args()
        runner = DeploymentRunner(env_mock, args)
        
        
        # 5. Deploy protocol using same logic as regular deployments
        print_section("Contract deployments")

        verifier = ContractVerifier(env_mock, args)
        runner.build_contracts()

        # Deploy protocol
        print_subsection("Deploying protocol")
        if not runner.run_deploy("FullDeployer"):
            return False
        args.step = "deploy:protocol"
        verifier.update_network_config()
            
        # Deploy adapters  
        print_subsection("Deploying adapters")
        if not runner.run_deploy("Adapters"):
            return False
        args.step = "deploy:adapters"
        verifier.update_network_config()
        print_section("Contract verifications")
        # Verify deployments
        if not self._verify_deployments():
            return False
        
        # Deploy test data - temporarily use admin account's private key
        # We need to sign TestData with the ADMIN key
        env_mock.private_key = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"  # 2nd account private key
        print_section("Test data deployment")
        print_info(f"Using Anvil account #2 private key for TestData script {format_account(env_mock.private_key)}")
        if not runner.run_deploy("TestData"):
            return False
            

        
        # All steps succeeded
        print_success("Protocol and adapters deployed successfully")
        print_success("TestData deployed successfully")
        print_info(f"Deployed contract addresses can be found in {self.anvil_config_file}")
        print_warning("Anvil is still running for you to test the protocol")
        print_warning("Use 'pkill anvil' to stop it")
        return True


    def _setup_anvil(self, fork_url: str) -> None:
        """Setup and start Anvil"""
        print_subsection("Setting up Anvil local network")
        subprocess.run(["pkill", "anvil"], capture_output=True)
        time.sleep(1)
        
        # Start Anvil
        print_step("Starting Anvil")
        cmd = [
            "anvil",
            "--chain-id", self.chain_id,
            "--gas-limit", "50000000", 
            "--code-size-limit", "50000",
            "--fork-url", fork_url
        ]
        # Needed to mask the rpc_url in the command
        class MockEnvLoader:
            def __init__(self, rpc_url):
                self.rpc_url = rpc_url

        print_command(cmd, env_loader=MockEnvLoader(fork_url))
        with open("anvil-service.log", "w") as log_file:
            subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        
        time.sleep(3)
        
        # Verify it's running
        if subprocess.run(["pgrep", "anvil"], capture_output=True).returncode == 0:
            print_success(f"Anvil started on {self.anvil_url}")
        else:
            raise RuntimeError("Anvil failed to start")
    

    
    def _verify_deployments(self) -> bool:
        """Verify contracts are deployed by checking code"""
        print_subsection("Verifying deployments on Anvil")
        
        try:
            # Read deployment output
            with open(self.anvil_config_file, 'r') as f:
                deployment = json.load(f)
            
            contracts = deployment.get("contracts", {})
            if not contracts:
                print_error("No contracts found in deployment")
                return False
            
            verified_count = 0
            for name, address in contracts.items():
                if self._has_contract_code(address):
                    print_success(f"{name}: {address} ✓")
                    verified_count += 1
                else:
                    print_error(f"{name}: {address} ✗ (no code)")
            
            print_info(f"Verified {verified_count}/{len(contracts)} contracts")
            return verified_count == len(contracts)
            
        except Exception as e:
            print_error(f"Verification failed: {e}")
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