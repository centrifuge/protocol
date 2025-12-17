#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Contract Verifier

Handles contract verification on Etherscan, smart file comparison between
latest deployments and network configs, and config file updates.
"""

import json
import urllib.request
import time
import shutil
import subprocess
import pathlib
import argparse
import os
import traceback
from .formatter import *
from .load_config import EnvironmentLoader


class ContractVerifier:
    def __init__(self, env_loader: EnvironmentLoader, args: argparse.Namespace):
        self.env_loader = env_loader
        self.latest_deployment = env_loader.root_dir / "env" / "latest" / f"{env_loader.chain_id}-latest.json"
        self.args = args
        self.root_dir = env_loader.root_dir
        self.rpc_url = self.env_loader.rpc_url
        self.etherscan_api_key = self.env_loader.etherscan_api_key
    
    def _get_broadcast_deployment_info(self, deployment_script: str) -> dict:
        """
        Parse Forge broadcast artifacts to get real deployment info (block numbers and tx hashes).
        
        Returns a dict mapping lowercase addresses to { blockNumber, txHash }.
        """
        # Find the broadcast file
        # deployment_script format: "script/SomeScript.s.sol:ScriptName"
        script_path = deployment_script.split(":")[0] if ":" in deployment_script else deployment_script
        script_name = pathlib.Path(script_path).name  # e.g., "LaunchDeployer.s.sol"
        
        broadcast_dir = self.root_dir / "broadcast" / script_name / str(self.env_loader.chain_id)
        broadcast_file = broadcast_dir / "run-latest.json"
        
        if not broadcast_file.exists():
            print_warning(f"Broadcast file not found: {broadcast_file}")
            return {}
        
        try:
            with open(broadcast_file, 'r') as f:
                broadcast_data = json.load(f)
            
            # Build address -> { blockNumber, txHash } map from receipts
            deployment_info = {}
            for receipt in broadcast_data.get("receipts", []):
                contract_address = receipt.get("contractAddress")
                block_number_hex = receipt.get("blockNumber")
                tx_hash = receipt.get("transactionHash")
                
                if contract_address and block_number_hex:
                    # Convert hex block number to decimal string
                    block_number = str(int(block_number_hex, 16))
                    deployment_info[contract_address.lower()] = {
                        'blockNumber': block_number,
                        'txHash': tx_hash
                    }
            
            if deployment_info:
                print_step(f"Found {len(deployment_info)} contract deployments from broadcast artifacts")
            
            return deployment_info
        except (json.JSONDecodeError, IOError) as e:
            print_warning(f"Failed to parse broadcast file: {e}")
            return {}

    def verify_contracts(self, deployment_script: str) -> bool:
        """Verify contracts on Etherscan"""
        # Always use -latest.json for verification
        if not self.latest_deployment.exists():
            print_error(f"Deployment file not found: {self.latest_deployment}")
            return False

        contracts_file = self.latest_deployment
        relative_path = format_path(contracts_file, self.root_dir)
        print_step(f"Checking contracts from {relative_path}")

        if not self.args.dry_run:
            with open(contracts_file, 'r') as f:
                data = json.load(f)
                contracts = data.get("contracts", {})
                contract_addresses = { k: v for k, v in contracts.items() }

            if not contract_addresses:
                print_error(f"No contracts found in {relative_path}")
                return False

            unverified_contracts = []
            undeployed_contracts = []
            verified_count = 0
            deployed_count = 0
            for contract_name, contract_address in contract_addresses.items():
                # First check if it is deployed
                if self._is_contract_deployed(contract_address):
                    print_success(f"{contract_name} ({contract_address}) is deployed")
                    deployed_count += 1
                else:
                    print_error(f"{contract_name} ({contract_address}) is NOT deployed (no code at address)")
                    undeployed_contracts.append(f"{contract_name}:{contract_address}")
                # Then check if it's verified on Etherscan
                if self._is_contract_verified(contract_address):
                    print_success(f"{contract_name} ({contract_address}) is verified on Etherscan")
                    verified_count += 1
                else:
                    print_error(f"{contract_name} ({contract_address}) NOT verified on Etherscan")
                    unverified_contracts.append(f"{contract_name}:{contract_address}")
                time.sleep(0.2)  # Rate limiting

            print_info(f"Deployment check complete: {deployed_count}/{len(contract_addresses)} contracts deployed")
            print_info(f"Verification check complete: {verified_count}/{len(contract_addresses)} contracts verified")

            if unverified_contracts or undeployed_contracts:
                print_error("Some contracts failed checks")
                return False
            else:
                print_success("All contracts checks passed!")
                print_info(f"Trying to update network config now...")
                # Check if -latest.json is old before updating main config
                if self._is_deployment_old():
                        print_info("Skipping update of main config file")
                        return True
                else:
                    self.update_network_config(deployment_script)
        else:
            print_info("Dry run mode, skipping contracts checks")

        return True

    def config_has_latest_contracts(self) -> bool:
        """Fast check: are contracts from env/latest already merged into env/<network>.json?"""
        try:
            if not self.latest_deployment.exists():
                return False
            with open(self.latest_deployment, 'r') as f:
                latest = json.load(f)
            with open(self.env_loader.config_file, 'r') as f:
                cfg = json.load(f)
            latest_contracts = latest.get('contracts', {}) or {}
            config_contracts = cfg.get('contracts', {}) or {}
            # Require every contract in latest to exist in config with identical address
            for name, addr in latest_contracts.items():
                if name not in config_contracts or config_contracts[name].lower() != addr.lower():
                    return False
            return True if latest_contracts else False
        except Exception:
            return False

    def _is_contract_deployed(self, address: str) -> bool:
        """Check if contract has code deployed"""
        payload = {
            "jsonrpc": "2.0",
            "method": "eth_getCode",
            "params": [address, "latest"],
            "id": 1
        }

        try:
            req = urllib.request.Request(
                self.rpc_url,
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req) as response:
                result = json.loads(response.read().decode())
                code = result.get("result", "0x")
                return code != "0x" and code != "null"
        except Exception:
            return False

    def _is_contract_verified(self, address: str) -> bool:
        """Check if contract is verified on Etherscan"""
        api_key = self.etherscan_api_key
        chain_id = self.env_loader.chain_id

        url = f"https://api.etherscan.io/v2/api?chainid={chain_id}&module=contract&action=getsourcecode&address={address}&apikey={api_key}"

        try:
            with urllib.request.urlopen(url) as response:
                result = json.loads(response.read().decode())

                if result.get("status") != "1":
                    return False

                contract_data = result.get("result", [{}])[0]
                source_code = contract_data.get("SourceCode", "")
                contract_name = contract_data.get("ContractName", "")

                return (source_code and
                       source_code != "Contract source code not verified" and
                       contract_name)
        except Exception:
            return False

    def update_network_config(self, deployment_script: str = None):
        """Update network config with deployment output"""
        relative_path = format_path(self.env_loader.config_file, self.root_dir)
        print_step(f"Merging contract addresses to {relative_path}")
        network_config = self.env_loader.config_file

        # Create a backup of the current config
        backup_config = pathlib.Path(str(network_config) + ".bak")
        shutil.copy2(network_config, backup_config)

        try:
            # Get the current git commit hash
            git_result = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                capture_output=True, check=True, text=True,
                cwd=self.env_loader.root_dir
            )
            git_commit = git_result.stdout.strip()
        except subprocess.CalledProcessError:
            print_error("Failed to get git commit hash")
            backup_config.unlink()  # Remove backup
            return False

        # Get real deployment info (block numbers and tx hashes) from broadcast artifacts
        broadcast_deployment_info = {}
        if deployment_script:
            broadcast_deployment_info = self._get_broadcast_deployment_info(deployment_script)

        try:
            # Load both files
            with open(network_config, 'r') as f:
                config_data = json.load(f)
            with open(self.latest_deployment, 'r') as f:
                latest_data = json.load(f)

            # Merge the contracts section
            if 'contracts' not in config_data:
                config_data['contracts'] = {}

            # Update contracts with new deployments
            contracts_from_latest = latest_data.get('contracts', {})
            for contract_name, contract_data in contracts_from_latest.items():
                # Extract address from either format
                if isinstance(contract_data, dict):
                    contract_address = contract_data.get('address')
                else:
                    contract_address = contract_data
                
                if not contract_address:
                    continue
                
                # Get real deployment info from broadcast artifacts (preferred)
                deploy_info = broadcast_deployment_info.get(contract_address.lower(), {})
                
                # Always write in the new format with address, blockNumber, and txHash
                config_data['contracts'][contract_name] = {
                    'address': contract_address,
                    'blockNumber': deploy_info.get('blockNumber'),  # Will be None if not found
                    'txHash': deploy_info.get('txHash')  # Will be None if not found
                }


            # Get deployment timestamp from latest deployment file
            latest_stat = self.latest_deployment.stat()
            deployment_timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(latest_stat.st_mtime))
            # Set deployment info
            if 'deploymentInfo' not in config_data:
                config_data['deploymentInfo'] = {}

            # Determine which deployment info entry to update
            deployment_step = self.args.step
            if deployment_step in ["release:sepolia", "deploy:testnets"]:
                # For release:sepolia and deploy:testnets, update the deploy:full entry instead
                deployment_step = "deploy:full"
            
            if "deploy" in deployment_step:
                # if there's a deploy:adapters, deploy:full overrides them. Delete:
                if 'deploymentInfo' in config_data and 'deploy:adapters' in config_data['deploymentInfo']:
                    del config_data['deploymentInfo']['deploy:adapters']
                config_data['deploymentInfo'][deployment_step] = {
                    'gitCommit': git_commit,
                    'timestamp': deployment_timestamp,
                    'version': os.environ.get("VERSION", "Null / NotSet")
                }

            # Write updated config
            with open(network_config, 'w') as f:
                json.dump(config_data, f, indent=2)

            # Remove backup since update was successful
            backup_config.unlink()

            relative_path = format_path(network_config, self.root_dir)
            print_success(f"Deployed contracts added to {relative_path} (.contracts section)")
            return True

        except (json.JSONDecodeError, KeyError, IOError) as e:
            print_error(f"Failed to update network config: {e}")
            print_error("Full error details:")
            print_error(traceback.format_exc())
            # Restore backup
            shutil.move(backup_config, network_config)
            return False

    def _check_deployment_age(self) -> bool:
        """Check if -latest.json is old and should warn user"""
        if not self.latest_deployment.exists():
            return False

        latest_file_age = int(time.time() - self.latest_deployment.stat().st_mtime)
        one_day_in_seconds = 86400

        return latest_file_age > one_day_in_seconds

    def _is_deployment_old(self) -> bool:
        """Check if -latest.json is old and should warn user
           Returns True deployment is old, False if not (or if user wants to proceed)"""

        latest_deploy_file = format_path(self.latest_deployment, self.root_dir)
        deploy_config = format_path(self.env_loader.config_file, self.root_dir)
        latest_file_age = int(time.time() - self.latest_deployment.stat().st_mtime)
        one_day_in_seconds = 86400

        if latest_file_age < one_day_in_seconds:
            return False
        # else

        print_warning(f"{latest_deploy_file} is old (age: {latest_file_age // 3600} hours)")
        print_warning(f"This will replace contracts in {deploy_config} with addresses from {latest_deploy_file}")

        while True:
            try:
                choice = input("Do you want to proceed? (y/N): ").strip().lower()
                if choice in ["y", "yes"]:
                    return False
                elif choice in ["n", "no", ""]:
                    return True
                else:
                    print_info("Please enter 'y' or 'n'")
            except (EOFError, KeyboardInterrupt):
                print_info("No choice made, skipping update")
                return True
