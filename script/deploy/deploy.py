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
import traceback
import time
from lib.formatter import *
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
  python3 deploy.py base-sepolia deploy:full --catapulta --priority-gas-price 2
  python3 deploy.py sepolia deploy:test --resume
  python3 deploy.py sepolia verify:protocol
  python3 deploy.py arbitrum-sepolia verify:protocol
        """
    )
    
    parser.add_argument("network", nargs="?", help="Network name (must match env/<network>.json)")
    parser.add_argument("step", nargs="?", help="Deployment step", choices=[
        "deploy:protocol", "deploy:full", "wire:adapters", 
        "deploy:test", "verify:protocol", "dump:config"
    ])
    parser.add_argument("--catapulta", action="store_true", help="Use Catapulta for deployment")
    parser.add_argument("--ledger", action="store_true", help="Force use of Ledger hardware wallet")

    parser.add_argument("--dry-run", action="store_true", help="Show what this script would do without running a deployment")
    
    return parser


def validate_arguments(args, root_dir: pathlib.Path):
    """Validate command line arguments and provide helpful error messages"""
    print_section("Validating arguments")
    
    # Print detected arguments for debugging
    if args.dry_run:
        print_step("Detected Arguments")
        print_info(f"Network: {args.network}")
        print_info(f"Step: {args.step}")
        print_info(f"Catapulta: {args.catapulta}")
        print_info(f"Ledger: {args.ledger}")
        if args.forge_args:
            print_info(f"Forge args: {' '.join(args.forge_args)}")
        print_info(f"VERSION env: {os.environ.get('VERSION', 'Not set')}")
    
    # Check for required arguments
    if not args.network:
        print_error("Network name is required")
        print_info("Available networks:")
        env_dir = root_dir / "env"
        if env_dir.exists():
            for config_file in env_dir.glob("*.json"):
                if config_file.name != "latest":
                    print_info(f"  - {config_file.stem}")
        raise SystemExit(1)
    
    if not args.step:
        print_error("Deployment step is required.")
        print_info("Run python3 deploy.py --help for available steps")
        raise SystemExit(1)        
    network_config = root_dir / "env" / f"{args.network}.json"
    if not network_config.exists():
        print_error(f"Network config file not found: {network_config}")
        print_info("Available networks:")
        env_dir = root_dir / "env"
        if env_dir.exists():
            available_networks = [f.stem for f in env_dir.glob("*.json") if f.name != "latest"]
            available_networks.append("anvil")  # Add anvil as special case
            if available_networks:
                for network in sorted(available_networks):
                    print_info(f"  - {network}")
            else:
                print_info("  - anvil (local)")
        raise SystemExit(1)

    # Check if VERSION environment variable is set for deployment steps
    if args.step.startswith("deploy:") and not os.environ.get("VERSION") and not args.dry_run:
        print_warning("VERSION environment variable not set. Create3 address collisions may occur.")
        print_info("Consider running: VERSION=XYZ python3 deploy.py ...")

    # Validate forge arguments don't conflict with script defaults
    if args.forge_args:
        conflicting_args = ["--verify", "--broadcast", "--chain-id", "--tc", "--optimize"]
        for arg in args.forge_args:
            if any(arg.startswith(conflict) for conflict in conflicting_args):
                print_warning(f"Forge argument '{arg}' may conflict with script defaults")
                raise SystemExit(1)
    print_success("Arguments validated")
    return True


def main():
    parser = create_parser()
    args, unknown_args = parser.parse_known_args()
    
    # Add unknown arguments as forge_args
    args.forge_args = unknown_args
    
    # Get root directory early for validation
    script_dir = pathlib.Path(__file__).parent
    root_dir = script_dir.parent.parent
    
    # Validate arguments
    if args.network != "anvil":
        validate_arguments(args, root_dir)

    try:
        # Handle Anvil deployment specially - it's completely self-contained
        if args.network == "anvil":
            anvil_manager = AnvilManager(root_dir)
            success = anvil_manager.deploy_full_protocol()
            sys.exit(0 if success else 1)
        
        # Create environment loader
        env_loader = EnvironmentLoader(
            network_name=args.network,
            root_dir=root_dir,
            args=args
        )
        
        print_step(f"Network: {args.network}")
        print_info(f"Chain ID: {env_loader.chain_id}")
        print_info(f"Deployment mode: {'Catapulta' if args.catapulta else 'Forge'}")
        
        # Set up deployment runner and verifier
        runner = DeploymentRunner(env_loader, args)
        verifier = ContractVerifier(env_loader, args)
        
        # Execute the requested step
        verify_success = True
        deploy_success = True

        if args.step == "deploy:full":
            print_section("Running Full Deployment")
            runner.build_contracts()
            print_subsection(f"Deploying core protocol contracts for {args.network}")
            retries = 3
            # Deploy protocol Core contracts
            while not runner.run_deploy("FullDeployer"):
                retries -= 1
                # Add --resume to continue from where we left off after first try
                if "--resume" not in args.forge_args:
                    args.forge_args.append("--resume")
                if retries ==0:
                    print_error("Full deployment failed")
                    sys.exit(1)
                else:
                    print_error("Full deployment failed, retrying {retries}/3")
                    time.sleep(10)
            print_section(f"Verifying deployment for {args.network}")
            if not verifier.verify_contracts("FullDeployer"):
                print_error("Full deployment verification failed. Check logs for details.")
                sys.exit(1)
            print_success("Full deployment completed successfully")
            
            # Deploy Test Data on testnets
            if env_loader.is_testnet:
                print_info("Running test data deployment")
                if not runner.run_deploy("TestData"):
                    print_error("Test data deployment failed")
                    sys.exit(1)
            print_success("Test data deployment completed successfully")
            sys.exit(0)
            
        elif args.step == "deploy:protocol":
            print_section("Running Protocol Deployment")
            runner.build_contracts()
            print_subsection(f"Deploying core protocol contracts for {args.network}")
            deploy_success = runner.run_deploy("FullDeployer")
            print_section(f"Verifying deployment for {args.network}")
            if args.catapulta:
                print_info("Waiting for catapulta verification to complete...")
                # Retry verification up to 3 times for catapulta since verification happens on their servers
                retries = 3
                verify_success = False
                while not verify_success and retries > 0:
                    print_info(f"Verification attempt {4-retries}/3 for catapulta...")
                    time.sleep(120)  # Wait 2 minutes between attempts
                    verify_success = verifier.verify_contracts("FullDeployer")
                    if not verify_success and retries > 1:
                        print_warning("Verification failed, retrying...")
                    retries -= 1
                    print_error("Verification failed after 3 attempts")
            else:
                # Forge would only get there if the --verify has completed
                verify_success = verifier.verify_contracts("FullDeployer")
            
        elif args.step == "wire:adapters":
            print_step(f"Wiring adapters for {args.network}")
            deploy_success = runner.run_deploy("WireAdapters")
            
        elif args.step == "deploy:test":
            print_section(f"Deploying test data for {args.network}")
            deploy_success = runner.run_deploy("TestData")
            
        elif args.step == "verify:protocol":
            print_section(f"Verifying core protocol contracts for {args.network}")
            verify_success = verifier.verify_contracts("FullDeployer")
        
        # Handle errors 
        if not verify_success:
            if args.catapulta:
                print_info("Wait for catapulta verification and run python3 deploy.py --catapulta --network <network> verify:protocol again")
            print_error("Some contracts are not deployed or not verified")
            sys.exit(1)
        
        if not deploy_success and verify_success:
            print_error("Forge failed but all contracts seem deployed and verified")
            log_file = env_loader.root_dir / "deploy" / "logs" / f"forge-validate-{args.network}.log"
            if os.path.exists(log_file):
                print_error("This is most likely due to the batcher contract not being verified")
                print_error(f"See {log_file} for details.")
    
    except Exception as e:
        print_error(f"Deployment failed: {str(e)}")
        print_error("Full traceback:")
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main() 