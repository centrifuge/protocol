#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Cross-Chain Test Manager

Orchestrates the TestAdapterIsolation.s.sol 3-phase workflow via deploy.py.

Full sequence (single command):
  1. Register assets on each spoke (if needed)
  2. Create pools + configure adapters on hub (phases 1+2)
  3. Wait for cross-chain message relay
  4. Run share class test on hub (phase 3, repeatable)

Individual steps are also available for advanced usage.
"""

import json
import os
import time
import pathlib
from typing import Dict, List, Optional, Any
from .formatter import *
from .load_config import EnvironmentLoader
from .runner import DeploymentRunner


class CrossChainTestManager:
    SCRIPT_NAME = "TestAdapterIsolation"

    def __init__(self, env_loader: EnvironmentLoader, args, root_dir: pathlib.Path):
        self.env_loader = env_loader
        self.args = args
        self.root_dir = root_dir

    # -----------------------------------------------------------------
    # Main entry point — full sequence
    # -----------------------------------------------------------------

    def run_full(self) -> Dict[str, Any]:
        """Run the complete cross-chain test sequence.

        1. Register assets on each spoke chain (registerAssetOnly)
        2. Create pools + configure adapters on hub (phases 1+2)
        3. Wait for cross-chain relay
        4. Test share class notifications (phase 3)
        """
        connects_to = self._get_connected_networks()
        self._validate_hub_contracts()

        print_section("Cross-Chain Adapter Isolation Test")
        print_info(f"Hub network: {self.env_loader.network_name}")
        print_info(f"Connected spokes: {', '.join(connects_to)}")

        # ── Step 1: Spoke asset registration ──────────────────────────
        print_section("Step 1/4 — Register assets on spokes")
        self._run_spoke_registration(connects_to)

        # ── Step 2: Hub phases 1+2 ───────────────────────────────────
        print_section("Step 2/4 — Hub pool setup + adapter configuration")
        self._run_hub_setup()

        # ── Step 3: Wait for relay ───────────────────────────────────
        print_section("Step 3/4 — Wait for cross-chain relay")
        self._print_explorer_links(connects_to)
        self._wait_for_relay()

        # ── Step 4: Share class test ─────────────────────────────────
        print_section("Step 4/4 — Share class test (NotifyShareClass)")
        self._run_share_class_test()

        print_section("Cross-Chain Test Complete")
        print_success("All 4 steps finished successfully.")
        print_info("Run 'crosschaintest:test' to repeat phase 3 with new share classes.")

        return {"hub_network": self.env_loader.network_name, "spokes": connects_to}

    # -----------------------------------------------------------------
    # Individual steps (for advanced / manual usage)
    # -----------------------------------------------------------------

    def run_hub_test(self) -> Dict[str, Any]:
        """Run phases 1+2 on the hub (pool setup + adapter configuration)."""
        connects_to = self._get_connected_networks()
        self._validate_hub_contracts()
        self._run_hub_setup()
        self._print_explorer_links(connects_to)
        return {"hub_network": self.env_loader.network_name, "spokes": connects_to}

    def run_spoke_tests(self) -> Dict[str, Any]:
        """Run asset registration on each connected spoke."""
        connects_to = self._get_connected_networks()
        return self._run_spoke_registration(connects_to)

    def run_share_class_test(self) -> Dict[str, Any]:
        """Run phase 3 (repeatable share class test) on the hub."""
        connects_to = self._get_connected_networks()
        self._run_share_class_test()
        self._print_explorer_links(connects_to)
        return {"hub_network": self.env_loader.network_name}

    # -----------------------------------------------------------------
    # Step implementations
    # -----------------------------------------------------------------

    def _run_spoke_registration(self, connects_to: List[str]) -> Dict[str, Any]:
        """Register assets on each spoke network."""
        results = []
        for spoke_network in connects_to:
            print_subsection(f"Registering asset on {spoke_network}")

            try:
                spoke_env_loader = EnvironmentLoader(spoke_network, self.root_dir, self.args)
                spoke_runner = DeploymentRunner(spoke_env_loader, self.args)

                spoke_runner.env["HUB_NETWORK"] = self.env_loader.network_name

                original_forge_args = list(self.args.forge_args)
                self.args.forge_args = [a for a in self.args.forge_args if a != "--resume"]
                self.args.forge_args.extend(["--sig", "registerAssetOnly()"])

                success = spoke_runner.run_deploy(self.SCRIPT_NAME)

                self.args.forge_args = original_forge_args

                if success:
                    print_success(f"Asset registered on {spoke_network}")
                    results.append({"network": spoke_network, "success": True})
                else:
                    print_error(f"Asset registration failed on {spoke_network}")
                    results.append({"network": spoke_network, "success": False})

            except Exception as e:
                print_error(f"Error on {spoke_network}: {e}")
                results.append({"network": spoke_network, "success": False})

        return {"results": results}

    def _run_hub_setup(self):
        """Run phases 1 (pool setup) and 2 (adapter config) on the hub."""
        print_info(f"Hub network: {self.env_loader.network_name}")

        # Phase 1 — pool setup (hub only, no XC messages)
        print_subsection("Phase 1: Pool Setup")
        if not self._run_sig("runPoolSetup()"):
            print_error("Phase 1 (pool setup) failed")
            raise SystemExit(1)
        print_success("Phase 1 complete — pools created on hub")

        # Phase 2 — adapter config (sends XC messages to spokes)
        print_subsection("Phase 2: Adapter Setup")
        if not self._run_sig("runAdapterSetup()"):
            print_error("Phase 2 (adapter setup) failed")
            raise SystemExit(1)
        print_success("Phase 2 complete — adapters configured, XC messages sent")

    def _run_share_class_test(self):
        """Run phase 3 (share class test) on the hub."""
        print_subsection("Phase 3: Share Class Test")
        if not self._run_sig("runShareClassTest()"):
            print_error("Phase 3 (share class test) failed")
            raise SystemExit(1)
        print_success("Phase 3 complete — NotifyShareClass sent")

    def _wait_for_relay(self):
        """Wait for cross-chain messages to be relayed.

        Interactive: prompts the user to press Enter.
        CI (GITHUB_ACTIONS): auto-waits 10 minutes.
        """
        if os.environ.get("GITHUB_ACTIONS"):
            wait_seconds = int(os.environ.get("XC_RELAY_WAIT", "600"))
            print_info(f"CI mode: waiting {wait_seconds}s for XC relay...")
            time.sleep(wait_seconds)
        else:
            print_warning("Cross-chain messages need ~5-10 minutes to relay.")
            print_info("Check the explorer links above to monitor delivery.")
            print_info("")
            try:
                input("  Press Enter when messages have been relayed (or Ctrl+C to abort)... ")
            except KeyboardInterrupt:
                print_info("\nAborted by user")
                raise SystemExit(1)

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    def _run_sig(self, sig: str) -> bool:
        """Run TestAdapterIsolation with a specific --sig entry point."""
        runner = DeploymentRunner(self.env_loader, self.args)

        original_forge_args = list(self.args.forge_args)
        self.args.forge_args = [a for a in self.args.forge_args if a != "--resume"]
        self.args.forge_args.extend(["--sig", sig])

        success = runner.run_deploy(self.SCRIPT_NAME)

        self.args.forge_args = original_forge_args
        return success

    def _get_connected_networks(self) -> List[str]:
        connects_to = self.env_loader.config.get("network", {}).get("connectsTo", [])
        if not connects_to:
            print_error("No connected networks found in config. Add 'connectsTo' to network config.")
            raise SystemExit(1)
        return connects_to

    def _validate_hub_contracts(self):
        required = ["gateway", "hub", "hubRegistry", "multiAdapter", "subsidyManager"]
        contracts = self.env_loader.config.get("contracts", {})
        missing = [c for c in required if c not in contracts]
        if missing:
            print_error(f"Missing hub contracts: {', '.join(missing)}")
            print_info("Run deploy:full first to deploy these contracts")
            raise SystemExit(1)

    def _print_explorer_links(self, connects_to: List[str]) -> None:
        print_subsection("Monitor Cross-Chain Messages")
        sender = self.env_loader.ops_admin_address
        hub_axelar_id = self.env_loader.config.get("adapters", {}).get("axelar", {}).get("axelarId", "")

        for spoke_network in connects_to:
            cfg_file = self.root_dir / "env" / f"{spoke_network}.json"
            if not cfg_file.exists():
                continue
            with open(cfg_file, "r") as f:
                cfg = json.load(f)
            spoke_axelar_id = cfg.get("adapters", {}).get("axelar", {}).get("axelarId", "")
            if hub_axelar_id and spoke_axelar_id:
                print_info(
                    f"Axelar ({spoke_network}): https://testnet.axelarscan.io/gmp/search"
                    f"?sourceChain={hub_axelar_id}&destinationChain={spoke_axelar_id}"
                    f"&senderAddress={sender}"
                )

        print_info(f"LayerZero: https://testnet.layerzeroscan.com/address/{sender}")
        print_info(f"Chainlink: https://ccip.chain.link/address/{sender}")
        print_info(f"Wormhole (deprecated): https://wormholescan.io/#/txs?address={sender}&network=Testnet")
