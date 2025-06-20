# Changelog

All notable changes to Container Package Mapper will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.5.1] - 2025-06-20

### Changed
- Enhanced error handling and logging across all scripts
- Improved package mapping with better API integration
- Updated archive scripts to maintain consistency
- Better handling of edge cases in container detection
- Improved robustness in ultimate_migration_script.sh with additional error recovery

### Fixed
- Edge cases in container package detection
- API request handling for better reliability
- Error propagation in backup operations

## [4.5.0] - 2025-06-15

### Added
- Extended validation for container detection
- Improved logging system with better error tracking
- Enhanced API retry logic with exponential backoff

## [4.4.0] - 2025-05-01

### Added
- Support for additional container types
- Better handling of network failures
- Improved cache management

## [4.3.0] - 2025-03-15

### Changed
- Optimized package mapping algorithm
- Improved performance for large package lists
- Better memory usage during backup operations

## [4.2.0] - 2025-02-01

### Added
- Support for custom Repology API endpoints
- Better handling of rate limiting
- Improved progress reporting

## [4.1.0] - 2024-12-15

### Fixed
- Various bug fixes and stability improvements
- Better error messages for common issues

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