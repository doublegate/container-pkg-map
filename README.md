# Container Package Mapper

[![Version](https://img.shields.io/badge/version-4.5.1-blue.svg)](https://github.com/doublegate/container-pkg-map/releases)

A comprehensive migration and backup tool for Fedora-based systems (including Bazzite, Silverblue, Kinoite) moving to Arch Linux.

## Features

- **Full System Backup**: Creates encrypted backups using Borg of your home directory and system configuration
- **Package Mapping**: Intelligent mapping of Fedora packages to Arch Linux equivalents using Repology API
- **Container Support**: Captures and manages Distrobox container configurations and packages
- **Flatpak Management**: Backs up and restores Flatpak applications
- **ISO Verification**: Validates installation media checksums and GPG signatures
- **Dual Interface**: Works in both CLI and GUI mode (using Zenity)

## Requirements

- Fedora-based system (Fedora, Bazzite, Silverblue, Kinoite)
- Bash 4.0+
- Required tools:
  - `borg` - For encrypted backups
  - `curl` - For API requests
  - `jq` - For JSON parsing
  - `flatpak` - For Flatpak management
  - `distrobox` - For container management
  - `podman` - Container runtime
  - `rpm` - Package queries
  - `zenity` - GUI mode (optional)

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/doublegate/container-pkg-map.git
   cd container-pkg-map
   ```

2. Make the script executable:

   ```bash
   chmod +x ultimate_migration_script.sh
   ```

## Usage

### Basic Commands

```bash
# Show help
./ultimate_migration_script.sh --help

# Create backup (default: ~/migrate-YYYYMMDD_HHMM)
./ultimate_migration_script.sh backup

# Create backup to specific directory
./ultimate_migration_script.sh backup /path/to/backup

# Restore from backup
./ultimate_migration_script.sh restore /path/to/backup

# Verify ISO
./ultimate_migration_script.sh verify-iso /path/to/arch.iso /path/to/checksum.txt

# Install from verified ISO
./ultimate_migration_script.sh install-iso /path/to/arch.iso /path/to/checksum.txt
```

### Advanced Options

```bash
# GUI mode with progress dialogs
./ultimate_migration_script.sh --gui backup

# Dry run (preview actions without executing)
./ultimate_migration_script.sh --dry-run backup

# Verbose output for debugging
./ultimate_migration_script.sh --verbose backup

# Clear package mapping cache
./ultimate_migration_script.sh --clear-cache backup

# Limit package processing (for testing)
./ultimate_migration_script.sh --max-packages 50 backup
```

## What Gets Backed Up

1. **System Configuration**: `/etc` directory
2. **User Home**: Complete home directory with Borg deduplication
3. **Package Lists**:
   - RPM packages from host system
   - Flatpak applications
   - Packages from each Distrobox container
4. **Package Mappings**: Fedora to Arch package equivalents

## Migration Workflow

1. **On Fedora System**:

   ```bash
   # Create comprehensive backup
   ./ultimate_migration_script.sh backup ~/migration-backup
   ```

2. **Transfer to New System**: Copy the backup directory to your new Arch Linux installation

3. **On Arch System**:

   ```bash
   # Restore configuration and data
   ./ultimate_migration_script.sh restore ~/migration-backup
   ```

## Package Mapping

The script uses the Repology API to find Arch Linux equivalents for Fedora packages:

- Searches for exact matches first
- Falls back to similar package names
- Caches results for 24 hours to minimize API calls
- Respects API rate limits (1 request/second)

## Security

- Borg backups are encrypted using keyfile-blake2
- Encryption keys are exported for disaster recovery
- Passphrase stored securely in `~/.borg/passphrase`
- All operations respect user permissions

## Troubleshooting

- Use `--verbose` flag for detailed output
- Check `migrate.log` in the backup directory
- Clear cache with `--clear-cache` if mapping issues occur
- Ensure all dependencies are installed

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Repology](https://repology.org/) for package mapping API
- [BorgBackup](https://www.borgbackup.org/) for reliable encrypted backups
- [Distrobox](https://github.com/89luca89/distrobox) for container management
