#!/usr/bin/env bash
set -euo pipefail

# Determine real user and home directory
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
DRY_RUN=false
CLEAR_CACHE=false
VERBOSE=false
COMPRESSION="lz4"
PARALLEL=4
GUI=false
CACHE_DIR="$USER_HOME/.cache/migrate_pkg_map"
BORG_BASE_DIR="$USER_HOME/.borg"
PASSPHRASE_FILE="$USER_HOME/.borg/passphrase"
mkdir -p "$CACHE_DIR" "$BORG_BASE_DIR"

# Parse options
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --clear-cache)
      CLEAR_CACHE=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --compression)
      COMPRESSION="$2"
      [[ "$COMPRESSION" =~ ^(none|lz4|zstd)$ ]] || { echo "Invalid compression: $COMPRESSION (use none, lz4, zstd)"; exit 1; }
      shift 2
      ;;
    --parallel)
      PARALLEL="$2"
      [[ "$PARALLEL" =~ ^[0-9]+$ ]] || { echo "Invalid parallel value: $PARALLEL (use a positive integer)"; exit 1; }
      shift 2
      ;;
    --gui)
      GUI=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

# GUI mode
if $GUI; then
  MODE=$(zenity --list --title="Migration Mode" --text="Select migration mode:" --column="Mode" backup verify-iso install-iso restore 2>/dev/null) || { zenity --error --text="Mode selection cancelled"; exit 1; }
  if $VERBOSE; then
    log "[VERBOSE] GUI mode selected: $MODE"
  fi
else
  MODE="$1"
  shift
fi

