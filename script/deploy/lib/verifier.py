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
        self.args = args
        self.root_dir = env_loader.root_dir
        self.rpc_url = self.env_loader.rpc_url
        self.etherscan_api_key = self.env_loader.etherscan_api_key

    def _get_broadcast_dir(self, deployment_script: str) -> pathlib.Path:
        """Get the broadcast directory for a deployment script."""
        if not deployment_script:
            return None

        script_path = deployment_script.split(":")[0] if ":" in deployment_script else deployment_script
        script_filename = pathlib.Path(script_path).name
        if not script_filename.endswith(".s.sol"):
            script_filename = f"{script_filename}.s.sol"

        return self.root_dir / "broadcast" / script_filename / str(self.env_loader.chain_id)

    def _get_broadcast_file(self, deployment_script: str) -> pathlib.Path:
        """Get the path to the broadcast run-latest.json file."""
        broadcast_dir = self._get_broadcast_dir(deployment_script)
        if not broadcast_dir:
            return None
        return broadcast_dir / "run-latest.json"

    def _merge_deployment_metadata(self, deployment_script: str) -> bool:
        """Merge the deployment-metadata.json sidecar into run-latest.json, then delete the sidecar."""
        broadcast_dir = self._get_broadcast_dir(deployment_script)
        if not broadcast_dir:
            return False

        sidecar = broadcast_dir / "deployment-metadata.json"
        broadcast_file = broadcast_dir / "run-latest.json"

        if not sidecar.exists():
            return False

        if not broadcast_file.exists():
            return False

        try:
            with open(sidecar, 'r') as f:
                metadata = json.load(f)
            with open(broadcast_file, 'r') as f:
                broadcast_data = json.load(f)

            broadcast_data['deploymentMetadata'] = metadata

            with open(broadcast_file, 'w') as f:
                json.dump(broadcast_data, f, indent=2)

            sidecar.unlink()
            print_step("Merged deployment metadata into broadcast file")
            return True
        except (json.JSONDecodeError, IOError) as e:
            print_warning(f"Failed to merge deployment metadata into broadcast file: {e}")
            return False

    def _broadcast_has_deployment_metadata(self, deployment_script: str) -> bool:
        """Check whether the broadcast file already contains embedded deployment metadata."""
        broadcast_file = self._get_broadcast_file(deployment_script)
        if not broadcast_file or not broadcast_file.exists():
            return False

        try:
            with open(broadcast_file, 'r') as f:
                data = json.load(f)
            return bool(data.get('deploymentMetadata'))
        except (json.JSONDecodeError, IOError) as e:
            print_warning(f"Failed to parse broadcast file: {e}")
            return False

    def finalize_broadcast_metadata(self, deployment_script: str) -> bool:
        """Ensure deployment metadata lives in run-latest.json before follow-up tooling reads it."""
        if not deployment_script:
            return False

        if self._merge_deployment_metadata(deployment_script):
            return True

        return self._broadcast_has_deployment_metadata(deployment_script)

    def _load_deployment_metadata(self, deployment_script: str) -> dict:
        """Load deployment metadata (logical names, addresses, versions) from the broadcast file.
        
        If a stale deployment-metadata.json sidecar exists, merge it into
        run-latest.json before reading.
        """
        self.finalize_broadcast_metadata(deployment_script)

        broadcast_file = self._get_broadcast_file(deployment_script)
        if not broadcast_file or not broadcast_file.exists():
            print_warning(f"Broadcast file not found: {broadcast_file}")
            return {}

        try:
            with open(broadcast_file, 'r') as f:
                data = json.load(f)
            metadata = data.get('deploymentMetadata')
            if not metadata:
                print_warning(f"No deploymentMetadata found in {broadcast_file}")
                return {}
            return metadata
        except (json.JSONDecodeError, IOError) as e:
            print_warning(f"Failed to parse broadcast file: {e}")
            return {}
    
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
        if not deployment_script:
            print_warning("No deployment script provided; skipping broadcast deployment info extraction")
            return {}

        broadcast_file = self._get_broadcast_file(deployment_script)

        if not broadcast_file or not broadcast_file.exists():
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
        """Verify contracts on Etherscan using deployment metadata from the broadcast file."""
        metadata = self._load_deployment_metadata(deployment_script)
        if not metadata:
            print_error(f"Deployment metadata not found for script: {deployment_script}")
            return False

        broadcast_file = self._get_broadcast_file(deployment_script)
        relative_path = format_path(broadcast_file, self.root_dir)
        print_step(f"Checking contracts from {relative_path}")

        if not self.args.dry_run:
            contracts = metadata.get("contracts", {})
            if not contracts:
                print_error(f"No contracts found in {relative_path}")
                return False

            unverified_contracts = []
            undeployed_contracts = []
            verified_count = 0
            deployed_count = 0
            for contract_name, contract_data in contracts.items():
                contract_address = contract_data.get('address') if isinstance(contract_data, dict) else contract_data
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

            print_info(f"Deployment check complete: {deployed_count}/{len(contracts)} contracts deployed")
            print_info(f"Verification check complete: {verified_count}/{len(contracts)} contracts verified")

            if unverified_contracts or undeployed_contracts:
                print_error("Some contracts failed checks")
                return False
            else:
                print_success("All contracts checks passed!")
                print_info(f"Trying to update network config now...")
                # Check if metadata is old before updating main config
                if self._is_deployment_old(deployment_script):
                        print_info("Skipping update of main config file")
                        return True
                else:
                    self.update_network_config(deployment_script)
        else:
            print_info("Dry run mode, skipping contracts checks")

        return True

    def config_has_latest_contracts(self, deployment_script: str = None) -> bool:
        """Fast check: are contracts from deployment metadata already merged into env/<network>.json?"""
        try:
            metadata = self._load_deployment_metadata(deployment_script)
            if not metadata:
                return False
            with open(self.env_loader.config_file, 'r') as f:
                cfg = json.load(f)
            latest_contracts = metadata.get('contracts', {}) or {}
            config_contracts = cfg.get('contracts', {}) or {}
            # Require every contract in metadata to exist in config with identical address
            for name, contract_data in latest_contracts.items():
                addr = contract_data.get('address') if isinstance(contract_data, dict) else contract_data
                cfg_entry = config_contracts.get(name)
                cfg_addr = cfg_entry.get('address') if isinstance(cfg_entry, dict) else cfg_entry
                if not cfg_addr or cfg_addr.lower() != addr.lower():
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
        """Update network config with deployment output from the broadcast directory."""
        relative_path = format_path(self.env_loader.config_file, self.root_dir)
        print_step(f"Merging contract addresses to {relative_path}")
        network_config = self.env_loader.config_file

        # Load deployment metadata from broadcast directory
        metadata = self._load_deployment_metadata(deployment_script)
        if not metadata:
            print_error(f"Deployment metadata not found for script: {deployment_script}")
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
            print_error("Failed to get git commit hash")
            backup_config.unlink()  # Remove backup
            return False

        # Get real deployment info (block numbers and tx hashes) from broadcast artifacts
        broadcast_deployment_info = {}
        if deployment_script:
            broadcast_deployment_info = self._get_broadcast_deployment_info(deployment_script)

        try:
            # Load network config
            with open(network_config, 'r') as f:
                config_data = json.load(f)

            # Merge the contracts section
            if 'contracts' not in config_data:
                config_data['contracts'] = {}

            # Update contracts with new deployments from metadata
            contracts_from_metadata = metadata.get('contracts', {})
            for contract_name, contract_data in contracts_from_metadata.items():
                # Extract address from either format
                if isinstance(contract_data, dict):
                    contract_address = contract_data.get('address')
                else:
                    contract_address = contract_data

                if not contract_address:
                    continue

                # Get real deployment info from broadcast artifacts (preferred)
                deploy_info = broadcast_deployment_info.get(contract_address.lower(), {})

                # Preserve existing blockNumber/txHash/version if we are not able to resolve them from broadcast.
                # This is important for flows like `verify:contracts` where no deployment script/broadcast is provided.
                existing_entry = config_data['contracts'].get(contract_name)
                existing_address = None
                existing_block = None
                existing_tx = None
                existing_version = None
                if isinstance(existing_entry, dict):
                    existing_address = existing_entry.get('address')
                    existing_block = existing_entry.get('blockNumber')
                    existing_tx = existing_entry.get('txHash')
                    existing_version = existing_entry.get('version')

                new_block = deploy_info.get('blockNumber')
                new_tx = deploy_info.get('txHash')
                new_version = contract_data.get('version') if isinstance(contract_data, dict) else None

                same_address = (
                    isinstance(existing_address, str)
                    and existing_address.lower() == contract_address.lower()
                )

                block_out = new_block if new_block is not None else (existing_block if same_address else None)
                tx_out = new_tx if new_tx is not None else (existing_tx if same_address else None)
                version_out = new_version or (existing_version if same_address else None)

                # Always write in the new format with address, blockNumber, txHash, and version
                entry = {
                    'address': contract_address,
                    'blockNumber': block_out,
                    'txHash': tx_out,
                }
                if version_out:
                    entry['version'] = version_out
                config_data['contracts'][contract_name] = entry

            # Get deployment timestamp from broadcast file
            broadcast_file = self._get_broadcast_file(deployment_script)
            broadcast_stat = broadcast_file.stat()
            deployment_timestamp = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(broadcast_stat.st_mtime))

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
                    'suffix': os.environ.get("SUFFIX", "")
                }

            # Always include suffix key in deploymentInfo
            if deployment_step not in config_data['deploymentInfo']:
                config_data['deploymentInfo'][deployment_step] = {}
            config_data['deploymentInfo'][deployment_step]['suffix'] = os.environ.get("SUFFIX", "")
            
            # Get startBlock from deployment metadata if available
            # Only calculate from contract block numbers if not provided by deployment
            deployment_start_block = metadata.get('deploymentStartBlock')
            if deployment_start_block is not None:
                # Use startBlock from deployment metadata
                config_data['deploymentInfo'][deployment_step]['startBlock'] = int(deployment_start_block)
            else:
                # Fallback: Calculate from deployed contract block numbers
                # Collect all block numbers from this deployment (from broadcast artifacts)
                deployed_block_numbers = []
                for contract_name, contract_data in contracts_from_metadata.items():
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

    def _is_deployment_old(self, deployment_script: str) -> bool:
        """Check if the broadcast file is old and should warn user.
           Returns True if deployment is old, False if not (or if user wants to proceed)."""
        broadcast_file = self._get_broadcast_file(deployment_script)
        if not broadcast_file or not broadcast_file.exists():
            return False

        deploy_config = format_path(self.env_loader.config_file, self.root_dir)
        broadcast_display = format_path(broadcast_file, self.root_dir)
        file_age = int(time.time() - broadcast_file.stat().st_mtime)
        one_day_in_seconds = 86400

        if file_age < one_day_in_seconds:
            return False

        print_warning(f"{broadcast_display} is old (age: {file_age // 3600} hours)")
        print_warning(f"This will replace contracts in {deploy_config} with addresses from {broadcast_display}")

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
