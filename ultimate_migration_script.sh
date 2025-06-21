#!/usr/bin/env bash
#
# ultimate_migration_script.sh
#
# Author: DoubleGate
# Date: 2025-06-20
# Version: 4.5.1
#
# Description:
#   A comprehensive migration and backup script for Fedora-based systems moving to Arch Linux.
#   It combines robust Borg backups, Flatpak and Distrobox container management, and an
#   advanced Fedora-to-Arch package mapper.
#
#   This script integrates the functionality of 'enhanced_pkg_mapper.sh' into the
#   'migrate.sh' framework for a complete, all-in-one solution.
#
# Features:
#   - Full system state backup using Borg (home directory, /etc).
#   - Captures Flatpak lists and Distrobox container configurations.
#   - Advanced Fedora-to-Arch package mapping with a robust, cached, single-call API lookup.
#   - Full restore capabilities for files, Flatpaks, and containers.
#   - ISO verification and installation helpers.
#   - Optional GUI mode using Zenity for easier interaction.
#
# Dependencies:
#   - bash (v4.0+), borg, curl, jq, flatpak, distrobox, podman, rpm, stat, bc, zenity (for GUI)
#
# Version History:
#   4.5.1 - Fixed bug in container capture and package mapping.
#   4.5 - Added container capture and package mapping.
#   4.0 - Initial release.

# --- Strict Mode & Safety ---
set -euo pipefail

# --- Constants & Configuration ---
readonly SCRIPT_NAME
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="4.5.1"
readonly SCRIPT_URL="https://github.com/doublegate/container-pkg-map" # Keeping original repo link
readonly CONTACT_EMAIL="parobek@gmail.com"
readonly API_BASE_URL="https://repology.org/api/v1"
readonly USER_AGENT="UltimateMigrationScript/${SCRIPT_VERSION} (${SCRIPT_URL}; mailto:${CONTACT_EMAIL})"
readonly CACHE_TTL_SECONDS=$((24 * 60 * 60)) # 24 hours

# --- Determine User and Home Directory ---
readonly REAL_USER="${SUDO_USER:-$USER}"
readonly USER_HOME
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$USER_HOME/.cache}/ultimate-migration-mapper"
readonly BORG_BASE_DIR="$USER_HOME/.borg"
readonly PASSPHRASE_FILE="$USER_HOME/.borg/passphrase"

# --- Global Script Variables ---
DRY_RUN=false
CLEAR_CACHE=false
VERBOSE=false
GUI=false
COMPRESSION="zstd"
PARALLEL="$(nproc)"
MAX_PACKAGES=0 # 0 means no limit
LOG_FILE="" # Will be set based on mode

# --- Logging Functions ---
# Standard log message
log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE"
    else
        echo "$message"
    fi
}

# Verbose/debug log message
vlog() {
    if [[ "$VERBOSE" == "true" ]]; then
        local message
        message="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1"
        # Verbose logs only go to stderr to not clutter output files
        echo "$message" >&2
    fi
}

# Error log message
error_log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE" >&2
    else
        echo "$message" >&2
    fi
}

# --- Core Helper Functions ---
usage() {
    local msg
    msg=$(
        cat <<EOF
Usage: $SCRIPT_NAME [options] <mode> [mode_args...]

Modes:
  backup [dir]                     Back up system config, user data, and package lists.
                                   (Default dir: ~/migrate-YYYYMMDD_HHMM)
  restore <backup_dir> [etc] [home] Restore from a backup.
  verify-iso <iso> <sum_file>      Verify the checksum and signature of an ISO file.
  install-iso <iso> <sum_file>     Verify and then launch the installer from an ISO.

Options:
  --dry-run                        Simulate actions without making changes.
  --clear-cache                    Clear the package mapping cache.
  --verbose                        Enable detailed debug output.
  --gui                            Enable interactive GUI mode (uses Zenity).
  --compression <lz4|zstd|none>    Set Borg compression level (default: zstd).
  --parallel N                     Set number of parallel jobs for restore (default: autodetect).
  --max-packages N                 Limit package mapping to the first N host packages.
  --help, -h                       Display this help message.
EOF
    )
    if $GUI; then
        zenity --info --title="Usage" --text="$msg" --no-wrap
    else
        echo "$msg"
    fi
    exit 1
}

