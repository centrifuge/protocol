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
from .formatter import Formatter
from .load_config import EnvironmentLoader


class ContractVerifier:
    def __init__(self, env_loader: EnvironmentLoader, args: argparse.Namespace):
        self.env_loader = env_loader
        self.latest_deployment = env_loader.root_dir / "env" / "latest" / f"{env_loader.chain_id}-latest.json"
        self.args = args
        self.root_dir = env_loader.root_dir
        self.rpc_url = self.env_loader.rpc_url
        self.etherscan_api_key = self.env_loader.etherscan_api_key

    def verify_contracts(self, deployment_script: str) -> bool:
        """Verify contracts on Etherscan"""
        contracts_file = self._determine_contracts_file()
        relative_path = Formatter.format_path(contracts_file, self.root_dir)
        Formatter.print_step(f"Checking contracts from {relative_path}")
        
        if not self.args.dry_run:
            contract_addresses = self._get_contract_addresses(contracts_file, deployment_script)
            if not contract_addresses:
                Formatter.print_error(f"No contracts found to verify for deployment script: {deployment_script}")
                return False

            unverified_contracts = []
            verified_count = 0

            for contract_name, contract_address in contract_addresses.items():
                if self._verify_single_contract(contract_name, contract_address):
                    verified_count += 1
                else:
                    unverified_contracts.append(f"{contract_name}:{contract_address}")
                
                time.sleep(0.5)  # Rate limiting

            Formatter.print_info(f"Verification check complete: {verified_count}/{len(contract_addresses)} contracts verified")

            if unverified_contracts:
                Formatter.print_error("Some contracts failed verification")
                return False
            else:
                Formatter.print_success("All contracts are verified!")
                self.update_network_config()
        else:
            Formatter.print_info("Dry run mode, skipping contracts checks (exists and verified)")
            
        return True

    def _determine_contracts_file(self) -> pathlib.Path:
        """Determine which contracts file to use for verification - matches bash logic"""
        network_config = self.env_loader.config_file

        if not self.latest_deployment.exists():
            return network_config

        Formatter.print_step("Checking if latest deployment differs from network env file...")

        # Compare addresses between files
        try:
            with open(network_config, 'r') as f:
                config_contracts = json.load(f).get("contracts", {})
            with open(self.latest_deployment, 'r') as f:
                latest_contracts = json.load(f).get("contracts", {})

            # Convert to sorted lists of "key:value" strings for comparison
            config_entries = sorted([f"{k}:{v}" for k, v in config_contracts.items()])
            latest_entries = sorted([f"{k}:{v}" for k, v in latest_contracts.items()])

            addresses_differ = config_entries != latest_entries

        except (json.JSONDecodeError, KeyError, IOError):
            # If we can't read files, default to network config
            return network_config

        if addresses_differ:
            latest_deploy_file = Formatter.format_path(self.latest_deployment, self.root_dir)
            deploy_config = Formatter.format_path(network_config, self.root_dir)
            
            Formatter.print_warning(f"{latest_deploy_file} has different contract addresses than {deploy_config}")
            Formatter.print_warning(f"This probably means etherscan contract verification failed")
            Formatter.print_warning(f"If you are sure the contracts are verified, you can manually update {deploy_config}")
            Formatter.print_warning(f"If you are not sure, you can run python3 deploy.py {self.env_loader.network_name} deploy:{self.args.step} --resume")

            # Check file ages
            latest_file_age = int(time.time() - self.latest_deployment.stat().st_mtime)
            deploy_file_age = int(time.time() - network_config.stat().st_mtime)
            one_day_in_seconds = 86400

            if latest_file_age > one_day_in_seconds:
                Formatter.print_warning(f"{latest_deploy_file} is old (age: {latest_file_age // 3600} hours)")
                Formatter.print_warning("Decide which contracts to verify:")
                Formatter.print_info(f"1. Verify {latest_deploy_file} - it will override {deploy_config} when finished")
                Formatter.print_info(f"2. Verify {deploy_config} - age: {deploy_file_age // 3600} hours")

                # Interactive choice
                choice = self._prompt_user_choice()
                if choice == "1":
                    Formatter.print_info(f"Use {latest_deploy_file} - and it will update {self.env_loader.config_file.name} when successful")
                    contracts_file = self.latest_deployment
                else:
                    Formatter.print_info(f"{deploy_config} contract list selected for verification checks")
                    contracts_file = network_config
            else:
                Formatter.print_info(f"{latest_deploy_file} contract list selected for verification checks")
                contracts_file = self.latest_deployment

            return contracts_file
        
        return network_config

    def _prompt_user_choice(self) -> str:
        """Prompt user for choice between files"""
        while True:
            try:
                choice = input("Choose option (1/2): ").strip()
                if choice in ["1", "2"]:
                    return choice
                else:
                    Formatter.print_info("Invalid choice, please try again")
            except (EOFError, KeyboardInterrupt):
                # Handle Ctrl+C or EOF gracefully
                Formatter.print_info("No choice made, defaulting to network config")
                return "2"

    def _get_contract_addresses(self, contracts_file: pathlib.Path, deployment_script: str) -> dict[str, str]:
        """Get contract addresses based on deployment type"""
        with open(contracts_file, 'r') as f:
            data = json.load(f)
        
        contracts = data.get("contracts", {})
        
        # Filter based on deployment script
        if deployment_script == "Adapters":
            # Only adapter contracts
            return {k: v for k, v in contracts.items() 
                   if k in ["wormholeAdapter", "axelarAdapter"]}
        elif deployment_script == "FullDeployer":
            # All contracts except adapters
            return {k: v for k, v in contracts.items() 
                   if k not in ["wormholeAdapter", "axelarAdapter"]}
        else:
            return contracts

    def _verify_single_contract(self, contract_name: str, contract_address: str) -> bool:
        """Verify a single contract"""
        # Check if contract is deployed
        if not self._is_contract_deployed(contract_address):
            Formatter.print_error(f"{contract_name} ({contract_address}) is NOT deployed (no code at address)")
            return False
        
        Formatter.print_success(f"{contract_name} ({contract_address}) is deployed")

        # Check if verified on Etherscan
        if self._is_contract_verified(contract_address):
            Formatter.print_success(f"{contract_name} ({contract_address}) is verified on Etherscan")
            return True
        else:
            Formatter.print_error(f"{contract_name} ({contract_address}) is deployed but NOT verified on Etherscan")
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
        
    def update_network_config(self):
        """Update network config with deployment output"""
        relative_path = Formatter.format_path(self.env_loader.config_file, self.root_dir)
        Formatter.print_step(f"Adding contract addresses to {relative_path}")
        network_config = self.env_loader.config_file

        if not self.latest_deployment.exists():
            Formatter.print_error(f"Deployment output file not found at {self.latest_deployment}")
            return False

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
            Formatter.print_error("Failed to get git commit hash")
            backup_config.unlink()  # Remove backup
            return False
        
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
            config_data['contracts'].update(latest_data.get('contracts', {}))
            
            
            # Get deployment timestamp from latest deployment file
            latest_stat = self.latest_deployment.stat()
            deployment_timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(latest_stat.st_mtime))
            # Set deployment info        
            if 'deploymentInfo' not in config_data:
                config_data['deploymentInfo'] = {}
            
            if "deploy" in self.args.step:
                config_data['deploymentInfo'][self.args.step] = {
                    'gitCommit': git_commit,
                    'timestamp': deployment_timestamp,
                }

            if os.environ.get("VERSION"):
                config_data['deploymentInfo'][self.args.step]['version'] = os.environ.get("VERSION")

            # Write updated config
            with open(network_config, 'w') as f:
                json.dump(config_data, f, indent=2)

            # Remove backup since update was successful
            backup_config.unlink()
            
            relative_path = Formatter.format_path(network_config, self.root_dir)
            Formatter.print_success(f"Deployed contracts added to {relative_path} (.contracts section)")
            return True

        except (json.JSONDecodeError, KeyError, IOError) as e:
            Formatter.print_error(f"Failed to update network config: {e}")
            Formatter.print_error("Full error details:")
            Formatter.print_error(traceback.format_exc())
            # Restore backup
            shutil.move(backup_config, network_config)
            return False 