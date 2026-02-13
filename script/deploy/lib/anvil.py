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
import os
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
        # https://getfoundry.sh/anvil/overview/
        self.anvil_account0 = {
            "private_key": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
            "address": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
        }
        self.anvil_account1 = {
            "private_key": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
            "address": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
        }
        self.deploy_key = self.anvil_account0["private_key"]
        self.protocol_admin_address = self.anvil_account1["address"]
        self.ops_admin_address = self.anvil_account1["address"]

    def _create_anvil_env(self, network_name: str):
        """Create per-fork env under env/anvil and return a minimal loader-like object."""
        import shutil
        env_root = self.root_dir / "env"
        anvil_dir = env_root / "anvil"
        anvil_dir.mkdir(parents=True, exist_ok=True)

        # Copy base config to env/anvil/<net>.json
        src_cfg: Path = env_root / f"{network_name}.json"
        dst_cfg: Path = anvil_dir / f"{network_name}.json"
        shutil.copyfile(src_cfg, dst_cfg)

        # Rewrite connectsTo to point to anvil/* configs
        try:
            with open(dst_cfg, "r") as f:
                cfg = json.load(f)
            connects = cfg.get("network", {}).get("connectsTo", [])
            if isinstance(connects, list):
                allowed = {"sepolia", "arbitrum-sepolia"}
                filtered = [n for n in connects if n in allowed]
                cfg["network"]["connectsTo"] = [f"anvil/{n}" for n in filtered]
            with open(dst_cfg, "w") as f:
                json.dump(cfg, f, indent=2)
        except Exception as e:
            print_warning(f"Failed to rewrite connectsTo for {dst_cfg}: {e}")

        if network_name == "sepolia":
            port, chain_id = (8545, "31337")
        elif network_name == "arbitrum-sepolia":
            port, chain_id = (8546, "31338")
        else:
            raise ValueError(f"Unsupported anvil network: {network_name}")

        class AnvilEnv:
            def __init__(self, manager, net_name_base: str, port_inner: int, config_path: Path, chain_id_inner: str):
                # Attributes expected by DeploymentRunner/ContractVerifier
                self.network_name = f"anvil/{net_name_base}"
                self.base_network = net_name_base
                self.chain_id = chain_id_inner
                self.root_dir = manager.root_dir
                self.rpc_url = f"http://localhost:{port_inner}"
                self.private_key = manager.deploy_key
                self.etherscan_api_key = ""  # Not needed for anvil
                self.protocol_admin_address = manager.protocol_admin_address
                self.ops_admin_address = manager.ops_admin_address
                self.is_testnet = True
                self.config_file = config_path

        return AnvilEnv(self, network_name, port, dst_cfg, chain_id)

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
                "protocolAdmin": self.protocol_admin_address,
                "opsAdmin": self.ops_admin_address
            },
            "contracts": {},  # Will be populated after LaunchDeployer runs
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
        """Backward-compat entrypoint. Now delegates to deploy()."""
        return self.deploy()

    def deploy(self) -> bool:
        """Fork Sepolia (8545) and Arbitrum Sepolia (8546), deploy both (protocol + test data), then wire."""
        print_section("Dual-fork deploy + wire")

        class Args:
            def __init__(self):
                self.catapulta = False
                self.ledger = False
                self.dry_run = False
                self.forge_args = []

        args = Args()
        
        # Generate a random 8-character string for VERSION to avoid collisions on running Anvil multiple times
        random_version = ''.join(random.choices(string.ascii_lowercase + string.digits, k=8))
        environ["VERSION"] = random_version
        print_info(f"Using random VERSION for Anvil: {random_version}")

        # Prepare API keys
        sepolia_loader = EnvironmentLoader("sepolia", self.root_dir, args)
        api_key = sepolia_loader._get_secret("alchemy_api")


        # SEPOLIA
        sep_env = self._create_anvil_env("sepolia")
        # Start Sepolia fork
        self._setup_anvil(sep_env, api_key)
        if not self._deploy_fork(sep_env, args):
            return False
        args.step = "deploy:protocol"
        verifier.update_network_config("script/LaunchDeployer.s.sol")

        # ARBITRUM SEPOLIA
        # Create env for Arbitrum Sepolia
        arb_env = self._create_anvil_env("arbitrum-sepolia")
        # Start Arbitrum Sepolia fork
        self._setup_anvil(arb_env, api_key, kill_existing=False)
        if not self._deploy_fork(arb_env, args):
            return False
        print_success("Arbitrum Sepolia fork deployed")

        # Wiring after both forks have deployed and configs are merged
        print_subsection("Wiring adapters on both forks")
        for net_env in [sep_env, arb_env]:
            try:
                args.step = "wire:adapters"
                wire_runner = DeploymentRunner(net_env, args)
                if not wire_runner.run_deploy("WireAdapters"):
                    return False
            except Exception as e:
                print_error(f"Wiring failed on {net_env.network_name}: {e}")
                return False

        print_success("Dual-fork deploy and bidirectional wiring completed (8545: sepolia, 8546: arbitrum-sepolia)")
        # Auto-stop anvil in CI for cleanliness
        try:
            if os.environ.get("GITHUB_ACTIONS"):
                subprocess.run(["pkill", "anvil"], capture_output=True)
                print_success("Anvil instances stopped (CI)")
            else:
                print_warning("Use 'pkill anvil' to stop both instances")
        except Exception:
            print_warning("Failed to stop anvil automatically")
        return True

    def _deploy_fork(self, net_env, args):
        runner = DeploymentRunner(net_env, args)
        # Deploy core protocol
        args.step = "deploy:full"
        if not runner.run_deploy("LaunchDeployer"):
            return False
        # Merge latest into env/anvil/<net>.json
        try:
            verifier = ContractVerifier(net_env, args)
            verifier.update_network_config()
        except Exception as e:
            print_warning(f"Failed to merge deployment into config: {e}")
        # Verify deployments after merge
        self._verify_deployments(net_env)

        print_section(f"Test data deployment ({getattr(net_env, 'base_network', net_env.network_name)})")
        # Use the protocol admin key for TestData so actions come from the admin
        net_env.private_key = self.anvil_account1["private_key"]
        args.step = "deploy:test"
        if not runner.run_deploy("TestData"):
            return False
        # Merge test deployments as well
        try:
            verifier = ContractVerifier(net_env, args)
            verifier.update_network_config()
        except Exception as e:
            print_warning(f"Failed to merge test deployment into config: {e}")
        # Do not wire here; wiring happens after both forks deploy
        return True

    def _setup_anvil(self,net_env, api_key, kill_existing: bool = True) -> None:
        """Setup and start Anvil"""
        base_net = getattr(net_env, "base_network", net_env.network_name.split("/")[-1])
        if base_net == "sepolia":
            fork_url = f"https://eth-sepolia.g.alchemy.com/v2/{api_key}"
            port = 8545
        elif base_net == "arbitrum-sepolia":
            fork_url = f"https://arb-sepolia.g.alchemy.com/v2/{api_key}"
            port = 8546

        print_subsection("Setting up Anvil local network")
        if kill_existing:
            subprocess.run(["pkill", "anvil"], capture_output=True)
            print_success("Running Anvil processes killed")
            time.sleep(1)

        # Start Anvil
        print_step("Starting Anvil")
        cmd = [
            "anvil",
            "--chain-id", net_env.chain_id,
            "--gas-limit", "50000000",
            "--code-size-limit", "50000",
            "--fork-url", fork_url,
            "--port", str(port)
        ]
        # Needed to mask the rpc_url in the command
        class MockEnvLoader:
            def __init__(self, manager, rpc_url):
                self.rpc_url = rpc_url
                # Add other attributes that formatter might expect
                self.private_key = manager.deploy_key
                self.etherscan_api_key = ""

        print_command(cmd, env_loader=MockEnvLoader(self,rpc_url=fork_url))
        with open("anvil-service.log", "w") as log_file:
            subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)

        time.sleep(3)

        # Verify it's running
        if subprocess.run(["pgrep", "anvil"], capture_output=True).returncode == 0:
            print_success(f"Anvil started on http://localhost:{port}")
        else:
            raise RuntimeError("Anvil failed to start")



    def _verify_deployments(self, net_env) -> bool:
        """Verify contracts are deployed by checking code"""
        print_subsection("Verifying deployments on Anvil")

        try:
            # Read deployment output
            with open(net_env.config_file, 'r') as f:
                deployment = json.load(f)

            contracts = deployment.get("contracts", {})
            if not contracts:
                print_error("No contracts found in deployment")
                return False

            verified_count = 0
            for name, address in contracts.items():
                if self._has_contract_code(net_env, address):
                    print_success(f"{name}: {address} ✓")
                    verified_count += 1
                else:
                    print_error(f"{name}: {address} ✗ (no code)")

            print_info(f"Verified {verified_count}/{len(contracts)} contracts")
            return verified_count == len(contracts)

        except Exception as e:
            print_error(f"Verification failed: {e}")
            return False

    def _has_contract_code(self, net_env, address: str) -> bool:
        """Check if address has contract code"""
        payload = {
            "jsonrpc": "2.0",
            "method": "eth_getCode",
            "params": [address, "latest"],
            "id": 1
        }

        try:
            req = urllib.request.Request(
                net_env.rpc_url,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req) as response:
                result = json.loads(response.read().decode())
                code = result.get("result", "0x")
                return code != "0x" and len(code) > 2
        except Exception:
            return False
