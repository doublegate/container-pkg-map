#!/usr/bin/env bash
#
# enhanced_pkg_mapper.sh
#
# Description:
#   A comprehensive script to capture package lists from the host system (if Fedora-based)
#   and Distrobox containers, then map the Fedora package names to their Arch Linux
#   equivalents using the Repology.org API.
#
#   This script merges the robust API/caching logic from 'fedora-to-arch-mapper.sh'
#   with the container and host processing features of 'container_pkg_map.sh'.
#
# Features:
#   - Captures packages from multiple container types (Arch, Debian, Fedora-based).
#   - Captures packages from the host system if it's a Fedora derivative.
#   - Uses a highly robust and efficient single-call Repology API lookup.
#   - Implements a time-to-live (TTL) based cache (24 hours) to ensure data freshness
#     while minimizing API calls.
#   - Provides verbose debugging output and progress indicators.
#   - Handles API errors and network issues gracefully.
#   - Safe to interrupt and resume due to robust caching.
#
# Dependencies:
#   - bash (v4.0+)
#   - curl
#   - jq
#   - distrobox (optional, for container capture)
#   - podman (optional, for container capture)
#   - rpm (optional, for host capture)
#   - stat (from coreutils)
#   - bc (for time estimates)
#
# Usage:
#    ./enhanced_pkg_mapper.sh [--verbose] [--clear-cache] [--max-packages N] [output_directory]
#
# Examples:
#    ./enhanced_pkg_mapper.sh
#    ./enhanced_pkg_mapper.sh --max-packages 50
#    ./enhanced_pkg_mapper.sh --verbose --clear-cache ./output/
#

# --- Strict Mode & Safety ---
set -o errexit
set -o nounset
set -o pipefail

# --- Constants & Configuration ---
readonly SCRIPT_NAME
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_URL="https://github.com/doublegate/container-pkg-map"
readonly CONTACT_EMAIL="parobek@gmail.com"
readonly API_BASE_URL="https://repology.org/api/v1"
readonly USER_AGENT="EnhancedPkgMapper/${SCRIPT_VERSION} (${SCRIPT_URL}; mailto:${CONTACT_EMAIL})"
readonly CACHE_TTL_SECONDS=$((24 * 60 * 60)) # 24 hours

# --- Determine User and Home Directory ---
# This is critical for running commands correctly, especially if sudo is involved.
readonly REAL_USER="${SUDO_USER:-$USER}"
readonly USER_HOME
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$USER_HOME/.cache}/enhanced-pkg-mapper"

# --- Global Variables ---
VERBOSE=false
CLEAR_CACHE=false
MAX_PACKAGES=0 # 0 means no limit
OUTPUT_DIR=""
LOG_FILE=""

# --- Logging Functions ---

# Standard log message
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE"
    else
        echo "$message"
    fi
}

# Verbose/debug log message
vlog() {
    if [[ "$VERBOSE" == "true" ]]; then
        local message="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1"
        # Verbose logs only go to stderr to not clutter output files
        echo "$message" >&2
    fi
}

# Error log message
error_log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE" >&2
    else
        echo "$message" >&2
    fi
}

# --- Core Functions ---

usage() {
    echo "Usage: ${SCRIPT_NAME} [--verbose] [--clear-cache] [--max-packages N] [output_directory]"
    echo
    echo "Captures and maps Fedora packages to Arch Linux equivalents."
    echo
    echo "Options:"
    echo "  output_directory   Directory to store output files (default: ~/pkg-mapper-YYYYMMDD_HHMM)."
    echo "  --verbose          Enable verbose/debug output."
    echo "  --clear-cache      Clear the package mapping cache before running."
    echo "  --max-packages N   Limit mapping to the first N packages from the host (for testing)."
    echo "  --help, -h         Display this help message and exit."
    exit 0
}

check_dependencies() {
    vlog "Checking for required dependencies..."
    local missing_deps=0
    for cmd in curl jq stat bc; do
        if ! command -v "${cmd}" &>/dev/null; then
            error_log "Required command '${cmd}' is not installed."
            missing_deps=1
        fi
    done
    if [[ "${missing_deps}" -eq 1 ]]; then
        error_log "Please install the missing dependencies and try again."
        exit 1
    fi
    vlog "All core dependencies are present."
}

