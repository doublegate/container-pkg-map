# Changelog

All notable changes to Container Package Mapper will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0] - 2024-01-20

### Added
- Integrated all functionality from archived scripts into `ultimate_migration_script.sh`
- Comprehensive Borg backup support with encryption
- Advanced Fedora-to-Arch package mapping using Repology API
- Distrobox container detection and package capture
- GUI mode support using Zenity
- ISO verification and installation helpers
- Package mapping cache with 24-hour TTL
- Rate limiting for API requests
- Progress monitoring for long operations

### Changed
- Consolidated multiple scripts into single unified solution
- Improved error handling and recovery
- Enhanced logging with timestamps
- Better sudo handling and privilege management

### Security
- Encrypted backups using Borg with keyfile-blake2
- Secure passphrase storage
- Proper permission handling

## [3.0] - Previous Versions

### Archive Scripts
The following scripts have been integrated and archived:
- `container_pkg_map.sh` - Original container package capture
- `enhanced_pkg_mapper.sh` - Improved package mapper
- `fedora-to-arch-mapper.sh` - Standalone package mapping
- `migrate.sh` - Original migration framework

These scripts laid the foundation for the current unified solution.