# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains the **Container Package Mapper** - a comprehensive migration and backup tool for Fedora-based systems (including Bazzite, Silverblue, Kinoite) moving to Arch Linux. The main script is `ultimate_migration_script.sh` which integrates functionality from the archived scripts to provide an all-in-one solution.

## Key Commands

### Running the Script

```bash
# Basic usage - show help
./ultimate_migration_script.sh --help

# Backup mode (default directory: ~/migrate-YYYYMMDD_HHMM)
./ultimate_migration_script.sh backup
./ultimate_migration_script.sh backup /path/to/backup/dir

# Restore mode
./ultimate_migration_script.sh restore /path/to/backup/dir

# ISO verification and installation
./ultimate_migration_script.sh verify-iso /path/to/iso /path/to/sum/file
./ultimate_migration_script.sh install-iso /path/to/iso /path/to/sum/file

# Common options
./ultimate_migration_script.sh --verbose --dry-run backup
./ultimate_migration_script.sh --gui backup  # Interactive GUI mode with Zenity
./ultimate_migration_script.sh --max-packages 50 backup  # Test with limited packages
./ultimate_migration_script.sh --clear-cache backup  # Clear package mapping cache
```

### Development and Testing

```bash
# Run with verbose output for debugging
./ultimate_migration_script.sh --verbose --dry-run backup

# Test package mapping with limited set
./ultimate_migration_script.sh --max-packages 10 --verbose backup

# Clear cache and do fresh run
./ultimate_migration_script.sh --clear-cache --verbose backup
```

## Architecture and Code Structure

### Main Script: `ultimate_migration_script.sh`

The script is organized into several major sections:

1. **Configuration and Setup (lines 1-52)**
   - Strict mode settings (`set -euo pipefail`)
   - Constants for API endpoints, cache settings, version info
   - User and directory detection (handles sudo execution properly)
   - Global configuration variables

2. **Core Functions**
   - **Logging Functions** (lines 54-82): `log()`, `vlog()`, `error_log()` with timestamp formatting
   - **Package Mapping Engine** (lines 117-254): 
     - Uses Repology API to map Fedora packages to Arch equivalents
     - Implements caching with 24-hour TTL to minimize API calls
     - Rate limiting (1 request/second) to respect API limits
     - Robust error handling with retries
   - **Borg Backup Integration** (lines 256-340):
     - Encrypted backup using Borg with keyfile-blake2
     - Progress monitoring (GUI and CLI modes)
     - Compression options (lz4, zstd, none)
   - **Container Management** (lines 296-318):
     - Distrobox container detection and package capture
     - Multi-distro support (Arch, Debian, Fedora-based containers)

3. **Main Modes**
   - **backup**: Creates comprehensive system backup including:
     - System configuration (/etc)
     - User home directory
     - RPM and Flatpak package lists
     - Distrobox container configurations
     - Fedora-to-Arch package mapping
   - **restore**: Restores from backup with selective options
   - **verify-iso**: Validates ISO checksums and GPG signatures
   - **install-iso**: Verifies then launches installer

### Key Design Patterns

1. **Error Handling**: Uses `set -euo pipefail` with graceful error recovery for API failures
2. **Caching Strategy**: File-based cache in `~/.cache/ultimate-migration-mapper/` with TTL checking
3. **Progress Feedback**: Dual-mode progress (Zenity GUI or terminal progress bar)
4. **Sudo Handling**: Detects and properly handles sudo execution, drops privileges for user operations
5. **API Integration**: Custom User-Agent, retry logic, rate limiting for Repology API

### Dependencies

The script requires these external tools:
- **Core**: bash (v4.0+), coreutils
- **Backup**: borg
- **API/Processing**: curl, jq, stat, bc
- **Package Management**: rpm, flatpak, distrobox, podman
- **GUI (optional)**: zenity

### Important Files and Directories

- `~/.cache/ultimate-migration-mapper/`: Package mapping cache
- `~/.borg/`: Borg repository base directory
- `~/.borg/passphrase`: Borg encryption passphrase
- `~/migrate-YYYYMMDD_HHMM/`: Default backup directory structure:
  - `borg-repo/`: Encrypted Borg repository
  - `host-fedora-packages.txt`: RPM package list
  - `flatpaks.txt`: Flatpak application list
  - `containers_list.txt`: Distrobox container inventory
  - `fedora_to_arch_mapping.txt`: Generated package mapping
  - `migrate.log`: Operation log file

### Archive Directory

Contains previous iterations of the migration tooling:
- `container_pkg_map.sh`: Original container package capture script
- `enhanced_pkg_mapper.sh`: Improved mapper with better API handling
- `fedora-to-arch-mapper.sh`: Standalone package mapper
- `migrate.sh`: Original migration framework

These scripts have been integrated into `ultimate_migration_script.sh` but are preserved for reference.

## Key Implementation Details

### Repology API Integration

The package mapping uses a two-step process:
1. Search for exact project match: `GET /api/v1/projects/?search={package}&exact=1`
2. Extract Arch/AUR package names from the response using jq filters
3. Cache results to avoid repeated API calls

### Borg Backup Strategy

- Uses keyfile-blake2 encryption for security
- Compression is configurable (lz4 default, zstd for better ratio, none for speed)
- Creates timestamped archives: `etc-{now}`, `home-{now}`
- Exports encryption key for disaster recovery

### Container Package Capture

The script detects the package manager in each container and runs appropriate commands:
- Arch-based: `pacman -Qq`
- Debian-based: `dpkg-query -W -f='${Package}\n'`
- Fedora-based: `rpm -qa --qf '%{NAME}\n'`

Results are stored per container for selective restoration.