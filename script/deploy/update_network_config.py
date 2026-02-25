#!/usr/bin/env python3

# Copy contract addresses from $CHAIN_ID/run-latest.json to the associated network json file
import pathlib
import argparse
from lib.load_config import EnvironmentLoader
from lib.verifier import ContractVerifier

root_dir = pathlib.Path(__file__).parent.parent.parent

parser = argparse.ArgumentParser(description="Update network configuration.")
parser.add_argument("network_name")
parser.add_argument("--script", "-s", 
                    help="Deployment script path (e.g., script/LaunchDeployer.s.sol) to extract real block numbers from broadcast artifacts",
                    default=None)
args_cli = parser.parse_args()
network_name = args_cli.network_name

args = argparse.Namespace(
  catapulta=False,
  ledger=False,
  dry_run=False,
  forge_args=[],
  step="deploy:protocol"  # Required for deploymentInfo tracking
)

# Create environment loader
env_loader = EnvironmentLoader(network_name, root_dir, args)

# Create verifier instance
verifier = ContractVerifier(env_loader, args)

# Call the function
verifier.update_network_config(args_cli.script)
