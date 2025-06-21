#!/usr/bin/env bash
# container_pkg_map.sh - Enhanced script for capturing container packages and mapping Fedora to Arch
#
# This script captures package lists from Distrobox containers and creates a mapping
# between Fedora and Arch Linux packages using the Repology API.
#
# Features:
# - Captures packages from multiple container types (Arch, Debian, Fedora-based)
# - Uses a robust two-step Repology API lookup (search then fetch)
# - Implements 30-day caching to minimize API calls and improve performance
# - Provides verbose debugging output
# - Handles API errors gracefully without exiting
# - Shows progress and time estimates during package mapping
# - Safe to interrupt and resume thanks to caching
#
# Performance Notes:
# - First run will be slow due to API rate limiting (1 request/second)
# - Subsequent runs use cached data and are much faster
# - Use --max-packages N to test with a limited set first
# - Cache is stored in ~/.cache/migrate_pkg_map/
#
# Usage:
#    ./container_pkg_map.sh [--verbose] [--clear-cache] [--max-packages N] [backup_directory]
#
# Examples:
#    ./container_pkg_map.sh                     # Full run with defaults
#    ./container_pkg_map.sh --max-packages 50   # Test with first 50 packages
#    ./container_pkg_map.sh --verbose --clear-cache ./output/  # Verbose fresh run
#
# Options:
#    --verbose          Enable verbose output for debugging
#    --clear-cache      Clear the package mapping cache before running
#    --max-packages N   Limit package mapping to first N packages (for testing)
#    backup_dir         Directory to store output files (default: ~/migrate-YYYYMMDD_HHMM)

set -euo pipefail

# Script version and contact info for User-Agent header
SCRIPT_VERSION="2.6"
SCRIPT_URL="https://github.com/doublegate/container-pkg-map"
CONTACT_EMAIL="parobek@gmail.com"

# Determine real user and home directory, critical for running with sudo
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# Check if we need sudo for distrobox operations. This script should not be run as root.
if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ]; then
    echo "Error: This script is designed to be run as a regular user."
    echo "It will call 'sudo' for specific commands when necessary."
    echo "Please run without 'sudo'."
    exit 1
fi

# Initialize configuration variables
VERBOSE=false
CLEAR_CACHE=false
BACKUP_DIR=""
LOG=""
CACHE_DIR="$USER_HOME/.cache/migrate_pkg_map"
REPOLOGY_BASE_URL="https://repology.org/api/v1"
USER_AGENT="ContainerPkgMap/${SCRIPT_VERSION} (${SCRIPT_URL}; ${CONTACT_EMAIL})"
MAX_PACKAGES=0  # 0 means process all packages

# Logging function with timestamp and optional verbose output
log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    # Ensure log file path is set before trying to write to it
    if [ -n "$LOG" ]; then
        echo "$message" | tee -a "$LOG"
    else
        echo "$message"
    fi
}

# Verbose logging function
vlog() {
    if $VERBOSE; then
        log "[VERBOSE] $1"
    fi
}

# Parse command line options
while [ "$#" -gt 0 ]; do
  case "$1" in
    --verbose)
      VERBOSE=true
      shift
      ;;
    --clear-cache)
      CLEAR_CACHE=true
      shift
      ;;
    --max-packages)
      shift
      if [ "$#" -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_PACKAGES=$1
        shift
      else
        echo "Error: --max-packages requires a numeric argument" >&2
        exit 1
      fi
      ;;
    *)
      if [ -z "$BACKUP_DIR" ]; then
        BACKUP_DIR="$1"
        shift
      else
        echo "Error: Only one backup directory can be specified" >&2
        exit 1
      fi
      ;;
  esac
done

# Set default backup directory if not provided
[ -z "$BACKUP_DIR" ] && BACKUP_DIR="$USER_HOME/migrate-$(date +%Y%m%d_%H%M)"

# Normalize backup directory path (remove trailing slash if present)
BACKUP_DIR="${BACKUP_DIR%/}"

# Create necessary directories and set the log file path
mkdir -p "$BACKUP_DIR" "$CACHE_DIR"
LOG="$BACKUP_DIR/migrate.log"

# Now that LOG is set, we can start logging officially
log "Log file initialized at: $LOG"

