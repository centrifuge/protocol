#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Ledger Hardware Wallet Support

Handles Ledger hardware wallet detection, account listing, and authentication
setup for Forge deployments.
"""

import subprocess
import argparse
from typing import List, Optional
from .formatter import *


class LedgerManager:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.max_accounts = 4
        self.ledger_account, self.ledger_account_index = self._account_selection()
    
    @property
    def get_ledger_account(self) -> str:
        """Get the ledger account"""
        return self.ledger_account
    
    @property
    def get_ledger_args(self) -> List[str]:
        """Setup ledger authentication arguments for Forge/Catapulta"""
        return ["--ledger", "--mnemonic-indexes", str( self.ledger_account_index)]

    def _account_selection(self) -> int:
        """List available Ledger accounts and prompt user to select one"""
        print_step("Loading available Ledger accounts")

        self._check_ledger_available()
        try:
            result = subprocess.run([
                "cast", "wallet", "list", "--ledger", "--max-senders", str(self.max_accounts)
            ], capture_output=True, text=True, check=True)
            
            # Parse addresses and take only external addresses (first half)
            all_addresses = [line.split()[0] for line in result.stdout.strip().split('\n') 
                           if line.strip() and line.startswith('0x')]
            addresses = all_addresses[:len(all_addresses)//2]
            
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Failed to get Ledger addresses: {e}")
        
        if not addresses:
            raise RuntimeError("No Ledger accounts found")
        
        if index := self._check_existing_mnemonic_index():
            account = addresses[index]
            return account, index
        
        print_step("Available Ledger accounts:")
        for idx, address in enumerate(addresses):
            print_info(f"{idx}: {address}")
        
        # Prompt user selection
        while True:
            try:
                selection = int(input(f"Select account (0-{len(addresses)-1}): ").strip())
                
                if 0 <= selection < len(addresses):
                    selected_address = addresses[selection]
                    print_success(f"Selected: {selected_address} (index {selection})")
                    return selected_address, selection
                else:
                    print_error(f"Invalid selection. Please choose 0-{len(addresses)-1}")
                    
            except (ValueError, EOFError, KeyboardInterrupt):
                print_error("Invalid input or cancelled. Using account 0 as default")
                return 0 

    def _check_ledger_available(self) -> bool:
        """Check if Ledger is connected and available, with retry option"""
        max_attempts = 3
        
        for attempt in range(max_attempts):
            try:
                print_step(f"Checking Ledger connection (attempt {attempt + 1}/{max_attempts})")
                
                result = subprocess.run([
                    "cast", "wallet", "list", "--ledger"
                ], capture_output=True, text=True, timeout=10)
                
                # Check for actual success: return code 0 AND no error messages AND has addresses
                has_error = "error=" in result.stderr or "Error:" in result.stderr or "Could not connect" in result.stderr
                has_addresses = result.stdout.strip() and "0x" in result.stdout
                
                if result.returncode == 0 and not has_error and has_addresses:
                    print_success("Ledger connected successfully")
                    return True
                else:
                    # Ledger not found or not ready
                    if attempt < max_attempts - 1:
                        print_warning("Ledger not detected")
                        print_info("Please ensure your Ledger device is:")
                        print_info("  - Connected via USB")
                        print_info("  - Unlocked with your PIN")
                        print_info("  - Ethereum app is open and ready")
                        print_info("  - Contract data and blind signing enabled (if needed)")
                        
                        try:
                            input("Press Enter when ready to retry, or Ctrl+C to cancel...")
                        except KeyboardInterrupt:
                            raise RuntimeError("Ledger setup cancelled by user")
                    else:
                        # Final attempt failed
                        error_msg = result.stderr.strip() if result.stderr.strip() else "Unknown error"
                        raise RuntimeError(f"Ledger connection failed: {error_msg}")
                        
            except Exception as e:
                if attempt < max_attempts - 1:
                    print_warning(f"Error checking Ledger: {e}")
                    self._prompt_ledger_setup()
                else:
                    raise RuntimeError(f"Error checking Ledger: {e}")
        
        return False
    
    def _check_existing_mnemonic_index(self) -> Optional[int]:
        """Check if mnemonic index is already specified in forge_args"""
        forge_args = getattr(self.args, 'forge_args', [])
        for i, arg in enumerate(forge_args):
            if arg == "--mnemonic-indexes" and i + 1 < len(forge_args):
                try:
                    return int(forge_args[i + 1])
                except ValueError:
                    continue
        return None
    