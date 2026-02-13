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

        Important: We do NOT rely on `receipts[].contractAddress` because:
        - some deployments (e.g. CREATE3/factory patterns) will not populate it, and
        - the same address may appear multiple times across receipts in some broadcasts.

        Approach:
        - derive deployed contract addresses from `transactions[]` (and `transactions[].additionalContracts[]`)
          using their `contractName` + `contractAddress`
        - derive the blockNumber/txHash by looking up receipts by the *parent transaction hash*
          (and if an address maps to multiple tx hashes, use the youngest/max blockNumber)

        Returns a dict mapping lowercase addresses to { blockNumber, txHash }.
        """
        # Find the broadcast file
        # deployment_script can be one of:
        # - "script/SomeScript.s.sol:ScriptName"
        # - "script/SomeScript.s.sol"
        # - "SomeScript.s.sol" (e.g. "LaunchDeployer.s.sol")
        # - "SomeScript" (e.g. "LaunchDeployer")
        if not deployment_script:
            print_warning("No deployment script provided; skipping broadcast deployment info extraction")
            return {}

        script_path = deployment_script.split(":")[0] if ":" in deployment_script else deployment_script
        script_filename = pathlib.Path(script_path).name  # e.g., "LaunchDeployer.s.sol" or "LaunchDeployer"
        if not script_filename.endswith(".s.sol"):
            script_filename = f"{script_filename}.s.sol"

        broadcast_dir = self.root_dir / "broadcast" / script_filename / str(self.env_loader.chain_id)
        broadcast_file = broadcast_dir / "run-latest.json"

        if not broadcast_file.exists():
            print_warning(f"Broadcast file not found: {broadcast_file}")
            return {}

        try:
            with open(broadcast_file, 'r') as f:
                broadcast_data = json.load(f)

            transactions = broadcast_data.get("transactions", []) or []
            receipts = broadcast_data.get("receipts", []) or []

            def _parse_block_number(raw):
                if raw is None:
                    return None
                if isinstance(raw, int):
                    return raw
                if isinstance(raw, str):
                    try:
                        return int(raw, 16) if raw.startswith("0x") else int(raw)
                    except ValueError:
                        return None
                return None

            # Build txHash -> blockNumber mapping from receipts (receipts are per tx)
            txhash_to_block = {}
            for receipt in receipts:
                tx_hash = receipt.get("transactionHash") or receipt.get("hash")
                if not tx_hash:
                    continue
                block_int = _parse_block_number(receipt.get("blockNumber"))
                if block_int is None:
                    continue
                txhash_to_block[tx_hash.lower()] = block_int

            # Build address -> tx hashes from transactions (top-level + additionalContracts)
            # Only include entries with a contractName, to avoid mistakenly capturing call targets.
            address_to_txhashes = {}

            def _add_contract(contract_name, contract_address, parent_tx_hash):
                if not contract_name or not contract_address or not parent_tx_hash:
                    return
                addr_l = contract_address.lower()
                tx_l = parent_tx_hash.lower()
                if addr_l not in address_to_txhashes:
                    address_to_txhashes[addr_l] = set()
                address_to_txhashes[addr_l].add(tx_l)

            for tx in transactions:
                parent_hash = tx.get("hash") or tx.get("transactionHash")
                _add_contract(tx.get("contractName"), tx.get("contractAddress"), parent_hash)

                for extra in tx.get("additionalContracts", []) or []:
                    # additionalContracts use "address" not "contractAddress"
                    _add_contract(extra.get("contractName"), extra.get("address"), parent_hash)

            # Compute per-address deployment info from associated tx hashes.
            # If an address maps to multiple tx hashes, pick the youngest/max blockNumber.
            deployment_info = {}
            for addr_l, tx_hashes in address_to_txhashes.items():
                best_block = None
                best_hash = None
                for tx_l in tx_hashes:
                    bn = txhash_to_block.get(tx_l)
                    if bn is None:
                        continue
                    if best_block is None or bn > best_block:
                        best_block = bn
                        best_hash = tx_l

                deployment_info[addr_l] = {
                    'blockNumber': best_block if best_block is not None else None,
                    'txHash': best_hash,
                }

            if deployment_info:
                print_step(
                    f"Found {len(deployment_info)} contract deployments from broadcast artifacts "
                    f"(transactions/additionalContracts)"
                )
            else:
                print_warning("No contract deployments found in broadcast artifacts (transactions/additionalContracts)")

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
                
                # Preserve existing blockNumber/txHash if we are not able to resolve them from broadcast.
                # This is important for flows like `verify:contracts` where no deployment script/broadcast is provided.
                existing_entry = config_data['contracts'].get(contract_name)
                existing_address = None
                existing_block = None
                existing_tx = None
                if isinstance(existing_entry, dict):
                    existing_address = existing_entry.get('address')
                    existing_block = existing_entry.get('blockNumber')
                    existing_tx = existing_entry.get('txHash')
                
                new_block = deploy_info.get('blockNumber')
                new_tx = deploy_info.get('txHash')
                
                same_address = (
                    isinstance(existing_address, str)
                    and existing_address.lower() == contract_address.lower()
                )
                
                block_out = new_block if new_block is not None else (existing_block if same_address else None)
                tx_out = new_tx if new_tx is not None else (existing_tx if same_address else None)
                
                # Always write in the new format with address, blockNumber, and txHash
                config_data['contracts'][contract_name] = {
                    'address': contract_address,
                    'blockNumber': block_out,
                    'txHash': tx_out,
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

            # Always include VERSION key in deploymentInfo (may be empty string if not set)
            if deployment_step not in config_data['deploymentInfo']:
                config_data['deploymentInfo'][deployment_step] = {}
            config_data['deploymentInfo'][deployment_step]['version'] = os.environ.get("VERSION", "Null / NotSet")
            
            # Get startBlock from deployment mechanism (-latest.json file) if available
            # Only calculate from contract block numbers if not provided by deployment
            deployment_start_block = latest_data.get('deploymentStartBlock')
            if deployment_start_block is not None:
                # Use startBlock from deployment mechanism
                config_data['deploymentInfo'][deployment_step]['startBlock'] = int(deployment_start_block)
            else:
                # Fallback: Calculate from deployed contract block numbers
                # Collect all block numbers from this deployment (from broadcast artifacts)
                deployed_block_numbers = []
                for contract_name, contract_data in contracts_from_latest.items():
                    if isinstance(contract_data, dict):
                        contract_address = contract_data.get('address')
                    else:
                        contract_address = contract_data
                    
                    if not contract_address:
                        continue
                    
                    deploy_info = broadcast_deployment_info.get(contract_address.lower(), {})
                    new_block = deploy_info.get('blockNumber')
                    
                    if new_block is not None:
                        deployed_block_numbers.append(new_block)
                
                if deployed_block_numbers:
                    # Use outlier detection to find the startBlock of this deployment
                    # This handles cases where some contracts (like root) didn't change from previous deployments
                    calculated_start_block = self._calculate_start_block_with_outlier_detection(deployed_block_numbers)
                    if calculated_start_block is not None:
                        config_data['deploymentInfo'][deployment_step]['startBlock'] = calculated_start_block
                # If no new blocks were deployed (e.g., verify-only flow), preserve existing startBlock if present
                elif deployment_step in config_data['deploymentInfo'] and 'startBlock' in config_data['deploymentInfo'][deployment_step]:
                    # Keep existing startBlock
                    pass

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

    def _calculate_start_block_with_outlier_detection(self, block_numbers: list) -> int:
        """
        Calculate startBlock by eliminating outliers (contracts from previous deployments).
        
        Uses gap detection to identify the cluster of blocks from this deployment:
        1. Sorts all block numbers
        2. Identifies the last significant gap between consecutive blocks
        3. Uses blocks after the last gap (current deployment)
        4. Returns the minimum of those blocks
        
        This handles cases where some contracts (like root) didn't change from previous deployments.
        The "last" gap is used because there may be multiple large gaps (e.g., root from very old
        deployment, some contracts from last deployment, new contracts from current deployment).
        """
        if not block_numbers:
            return None
        
        if len(block_numbers) == 1:
            return block_numbers[0]
        
        # Sort block numbers
        sorted_blocks = sorted(block_numbers)
        
        # If we have only 2 blocks, use the minimum (can't reliably detect outliers)
        if len(sorted_blocks) <= 2:
            return sorted_blocks[0]
        
        # Look for large gaps between consecutive blocks
        # Find the LAST significant gap (closest to current deployment)
        # This handles cases with multiple gaps (e.g., root from old deployment, some contracts from last deployment)
        median_block = sorted_blocks[len(sorted_blocks) // 2]
        gap_threshold = max(10000, median_block * 0.1)  # At least 10000 blocks or 10% of median
        
        last_large_gap_index = -1
        for i in range(len(sorted_blocks) - 1):
            gap = sorted_blocks[i + 1] - sorted_blocks[i]
            if gap > gap_threshold:
                last_large_gap_index = i  # Keep updating to find the last one
        
        if last_large_gap_index >= 0:
            # Use blocks after the last large gap (current deployment)
            current_deployment_blocks = sorted_blocks[last_large_gap_index + 1:]
            return min(current_deployment_blocks)
        
        # If no large gap found, all blocks are likely from the same deployment
        return sorted_blocks[0]

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