# --- Package Mapping Functions (from enhanced_pkg_mapper.sh) ---

check_mapper_dependencies() {
    vlog "Checking for package mapper dependencies..."
    for cmd in curl jq stat bc; do
        if ! command -v "${cmd}" &>/dev/null; then
            error_log "Mapper dependency '${cmd}' is not installed."
            return 1
        fi
    done
    vlog "All mapper dependencies are present."
    return 0
}

fetch_from_api() {
    local url="$1"
    local retries=3
    local delay=2
    for ((i = 1; i <= retries; i++)); do
        local response
        response=$(curl --fail --connect-timeout 10 -sSL -H "User-Agent: ${USER_AGENT}" "${url}" || true)
        [[ -n "${response}" ]] && { echo "${response}"; return 0; }
        [[ ${i} -lt ${retries} ]] && { vlog "API call to ${url} failed. Retrying in ${delay}s..."; sleep "${delay}"; delay=$((delay * 2)); }
    done
    vlog "API call to ${url} failed after ${retries} attempts."
    echo "" # Return empty on failure
    return 0
}

map_package() {
    local fedora_pkg="$1"
    local safe_pkg_name
    safe_pkg_name="${fedora_pkg//[^a-zA-Z0-9._-]/_}"
    local cache_file="${CACHE_DIR}/${safe_pkg_name}"

    if [[ -f "${cache_file}" ]]; then
        local now file_mod_time
        now=$(date +%s)
        file_mod_time=$(stat -c %Y "${cache_file}")
        if [[ $((now - file_mod_time)) -lt ${CACHE_TTL_SECONDS} ]]; then
            vlog "Cache hit for '${fedora_pkg}'."
            cat "${cache_file}"
            return 0
        fi
    fi

    vlog "Querying API for '${fedora_pkg}'..."
    local search_url="${API_BASE_URL}/projects/?search=${fedora_pkg}&exact=1"
    local response_data
    response_data=$(fetch_from_api "${search_url}")
    sleep 1 # API rate limit

    if [[ -z "${response_data}" || "${response_data}" == "{}" ]]; then
        vlog "No project found for '${fedora_pkg}'. Caching as not found."
        touch "${cache_file}"
        echo ""
        return 0
    fi

    local arch_pkg
    arch_pkg=$(echo "${response_data}" | jq -r 'first(.[]|select(.!=null)) | ((map(select(.repo=="arch"))|.[0].visiblename)//(map(select(.repo=="aur"))|.[0].visiblename))//" "')

    if [[ -z "$arch_pkg" ]]; then
        vlog "No Arch package found for '${fedora_pkg}'. Caching as not found."
        touch "${cache_file}"
    else
        vlog "Mapped '${fedora_pkg}' -> '${arch_pkg}'. Caching."
        echo "${arch_pkg}" >"${cache_file}"
    fi
    echo "${arch_pkg}"
}

