#!/usr/bin/env python3
"""
Centrifuge Protocol Release Manager

Handles orchestrated deployments across multiple networks for release processes.
This includes deploying protocol contracts, verification, wiring adapters, and test data.
"""

import os
import time
import json
from pathlib import Path
from typing import List, Dict, Any
from .formatter import *
from .load_config import EnvironmentLoader
from .runner import DeploymentRunner
from .verifier import ContractVerifier


class ReleaseManager:
    """Manages multi-network deployment orchestration for releases"""
    
    def __init__(self, root_dir: Path, args):
        self.root_dir = root_dir
        self.args = args
        self.deployment_summary = {}
        self.state_file = root_dir / "script" / "deploy"  / "logs" / "release_state.json"
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
    
    def deploy_sepolia_testnets(self) -> bool:
        """
        Deploy protocol to all Sepolia testnets (Sepolia, Base Sepolia, Arbitrum Sepolia)
        
        Returns:
            bool: True if all deployments succeeded, False otherwise
        """
        print_section("🚀 Sepolia Testnet Release Deployment")
        print_info("This will deploy to: Sepolia, Base Sepolia, and Arbitrum Sepolia")
        print_info("Each network will be deployed, verified, wired, and loaded with test data")
        print_warning("This process may take 30-60 minutes")
        
        # Load existing state or initialize new
        self._load_state()

        # Check if suffix changed - if so, clear state and start fresh
        current_suffix = os.environ.get("SUFFIX", "")
        saved_suffix = self.deployment_summary.get("suffix")

        if saved_suffix is not None and saved_suffix != current_suffix:
            print_warning(f"SUFFIX changed from '{saved_suffix}' to '{current_suffix}'")
            print_info("🔄 Clearing state and starting fresh deployment...")
            self.clear_state()
        elif self.deployment_summary.get("networks"):
            print_info("📋 Resuming previous deployment...")
            self._print_resume_status()
        
        # Build contracts once upfront (only if not resuming and not dry-run)
        if not self.deployment_summary.get("networks") and not self.args.dry_run:
            print_subsection("Building contracts")
            temp_env = EnvironmentLoader(network_name="sepolia", root_dir=self.root_dir, args=self.args)
            temp_runner = DeploymentRunner(temp_env, self.args)
            temp_runner.build_contracts()
        
        # Initialize deployment summary if new
        if not self.deployment_summary.get("networks"):
            self.deployment_summary = {
                "suffix": os.environ.get("SUFFIX", ""),
                "networks": {},
                "started_at": time.strftime("%Y-%m-%d %H:%M:%S")
            }
        
        networks = ["sepolia", "base-sepolia", "arbitrum-sepolia"]
        
        # Deploy to each network (skip completed ones)
        for network in networks:
            print_info(f"🔍 Checking {network.upper()} status...")
            if self._is_network_complete(network):
                print_info(f"⏭️  Skipping {network.upper()} - already completed")
                continue
            else:
                print_info(f"📡 {network.upper()} needs deployment")
                
            if not self._deploy_network(network):
                self.deployment_summary["failed_at"] = network
                self._save_state()
                self._print_summary()
                return False
        
        # Success!
        self.deployment_summary["completed_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
        self._save_state()
        self._print_summary()
        print_success("🎉 All Sepolia testnets deployed successfully!")
        return True
    
    def _deploy_network(self, network: str) -> bool:
        """
        Deploy protocol to a single network with all steps
        
        Args:
            network: Network name (e.g., "sepolia", "base-sepolia")
            
        Returns:
            bool: True if deployment succeeded, False otherwise
        """
        print_section(f"📡 Deploying to {network.upper()}")
        
        # Initialize network status if not already present
        if network not in self.deployment_summary["networks"]:
            self.deployment_summary["networks"][network] = {
                "protocol": False,
                "verification": False,
                "wiring": False,
                "test_data": False
            }
        
        # Create environment loader and tools for this network
        network_env = EnvironmentLoader(
            network_name=network,
            root_dir=self.root_dir,
            args=self.args
        )
        network_runner = DeploymentRunner(network_env, self.args)
        network_verifier = ContractVerifier(network_env, self.args)

        # Step 1: Deploy protocol with retries (skip if already done)
        if not self.deployment_summary["networks"][network]["protocol"]:
            print_subsection(f"Step 1/4: Deploying protocol contracts to {network}")
            # The gate is a per-chain prerequisite of both phases, and is never brought up from here: its salt
            # embeds its deployer, so a gate deployed with the release key would give this chain a different
            # address set than every other one. A missing gate is not transient, so it must not be retried
            if not self._has_deploy_gate(network_env, network_verifier):
                print_error(f"No DeployGate on {network}. Bring it up once, from the canonical deployer:")
                print_info(f"  EXECUTORS=<addresses> NETWORK={network} forge script script/DeployGateDeployer.s.sol \\")
                print_info(f"    --tc DeployGateDeployer --rpc-url <rpc> --ledger --broadcast")
                print_info(f"  python3 script/deploy/deploy.py {network} verify:contracts")
                self._save_state()
                return False

            # The protocol goes through the DeployGate in one run per phase, and each is retried on its own:
            # a failed execute has to be retried as execute, since re-entering validate would redeploy the
            # whole protocol locally onto addresses the partial execute has already taken
            phases = network_runner.gated_phases()
            started_at = time.time()
            for phase in phases:
                if not self._retry_deployment(network, network_runner, "LaunchDeployer", None, phase):
                    self._save_state()
                    return False

            # The step is recorded here, not by the phase that finished, so that it is only ever recorded over
            # a deployment that is actually on chain. A forge run reports its own exit code, which says nothing
            # about whether it deployed anything, and the steps below would otherwise run against an empty chain
            if "execute" in phases and not self._protocol_landed(network_verifier, started_at):
                print_error(f"The execute phase reported success but deployed nothing on {network}")
                self._save_state()
                return False

            self.deployment_summary["networks"][network]["protocol"] = True
            self._save_state()
        else:
            print_info("⏭️  Protocol already deployed, skipping...")
        
        # Step 2: Verify contracts with retries (skip if already done or dry-run)
        if not self.deployment_summary["networks"][network]["verification"]:
            if not self.args.dry_run:
                print_subsection(f"Step 2/4: Verifying contracts on {network}")
                if not self._retry_verification(network, network_verifier, "LaunchDeployer", "verification"):
                    self._save_state()
                    return False
            else:
                print_info("⏭️  Dry-run mode: skipping verification")
                self.deployment_summary["networks"][network]["verification"] = True
        else:
            print_info("⏭️  Contracts already verified, skipping...")
        
        # Step 3: Wire adapters (skip if already done)
        if not self.deployment_summary["networks"][network]["wiring"]:
            print_subsection(f"Step 3/4: Wiring adapters on {network}")
            if not self._retry_deployment(network, network_runner, "WireAdapters", "wiring"):
                self._save_state()
                return False
        else:
            print_info("⏭️  Adapters already wired, skipping...")
        
        # Step 4: Deploy test data (skip if already done)
        if not self.deployment_summary["networks"][network]["test_data"]:
            print_subsection(f"Step 4/4: Deploying test data to {network}")
            if not self._retry_deployment(network, network_runner, "TestData", "test_data"):
                self._save_state()
                return False
        else:
            print_info("⏭️  Test data already deployed, skipping...")
        
        print_success(f"🎉 {network.upper()} deployment complete!\n")
        self._save_state()
        return True
    
    
    def _print_summary(self):
        """Print a formatted summary of the deployment results"""
        print_section("📊 Deployment Summary")
        suffix = self.deployment_summary.get('suffix', '')
        print_info(f"Suffix: {suffix if suffix else '(none - canonical addresses)'}")
        print_info(f"Started: {self.deployment_summary.get('started_at', 'N/A')}")
        
        if "completed_at" in self.deployment_summary:
            print_info(f"Completed: {self.deployment_summary['completed_at']}")
        
        if "failed_at" in self.deployment_summary:
            print_error(f"Failed at: {self.deployment_summary['failed_at']}")
        
        print_step("Network Status:")
        for network, status in self.deployment_summary.get("networks", {}).items():
            print_info(f"\n  {network.upper()}:")
            print_info(f"    Protocol:     {'✓' if status.get('protocol') else '✗'}")
            print_info(f"    Verification: {'✓' if status.get('verification') else '✗'}")
            print_info(f"    Wiring:       {'✓' if status.get('wiring') else '✗'}")
            print_info(f"    Test Data:    {'✓' if status.get('test_data') else '✗'}")
    
    def _retry_deployment(
        self, network: str, runner: DeploymentRunner, script_name: str, step_name: str, phase: str = None
    ) -> bool:
        """
        Generic retry mechanism for deployment steps with 1-minute waits and --resume

        Args:
            network: Network name
            runner: DeploymentRunner instance
            script_name: Name of the deployment script (e.g., "LaunchDeployer")
            step_name: Name of the step for tracking (e.g., "protocol"), or None not to record it
            phase: DEPLOY_PHASE for a gated deployment, one phase per call

        Returns:
            bool: True if deployment succeeded, False otherwise
        """
        # An existing broadcast file says a previous run of this script stopped partway, so resume it rather
        # than simulating it again. Not for a gated deployment: its phases share the one sequence file, so an
        # existing one may well have been written by the phase that just succeeded, and resuming that would
        # find it confirmed and deploy nothing
        resume = phase is None and self._has_partial_deployment(runner, script_name)
        if resume:
            print_info(f"📂 Detected existing broadcast file for {script_name} on {network}, resuming")

        label = f"{script_name} ({phase})" if phase else script_name
        retries = 3
        attempt = 0

        while attempt < retries:
            attempt += 1
            print_info(f"{label}: deployment attempt {attempt}/{retries}")

            sequence = self._sequence_state(runner, script_name)
            if runner.run_deploy(script_name, phase, resume):
                if step_name:
                    self.deployment_summary["networks"][network][step_name] = True
                    self._save_state()  # Save state after each successful step
                print_success(f"✓ {label} finished on {network}")
                return True

            if attempt < retries:
                # --resume replays the saved sequence, so it is only ever valid once this phase has written
                # one. An attempt that failed in simulation broadcast nothing and left the file as whoever ran
                # before it wrote it, which for a gated deployment is the validate phase: resuming that would
                # find its one transaction confirmed, send nothing, and report success over an empty chain.
                # Sticky once it does broadcast, since from then on the contracts it deployed are on chain and
                # simulating the phase again would abort on the first validation it already spent
                resume = resume or self._sequence_state(runner, script_name) != sequence
                how = "with --resume" if resume else "from scratch (nothing was broadcast)"
                print_warning(f"Deployment failed, waiting 1 minute then retrying {how}...")
                time.sleep(60)  # Wait 1 minute before retry

        print_error(f"✗ Failed to deploy {label} to {network} after {retries} attempts")
        return False
    
    def _retry_verification(self, network: str, verifier: ContractVerifier, script_name: str, step_name: str) -> bool:
        """
        Generic retry mechanism for verification steps with 1-minute waits
        
        Args:
            network: Network name
            verifier: ContractVerifier instance
            script_name: Name of the script to verify (e.g., "LaunchDeployer")
            step_name: Name of the step for tracking (e.g., "verification")
            
        Returns:
            bool: True if verification succeeded, False otherwise
        """
        retries = 3
        attempt = 0
        
        while attempt < retries:
            attempt += 1
            print_info(f"Verification attempt {attempt}/{retries}")
            
            if verifier.verify_contracts(script_name):
                self.deployment_summary["networks"][network][step_name] = True
                self._save_state()  # Save state after each successful step
                print_success(f"✓ Contracts verified on {network}")
                return True
            
            if attempt < retries:
                print_warning(f"Verification incomplete, waiting 1 minute then retrying...")
                time.sleep(60)  # Wait 1 minute before retry
        
        print_error(f"✗ Failed to verify all contracts on {network}")
        return False
    
    def _load_state(self):
        """Load deployment state from file"""
        if self.state_file.exists():
            try:
                with open(self.state_file, 'r') as f:
                    self.deployment_summary = json.load(f)
                print_info(f"📂 Loaded deployment state from {self.state_file}")
            except (json.JSONDecodeError, FileNotFoundError) as e:
                print_warning(f"Could not load state file: {e}")
                self.deployment_summary = {}
        else:
            self.deployment_summary = {}
    
    def _save_state(self):
        """Save deployment state to file"""
        if self.args.dry_run:
            print_info("💾 Dry-run mode: skipping state save")
            return
        try:
            with open(self.state_file, 'w') as f:
                json.dump(self.deployment_summary, f, indent=2)
            print_info(f"💾 State saved to {self.state_file}")
        except Exception as e:
            print_warning(f"Could not save state file: {e}")
    
    def _is_network_complete(self, network: str) -> bool:
        """Check if a network deployment is complete"""
        if network not in self.deployment_summary.get("networks", {}):
            return False
        
        network_status = self.deployment_summary["networks"][network]
        return all([
            network_status.get("protocol", False),
            network_status.get("verification", False),
            network_status.get("wiring", False),
            network_status.get("test_data", False)
        ])
    
    def _print_resume_status(self):
        """Print status of what will be resumed"""
        print_subsection("Resume Status:")
        for network, status in self.deployment_summary.get("networks", {}).items():
            completed_steps = []
            if status.get("protocol"): completed_steps.append("Protocol")
            if status.get("verification"): completed_steps.append("Verification")
            if status.get("wiring"): completed_steps.append("Wiring")
            if status.get("test_data"): completed_steps.append("Test Data")
            
            if completed_steps:
                print_info(f"  {network.upper()}: {', '.join(completed_steps)} completed")
            else:
                print_info(f"  {network.upper()}: Not started")
    
    def clear_state(self):
        """Clear deployment state (useful for starting fresh)"""
        if self.state_file.exists():
            self.state_file.unlink()
            print_info("🗑️  Cleared deployment state")
        self.deployment_summary = {}
    
    def _has_deploy_gate(self, network_env: EnvironmentLoader, verifier: ContractVerifier) -> bool:
        """Check that the chain has the DeployGate both phases of a gated deployment need"""
        entry = (network_env.config.get("contracts", {}) or {}).get("deployGate") or {}
        gate = entry.get("address") if isinstance(entry, dict) else entry

        try:
            missing = not gate or int(gate, 16) == 0
        except (TypeError, ValueError):
            missing = True

        if missing:
            print_error(f"No usable contracts.deployGate in {format_path(network_env.config_file, self.root_dir)}")
            return False
        if not verifier.is_contract_deployed(gate):
            print_error(f"contracts.deployGate is {gate}, but there is no code at that address")
            return False

        print_success(f"DeployGate found at {gate}")
        return True

    def _protocol_landed(self, verifier: ContractVerifier, since: float) -> bool:
        """Check that the execute phase actually deployed, rather than only exiting zero.

        The manifest is written by the phase that deploys, and only by it, so one that predates this run is
        the previous deployment's and its addresses hold nothing on this chain.
        """
        manifest = verifier.latest_deployment

        if not manifest.exists() or manifest.stat().st_mtime < since:
            print_error(f"No deployment manifest was written by this run ({format_path(manifest, self.root_dir)})")
            return False

        try:
            with open(manifest, 'r') as f:
                root = (json.load(f).get("contracts", {}) or {}).get("root")
        except (json.JSONDecodeError, OSError) as e:
            print_error(f"Could not read the deployment manifest: {e}")
            return False

        if not root:
            print_error("The deployment manifest reports no root")
            return False
        if not verifier.is_contract_deployed(root):
            print_error(f"The deployment manifest reports root at {root}, but there is no code at that address")
            return False

        return True

    def _sequence_state(self, runner: DeploymentRunner, script_name: str):
        """Fingerprint of the forge broadcast sequence, to tell whether a run broadcast anything"""
        run_latest = (
            self.root_dir / "broadcast" / f"{script_name}.s.sol" / runner.env_loader.chain_id / "run-latest.json"
        )

        try:
            stat = run_latest.stat()
            return (stat.st_mtime_ns, stat.st_size)
        except OSError:
            return None

    def _has_partial_deployment(self, runner: DeploymentRunner, script_name: str) -> bool:
        """
        Check if there's a partial deployment in progress by looking for broadcast files
        
        Args:
            runner: DeploymentRunner instance (to get chain_id)
            script_name: Name of the script (e.g., "LaunchDeployer", "TestData")
            
        Returns:
            bool: True if broadcast file exists and is recent, False otherwise
        """
        broadcast_dir = self.root_dir / "broadcast" / f"{script_name}.s.sol" / runner.env_loader.chain_id
        run_latest = broadcast_dir / "run-latest.json"
        
        if not run_latest.exists():
            return False
        
        # Check if the file is recent (less than 24 hours old)
        try:
            file_age = time.time() - run_latest.stat().st_mtime
            # If file is recent (24h=86400 seconds, 1h=3600 seconds)
            if file_age < 3600:
                print_info(f"  Found recent broadcast file (age: {int(file_age/60)} minutes)")
                return True
            else:
                print_info(f"  Broadcast file is old (age: {int(file_age/3600)} hours), starting fresh")
                return False
        except Exception as e:
            print_warning(f"Could not check broadcast file age: {e}")
            return False


