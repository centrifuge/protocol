#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Formatter Module

Provides consistent, Homebrew-style formatting for deployment output.
Designed to work well in both terminal and CI environments.
"""

import pathlib

# Define what gets imported with "from .formatter import *"
__all__ = [
    'print_section',
    'print_subsection', 
    'print_step',
    'print_info',
    'print_success',
    'print_error',
    'print_warning',
    'print_command',
    'format_account',
    'format_command',
    'format_path'
]

class Formatter:
    # Color constants
    RESET = '\033[0m'
    BOLD = '\033[1m'
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    
    @staticmethod
    def print_section(title: str):
        """Print a main section header (blue, bold)"""
        print(f"{Formatter.BOLD}{Formatter.BLUE}==> {title}{Formatter.RESET}")
    
    @staticmethod
    def print_subsection(title: str):
        """Print a subsection header (cyan, bold)"""
        print(f"{Formatter.BOLD}{Formatter.CYAN} ==> {title}{Formatter.RESET}")
    
    @staticmethod
    def print_step(message: str):
        """Print a step message (bold)"""
        print(f"{Formatter.BOLD}  → {message}{Formatter.RESET}")
    
    @staticmethod
    def print_info(message: str):
        """Print an info message (normal)"""
        print(f"    • {message}")
    
    @staticmethod
    def print_success(message: str):
        """Print a success message (green checkmark)"""
        print(f"    {Formatter.GREEN}✓ {message} {Formatter.RESET}")
    
    @staticmethod
    def print_error(message: str):
        """Print an error message (red X)"""
        print(f"    {Formatter.RED}✗ {message} {Formatter.RESET}")
    
    @staticmethod
    def print_warning(message: str):
        """Print a warning message (yellow warning)"""
        import time
        time.sleep(0.2)
        print(f"    {Formatter.YELLOW}⚠ {message} {Formatter.RESET}")
    
    @staticmethod
    def format_path(path, root_dir=None):
        """Format path to show relative to root directory when possible"""
        if root_dir is None:
            # Try to find git root or use current working directory
            try:
                import subprocess
                result = subprocess.run(
                    ["git", "rev-parse", "--show-toplevel"], 
                    capture_output=True, text=True, check=True
                )
                root_dir = pathlib.Path(result.stdout.strip())
            except (subprocess.CalledProcessError, FileNotFoundError):
                root_dir = pathlib.Path.cwd()
        
        try:
            path_obj = pathlib.Path(path)
            root_obj = pathlib.Path(root_dir)
            relative_path = path_obj.relative_to(root_obj)
            return str(relative_path)
        except ValueError:
            # Path is not relative to root, return as-is
            return str(path) 

    @staticmethod
    def format_command(cmd: list, env_loader=None, script_path=None, root_dir=None) -> str:
        """
        Format a command list for display, masking secrets and showing relative paths
        
        Args:
            cmd: List of command arguments
            env_loader: Optional environment loader for secret masking
            script_path: Optional script path to make relative
            root_dir: Optional root directory for relative paths
            
        Returns:
            Formatted command string with secrets masked
        """
        debug_cmd = " ".join(str(arg) for arg in cmd)
        
        # Mask secrets if env_loader provided
        if env_loader:
            # Mask private key
            if hasattr(env_loader, 'private_key') and env_loader.private_key:
                debug_cmd = debug_cmd.replace(env_loader.private_key, "$PRIVATE_KEY")
            
            # Mask Alchemy API key in RPC URL
            if hasattr(env_loader, 'rpc_url') and env_loader.rpc_url and "alchemy" in env_loader.rpc_url:
                alchemy_key = env_loader.rpc_url.split("/")[-1]
                debug_cmd = debug_cmd.replace(alchemy_key, "$ALCHEMY_API_KEY")
            
            # Mask Etherscan API key
            if hasattr(env_loader, 'etherscan_api_key') and env_loader.etherscan_api_key:
                debug_cmd = debug_cmd.replace(env_loader.etherscan_api_key, "$ETHERSCAN_API_KEY")
        
        # Show relative path if script_path and root_dir provided
        if script_path and root_dir:
            relative_script_path = Formatter.format_path(script_path, root_dir)
            debug_cmd = debug_cmd.replace(str(script_path), relative_script_path)
        
        return debug_cmd
    
    @staticmethod
    def print_command(cmd: list, env_loader=None, script_path=None, root_dir=None):
        """
        Print a formatted command with secrets masked
        
        Args:
            cmd: List of command arguments
            env_loader: Optional environment loader for secret masking
            script_path: Optional script path to make relative
            root_dir: Optional root directory for relative paths
        """
        Formatter.print_info("Command")
        formatted_cmd = Formatter.format_command(cmd, env_loader, script_path, root_dir)
        print(f"  {formatted_cmd}")
    @staticmethod
    def format_account(account: str) -> str:
        """Format truncated account address as string"""
        return f"{Formatter.CYAN}{account[:6]}...{account[-4:]}{Formatter.RESET}"


# Standalone functions for import * compatibility
def print_section(title: str):
    """Print a main section header (blue, bold)"""
    Formatter.print_section(title)

def print_subsection(title: str):
    """Print a subsection header (cyan, bold)"""
    Formatter.print_subsection(title)

def print_step(message: str):
    """Print a step message (bold)"""
    Formatter.print_step(message)

def print_info(message: str):
    """Print an info message (normal)"""
    Formatter.print_info(message)

def print_success(message: str):
    """Print a success message (green checkmark)"""
    Formatter.print_success(message)

def print_error(message: str):
    """Print an error message (red X)"""
    Formatter.print_error(message)

def print_warning(message: str):
    """Print a warning message (yellow warning)"""
    Formatter.print_warning(message)

def print_command(cmd: list, env_loader=None, script_path=None, root_dir=None):
    """Print a formatted command with secrets masked"""
    Formatter.print_command(cmd, env_loader, script_path, root_dir)

def format_account(account: str) -> str:
    """Format truncated account address as string"""
    return Formatter.format_account(account)

def format_command(cmd: list, env_loader=None, script_path=None, root_dir=None) -> str:
    """Format a command list for display, masking secrets and showing relative paths"""
    return Formatter.format_command(cmd, env_loader, script_path, root_dir)

def format_path(path, root_dir=None):
    """Format path to show relative to root directory when possible"""
    return Formatter.format_path(path, root_dir)