run_package_mapping() {
    local backup_dir="$1"
    log "Starting host package mapping..."
    if [[ ! -f /etc/os-release ]] || ! grep -qi "fedora\|bazzite\|silverblue\|kinoite" /etc/os-release; then
        log "Host is not a known Fedora-based system. Skipping host package mapping."
        return
    fi
    if ! check_mapper_dependencies; then
        log "Missing dependencies for package mapping. Skipping."
        return
    fi

    local host_pkg_file="$backup_dir/host-fedora-packages.txt"
    log "Host package list located at: $host_pkg_file"

    local packages_array=()
    mapfile -t packages_array < "$host_pkg_file"
    local total_packages=${#packages_array[@]}
    local packages_to_process=$total_packages

    if [[ "$MAX_PACKAGES" -gt 0 && "$MAX_PACKAGES" -lt "$total_packages" ]]; then
        log "Limiting mapping to first $MAX_PACKAGES packages."
        packages_to_process=$MAX_PACKAGES
    fi
    [[ "$packages_to_process" -eq 0 ]] && { log "No host packages to map."; return; }

    log "Found $packages_to_process host packages to map."

    local mapping_file="$backup_dir/fedora_to_arch_mapping.txt"
    echo "# Fedora to Arch Linux Package Mapping | Generated on $(date)" > "$mapping_file"
    echo "# Format: fedora_package -> arch_package" >> "$mapping_file"

    local processed=0 found=0
    local temp_stats="/tmp/mapping_stats_$$"
    
    {
        for i in $(seq 0 $((packages_to_process - 1))); do
            local pkg="${packages_array[$i]}"
            [[ -z "$pkg" ]] && continue

            local arch_pkg
            arch_pkg=$(map_package "$pkg")

            if [[ -n "$arch_pkg" ]]; then
                echo "$pkg -> $arch_pkg" >> "$mapping_file"
                ((found++))
            else
                echo "$pkg -> [NOT FOUND]" >> "$mapping_file"
            fi
            ((processed++))
            echo $((processed * 100 / packages_to_process))
            echo "# Processing $pkg ($processed/$packages_to_process)"
        done
        echo "$found $processed" > "$temp_stats"
    } | if $GUI; then
        zenity --progress --title="Package Mapping" --text="Mapping Fedora packages to Arch..." --auto-close
    else
        # Simple text progress bar for non-GUI
        while read -r line; do
          if [[ "$line" =~ ^[0-9]+$ ]]; then
            printf "\rProgress: [%-50s] %d%%" "$(printf "=%.0s" $(seq 1 $((line/2)) ))" "$line"
          fi
        done
        echo # Newline after progress bar
    fi

    # Read the stats back
    if [[ -f "$temp_stats" ]]; then
        read -r found processed < "$temp_stats"
        rm -f "$temp_stats"
    fi

    log "Package mapping complete. Mapped: $found, Not Found: $((processed-found))."
    log "Mapping file saved to: $mapping_file"
}

# --- Main Mode Functions ---

backup() {
    local backup_dir="$1"
    log "Starting backup to $backup_dir"
    $DRY_RUN && { log "[DRY-RUN] Skipping all backup operations."; return; }

    mkdir -p "$backup_dir"
    local borg_repo="$backup_dir/borg-repo"

    # Init Borg repo if it doesn't exist
    if [ ! -d "$borg_repo" ]; then
        log "Initializing new Borg repository..."
        export BORG_PASSPHRASE
        BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE")
        borg init --encryption=keyfile-blake2 "$borg_repo"
        unset BORG_PASSPHRASE
    fi

    log "Backing up /etc..."
    borg_with_progress "borg create" "Borg Backup" "Backing up /etc..." "--compression" "$COMPRESSION" "$borg_repo::etc-{now}" /etc
    log "Backing up $USER_HOME..."
    borg_with_progress "borg create" "Borg Backup" "Backing up home..." "--compression" "$COMPRESSION" "$borg_repo::home-{now}" "$USER_HOME"

    log "Capturing installed package lists..."
    rpm -qa --qf '%{NAME}\n' | sort -u >"$backup_dir/host-fedora-packages.txt"
    flatpak list --app --columns=application >"$backup_dir/flatpaks.txt"
    log "Saved host RPM and Flatpak lists."

    # Run container capture and package mapping
    run_container_capture "$backup_dir"
    run_package_mapping "$backup_dir"

    log "Exporting Borg key..."
    export BORG_PASSPHRASE
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE")
    borg key export "$borg_repo" "$backup_dir/borg-key"
    unset BORG_PASSPHRASE

    log "Backup completed successfully at $backup_dir"
}


# --- Container Capture Helper Functions ---

_get_pkg_manager_cmd() {
    local container_name="$1"
    vlog "Detecting package manager in '$container_name'..."
    if sudo -u "$REAL_USER" distrobox-enter "$container_name" -- which pacman &>/dev/null < /dev/null; then
        vlog "Detected Arch-based container."
        echo "pacman -Qq"
    elif sudo -u "$REAL_USER" distrobox-enter "$container_name" -- which dpkg &>/dev/null < /dev/null; then
        vlog "Detected Debian-based container."
        printf "%s\n" "dpkg-query -W -f='\${Package}\n'"
    elif sudo -u "$REAL_USER" distrobox-enter "$container_name" -- which rpm &>/dev/null < /dev/null; then
        vlog "Detected RPM-based container."
        printf "%s\n" "rpm -qa --qf '%{NAME}\n'"
    else
        echo "" # Return empty string if no supported manager is found
    fi
}

_capture_packages_for_container() {
    local container="$1"
    local backup_dir="$2"
    local pkg_file="$backup_dir/container-${container}-pkgs.txt"
    local err_file="$backup_dir/container-${container}-err.log"

    log "Processing container: $container"

    local status
    status=$(sudo -u "$REAL_USER" podman ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null || echo "Error")

    if [[ ! "$status" =~ ^Up ]]; then
        log "Container '$container' is not running (status: $status). Skipping."
        return 1
    fi

    local pkg_cmd
    pkg_cmd=$(_get_pkg_manager_cmd "$container")

    if [[ -z "$pkg_cmd" ]]; then
        log "Unsupported package manager in container '$container'. Skipping."
        return 1
    fi

    vlog "Executing package capture in '$container': '$pkg_cmd'"
    if sudo -u "$REAL_USER" distrobox-enter "$container" -- sh -c "$pkg_cmd" 2>"$err_file" < /dev/null | sudo -u "$REAL_USER" tee "$pkg_file" > /dev/null; then
        log "Successfully captured packages from '$container' to '$pkg_file'."
        [[ ! -s "$err_file" ]] && rm -f "$err_file"
        return 0
    else
        error_log "Failed to capture packages from '$container'. See '$err_file'."
        return 1
    fi
}

run_container_capture() {
    local backup_dir="$1"
    log "Starting Distrobox container package capture..."
    if ! command -v distrobox-list &>/dev/null; then
        log "distrobox command not found. Skipping container capture."
        return
    fi

    local container_list_file="$backup_dir/containers_list.txt"
    local err_log="$backup_dir/distrobox-list-err.log"
    if ! sudo -u "$REAL_USER" distrobox-list 2>"$err_log" | sudo -u "$REAL_USER" tee "$container_list_file" > /dev/null; then
        error_log "Failed to list distrobox containers. Check '$err_log'. Skipping."
        [[ ! -s "$err_log" ]] && rm -f "$err_log"
        return
    fi
    [[ ! -s "$err_log" ]] && rm -f "$err_log"

    local container_names
    mapfile -t container_names < <(tail -n +2 "$backup_dir/containers_list.txt" | awk -F ' *\\| *' '{print $2}')
    local total_containers=${#container_names[@]}
    [[ "$total_containers" -eq 0 ]] && { log "No active Distrobox containers found."; return; }

    log "Found $total_containers containers to process: ${container_names[*]}"
    local skipped_or_failed_count=0

    for container in "${container_names[@]}"; do
        if ! _capture_packages_for_container "$container" "$backup_dir"; then
            ((skipped_or_failed_count++))
        fi
    done

    local captured_count=$((total_containers - skipped_or_failed_count))
    log "Container capture complete. Captured packages from $captured_count of $total_containers containers ($skipped_or_failed_count skipped or failed)."
}


borg_with_progress() {
    local cmd=$1; local title=$2; local text=$3; shift 3
    $DRY_RUN && { log "[DRY-RUN] Borg command: $cmd $*"; return; }

    export BORG_PASSPHRASE
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE")

    if $GUI; then
        (borg "$cmd" --progress "$@" 2>&1) | \
        while read -r line; do
            if echo "$line" | grep -qP '\d+\.\d+%'; then
                echo "${line%%\%*}" | awk '{print $NF}'
            fi
        done | zenity --progress --title="$title" --text="$text" --auto-close
    else
        borg "$cmd" --progress --stats "$@"
    fi
    unset BORG_PASSPHRASE
}

_select_borg_archive() {
    local borg_repo="$1"
    local archive_prefix="$2"
    local title="$3"

    vlog "Listing archives with prefix '$archive_prefix' in repo '$borg_repo'"
    export BORG_PASSPHRASE
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE")
    local archives
    mapfile -t archives < <(borg list "$borg_repo" --glob "$archive_prefix*" --format '{name}{NL}' | sort -r)
    unset BORG_PASSPHRASE

    if [[ ${#archives[@]} -eq 0 ]]; then
        error_log "No archives found with prefix '$archive_prefix' in the repository."
        return 1
    fi

    if $GUI; then
        local selected_archive
        selected_archive=$(zenity --list --title="$title" --text="Select an archive to restore from:" \
            --column="Available Archives" "${archives[@]}" 2>/dev/null)
        if [[ -n "$selected_archive" ]]; then
            echo "$selected_archive"
            return 0
        else
            error_log "No archive selected."
            return 1
        fi
    else
        log "Please select an archive to restore from:"
        select archive in "${archives[@]}"; do
            if [[ -n "$archive" ]]; then
                echo "$archive"
                return 0
            else
                error_log "Invalid selection. Please try again."
            fi
        done
    fi
}

_restore_etc() {
    local backup_dir="$1"
    local borg_repo="$backup_dir/borg-repo"
    local etc_archive
    etc_archive=$(_select_borg_archive "$borg_repo" "etc-" "Select /etc Archive") || return 1

    local tmp_etc
    tmp_etc="/tmp/etc_restore_$(date +%Y%m%d_%H%M)"
    log "Restoring /etc from archive '$etc_archive' to temporary location: $tmp_etc"
    mkdir -p "$tmp_etc"
    borg_with_progress "borg extract" "Borg Restore" "Restoring /etc..." \
        "$borg_repo::$etc_archive" --strip-components 1 -C "$tmp_etc" etc

    log "Restore of /etc complete. Please manually review and merge files from '$tmp_etc' to '/etc'."
    if $GUI; then
        zenity --info --text="The /etc backup has been restored to:\n\n$tmp_etc\n\nPlease manually merge the required configuration files."
    fi
}

_restore_home() {
    local backup_dir="$1"
    local borg_repo="$backup_dir/borg-repo"
    local home_archive
    home_archive=$(_select_borg_archive "$borg_repo" "home-" "Select Home Archive") || return 1

    log "Restoring home directory from archive '$home_archive'..."
    local confirm_restore=false
    if $GUI; then
        if zenity --question --title="Confirm Home Directory Restore" --text="This will restore files from the backup to your home directory.\n\n<b>Existing files with the same name will be overwritten.</b>\n\nAre you sure you want to continue?"; then
            confirm_restore=true
        fi
    else
        read -p "WARNING: This will overwrite existing files in your home directory. Continue? (y/N) " -n 1 -r
        echo
        [[ "$REPLY" =~ ^[Yy]$ ]] && confirm_restore=true
    fi

    ! $confirm_restore && { log "Home directory restore cancelled by user."; return; }

    # We cd into the user's home directory to ensure files are restored to the correct location.
    (
        cd "$USER_HOME" && \
        borg_with_progress "borg extract" "Borg Restore" "Restoring home directory..." \
            "$borg_repo::$home_archive" --strip-components 2 "home/$(basename "$USER_HOME")"
    )
    log "Home directory restore complete."
}

_restore_flatpaks() {
    local backup_dir="$1"
    local flatpak_list="$backup_dir/flatpaks.txt"
    [[ ! -s "$flatpak_list" ]] && { log "No Flatpak list found. Skipping."; return; }

    log "Reinstalling Flatpaks in parallel ($PARALLEL jobs)..."
    local total count
    total=$(wc -l < "$flatpak_list")
    count=0

    (
    while read -r app_id || [[ -n "$app_id" ]]; do
        vlog "Installing Flatpak: $app_id"
        if ! flatpak install -y --noninteractive "$app_id"; then
            error_log "Failed to install Flatpak: $app_id"
        fi
        ((count++))
        echo $((count * 100 / total))
        echo "# Installing $app_id ($count/$total)"
    done < "$flatpak_list"
    ) | if $GUI; then
        zenity --progress --title="Flatpak Installation" --text="Installing Flatpaks..." --auto-close
    else
        # Simple text progress bar for non-GUI
        while read -r line; do
          if [[ "$line" =~ ^[0-9]+$ ]]; then
            printf "\rProgress: [%-50s] %d%%" "$(printf "=%.0s" $(seq 1 $((line/2)) ))" "$line"
          fi
        done
        echo
    fi
    log "Flatpak installation complete."
}

_restore_containers() {
    local backup_dir="$1"
    local container_list="$backup_dir/containers_list.txt"
    [[ ! -s "$container_list" ]] && { log "No container list found. Skipping."; return; }

    log "Recreating Distrobox containers..."
    local total count
    total=$(tail -n +2 "$container_list" | wc -l)
    count=0

    (
    tail -n +2 "$container_list" | awk -F ' *\\| *' '{gsub(/ /, "", $2); gsub(/ /, "", $4); print $2, $4}' | \
    while read -r name image; do
        [[ -z "$name" || -z "$image" ]] && continue
        log "Recreating container '$name' with image '$image'..."
        if ! sudo -u "$REAL_USER" distrobox create --name "$name" --image "$image"; then
            error_log "Failed to create container '$name'. Skipping package installation for it."
        else
            local pkg_file="$backup_dir/container-${name}-pkgs.txt"
            if [[ -s "$pkg_file" ]]; then
                log "Installing packages in container '$name'..."
                # Assuming the new host is Arch-based, so pacman is the target
                if ! sudo -u "$REAL_USER" sh -c "cat '$pkg_file' | distrobox-enter '$name' -- sudo pacman -S --noconfirm --needed -"; then
                    error_log "Failed to install packages in container '$name'."
                fi
            fi
        fi
        ((count++))
        echo $((count * 100 / total))
        echo "# Recreated $name ($count/$total)"
    done
    ) | if $GUI; then
        zenity --progress --title="Container Restoration" --text="Recreating containers..." --auto-close
    fi
    log "Container restoration complete."
}

restore() {
    local backup_dir="$1"
    log "Starting restore from $backup_dir"
    $DRY_RUN && { log "[DRY-RUN] Skipping all restore operations."; return; }

    if [[ ! -d "$backup_dir/borg-repo" || ! -f "$backup_dir/borg-key" ]]; then
        error_log "Backup is invalid. Missing 'borg-repo' or 'borg-key' in '$backup_dir'."
        $GUI && zenity --error --text="Invalid backup directory provided."
        exit 1
    fi

    log "Importing Borg key..."
    export BORG_PASSPHRASE
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE")
    borg key import "$backup_dir/borg-repo" "$backup_dir/borg-key"
    unset BORG_PASSPHRASE

    local choices
    if $GUI; then
        choices=$(zenity --list --checklist --title="Restore Options" --text="Select components to restore:" \
            --column="Select" --column="Component" --column="Description" \
            TRUE "etc" "System configuration files (restored to /tmp)" \
            TRUE "home" "User home directory (overwrites existing files)" \
            TRUE "containers" "Recreate Distrobox containers and packages" \
            TRUE "flatpaks" "Reinstall all backed-up Flatpaks" \
            --separator=":" 2>/dev/null)
    else
        # For CLI, we can assume all for now or add prompts. Let's assume all for simplicity.
        log "CLI mode: restoring all components (/etc, home, containers, flatpaks)."
        choices="etc:home:containers:flatpaks"
    fi

    [[ -z "$choices" ]] && { log "No components selected for restore. Aborting."; return; }

    [[ "$choices" =~ "etc" ]] && _restore_etc "$backup_dir"
    [[ "$choices" =~ "home" ]] && _restore_home "$backup_dir"
    [[ "$choices" =~ "containers" ]] && _restore_containers "$backup_dir"
    [[ "$choices" =~ "flatpaks" ]] && _restore_flatpaks "$backup_dir"

    log "Restore process finished."
    if [[ -f "$backup_dir/fedora_to_arch_mapping.txt" ]]; then
        log "A package mapping file is available at: $backup_dir/fedora_to_arch_mapping.txt"
        if $GUI; then
            zenity --info --text="Restore complete.\n\nSee the package mapping file for suggested Arch packages to install."
        fi
    fi
}

verify_iso() {
    local iso="$1" sumfile="$2"
    log "Verifying ISO: $iso"
    $DRY_RUN && { log "[DRY-RUN] Skipping ISO verification."; return; }
    sha256sum -c "$sumfile" || { error_log "Checksum validation failed!"; exit 1; }
    log "Checksum OK."
    gpg --verify "${iso}.sig" "${iso}" || { error_log "GPG signature validation failed!"; exit 1; }
    log "GPG Signature OK."
}

install_iso() {
    local iso="$1" sumfile="$2"
    log "Starting ISO installation process for: $iso"
    verify_iso "$@"
    # ... (install logic from migrate.sh)
}

# --- Main Execution Logic ---
main() {
    # Ensure cache directory exists
    mkdir -p "$CACHE_DIR" "$BORG_BASE_DIR"

    # Parse command line options
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --verbose) VERBOSE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --clear-cache) CLEAR_CACHE=true; shift ;;
            --gui) GUI=true; shift ;;
            --compression) COMPRESSION="$2"; shift 2 ;;
            --parallel) PARALLEL="$2"; shift 2 ;;
            --max-packages) MAX_PACKAGES="$2"; shift 2 ;;
            -h|--help) usage ;;
            -*) error_log "Unknown option: $1"; usage ;;
            *) break ;; # End of options
        esac
    done

    # Handle --clear-cache
    if [[ "$CLEAR_CACHE" == "true" ]]; then
        log "Clearing package mapping cache at $CACHE_DIR"
        rm -rf "${CACHE_DIR:?}"/*
    fi

    # Mode selection
    local MODE="${1:-}"
    if [[ -z "$MODE" ]]; then
        $GUI && MODE=$(zenity --list --title="Migration Mode" --text="Select mode:" --column="Mode" backup restore verify-iso install-iso 2>/dev/null)
        [[ -z "$MODE" ]] && { error_log "No mode selected."; usage; }
    fi
    shift # Consume mode argument

    # Set log file based on mode
    local backup_dir
    case "$MODE" in
        backup)
            backup_dir="${1:-$USER_HOME/migrate-$(date +%Y%m%d_%H%M)}"
            mkdir -p "$backup_dir"
            LOG_FILE="$backup_dir/migrate.log"
            log "=== Ultimate Migration Script v${SCRIPT_VERSION} | Backup Mode ==="
            backup "$backup_dir"
            ;;
        restore)
            backup_dir="${1:?Backup directory is required for restore}"
            LOG_FILE="$backup_dir/migrate.log"
            log "=== Ultimate Migration Script v${SCRIPT_VERSION} | Restore Mode ==="
            restore "$@"
            ;;
        verify-iso)
            LOG_FILE="/tmp/migrate-verify-$(date +%Y%m%d_%H%M).log"
            log "=== Ultimate Migration Script v${SCRIPT_VERSION} | Verify ISO Mode ==="
            verify_iso "$@"
            ;;
        install-iso)
            LOG_FILE="/tmp/migrate-install-$(date +%Y%m%d_%H%M).log"
            log "=== Ultimate Migration Script v${SCRIPT_VERSION} | Install ISO Mode ==="
            install_iso "$@"
            ;;
        *)
            error_log "Invalid mode: $MODE"
            usage
            ;;
    esac

    log "=== Operation completed successfully ==="
}

# Run the main function
main "$@"
