#!/usr/bin/env python3
"""
Centrifuge Protocol Deployment Tool - Formatter Module

Provides consistent, Homebrew-style formatting for deployment output.
Designed to work well in both terminal and CI environments.
"""

import pathlib

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
        print(f"    {Formatter.GREEN}✓{Formatter.RESET} {message}")
    
    @staticmethod
    def print_error(message: str):
        """Print an error message (red X)"""
        print(f"    {Formatter.RED}✗{Formatter.RESET} {message}")
    
    @staticmethod
    def print_warning(message: str):
        """Print a warning message (yellow warning)"""
        print(f"    {Formatter.YELLOW}⚠{Formatter.RESET} {message}")
    
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