#!/usr/bin/env python3
"""
Centrifuge Protocol Release Manager

Handles orchestrated deployments across multiple networks for release processes.
This includes deploying protocol contracts, verification, wiring adapters, and test data.
"""

import os
import time
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
        
        # Build contracts once upfront
        print_subsection("Building contracts")
        temp_env = EnvironmentLoader(network_name="sepolia", root_dir=self.root_dir, args=self.args)
        temp_runner = DeploymentRunner(temp_env, self.args)
        temp_runner.build_contracts()
        
        # Initialize deployment summary
        self.deployment_summary = {
            "version": os.environ.get("VERSION"),
            "networks": {},
            "started_at": time.strftime("%Y-%m-%d %H:%M:%S")
        }
        
        networks = ["sepolia", "base-sepolia", "arbitrum-sepolia"]
        
        # Deploy to each network
        for network in networks:
            if not self._deploy_network(network):
                self.deployment_summary["failed_at"] = network
                self._print_summary()
                return False
        
        # Success!
        self.deployment_summary["completed_at"] = time.strftime("%Y-%m-%d %H:%M:%S")
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
        
        # Initialize network status
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
        
        # Step 1: Deploy protocol with retries
        if not self._deploy_protocol(network, network_runner):
            return False
        
        # Step 2: Verify contracts with retries
        if not self._verify_contracts(network, network_verifier):
            return False
        
        # Step 3: Wire adapters
        if not self._wire_adapters(network, network_runner):
            return False
        
        # Step 4: Deploy test data
        if not self._deploy_test_data(network, network_runner):
            return False
        
        print_success(f"🎉 {network.upper()} deployment complete!\n")
        return True
    
    def _deploy_protocol(self, network: str, runner: DeploymentRunner) -> bool:
        """Deploy protocol contracts with retries"""
        print_subsection(f"Step 1/4: Deploying protocol contracts to {network}")
        
        retries = 3
        attempt = 0
        
        while attempt < retries:
            attempt += 1
            print_info(f"Deployment attempt {attempt}/{retries}")
            
            if runner.run_deploy("LaunchDeployer"):
                self.deployment_summary["networks"][network]["protocol"] = True
                print_success(f"✓ Protocol deployed to {network}")
                return True
            
            if attempt < retries:
                print_warning(f"Deployment failed, retrying with --resume...")
                if "--resume" not in self.args.forge_args:
                    self.args.forge_args.append("--resume")
                time.sleep(5)
        
        print_error(f"✗ Failed to deploy protocol to {network} after {retries} attempts")
        return False
    
    def _verify_contracts(self, network: str, verifier: ContractVerifier) -> bool:
        """Verify contracts with retries"""
        print_subsection(f"Step 2/4: Verifying contracts on {network}")
        
        retries = 3
        attempt = 0
        
        while attempt < retries:
            attempt += 1
            print_info(f"Verification attempt {attempt}/{retries}")
            
            if verifier.verify_contracts("LaunchDeployer"):
                self.deployment_summary["networks"][network]["verification"] = True
                print_success(f"✓ Contracts verified on {network}")
                return True
            
            if attempt < retries:
                print_warning(f"Verification incomplete, retrying in 30s...")
                time.sleep(30)
        
        print_error(f"✗ Failed to verify all contracts on {network}")
        return False
    
    def _wire_adapters(self, network: str, runner: DeploymentRunner) -> bool:
        """Wire adapters for the network"""
        print_subsection(f"Step 3/4: Wiring adapters on {network}")
        
        if runner.run_deploy("WireAdapters"):
            self.deployment_summary["networks"][network]["wiring"] = True
            print_success(f"✓ Adapters wired on {network}")
            return True
        
        print_error(f"✗ Failed to wire adapters on {network}")
        return False
    
    def _deploy_test_data(self, network: str, runner: DeploymentRunner) -> bool:
        """Deploy test data to the network"""
        print_subsection(f"Step 4/4: Deploying test data to {network}")
        
        if runner.run_deploy("TestData"):
            self.deployment_summary["networks"][network]["test_data"] = True
            print_success(f"✓ Test data deployed to {network}")
            return True
        
        print_error(f"✗ Failed to deploy test data to {network}")
        return False
    
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


