#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool

A Python replacement for deploy.sh that handles:
- Network configuration loading
- Environment variable management  
- Contract deployment via Forge/Catapulta
- Contract verification on Etherscan
- Ledger hardware wallet support
"""

import argparse
import pathlib
import sys
import os
from lib.formatter import Formatter
from lib.load_config import EnvironmentLoader
from lib.runner import DeploymentRunner
from lib.verifier import ContractVerifier
from lib.anvil import AnvilManager


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Centrifuge Protocol Deployment Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
IMPORTANT: 
  - This script is designed to be run from the root directory of the project.
  - The network name must match the name of the network in the env/<network>.json file.
  - Run with VERSION=XYZ preceeding the python3 command to avoid create3 collisions.

Examples:
  VERSION=XYZ python3 deploy.py sepolia deploy:protocol
  python3 deploy.py base-sepolia deploy:adapters --catapulta --priority-gas-price 2
  python3 deploy.py sepolia deploy:test --resume
  python3 deploy.py sepolia verify:protocol
  python3 deploy.py arbitrum-sepolia verify:adapters
        """
    )
    
    parser.add_argument("network", nargs="?", help="Network name (must match env/<network>.json)")
    parser.add_argument("step", nargs="?", help="Deployment step", choices=[
        "deploy:protocol", "deploy:adapters", "wire:adapters", 
        "deploy:test", "verify:protocol", "verify:adapters", "forge:clean"
    ])
    parser.add_argument("--catapulta", action="store_true", help="Use Catapulta for deployment")
    parser.add_argument("--ledger", action="store_true", help="Force use of Ledger hardware wallet")
    parser.add_argument("forge_args", nargs="*", help="Additional arguments to pass to forge")
    parser.add_argument("--dry-run", action="store_true", help="Show what this script would do without running a deployment")
    
    return parser


def validate_arguments(args, root_dir: pathlib.Path):
    """Validate command line arguments and provide helpful error messages"""
    Formatter.print_section("Validating arguments")
    
    # Print detected arguments for debugging
    if args.dry_run:
        Formatter.print_step("Detected Arguments")
        Formatter.print_info(f"Network: {args.network}")
        Formatter.print_info(f"Step: {args.step}")
        Formatter.print_info(f"Catapulta: {args.catapulta}")
        Formatter.print_info(f"Ledger: {args.ledger}")
        if args.forge_args:
            Formatter.print_info(f"Forge args: {' '.join(args.forge_args)}")
        Formatter.print_info(f"VERSION env: {os.environ.get('VERSION', 'Not set')}")
    
    # Check for required arguments
    if not args.network:
        Formatter.print_error("Network name is required")
        Formatter.print_info("Available networks:")
        env_dir = root_dir / "env"
        if env_dir.exists():
            for config_file in env_dir.glob("*.json"):
                if config_file.name != "latest":
                    Formatter.print_info(f"  - {config_file.stem}")
        raise SystemExit(1)
    
    if not args.step:
        Formatter.print_error("Deployment step is required.")
        Formatter.print_info("Run python3 deploy.py --help for available steps")
        raise SystemExit(1)
    
    # Check if network config file exists
    network_config = root_dir / "env" / f"{args.network}.json"
    if not network_config.exists():
        Formatter.print_error(f"Network config file not found: {network_config}")
        Formatter.print_info("Available networks:")
        env_dir = root_dir / "env"
        if env_dir.exists():
            available_networks = [f.stem for f in env_dir.glob("*.json") if f.name != "latest"]
            if available_networks:
                for network in sorted(available_networks):
                    Formatter.print_info(f"  - {network}")
            else:
                Formatter.print_info("  No network configurations found")
        raise SystemExit(1)
    
    # Check if VERSION environment variable is set for deployment steps
    if args.step.startswith("deploy:") and not os.environ.get("VERSION") and not args.dry_run:
        Formatter.print_warning("VERSION environment variable not set. Create3 address collisions may occur.")
        Formatter.print_info("Consider running: VERSION=XYZ python3 deploy.py ...")
    
    # Validate forge arguments don't conflict with script defaults
    if args.forge_args:
        conflicting_args = ["--verify", "--broadcast", "--chain-id", "--tc", "--optimize"]
        for arg in args.forge_args:
            if any(arg.startswith(conflict) for conflict in conflicting_args):
                Formatter.print_warning(f"Forge argument '{arg}' may conflict with script defaults")
                raise SystemExit(1)
    
    return True


def main():
    parser = create_parser()
    args = parser.parse_args()
    
    # Get root directory early for validation
    script_dir = pathlib.Path(__file__).parent
    root_dir = script_dir.parent.parent
    
    # Handle forge:clean separately as it doesn't need network config
    if args.network == "forge:clean" or args.step == "forge:clean":
        Formatter.print_section("Cleaning Forge Build")
        try:
            import subprocess
            subprocess.run(["forge", "clean"], check=True)
            Formatter.print_success("Forge build cleaned successfully")
        except subprocess.CalledProcessError:
            Formatter.print_error("Failed to clean forge build")
            sys.exit(1)
        return
    
    # Validate arguments
    validate_arguments(args, root_dir)

    try:
        # Handle Anvil deployment specially - it's completely self-contained
        if args.network == "anvil":
            anvil_manager = AnvilManager(root_dir)
            success = anvil_manager.deploy_full_protocol()
            sys.exit(0 if success else 1)
        
        # Create environment loader with deployment mode settings
        env_loader = EnvironmentLoader(
            network_name=args.network,
            root_dir=root_dir,
            use_ledger=args.ledger,
            catapulta_mode=args.catapulta
        )
        
        Formatter.print_step(f"Network: {args.network}")
        Formatter.print_info(f"Chain ID: {env_loader.chain_id}")
        Formatter.print_info(f"Deployment mode: {'Catapulta' if args.catapulta else 'Forge'}")
        
        # Set up deployment runner and verifier
        runner = DeploymentRunner(env_loader, args)
        verifier = ContractVerifier(env_loader, args)
        
        # Execute the requested step
        if args.step == "deploy:protocol":
            Formatter.print_section("Running Deployment")
            runner.build_contracts()
            Formatter.print_subsection(f"Deploying core protocol contracts for {args.network}")
            
            if runner.run_deploy("FullDeployer", args.catapulta, args.forge_args):
                Formatter.print_section(f"Verifying deployment for {args.network}")
                verifier.verify_contracts("FullDeployer")
            
            
        elif args.step == "deploy:adapters":
            Formatter.print_section("Running Deployment")
            runner.build_contracts()
            Formatter.print_step(f"Deploying adapters for {args.network}")
            
            if runner.run_deploy("Adapters", args.catapulta, args.forge_args):
                Formatter.print_section(f"Verifying deployment for {args.network}")
                verifier.verify_contracts("Adapters")
            
            
        elif args.step == "wire:adapters":
            Formatter.print_step(f"Wiring adapters for {args.network}")
            runner.run_deploy("WireAdapters", args.catapulta, args.forge_args)
            
        elif args.step == "deploy:test":
            Formatter.print_section(f"Deploying test data for {args.network}")
            runner.run_deploy("TestData", args.catapulta, args.forge_args)
            
        elif args.step == "verify:protocol":
            Formatter.print_section(f"Verifying core protocol contracts for {args.network}")
            verifier.verify_contracts("FullDeployer")
            
        elif args.step == "verify:adapters":
            Formatter.print_section(f"Verifying Adapters contracts for {args.network}")
            verifier.verify_contracts("Adapters")
    
    except Exception as e:
        Formatter.print_error(f"Deployment failed: {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    main() 