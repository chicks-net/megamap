# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

MegaRAID Linux drive mapper - a collection of Perl and shell scripts for mapping MegaRAID drive IDs to Linux drive names and managing drive blinking for hardware identification.

## Core Architecture

### Main Components

- **megamap** (Perl): Core mapping tool that correlates MegaRAID drive IDs with Linux device names (`sd*`) and WWN identifiers
- **megablink** (Perl): Drive blinking utility that accepts Linux drive names and starts physical drive blinking
- **megaunblink** (bash): Wrapper script that calls `megablink -u` to stop drive blinking
- **megatrouble** (bash): Diagnostic script that collects system information for troubleshooting

### Data Flow

1. `megamap` executes `megacli -pdlist -a0` to get MegaRAID physical drive info
2. Parses enclosure ID, slot numbers, and WWN identifiers from megacli output
3. Correlates WWN data with Linux `/dev/disk/by-id` entries to map to `sd*` devices
4. `megablink` uses `megamap` output to translate Linux drive names to MegaRAID slot positions
5. Executes `megacli -PdLocate` commands to control physical drive LEDs

### Key Dependencies

- **megacli**: LSI MegaRAID CLI tool (requires root privileges)
- **Readonly**: Perl module for constants (debian package: `libreadonly-perl`)
- Root access required for all operations

## Development Commands

### Testing and Validation

```bash
# Run the main mapping tool
sudo ./megamap

# Test drive blinking (replace sdn with actual drive)
sudo ./megablink /dev/sdn

# Stop blinking
sudo ./megaunblink /dev/sdn
# or
sudo ./megablink -u /dev/sdn

# Collect troubleshooting info
sudo ./megatrouble
```

### Debug Mode

Set `MEGAMAP_DEBUG=1` to use static test files instead of live megacli commands:

```bash
# Generate test data
megacli -pdlist -a0 | egrep 'Slot|^SAS' > /tmp/megacli.out
ls -l /dev/disk/by-id | grep -v part > /tmp/ls.out

# Run in debug mode
MEGAMAP_DEBUG=1 ./megamap
```

## Important Implementation Details

- Linux WWN identifiers are "off-by-one or a few" from megacli WWN values - the code handles this mapping
- Drive matching uses both SAS address and WWN for correlation
- Supports enclosure ID and slot number parsing for multi-enclosure systems
- All tools require root privileges due to megacli requirements
- Drive specifications accept both `/dev/sdX` format and just `sdX`