#!/bin/bash

print_section() {
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "                     $1"
    echo "╚════════════════════════════════════════════════════════════╝"
}

print_step() {
    echo "  → $1"
}

print_info() {
    echo "    • $1"
}

print_success() {
    echo "    ✓ $1"
}

print_error() {
    echo "    ✗ $1"
}
