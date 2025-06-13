#!/bin/bash

# Helper function to center text within a given width
center_text() {
    local text="$1"
    local width="$2"
    local text_length=${#text}
    local padding=$(((width - text_length - 2) / 2)) # -2 for the borders

    # Create padding strings
    local left_padding=$(printf "%${padding}s" "")
    local right_padding=$(printf "%$((width - text_length - padding - 2))s" "")

    echo "${left_padding}${text}${right_padding}"
}

print_section() {
    local title="$1"
    local box_width=60 # Width of the box (including borders)

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║$(center_text "$title" $box_width)║"
    echo "╚════════════════════════════════════════════════════════════╝"
}

print_subtitle() {
    local title="$1"
    local box_width=58 # Width of the box (including borders and indentation)

    echo "  ┌────────────────────────────────────────────────────────┐"
    echo "  │$(center_text "$title" $box_width)│"
    echo "  └────────────────────────────────────────────────────────┘"
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
