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
import json
from lib.formatter import *
from lib.load_config import EnvironmentLoader
from lib.runner import DeploymentRunner
from lib.verifier import ContractVerifier
from lib.anvil import AnvilManager
from lib.release import ReleaseManager
from lib.crosschain import CrossChainTestManager


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Centrifuge Protocol Deployment Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
IMPORTANT:
  - This script is designed to be run from the root directory of the project.
  - The network name must match the name of the network in the env/<network>.json file.
  - Run with VERSION=XYZ preceding the python3 command to avoid create3 collisions.

Examples:
  VERSION=vXYZ python3 deploy.py sepolia deploy:protocol
  python3 deploy.py base-sepolia deploy:protocol --catapulta --priority-gas-price 2
  python3 deploy.py sepolia deploy:adapters
  python3 deploy.py sepolia deploy:adapters --resume
  python3 deploy.py sepolia verify:protocol
  python3 deploy.py arbitrum-sepolia verify:protocol
  VERSION=vXYZ python3 deploy.py deploy:testnets  # Deploy all Sepolia testnets (auto-resumes)
  python3 deploy.py sepolia crosschaintest:hub  # Run cross-chain hub test
  python3 deploy.py base-sepolia crosschaintest:spoke  # Run cross-chain spoke tests
        """
    )

    parser.add_argument("network", nargs="?", help="Network name (must match env/<network>.json)")
    parser.add_argument("step", nargs="?", help="Deployment step", choices=[
        "deploy:protocol", "deploy:adapters", "deploy:testnets",
        "wire", "wire:all", "verify:protocol", "config:show", 
        "crosschaintest:hub", "crosschaintest:spoke"
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
    if not args.step:
        print_error("Deployment step is required.")
        print_info("Run python3 deploy.py --help for available steps")
        raise SystemExit(1)
    
    if not args.network:
        print_error("Network name is required")
        print_info("Available networks:")
        env_dir = root_dir / "env"
        if env_dir.exists():
            for config_file in env_dir.glob("*.json"):
                if config_file.name != "latest":
                    print_info(f"  - {config_file.stem}")
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

    # Backward-compat: support calling old deploy:testnets in network position
    if args.network == "deploy:testnets":
        args.step = "deploy:testnets"
        args.network = None
    
    # Validate arguments
    if args.network != "anvil" and args.step != "deploy:testnets":
        validate_arguments(args, root_dir)
    elif args.step == "deploy:testnets":
        # Special validation for deploy:testnets
        if not os.environ.get("VERSION"):
            print_error("VERSION environment variable is required for deploy:testnets")
            print_info("Example: VERSION=v3.1.4 python3 script/deploy/deploy.py deploy:testnets")
            sys.exit(1)

    try:
        # Handle Anvil deployment specially - it's completely self-contained
        if args.network == "anvil":
            anvil_manager = AnvilManager(root_dir)
            success = anvil_manager.deploy_full_protocol()
            sys.exit(0 if success else 1)

        if args.step != "deploy:testnets":
            # Create environment loader for single network deployments
            env_loader = EnvironmentLoader(
                network_name=args.network,
                root_dir=root_dir,
                args=args
            )

            print_step(f"Network: {args.network}")
            print_info(f"Chain ID: {env_loader.chain_id}")
            print_info(f"Deployment mode: {'Catapulta' if args.catapulta else 'Forge'}")

            # Validate network configuration for deployment and wiring steps
            if args.step in ["deploy:protocol", "deploy:adapters", "wire"]:
                env_loader.validate_network()

            # Set up deployment runner and verifier (only for deployment steps)
            if args.step != "dump:config":
                runner = DeploymentRunner(env_loader, args)
                verifier = ContractVerifier(env_loader, args)

        # Execute the requested step
        verify_success = True
        deploy_success = True

        if args.step == "deploy:protocol":
            print_section("Running Protocol Deployment")
            already_deployed = False
            if "--resume" in args.forge_args:
                already_deployed = verifier.config_has_latest_contracts()
            
            # Why did we need to build before running forge script?
            # if "--resume" not in args.forge_args and not already_deployed:
            #     runner.build_contracts()

            if already_deployed:
                print_info("Protocol contracts deployed and verified. Running TestData...")
                deploy_success = True
            else:
                print_subsection(f"Deploying core protocol contracts for {args.network}")
                deploy_success = runner.run_deploy("LaunchDeployer")
            print_section(f"Verifying deployment for {args.network}")
            if args.catapulta and not already_deployed:
                print_info("Waiting for catapulta verification to complete...")
                # Retry verification up to 3 times for catapulta since verification happens on their servers
                retries = 3
                verify_success = False
                while not verify_success and retries > 0:
                    print_info(f"Verification attempt {4-retries}/3 for catapulta...")
                    time.sleep(120)  # Wait 2 minutes between attempts
                    verify_success = verifier.verify_contracts("LaunchDeployer")
                    if not verify_success and retries > 1:
                        print_warning("Verification failed, retrying...")
                    retries -= 1
                if not verify_success:
                    print_error("Verification failed after 3 attempts")
                    sys.exit(1)
            elif not already_deployed:
                # Forge would only get there if the --verify has completed
                verify_success = verifier.verify_contracts("LaunchDeployer")

            # Auto-run TestData on testnets
            if verify_success and env_loader.is_testnet:
                print_info("Auto-running TestData for testnet")
                if "--resume" in args.forge_args and not already_deployed:
                    # User triggered command with --resume, probably because the protocol deployment failed
                    # but it is the first time we're running TestData, so we need to remove --resume this time
                    original_forge_args = list(args.forge_args)
                    args.forge_args = [a for a in args.forge_args if a != "--resume"]
                if not runner.run_deploy("TestData"):
                    print_error("TestData deployment failed")
                    sys.exit(1)
                print_success("TestData deployment completed successfully")
                # Restore forge args
                args.forge_args = original_forge_args
        
        elif args.step == "verify":
            print_section(f"Verifying core protocol contracts for {args.network}")
            verify_success = verifier.verify_contracts("LaunchDeployer")

        elif args.step == "deploy:adapters":
            print_section(f"Deploying adapters only for {args.network}")
            deploy_success = runner.run_deploy("OnlyAdapters")
            # After deploying with forge, also run our verifier to merge env/latest into env/<network>.json
            if deploy_success:
                print_section(f"Verifying deployment for {args.network}")
                verify_success = verifier.verify_contracts("OnlyAdapters")
        
        elif args.step == "deploy:testnets":
            # Orchestrated deployment across all Sepolia testnets
            release_manager = ReleaseManager(root_dir, args)
            success = release_manager.deploy_sepolia_testnets()
            sys.exit(0 if success else 1)

        elif args.step == "wire":
            print_step(f"Wiring adapters for {args.network}")
            deploy_success = runner.run_deploy("WireAdapters")
        
        elif args.step == "wire:all":
            print_section("Wiring adapters across connected networks")
            # Load current network config
            connects = []
            try:
                with open(env_loader.config_file, 'r') as f:
                    cfg = json.load(f)
                    connects = cfg.get('network', {}).get('connectsTo', []) or []
            except Exception as e:
                print_error(f"Failed to read network config: {e}")
                sys.exit(1)

            all_networks = [args.network] + connects
            unique_networks = []
            for n in all_networks:
                if n and n not in unique_networks:
                    unique_networks.append(n)

            print_warning(f"About to wire adapters for {len(unique_networks)} networks: {', '.join(unique_networks)}")
            print_warning("Ensure each network has the latest verified deployment. Press Ctrl+C to abort.")
            try:
                time.sleep(10)
            except KeyboardInterrupt:
                print_info("Aborted by user before wiring started.")
                sys.exit(1)

            # Run wiring for current network first
            print_step(f"Wiring adapters for {args.network}")
            if not runner.run_deploy("WireAdapters"):
                sys.exit(1)

            # Then wire for each connected network by swapping env loader
            for network_name in connects:
                print_section(f"Switching to {network_name} for wiring")
                # Recreate EnvironmentLoader, Runner, Verifier for the target network
                target_env_loader = EnvironmentLoader(network_name, root_dir, args)
                target_runner = DeploymentRunner(target_env_loader, args)
                print_step(f"Wiring adapters for {network_name}")
                if not target_runner.run_deploy("WireAdapters"):
                    print_error(f"Wiring failed for {network_name}")
                    sys.exit(1)
            deploy_success = True

        elif args.step == "config:dump":
            print_section(f"Dumping config for {args.network}")
            env_loader.dump_config()

        elif args.step == "crosschaintest:hub":
            print_section("Cross-Chain Hub Test")
            crosschain_manager = CrossChainTestManager(env_loader, args, root_dir)
            result = crosschain_manager.run_hub_test()
            print_success("Cross-chain hub test completed successfully")
            sys.exit(0)
            
        elif args.step == "crosschaintest:spoke":
            print_section("Cross-Chain Spoke Tests")
            crosschain_manager = CrossChainTestManager(env_loader, args, root_dir)
            result = crosschain_manager.run_spoke_tests()
            print_success("Cross-chain spoke tests completed")
            sys.exit(0)            

        # Handle errors
        if not verify_success:
            if args.catapulta:
                print_info(f"Wait for catapulta verification and run python3 deploy.py --catapulta --network {args.network} {args.step} again")
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
