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
        
        # Validate VERSION is set
        if not os.environ.get("VERSION"):
            print_error("VERSION environment variable is required for release deployments")
            print_info("Example: VERSION=v3.1.4 python3 script/deploy/deploy.py release:sepolia")
            return False
        
        # Load existing state or initialize new
        self._load_state()
        
        # Check if version changed - if so, clear state and start fresh
        current_version = os.environ.get("VERSION")
        saved_version = self.deployment_summary.get("version")
        
        if saved_version and saved_version != current_version:
            print_warning(f"Version changed from {saved_version} to {current_version}")
            print_info("🔄 Clearing state and starting fresh deployment...")
            self.clear_state()
        elif self.deployment_summary.get("networks"):
            print_info("📋 Resuming previous deployment...")
            self._print_resume_status()
        
        # Build contracts once upfront (only if not resuming)
        if not self.deployment_summary.get("networks"):
            print_subsection("Building contracts")
            temp_env = EnvironmentLoader(network_name="sepolia", root_dir=self.root_dir, args=self.args)
            temp_runner = DeploymentRunner(temp_env, self.args)
            temp_runner.build_contracts()
        
        # Initialize deployment summary if new
        if not self.deployment_summary.get("version"):
            self.deployment_summary = {
                "version": os.environ.get("VERSION"),
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
            if not self._retry_deployment(network, network_runner, "LaunchDeployer", "protocol"):
                self._save_state()
                return False
        else:
            print_info("⏭️  Protocol already deployed, skipping...")
        
        # Step 2: Verify contracts with retries (skip if already done)
        if not self.deployment_summary["networks"][network]["verification"]:
            print_subsection(f"Step 2/4: Verifying contracts on {network}")
            if not self._retry_verification(network, network_verifier, "LaunchDeployer", "verification"):
                self._save_state()
                return False
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
        print_info(f"Version: {self.deployment_summary.get('version', 'N/A')}")
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
    
    def _retry_deployment(self, network: str, runner: DeploymentRunner, script_name: str, step_name: str) -> bool:
        """
        Generic retry mechanism for deployment steps with 1-minute waits and --resume
        
        Args:
            network: Network name
            runner: DeploymentRunner instance
            script_name: Name of the deployment script (e.g., "LaunchDeployer")
            step_name: Name of the step for tracking (e.g., "protocol")
            
        Returns:
            bool: True if deployment succeeded, False otherwise
        """
        # Check if there's an existing broadcast file (indicating partial deployment)
        if self._has_partial_deployment(runner, script_name):
            print_info(f"📂 Detected existing broadcast file for {script_name} on {network}")
            if "--resume" not in self.args.forge_args:
                print_info("Adding --resume to continue from previous deployment")
                self.args.forge_args.append("--resume")
        
        retries = 3
        attempt = 0
        
        while attempt < retries:
            attempt += 1
            print_info(f"Deployment attempt {attempt}/{retries}")
            
            if runner.run_deploy(script_name):
                self.deployment_summary["networks"][network][step_name] = True
                self._save_state()  # Save state after each successful step
                print_success(f"✓ {script_name} deployed to {network}")
                return True
            
            if attempt < retries:
                print_warning(f"Deployment failed, waiting 1 minute then retrying with --resume...")
                if "--resume" not in self.args.forge_args:
                    self.args.forge_args.append("--resume")
                time.sleep(60)  # Wait 1 minute before retry
        
        print_error(f"✗ Failed to deploy {script_name} to {network} after {retries} attempts")
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