# Set variables based on mode and define required tools
case "$MODE" in
  backup)
    if $GUI; then
      BACKUP_DIR=$(zenity --file-selection --directory --title="Select backup directory" --filename="$USER_HOME/migrate-$(date +%Y%m%d_%H%M)/" 2>/dev/null) || BACKUP_DIR="$USER_HOME/migrate-$(date +%Y%m%d_%H%M)"
    else
      BACKUP_DIR="${1:-$USER_HOME/migrate-$(date +%Y%m%d_%H%M)}"
      shift
    fi
    LOG="$BACKUP_DIR/migrate.log"
    required_tools=(borg curl jq zenity flatpak distrobox rpm find xargs)
    ;;
  restore)
    if $GUI; then
      BACKUP_DIR=$(zenity --file-selection --directory --title="Select backup directory" --filename="$USER_HOME/" 2>/dev/null) || { zenity --error --text="Backup directory required"; exit 1; }
      # Create temporary directories for path selection
      TMP_PATHS_DIR="/tmp/borg_paths"
      mkdir -p "$TMP_PATHS_DIR/etc" "$TMP_PATHS_DIR/home/$(basename "$USER_HOME")"
      BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE" 2>/dev/null) || BORG_PASSPHRASE=""
      export BORG_PASSPHRASE
      borg list "$BACKUP_DIR/borg-repo::etc" --format="{path}\n" | while read -r path; do
        if [[ "$path" == etc/* ]]; then
          mkdir -p "$(dirname "$TMP_PATHS_DIR/$path")"
          touch "$TMP_PATHS_DIR/$path"
        fi
      done
      borg list "$BACKUP_DIR/borg-repo::home" --format="{path}\n" | while read -r path; do
        if [[ "$path" == home/$(basename "$USER_HOME")/* ]]; then
          mkdir -p "$(dirname "$TMP_PATHS_DIR/$path")"
          touch "$TMP_PATHS_DIR/$path"
        fi
      done
      unset BORG_PASSPHRASE
      ETC_PATHS=$(zenity --file-selection --multiple --separator=" " --title="Select /etc paths to restore" --directory --filename="$TMP_PATHS_DIR/etc/" 2>/dev/null | sed "s|$TMP_PATHS_DIR/etc/||g") || ETC_PATHS=""
      HOME_PATHS=$(zenity --file-selection --multiple --separator=" " --title="Select $USER_HOME paths to restore" --directory --filename="$TMP_PATHS_DIR/home/$(basename "$USER_HOME")/" 2>/dev/null | sed "s|$TMP_PATHS_DIR/home/$(basename "$USER_HOME")/||g") || HOME_PATHS=""
      rm -rf "$TMP_PATHS_DIR"
    else
      BACKUP_DIR="$1"
      ETC_PATHS="$2"
      HOME_PATHS="$3"
      shift 3
    fi
    if [ -z "$BACKUP_DIR" ]; then
      if $GUI; then
        zenity --error --text="Backup directory required"
      else
        echo "Error: backup directory required for restore"
      fi
      usage
    fi
    LOG="$BACKUP_DIR/migrate.log"
    required_tools=(borg zenity flatpak distrobox find xargs)
    ;;
  verify-iso)
    if $GUI; then
      ISO=$(zenity --file-selection --title="Select CachyOS ISO" --file-filter="ISO files | *.iso" 2>/dev/null) || { zenity --error --text="ISO file required"; exit 1; }
      SUMFILE=$(zenity --file-selection --title="Select SHA256 sum file" --file-filter="SHA256 files | *.sha256sum" 2>/dev/null) || { zenity --error --text="Sum file required"; exit 1; }
    else
      ISO="$1"
      SUMFILE="$2"
      shift 2
    fi
    if [ -z "$ISO" ] || [ -z "$SUMFILE" ]; then
      if $GUI; then
        zenity --error --text="ISO and sumfile required"
      else
        echo "Error: ISO and sumfile required for verify-iso"
      fi
      usage
    fi
    LOG="/tmp/migrate-verify-$(date +%Y%m%d_%H%M).log"
    required_tools=(sha256sum gpg)
    ;;
  install-iso)
    if $GUI; then
      ISO=$(zenity --file-selection --title="Select CachyOS ISO" --file-filter="ISO files | *.iso" 2>/dev/null) || { zenity --error --text="ISO file required"; exit 1; }
      SUMFILE=$(zenity --file-selection --title="Select SHA256 sum file" --file-filter="SHA256 files | *.sha256sum" 2>/dev/null) || { zenity --error --text="Sum file required"; exit 1; }
      CUSTOM_INSTALLER=$(zenity --entry --title="Custom Installer" --text="Enter custom installer path or command (leave blank for auto-detection):" 2>/dev/null) || CUSTOM_INSTALLER=""
      CUSTOM_INSTALLER_ARGS=($(zenity --entry --title="Installer Arguments" --text="Enter installer arguments (space-separated, leave blank for none):" 2>/dev/null)) || CUSTOM_INSTALLER_ARGS=()
    else
      ISO="$1"
      SUMFILE="$2"
      CUSTOM_INSTALLER="$3"
      shift 3
      CUSTOM_INSTALLER_ARGS=("$@")
    fi
    if [ -z "$ISO" ] || [ -z "$SUMFILE" ]; then
      if $GUI; then
        zenity --error --text="ISO and sumfile required"
      else
        echo "Error: ISO and sumfile required for install-iso"
      fi
      usage
    fi
    LOG="/tmp/migrate-install-$(date +%Y%m%d_%H%M).log"
    required_tools=(mount umount)
    ;;
  *)
    usage
    ;;
esac

# Check required tools
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        if $GUI; then
            zenity --error --text="$tool is not installed. Please install it."
        else
            echo "$tool is not installed. Please install it."
        fi
        exit 1
    fi
done

# Check passphrase file
if [ ! -f "$PASSPHRASE_FILE" ]; then
    if $GUI; then
        PASSPHRASE=$(zenity --password --title="Enter Borg Passphrase" --text="Enter passphrase for Borg repository:" 2>/dev/null) || { zenity --error --text="Passphrase required"; exit 1; }
        echo "$PASSPHRASE" > "$PASSPHRASE_FILE"
        chmod 600 "$PASSPHRASE_FILE"
    else
        echo "Error: Passphrase file $PASSPHRASE_FILE not found. Create it with your Borg passphrase."
        exit 1
    fi
fi

log() {
    echo "[$(date)] $1" | tee -a "$LOG"
    if $VERBOSE; then
        echo "[VERBOSE] $1" >&2
    fi
}
usage() { 
    local msg="Usage: $0 [--dry-run] [--clear-cache] [--verbose] [--compression <none|lz4|zstd>] [--parallel N] [--gui] backup [dir] | verify-iso <iso> <sha256sum> | install-iso <iso> <sha256sum> [installer [args...]] | restore <backupdir> [etc_paths] [home_paths]"
    if $GUI; then
        zenity --error --text="$msg"
    else
        echo "$msg"
    fi
    exit 1
}

borg_with_progress() {
    local cmd=$1
    local title=$2
    local text=$3
    shift 3
    if $DRY_RUN; then
        log "[DRY-RUN] Would run: $cmd --progress $*"
        return 0
    fi
    if $VERBOSE; then
        log "[VERBOSE] Executing: $cmd --progress $*"
    fi
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE") || { log "Failed to read passphrase"; if $GUI; then zenity --error --text="Failed to read passphrase"; fi; exit 1; }
    export BORG_PASSPHRASE
    BORG_BASE_DIR="$BORG_BASE_DIR" $cmd --progress "$@" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "%"; then
            percentage=$(echo "$line" | sed -n 's/.*\([0-9]\{1,3\}\)% .*/\1/p')
            echo "$percentage"
            if $VERBOSE; then
                log "[VERBOSE] Borg progress: $line"
            fi
        fi
    done | zenity --progress --title="$title" --text="$text" --auto-close
    unset BORG_PASSPHRASE
}

retry_command() {
    local cmd=$1
    shift
    local retries=3
    local delay=5
    local attempt=1
    while [ $attempt -le $retries ]; do
        if $VERBOSE; then
            log "[VERBOSE] Attempt $attempt/$retries: $cmd $*"
        fi
        if $cmd "$@"; then
            return 0
        fi
        log "Command failed: $cmd $*. Retrying ($attempt/$retries)..."
        sleep $delay
        attempt=$((attempt + 1))
    done
    log "Command failed after $retries attempts: $cmd $*"
    return 1
}

validate_paths() {
    local archive=$1
    local paths=$2
    local prefix=$3
    if [ -z "$paths" ]; then
        return 0
    fi
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE") || { log "Failed to read passphrase"; if $GUI; then zenity --error --text="Failed to read passphrase"; fi; exit 1; }
    export BORG_PASSPHRASE
    for path in $paths; do
        if ! BORG_BASE_DIR="$BORG_BASE_DIR" borg list "$BACKUP_DIR/borg-repo::$archive" --format="{path}\n" | grep -q "^$prefix$path$"; then
            log "Path $path not found in $archive archive"
            if $GUI; then
                zenity --error --text="Path $path not found in $archive archive"
            fi
            unset BORG_PASSPHRASE
            return 1
        fi
    done
    unset BORG_PASSPHRASE
    return 0
}

backup() {
    if $DRY_RUN; then
        log "[DRY-RUN] Would create backup directory: $BACKUP_DIR"
        log "[DRY-RUN] Would initialize Borg repo and back up /etc, $USER_HOME, packages, and containers"
        return 0
    fi
    if $VERBOSE; then
        log "[VERBOSE] Starting backup to $BACKUP_DIR with compression: $COMPRESSION"
    fi
    mkdir -p "$BACKUP_DIR"
    BORG_REPO="$BACKUP_DIR/borg-repo"
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE") || { log "Failed to read passphrase"; if $GUI; then zenity --error --text="Failed to read passphrase"; fi; exit 1; }
    export BORG_PASSPHRASE
    BORG_BASE_DIR="$BORG_BASE_DIR" borg init --encryption=keyfile-blake2 "$BORG_REPO"
    unset BORG_PASSPHRASE
    log "Initialized Borg repo"
    borg_with_progress "borg create" "Borg Backup" "Backing up /etc..." "--compression" "$COMPRESSION" "$BORG_REPO::etc" /etc
    borg_with_progress "borg create" "Borg Backup" "Backing up $USER_HOME..." "--compression" "$COMPRESSION" "$BORG_REPO::home" "$USER_HOME"
    log "Backed up /etc and $USER_HOME"
    rpm -qa --qf '%{NAME}\n' | sort -u >"$BACKUP_DIR/host-package-names.txt"
    flatpak list --app --columns=application >"$BACKUP_DIR/flatpaks.txt"
    log "Saved host package names & Flatpak list"
    # Capture container packages
    if sudo -u "$REAL_USER" -H distrobox-list > "$BACKUP_DIR/containers_list.txt"; then
        while read -r container; do
            sudo -u "$REAL_USER" -H distrobox enter "$container" -- pacman -Qq >"$BACKUP_DIR/container-${container}-pkgs.txt" || log "Failed to capture packages for container: $container"
            log "Captured packages from container: $container"
        done < <(tail -n +2 "$BACKUP_DIR/containers_list.txt" | awk '{print $2}')
        sudo -u "$REAL_USER" -H distrobox-list | tail -n +2 | awk '{print $2, $4}' >"$BACKUP_DIR/containers.txt"
        log "Saved list of containers and their images"
    else
        log "Failed to list distrobox containers. Skipping container backup."
    fi
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE") || { log "Failed to read passphrase"; if $GUI; then zenity --error --text="Failed to read passphrase"; fi; exit 1; }
    export BORG_PASSPHRASE
    BORG_BASE_DIR="$BORG_BASE_DIR" borg key export "$BORG_REPO" "$BACKUP_DIR/borg-key"
    unset BORG_PASSPHRASE
    log "Exported Borg key to $BACKUP_DIR/borg-key"

    # Generate package mapping
    if [ -f /etc/fedora-release ]; then
        FEDORA_VERSION=$(cat /etc/fedora-release | awk '{print $3}')
        REPO="fedora_${FEDORA_VERSION}"
        if command -v curl &> /dev/null && command -v jq &> /dev/null; then
            if $CLEAR_CACHE; then
                rm -rf "$CACHE_DIR"/*
                mkdir -p "$CACHE_DIR"
                log "Cleared package mapping cache"
            fi
            echo "Generating Fedora to Arch package mapping..."
            while read -r pkg; do
                cache_file="$CACHE_DIR/$pkg.cache"
                if [ -f "$cache_file" ] && ! $CLEAR_CACHE; then
                    if [ "$(find "$cache_file" -mtime -30)" ]; then
                        arch_pkg=$(cat "$cache_file")
                        if $VERBOSE; then
                            log "[VERBOSE] Using cached mapping for $pkg: $arch_pkg"
                        fi
                    else
                        if $VERBOSE; then
                            log "[VERBOSE] Cache for $pkg expired, refreshing"
                        fi
                        retry_command curl -s "https://repology.org/api/v1/projects/?inrepo=$REPO&search=exact:$pkg" | jq -r 'keys[0]' 2>/dev/null > /tmp/project || arch_pkg="not found"
                        project=$(cat /tmp/project)
                        if [ -n "$project" ] && [ "$project" != "not found" ]; then
                            retry_command curl -s "https://repology.org/api/v1/project/$project" | jq -r '.[] | select(.repo == "arch") | .srcname // .binname' | head -1 2>/dev/null > /tmp/arch_pkg || arch_pkg="not found in Arch"
                            arch_pkg=$(cat /tmp/arch_pkg)
                            [ -z "$arch_pkg" ] && arch_pkg="not found in Arch"
                        else
                            arch_pkg="not found"
                        fi
                        echo "$arch_pkg" >"$cache_file"
                        sleep 1  # Rate limit
                    fi
                else
                    if $VERBOSE; then
                        log "[VERBOSE] No cache for $pkg, fetching from Repology"
                    fi
                    retry_command curl -s "https://repology.org/api/v1/projects/?inrepo=$REPO&search=exact:$pkg" | jq -r 'keys[0]' 2>/dev/null > /tmp/project || arch_pkg="not found"
                    project=$(cat /tmp/project)
                    if [ -n "$project" ] && [ "$project" != "not found" ]; then
                        retry_command curl -s "https://repology.org/api/v1/project/$project" | jq -r '.[] | select(.repo == "arch") | .srcname // .binname' | head -1 2>/dev/null > /tmp/arch_pkg || arch_pkg="not found in Arch"
                        arch_pkg=$(cat /tmp/arch_pkg)
                        [ -z "$arch_pkg" ] && arch_pkg="not found in Arch"
                    else
                        arch_pkg="not found"
                    fi
                    echo "$arch_pkg" >"$cache_file"
                    sleep 1  # Rate limit
                fi
                echo "$pkg -> $arch_pkg" >>"$BACKUP_DIR/fedora_to_arch_mapping.txt"
            done < "$BACKUP_DIR/host-package-names.txt"
            log "Package mapping generated in $BACKUP_DIR/fedora_to_arch_mapping.txt"
        else
            log "Skipping package mapping due to missing tools."
        fi
    else
        log "Cannot determine Fedora version. Skipping package mapping."
    fi

    log "Backup completed at $BACKUP_DIR"
}

verify_iso() {
    if $DRY_RUN; then
        log "[DRY-RUN] Would verify ISO: $ISO with sumfile: $SUMFILE"
        return 0
    fi
    if $VERBOSE; then
        log "[VERBOSE] Verifying ISO: $ISO"
    fi
    sha256sum -c "$SUMFILE" | zenity --progress --pulsate --title="Checksum Verification" --text="Verifying ISO..." --auto-close || { log "Checksum validation failed"; if $GUI; then zenity --error --text="Checksum validation failed"; fi; exit 1; }
    log "Checksum OK"
    gpg --verify "${ISO}.sig" && log "GPG signature OK" || { log "GPG signature failed"; if $GUI; then zenity --error --text="GPG signature failed"; fi; exit 1; }
}

install_cachyos_iso() {
    if $DRY_RUN; then
        log "[DRY-RUN] Would verify and install ISO: $ISO with installer: ${CUSTOM_INSTALLER:-auto-detected} and args: ${CUSTOM_INSTALLER_ARGS[*]}"
        return 0
    fi
    if $VERBOSE; then
        log "[VERBOSE] Installing ISO: $ISO with installer: ${CUSTOM_INSTALLER:-auto-detected} and args: ${CUSTOM_INSTALLER_ARGS[*]}"
    fi
    verify_iso
    MNT=$(mktemp -d)
    sudo mount -o loop "$ISO" "$MNT"
    # Detect installer
    INSTALLER="$CUSTOM_INSTALLER"
    if [ -z "$INSTALLER" ]; then
        for candidate in "cachy-installer" "calamares" "archinstall"; do
            if [ -x "$MNT/$candidate" ]; then
                INSTALLER="$candidate"
                break
            fi
        done
    else
        if [[ "$INSTALLER" == /* && ! -x "$INSTALLER" ]]; then
            log "Custom installer $INSTALLER not executable"
            if $GUI; then
                zenity --error --text="Custom installer $INSTALLER not executable"
            fi
            sudo umount "$MNT"
            rmdir "$MNT"
            exit 1
        elif [[ "$INSTALLER" != /* && ! -x "$MNT/$INSTALLER" ]]; then
            log "Custom installer $INSTALLER not found in ISO"
            if $GUI; then
                zenity --error --text="Custom installer $INSTALLER not found in ISO"
            fi
            sudo umount "$MNT"
            rmdir "$MNT"
            exit 1
        fi
    fi
    if [ -z "$INSTALLER" ]; then
        log "No supported installer found on ISO"
        if $GUI; then
            zenity --error --text="No supported installer found on ISO"
        fi
        sudo umount "$MNT"
        rmdir "$MNT"
        exit 1
    fi
    if [[ "$INSTALLER" == /* ]]; then
        sudo "$INSTALLER" "${CUSTOM_INSTALLER_ARGS[@]}" 2>&1 | zenity --progress --pulsate --title="CachyOS Installer" --text="Installing with custom installer…" --auto-close || { log "Custom installer failed"; if $GUI; then zenity --error --text="Custom installer failed"; fi; sudo umount "$MNT"; rmdir "$MNT"; exit 1; }
    else
        sudo "$MNT/$INSTALLER" "${CUSTOM_INSTALLER_ARGS[@]}" 2>&1 | zenity --progress --pulsate --title="CachyOS Installer" --text="Installing with $INSTALLER…" --auto-close || { log "$INSTALLER failed"; if $GUI; then zenity --error --text="$INSTALLER failed"; fi; sudo umount "$MNT"; rmdir "$MNT"; exit 1; }
    fi
    sudo umount "$MNT"
    rmdir "$MNT"
    log "CachyOS installation succeeded with $INSTALLER"
}

restore() {
    if [ ! -d "$BACKUP_DIR/borg-repo" ] || [ ! -f "$BACKUP_DIR/borg-key" ]; then
        log "Required files not found in $BACKUP_DIR"
        if $GUI; then
            zenity --error --text="Required files not found in $BACKUP_DIR"
        fi
        exit 1
    fi
    if $DRY_RUN; then
        log "[DRY-RUN] Would restore from $BACKUP_DIR with etc_paths: ${ETC_PATHS:-all}, home_paths: ${HOME_PATHS:-all}"
        return 0
    fi
    if $VERBOSE; then
        log "[VERBOSE] Starting restore from $BACKUP_DIR with etc_paths: ${ETC_PATHS:-all}, home_paths: ${HOME_PATHS:-all}"
    fi
    BORG_PASSPHRASE=$(cat "$PASSPHRASE_FILE") || { log "Failed to read passphrase"; if $GUI; then zenity --error --text="Failed to read passphrase"; fi; exit 1; }
    export BORG_PASSPHRASE
    BORG_BASE_DIR="$BORG_BASE_DIR" borg key import "$BACKUP_DIR/borg-repo" "$BACKUP_DIR/borg-key"
    unset BORG_PASSPHRASE
    log "Imported Borg key"

    # Validate paths
    if [ -n "$ETC_PATHS" ]; then
        validate_paths "etc" "$ETC_PATHS" "etc/" || { 
            if $GUI; then
                zenity --error --text="Invalid etc paths specified"
            fi
            log "Invalid etc paths specified"
            exit 1
        }
    fi
    if [ -n "$HOME_PATHS" ]; then
        validate_paths "home" "$HOME_PATHS" "home/$(basename "$USER_HOME")/" || { 
            if $GUI; then
                zenity --error --text="Invalid home paths specified"
            fi
            log "Invalid home paths specified"
            exit 1
        }
    fi

    # Restore /etc to temporary directory
    TMP_ETC="/tmp/etc_restore_$(date +%Y%m%d_%H%M)"
    (
        mkdir -p "$TMP_ETC/etc"
        cd "$TMP_ETC/etc"
        if [ -n "$ETC_PATHS" ]; then
            borg_with_progress "borg extract" "Borg Restore" "Restoring selected /etc paths to $TMP_ETC/etc..." "$BACKUP_DIR/borg-repo::etc" --strip-components 1 etc/"$ETC_PATHS"
        else
            borg_with_progress "borg extract" "Borg Restore" "Restoring /etc to $TMP_ETC/etc..." "$BACKUP_DIR/borg-repo::etc" --strip-components 1 etc
        fi
    )
    log "Extracted /etc to $TMP_ETC/etc. Please manually merge the configurations into /etc."

    # Restore home directory if user agrees
    if zenity --question --text="Do you want to restore $USER_HOME from $BACKUP_DIR? This will overwrite existing files."; then
        if [ -n "$HOME_PATHS" ]; then
            borg_with_progress "borg extract" "Borg Restore" "Restoring selected $USER_HOME paths..." "$BACKUP_DIR/borg-repo::home" home/"$(basename "$USER_HOME")"/"$HOME_PATHS"
        else
            borg_with_progress "borg extract" "Borg Restore" "Restoring $USER_HOME..." "$BACKUP_DIR/borg-repo::home"
        fi
        log "Restored $USER_HOME"
    else
        log "Skipped restoring $USER_HOME"
    fi

    # Reinstall Flatpaks with parallel processing
    if [ -s "$BACKUP_DIR/flatpaks.txt" ]; then
        total=$(wc -l < "$BACKUP_DIR/flatpaks.txt")
        count=0
        xargs -n 1 -P "$PARALLEL" -I {} sh -c "echo \$((++count * 100 / $total)); $VERBOSE && echo '[VERBOSE] Installing Flatpak: {}' >> $LOG; retry_command flatpak install -y {} || echo 'Failed to install Flatpak {}' >> $LOG" < "$BACKUP_DIR/flatpaks.txt" | zenity --progress --title="Flatpak Installation" --text="Installing Flatpaks..." --auto-close || { log "Some Flatpak installations failed"; if $GUI; then zenity --error --text="Some Flatpak installations failed"; fi; exit 1; }
        log "Reinstalled Flatpaks"
    else
        log "No Flatpaks to install"
    fi

    # Restore containers
    if [ -f "$BACKUP_DIR/containers.txt" ]; then
        while read -r container image; do
            if $VERBOSE; then
                log "[VERBOSE] Creating container: $container with image: $image"
            fi
            retry_command distrobox create --name "$container" --image "$image" || { log "Failed to create container $container"; continue; }
            package_list="$BACKUP_DIR/container-${container}-pkgs.txt"
            if [ -f "$package_list" ]; then
                if $VERBOSE; then
                    log "[VERBOSE] Installing packages in container: $container"
                fi
                distrobox enter "$container" --root -- bash -c "sudo pacman -S --noconfirm \$(cat '$package_list')" || { log "Failed to install packages in container $container"; continue; }
            fi
        done < "$BACKUP_DIR/containers.txt"
        log "Recreated containers and installed packages"
    else
        log "No containers list found. Skipping container restoration."
    fi

    # Inform about package mapping
    if [ -f "$BACKUP_DIR/fedora_to_arch_mapping.txt" ]; then
        zenity --info --text="Restore complete. See $BACKUP_DIR/fedora_to_arch_mapping.txt for suggested Arch packages to install."
    else
        zenity --info --text="Restore complete. Package mapping was not generated."
    fi
    log "Restore completed from $BACKUP_DIR"
}

case "$MODE" in
  backup) backup "$@";;
  verify-iso) verify_iso "$@";;
  install-iso) install_cachyos_iso "$@";;
  restore) restore "$@";;
  *) usage ;;
esac

