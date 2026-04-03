#!/usr/bin/env bash
# Shared utilities for template sync system

# Platform-compatible checksum computation
compute_checksum() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "Error: Neither sha256sum nor shasum found" >&2
        exit 1
    fi
}