# Perform an API call with retry logic.
fetch_from_api() {
    local url="$1"
    local retries=3
    local delay=2

    for ((i=1; i<=retries; i++)); do
        local response
        # The '|| true' prevents script exit if curl fails, allowing retry logic to handle it.
        response=$(curl --fail --connect-timeout 10 -sSL -H "User-Agent: ${USER_AGENT}" "${url}" || true)

        if [[ -n "${response}" ]]; then
            echo "${response}"
            return 0
        fi

        if [[ ${i} -lt ${retries} ]]; then
            vlog "API call to ${url} failed. Retrying in ${delay}s... (${i}/${retries})"
            sleep "${delay}"
            delay=$((delay * 2)) # Exponential backoff
        fi
    done

    vlog "API call to ${url} failed after ${retries} attempts."
    echo "" # Return empty string on persistent failure
    return 0
}

# **IMPROVED** Core mapping logic for a single package, based on fedora-to-arch-mapper.sh
map_package() {
    local fedora_pkg="$1"
    # Sanitize package name for use as a filename
    local safe_pkg_name
    safe_pkg_name=$(echo "${fedora_pkg}" | sed 's/[^a-zA-Z0-9._-]/_/g')
    local cache_file="${CACHE_DIR}/${safe_pkg_name}"

    # 1. Check cache first.
    if [[ -f "${cache_file}" ]]; then
        local now file_mod_time
        now=$(date +%s)
        file_mod_time=$(stat -c %Y "${cache_file}")
        if [[ $((now - file_mod_time)) -lt ${CACHE_TTL_SECONDS} ]]; then
            vlog "Cache hit for '${fedora_pkg}'."
            cat "${cache_file}"
            return 0
        else
            vlog "Cache expired for '${fedora_pkg}'. Re-fetching."
        fi
    fi

    vlog "Querying API for '${fedora_pkg}'..."

    # **IMPROVED LOGIC**: Use the /projects/ endpoint which is designed for searching.
    # It's more direct and reliable than the previous two-step method.
    local search_url="${API_BASE_URL}/projects/?search=${fedora_pkg}&exact=1"
    local response_data
    response_data=$(fetch_from_api "${search_url}")
    sleep 1 # Respect API rate limit

    if [[ -z "${response_data}" || "${response_data}" == "{}" ]]; then
        vlog "No project found for '${fedora_pkg}'. Caching as not found."
        # Create an empty file to cache the "not found" result
        touch "${cache_file}"
        echo ""
        return 0
    fi

    # **IMPROVED JQ FILTER**: This is simpler and more robust.
    # It parses the dictionary response from /projects/, finds the first project,
    # and then searches for 'arch' repo, falling back to 'aur'.
    local arch_pkg
    arch_pkg=$(echo "${response_data}" | jq -r '
        first(.[] | select(.!=null)) | # Get the package list from the first project
        (
            (map(select(.repo == "arch")) | .[0].visiblename) // # Try official Arch repo
            (map(select(.repo == "aur")) | .[0].visiblename)    # Fallback to AUR
        ) // "" # Default to empty string if nothing is found
    ')

    if [[ -z "${arch_pkg}" ]]; then
        vlog "No corresponding Arch package found for '${fedora_pkg}'. Caching as not found."
        touch "${cache_file}"
        echo ""
    else
        vlog "Mapped '${fedora_pkg}' -> '${arch_pkg}'. Caching result."
        echo "${arch_pkg}" > "${cache_file}"
        echo "${arch_pkg}"
    fi
}


capture_container_packages() {
    log "Starting Distrobox container package capture..."
    if ! command -v distrobox-list &>/dev/null; then
        log "distrobox command not found. Skipping container capture."
        return
    fi

    local container_list_file="$OUTPUT_DIR/containers_list.txt"
    if ! sudo -u "$REAL_USER" distrobox-list > "$container_list_file" 2>"$OUTPUT_DIR/distrobox-list-err.log"; then
        log "Failed to list distrobox containers. Check 'distrobox-list-err.log'. Skipping."
        return
    fi

    # Extract container names, skipping the header line
    local container_names
    mapfile -t container_names < <(tail -n +2 "$container_list_file" | awk -F ' *\\| *' '{print $2}')

    if [[ ${#container_names[@]} -eq 0 ]]; then
        log "No active Distrobox containers found."
        return
    fi

    local total_containers=${#container_names[@]}
    log "Found $total_containers containers to process: ${container_names[*]}"
    local captured_count=0

    for container in "${container_names[@]}"; do
        log "Processing container: $container"
        local pkg_file="$OUTPUT_DIR/container-${container}-pkgs.txt"
        local err_file="$OUTPUT_DIR/container-${container}-err.log"

        local status
        status=$(sudo -u "$REAL_USER" podman ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null || echo "Error")

        if [[ ! "$status" =~ ^Up ]]; then
            log "Container '$container' is not running (status: $status). Skipping."
            continue
        fi

        vlog "Container '$container' is running. Detecting package manager..."
        local pkg_cmd=""
        if sudo -u "$REAL_USER" distrobox-enter "$container" -- which pacman &>/dev/null < /dev/null; then
            vlog "Detected Arch-based container."
            pkg_cmd="pacman -Qq"
        elif sudo -u "$REAL_USER" distrobox-enter "$container" -- which dpkg &>/dev/null < /dev/null; then
            vlog "Detected Debian-based container."
            pkg_cmd="dpkg-query -W -f='\${Package}\n'"
        elif sudo -u "$REAL_USER" distrobox-enter "$container" -- which rpm &>/dev/null < /dev/null; then
            vlog "Detected RPM-based container."
            pkg_cmd="rpm -qa --qf '%{NAME}\n'"
        else
            log "Unsupported package manager in container: $container. Skipping."
            continue
        fi

        # Execute the command to get packages
        if sudo -u "$REAL_USER" distrobox-enter "$container" -- sh -c "$pkg_cmd" >"$pkg_file" 2>"$err_file" < /dev/null; then
             log "Successfully captured packages from '$container' to '$pkg_file'."
             ((captured_count++))
        else
             log "Failed to capture packages from '$container'. See '$err_file'."
        fi
        # Remove error log if empty
        [[ ! -s "$err_file" ]] && rm -f "$err_file"
    done
    log "Container processing complete. Captured packages from $captured_count of $total_containers running containers."
}

generate_package_mapping() {
    log "Starting host package mapping..."
    if [[ ! -f /etc/os-release ]] || ! grep -qi "fedora\|bazzite\|silverblue\|kinoite" /etc/os-release; then
        log "Host is not a known Fedora-based system. Skipping host package mapping."
        return
    fi
     if ! command -v rpm &>/dev/null; then
        log "rpm command not found. Skipping host package mapping."
        return
    fi


    local fedora_version
    fedora_version=$(grep "VERSION_ID" /etc/os-release | cut -d= -f2 | tr -d '"')
    log "Detected Fedora-based system, version: ${fedora_version:-unknown}"

    log "Extracting host package names..."
    local host_pkg_file="$OUTPUT_DIR/host-fedora-packages.txt"
    rpm -qa --qf '%{NAME}\n' | sort -u > "$host_pkg_file"

    local packages_array=()
    mapfile -t packages_array < "$host_pkg_file"

    local total_packages=${#packages_array[@]}
    local packages_to_process=$total_packages

    if [[ "$MAX_PACKAGES" -gt 0 && "$MAX_PACKAGES" -lt "$total_packages" ]]; then
        log "Limiting to first $MAX_PACKAGES packages as per --max-packages option."
        packages_to_process=$MAX_PACKAGES
    fi

    if [[ "$packages_to_process" -eq 0 ]]; then
        log "No host packages found to map."
        return
    fi

    log "Found $packages_to_process host packages to map."
    local estimated_seconds=$((packages_to_process * 1)) # 1 sec per API call
    local estimated_minutes=$((estimated_seconds / 60))
    log "Estimated time for uncached packages: ~${estimated_minutes} minutes. Cached packages are instant."
    log "You can safely interrupt (Ctrl+C) and resume this process."

    local mapping_file="$OUTPUT_DIR/fedora_to_arch_mapping.txt"
    {
        echo "# Fedora ($fedora_version) to Arch Linux Package Mapping"
        echo "# Generated on $(date)"
        echo "# Format: fedora_package -> arch_package"
        echo ""
    } > "$mapping_file"

    local processed=0 found=0 not_found=0
    local start_time
    start_time=$(date +%s)

    for i in $(seq 0 $((packages_to_process - 1))); do
        local pkg="${packages_array[$i]}"
        [[ -z "$pkg" ]] && continue
        ((processed++))

        # Progress reporting
        if [[ $((processed % 10)) -eq 0 || "$processed" -eq "$packages_to_process" ]]; then
            local current_time elapsed rate remaining eta eta_min
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            if [[ "$elapsed" -gt 0 ]]; then
                rate=$(echo "scale=2; $processed / $elapsed" | bc)
                remaining=$((packages_to_process - processed))
                eta=$(echo "scale=0; $remaining / $rate" | bc 2>/dev/null || echo "0")
                eta_min=$(echo "scale=0; ($eta / 60) + 1" | bc 2>/dev/null || echo "1")
                log "Progress: $processed/$packages_to_process packages mapped... (~${eta_min} min remaining)"
            else
                log "Progress: $processed/$packages_to_process packages mapped..."
            fi
        fi

        local arch_pkg
        arch_pkg=$(map_package "$pkg")

        if [[ -n "$arch_pkg" ]]; then
            echo "$pkg -> $arch_pkg" >> "$mapping_file"
            ((found++))
        else
            echo "$pkg -> [NOT FOUND]" >> "$mapping_file"
            ((not_found++))
        fi
    done

    local end_time total_elapsed elapsed_min
    end_time=$(date +%s)
    total_elapsed=$((end_time - start_time))
    elapsed_min=$((total_elapsed / 60))

    log "Package mapping completed in ~${elapsed_min} minutes."
    log "Summary: $found packages mapped, $not_found not found."
    log "Full mapping saved to: $mapping_file"

    local successful_mapping_file="$OUTPUT_DIR/fedora_to_arch_mapping_successful.txt"
    grep -v '\[NOT FOUND\]' "$mapping_file" | grep ' -> ' > "$successful_mapping_file"
    log "Successfully mapped packages saved to: $successful_mapping_file"
}

create_summary() {
    log "Creating summary report..."
    local summary_file="$OUTPUT_DIR/summary.txt"
    local file_count
    file_count=$(find "$OUTPUT_DIR" -type f | wc -l)
    local mapping_status="No mapping was generated for the host."

    if [[ -f "$OUTPUT_DIR/fedora_to_arch_mapping.txt" ]]; then
         local found_count not_found_count
         found_count=$(grep -c ' -> ' "$OUTPUT_DIR/fedora_to_arch_mapping_successful.txt")
         not_found_count=$(grep -c '\[NOT FOUND\]' "$OUTPUT_DIR/fedora_to_arch_mapping.txt")
         mapping_status="Host Mapping: $found_count packages found, $not_found_count not found."
    fi

    cat > "$summary_file" <<EOF
=================================
Enhanced Package Mapping Summary
=================================
Date: $(date)
Output Location: $OUTPUT_DIR
Log File: $LOG_FILE
Total Files Generated: $file_count

Host Status:
$mapping_status

Container Status:
$(find "$OUTPUT_DIR" -name "container-*-pkgs.txt" -type f | wc -l) container package lists were captured.
EOF

    log "Summary report created at: $summary_file"
    echo "----------------------------------------------------"
    cat "$summary_file"
    echo "----------------------------------------------------"
}


# --- Main Execution Logic ---
main() {
    # Parse command line options
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --verbose) VERBOSE=true; shift ;;
            --clear-cache) CLEAR_CACHE=true; shift ;;
            --max-packages)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    MAX_PACKAGES=$2; shift 2
                else
                    error_log "--max-packages requires a numeric argument."; exit 1
                fi
                ;;
            -h|--help) usage ;;
            -*) error_log "Unknown option: $1"; usage ;;
            *)
                if [[ -z "$OUTPUT_DIR" ]]; then
                    OUTPUT_DIR="$1"; shift
                else
                    error_log "Only one output directory can be specified."; usage
                fi
                ;;
        esac
    done

    # Set default output directory if not provided
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="$USER_HOME/pkg-mapper-$(date +%Y%m%d_%H%M)"
    fi
    # Normalize path (remove trailing slash)
    OUTPUT_DIR="${OUTPUT_DIR%/}"

    # Create directories and set log file path
    mkdir -p "$OUTPUT_DIR" "$CACHE_DIR"
    LOG_FILE="$OUTPUT_DIR/mapper.log"

    # From now on, all 'log' calls will write to the file
    log "=== Enhanced Package Mapping Script v${SCRIPT_VERSION} Starting ==="
    log "Output will be saved to: $OUTPUT_DIR"
    vlog "Verbose mode enabled"

    check_dependencies

    # Handle cache clearing
    if [[ "$CLEAR_CACHE" == "true" ]]; then
        log "Clearing package mapping cache at $CACHE_DIR"
        rm -rf "${CACHE_DIR:?}"/* # The :? protects against accidental deletion of /
    fi

    # Network pre-flight check
    vlog "Performing network connectivity test to repology.org..."
    if ! curl --connect-timeout 5 -sSL "https://repology.org" > /dev/null; then
        error_log "Network Failure: Could not connect to repology.org."
        error_log "Please check your internet connection and DNS settings."
        exit 1
    fi
    vlog "Network test successful."

    # Execute main tasks
    capture_container_packages
    generate_package_mapping
    create_summary

    log "=== Operation completed successfully ==="
}

# Run the main function, passing all command-line arguments to it.
# This structure prevents unexpected errors when no arguments are provided.
main "$@"