# Clear cache if requested
if $CLEAR_CACHE; then
    if [ -d "$CACHE_DIR" ]; then
        log "Clearing package mapping cache at $CACHE_DIR"
        rm -rf "${CACHE_DIR:?}"/*
    fi
fi

# Check for required tools
required_tools=(curl jq distrobox rpm find xargs awk podman bc)
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log "Error: Required tool '$tool' is not installed. Please install it."
        exit 1
    fi
done

# Function to query Repology API for a single package.
# This function is designed to be robust and never trigger `set -e`.
query_repology_package() {
    local package_name="$1"
    local cache_file="$CACHE_DIR/${package_name}.json"

    # Check cache first (30-day expiry)
    if [ -f "$cache_file" ] && [ -n "$(find "$cache_file" -mtime -30 2>/dev/null)" ]; then
        vlog "Using cached data for package: $package_name"
        cat "$cache_file"
        return 0
    fi

    # Step 1: Search Repology for projects that match the package name. This is more robust.
    vlog "Searching Repology for package: $package_name"
    local search_url="https://repology.org/api/v1/projects/${package_name}/" # Trailing slash is recommended
    local search_response
    search_response=$(curl -s -H "User-Agent: $USER_AGENT" "$search_url")

    local best_project
    # Find the key that is an exact match for our package name, otherwise take the first one.
    best_project=$(echo "$search_response" | jq -r --arg pkg "$package_name" 'if has($pkg) then $pkg else (keys[0] // "") end')

    # Rate limit after the first, potentially non-cached API call.
    sleep 1

    if [ -z "$best_project" ]; then
        vlog "No project found for package: $package_name"
        echo "[]" > "$cache_file" # Cache the failure
        echo "[]"
        return 0 # Return success with empty data
    fi

    # Step 2: Now get the data for the best project match found.
    vlog "Found project '$best_project' for package '$package_name'. Fetching details."
    local project_url="${REPOLOGY_BASE_URL}/project/${best_project}/"
    local project_response
    project_response=$(curl -s -H "User-Agent: $USER_AGENT" "$project_url")
    sleep 1 # This is the main rate-limited call

    if echo "$project_response" | jq -e . >/dev/null 2>&1; then
        # Valid JSON, cache and return it
        echo "$project_response" > "$cache_file"
        echo "$project_response"
    else
        log "Invalid JSON response from Repology for project: $best_project (from package $package_name)"
        echo "[]" > "$cache_file" # Cache the failure
        echo "[]"
    fi

    return 0 # **CRITICAL**: Always return 0 to play nice with `set -e`
}


# Function to extract Arch package name from Repology data
get_arch_package_name() {
    local repology_data="$1"
    local arch_pkg=""

    arch_pkg=$(echo "$repology_data" | jq -r '(.[] | select(.repo == "arch") | .binname // .srcname // .name) // empty' | head -1)

    if [ -z "$arch_pkg" ]; then
        arch_pkg=$(echo "$repology_data" | jq -r '(.[] | select(.repo == "aur") | .binname // .srcname // .name) // empty' | head -1)
    fi

    if [ -n "$arch_pkg" ] && [ "$arch_pkg" != "null" ]; then
        echo "$arch_pkg"
    else
        echo ""
    fi
}

# Function to capture container packages
capture_container_packages() {
    log "Starting Distrobox container package capture"

    if ! sudo -u "$REAL_USER" distrobox-list 2>&1 | tee "$BACKUP_DIR/containers_list.txt" >/dev/null; then
        log "Failed to list distrobox containers. Skipping container backup."
        return 0
    fi
    vlog "Full distrobox list output saved to containers_list.txt"

    tail -n +2 "$BACKUP_DIR/containers_list.txt" | awk -F ' *\\| *' '{print $2}' > "$BACKUP_DIR/container_names.txt"

    local containers_array=()
    mapfile -t containers_array < "$BACKUP_DIR/container_names.txt"

    if [ ${#containers_array[@]} -eq 0 ]; then
        log "No active Distrobox containers found to process."
        return 0
    fi

    local total_containers=${#containers_array[@]}
    log "Found $total_containers containers to process."

    # This loop uses the `&& log || log` pattern which handles errors
    # gracefully without causing `set -e` to exit the script.
    for container in "${containers_array[@]}"; do
        log "Processing container: $container"
        local pkg_file="$BACKUP_DIR/container-${container}-pkgs.txt"
        local err_file="$BACKUP_DIR/container-${container}-err.log"

        local status
        status=$(sudo -u "$REAL_USER" podman ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null || echo "Error")

        if [[ ! "$status" =~ ^Up ]]; then
            log "Container '$container' is not running (status: $status). Skipping."
            continue
        fi

        if sudo -u "$REAL_USER" distrobox-enter "$container" -- true &>/dev/null < /dev/null; then
            vlog "Container is enterable. Detecting package manager..."

            if sudo -u "$REAL_USER" distrobox-enter "$container" -- which pacman &>/dev/null < /dev/null; then
                vlog "Detected Arch-based container: $container"
                ( sudo -u "$REAL_USER" distrobox-enter "$container" -- pacman -Qq < /dev/null 2>"$err_file" | tee "$pkg_file" >/dev/null && \
                    log "Captured packages from Arch-based container: $container" ) || \
                    log "Failed to capture packages from Arch-based container: $container. See $err_file"

            elif sudo -u "$REAL_USER" distrobox-enter "$container" -- which dpkg &>/dev/null < /dev/null; then
                vlog "Detected Debian-based container: $container"
                ( sudo -u "$REAL_USER" distrobox-enter "$container" -- sh -c "dpkg -l | awk '/^ii/ {print \$2}'" < /dev/null 2>"$err_file" | tee "$pkg_file" >/dev/null && \
                    log "Captured packages from Debian-based container: $container" ) || \
                    log "Failed to capture packages for Debian-based container: $container. See $err_file"

            elif sudo -u "$REAL_USER" distrobox-enter "$container" -- which rpm &>/dev/null < /dev/null; then
                vlog "Detected RPM-based container: $container"
                ( sudo -u "$REAL_USER" distrobox-enter "$container" -- rpm -qa --qf '%{NAME}\n' < /dev/null 2>"$err_file" | tee "$pkg_file" >/dev/null && \
                    log "Captured packages from RPM-based container: $container" ) || \
                    log "Failed to capture packages from RPM-based container: $container. See $err_file"
            else
                log "Unsupported package manager in container: $container"
            fi
        else
            log "Failed to enter container: $container. It may be stopped or misconfigured. Skipping."
        fi
    done

    local captured_count
    captured_count=$(find "$BACKUP_DIR" -name "container-*-pkgs.txt" -type f -size +0 2>/dev/null | wc -l)
    log "Container processing complete: packages captured from $captured_count of $total_containers containers."
}

# Function to generate Fedora to Arch package mapping
generate_package_mapping() {
    log "Starting Fedora-to-Arch package mapping"

    if [ ! -f /etc/os-release ]; then
        log "Cannot find /etc/os-release. Skipping host package mapping."
        return 0
    fi

    if ! grep -qi "fedora\|bazzite\|silverblue\|kinoite" /etc/os-release; then
        log "Not running on a known Fedora-based system. Skipping host package mapping."
        return 0
    fi

    local fedora_version
    fedora_version=$(grep "VERSION_ID" /etc/os-release | cut -d= -f2 | tr -d '"')
    [ -z "$fedora_version" ] && fedora_version="unknown"
    log "Detected Fedora-based system, version: $fedora_version"

    log "Extracting host package names..."
    rpm -qa --qf '%{NAME}\n' | sort -u > "$BACKUP_DIR/host-package-names.txt"

    local packages_array=()
    if [ "$MAX_PACKAGES" -gt 0 ]; then
        mapfile -t -n "$MAX_PACKAGES" packages_array < "$BACKUP_DIR/host-package-names.txt"
    else
        mapfile -t packages_array < "$BACKUP_DIR/host-package-names.txt"
    fi

    local packages_to_process=${#packages_array[@]}
    if [ "$packages_to_process" -eq 0 ]; then
        log "No host packages found to map."
        return 0
    fi
    log "Found $packages_to_process host packages to map."

    if [ "$MAX_PACKAGES" -gt 0 ]; then
        log "Limiting to first $packages_to_process packages as per --max-packages."
    fi

    local estimated_seconds=$((packages_to_process * 2)) # * 2 because of two potential API calls
    local estimated_minutes=$((estimated_seconds / 60))
    log "Estimated time for uncached packages: ~${estimated_minutes} minutes. Cached packages are instant."
    log "You can safely interrupt (Ctrl+C) and resume this process."

    local mapping_file="$BACKUP_DIR/fedora_to_arch_mapping.txt"
    {
        echo "# Fedora ($fedora_version) to Arch Linux Package Mapping"
        echo "# Generated on $(date)"
        echo "# Format: fedora_package -> arch_package"
        echo ""
    } > "$mapping_file"

    local processed=0 found=0 not_found=0
    local start_time
    start_time=$(date +%s)

    for pkg in "${packages_array[@]}"; do
        [ -z "$pkg" ] && continue
        ((processed++))

        if [ $((processed % 10)) -eq 0 ] || [ "$processed" -eq "$packages_to_process" ]; then
            local current_time elapsed rate remaining eta eta_min
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            if [ "$elapsed" -gt 0 ]; then
                rate=$(echo "scale=2; $processed / $elapsed" | bc)
                remaining=$((packages_to_process - processed))
                eta=$(echo "scale=0; $remaining / $rate" | bc 2>/dev/null || echo "0")
                eta_min=$(echo "scale=0; $eta / 60" | bc 2>/dev/null || echo "0")
                log "Progress: $processed/$packages_to_process packages (~${eta_min} min remaining)"
            else
                log "Progress: $processed/$packages_to_process packages..."
            fi
        fi

        vlog "Processing package: $pkg"
        # This call is now safe and will not exit the script on failure
        local repology_data
        repology_data=$(query_repology_package "$pkg")

        local arch_pkg
        arch_pkg=$(get_arch_package_name "$repology_data")

        if [ -n "$arch_pkg" ]; then
            echo "$pkg -> $arch_pkg" >> "$mapping_file"
            ((found++))
            vlog "Mapped: $pkg -> $arch_pkg"
        else
            echo "$pkg -> [NOT FOUND]" >> "$mapping_file"
            ((not_found++))
            vlog "No Arch equivalent found for: $pkg"
        fi
    done

    local end_time total_elapsed elapsed_min
    end_time=$(date +%s)
    total_elapsed=$((end_time - start_time))
    elapsed_min=$((total_elapsed / 60))

    log "Package mapping completed in $elapsed_min minutes."
    log "Summary: $found packages mapped, $not_found not found."
    log "Full mapping saved to: $mapping_file"

    local successful_mapping_file="$BACKUP_DIR/fedora_to_arch_mapping_successful.txt"
    grep -v '\[NOT FOUND\]' "$mapping_file" | grep ' -> ' > "$successful_mapping_file"
    log "Successfully mapped packages saved to: $successful_mapping_file"
}

# Function to create a final summary report
create_summary_report() {
    log "Creating summary report..."
    local summary_file="$BACKUP_DIR/summary.txt"
    local container_count=0
    local file_count=0
    local mapping_status="No mapping generated."

    if [ -f "$BACKUP_DIR/container_names.txt" ]; then
        container_count=$(wc -l < "$BACKUP_DIR/container_names.txt")
    fi

    file_count=$(find "$BACKUP_DIR" -type f | wc -l)

    if [ -f "$BACKUP_DIR/fedora_to_arch_mapping_successful.txt" ]; then
        mapping_status="$(wc -l < "$BACKUP_DIR/fedora_to_arch_mapping_successful.txt" | xargs) successful mappings found."
    elif [ -f "$BACKUP_DIR/fedora_to_arch_mapping.txt" ]; then
        mapping_status="Mapping run, but no successful matches found."
    fi

    cat > "$summary_file" <<EOF
Container Package Mapping Summary
=================================
Generated: $(date)
Backup Location: $BACKUP_DIR
Log File: $LOG

Containers Processed: $container_count
Total Files Generated: $file_count

Package Mapping Status:
$mapping_status
EOF
    log "Summary report created at $summary_file"
}


# Main execution flow
main() {
    log "=== Container Package Mapping Script v${SCRIPT_VERSION} ==="
    log "Backup directory: $BACKUP_DIR"
    vlog "Verbose mode enabled"
    $CLEAR_CACHE && log "Cache was cleared"
    [ "$MAX_PACKAGES" -gt 0 ] && log "Package limit set to: $MAX_PACKAGES"

    capture_container_packages
    generate_package_mapping
    create_summary_report

    log "=== Operation completed successfully ==="
    log "Check $BACKUP_DIR for all output files and logs."
}

# Run the main function and handle any unexpected errors
main
