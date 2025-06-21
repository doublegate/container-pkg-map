# Changelog

All notable changes to Container Package Mapper will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 4.7.0 - 2025-06-20

### Fixed
- Resolved all 41 remaining GitHub Code Scanning security warnings
- Fixed markdown lint issues:
  - Added missing newlines at end of CHANGELOG.md, CLAUDE.md, and CONTRIBUTING.md
  - Removed brackets from version numbers to fix reference link warnings (9 instances)
- Fixed shellcheck issues in archive scripts:
  - SC2024: Fixed sudo redirection issues using tee pattern (8 instances)
  - SC2001: Replaced sed with parameter expansion for sanitization (2 instances)
  - SC2115: Added parameter expansion safety for rm commands (2 instances)
  - SC2155: Separated variable declaration from assignment (4 instances)
  - SC2207: Fixed array assignment using mapfile (1 instance)
  - SC2002: Removed useless cat, using direct redirection (1 instance)
  - SC2015: Replaced A && B || C pattern with proper if-then-else (1 instance)
  - SC2034: Added shellcheck disable comment for false positive (1 instance)

### Security
- Enhanced shell script safety across all archive scripts
- Improved command execution patterns to prevent potential security issues
- All scripts now pass shellcheck validation with zero warnings

## 4.6.0 - 2025-06-20

### Added
- Project branding assets in images/ directory
  - CPM_Banner.png - Project banner image
  - CPM_Icon.ico - Windows icon file
  - CPM_Icon.png - PNG icon file
  - CPM_Logo.png - Project logo

### Fixed
- Resolved all GitHub Code Scanning security warnings
- Fixed SC2024: sudo redirection issues
- Fixed SC2001: replaced sed with parameter expansion for better performance
- Fixed SC2028: replaced echo with printf for proper escape sequence handling
- Fixed SC2030/SC2031: subshell variable modifications using temp file approach
- Fixed SC2002: removed useless cat command
- Fixed markdown lint issues in documentation

### Security
- Enhanced security by properly handling sudo redirections
- Improved shell script safety with shellcheck compliance

## 4.5.1 - 2025-06-20

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

## 4.5.0 - 2025-06-15

### Added
- Extended validation for container detection
- Improved logging system with better error tracking
- Enhanced API retry logic with exponential backoff

## 4.4.0 - 2025-05-01

### Added
- Support for additional container types
- Better handling of network failures
- Improved cache management

## 4.3.0 - 2025-03-15

### Changed
- Optimized package mapping algorithm
- Improved performance for large package lists
- Better memory usage during backup operations

## 4.2.0 - 2025-02-01

### Added
- Support for custom Repology API endpoints
- Better handling of rate limiting
- Improved progress reporting

## 4.1.0 - 2024-12-15

### Fixed
- Various bug fixes and stability improvements
- Better error messages for common issues

## 4.0.0 - 2024-01-20

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

## 3.0 - Previous Versions

### Archive Scripts
The following scripts have been integrated and archived:
- `container_pkg_map.sh` - Original container package capture
- `enhanced_pkg_mapper.sh` - Improved package mapper
- `fedora-to-arch-mapper.sh` - Standalone package mapping
- `migrate.sh` - Original migration framework

These scripts laid the foundation for the current unified solution.
