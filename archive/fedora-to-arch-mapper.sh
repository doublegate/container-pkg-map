#!/usr/bin/env bash
#
# fedora-to-arch-mapper.sh
#
# Description:
#   Maps a list of Fedora package names to their Arch Linux equivalents using the
#   Repology.org API. Features a local cache, network pre-flight check, and
#   robust API logic to ensure reliability and performance.
#
# Dependencies:
#   - bash (v4.0+)
#   - curl
#   - jq
#   - stat (from coreutils)
#
# Usage:
#  ./fedora-to-arch-mapper.sh [-v][-c][-i <input_file>][-o <output_file>]
#   dnf repoquery --userinstalled --qf '%{name}' | ./fedora-to-arch-mapper.sh
#

# --- Strict Mode & Safety ---
set -o errexit
set -o nounset
set -o pipefail

# --- Constants ---
readonly SCRIPT_NAME
SCRIPT_NAME="$(basename "$0")"
readonly API_BASE_URL="https://repology.org/api/v1"
readonly USER_AGENT="Fedora-to-Arch-Mapper-Script/1.6; (+https://github.com/doublegate/)"
readonly CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pkg-mapper"
readonly CACHE_TTL_SECONDS=$((24 * 60 * 60)) # 24 hours

# --- Global Variables ---
VERBOSE=0
INPUT_FILE=""
OUTPUT_FILE=""
CLEAR_CACHE=0

# --- Functions ---

usage() {
    echo "Usage: ${SCRIPT_NAME} [-h][-v][-c][-i <input_file>][-o <output_file>]"
    echo
    echo "Maps Fedora package names to Arch Linux equivalents via the Repology API."
    echo "Reads package names from stdin if -i is not specified."
    echo
    echo "Options:"
    echo "  -i <file>    Read Fedora package names from <file>."
    echo "  -o <file>    Write mapped package names to <file>."
    echo "  -v           Enable verbose/debug mode."
    echo "  -c           Clear the local package map cache before running."
    echo "  -h           Display this help message and exit."
    exit 0
}

log_message() {
    # FIX: Corrected syntax for the if statement
    if [[ "${VERBOSE}" -eq 1 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [LOG] ==> $1" >&2
    fi
}

error_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] ==> $1" >&2
}

check_dependencies() {
    log_message "Checking for dependencies..."
    local missing_deps=0
    for cmd in curl jq stat; do
        # FIX: Corrected syntax for the if statement
        if ! command -v "${cmd}" &>/dev/null; then
            error_message "Required command '${cmd}' is not installed."
            missing_deps=1
        fi
    done
    if [[ "${missing_deps}" -eq 1 ]]; then
        error_message "Please install the missing dependencies and try again."
        exit 1
    fi
}

# Perform an API call with retry logic.
fetch_from_api() {
    local url="$1"
    local retries=3
    local delay=2

    for ((i=1; i<=retries; i++)); do
        local response
        # FIX: Corrected syntax for the command substitution and pipe
        response=$(curl --fail --connect-timeout 5 -sSL -H "User-Agent: ${USER_AGENT}" "${url}" || true)

        if [[ -n "${response}" ]]; then
            echo "${response}"
            return 0
        fi

        if [[ ${i} -lt ${retries} ]]; then
            log_message "API call to ${url} failed. Retrying in ${delay}s... (${i}/${retries})"
            sleep "${delay}"
            delay=$((delay * 2)) # Exponential backoff
        fi
    done

    log_message "API call to ${url} failed after ${retries} attempts."
    echo "" # Return empty string on persistent failure
    return 0
}

# The core mapping logic for a single package.
map_package() {
    local fedora_pkg="$1"
    local safe_pkg_name
    safe_pkg_name="${fedora_pkg//[^a-zA-Z0-9._-]/_}"
    local cache_file="${CACHE_DIR}/${safe_pkg_name}"

    # 1. Check cache first.
    if [[ -f "${cache_file}" ]]; then
        local now file_mod_time
        now=$(date +%s)
        file_mod_time=$(stat -c %Y "${cache_file}")
        # FIX: Corrected syntax for the if statement
        if [[ $((now - file_mod_time)) -lt ${CACHE_TTL_SECONDS} ]]; then
            log_message "Cache hit for '${fedora_pkg}'."
            cat "${cache_file}"
            return
        else
            log_message "Cache expired for '${fedora_pkg}'."
        fi
    fi

    log_message "Querying API for '${fedora_pkg}'..."

    # **FIXED LOGIC**: Use the /projects/ endpoint which is designed for searching.
    local search_url="${API_BASE_URL}/projects/?search=${fedora_pkg}&exact=1"
    local response_data
    response_data=$(fetch_from_api "${search_url}")
    sleep 1 # Respect API rate limit

    # FIX: Corrected syntax for the if statement with OR condition
    if [[ -z "${response_data}" || "${response_data}" == "{}" ]]; then
        log_message "No project found for '${fedora_pkg}'. Caching as not found."
        touch "${cache_file}"
        echo ""
        return
    fi

    # This jq filter now correctly parses the dictionary response from the /projects/ endpoint.
    # It takes the first value (the array of packages) from the dictionary and searches within it.
    local arch_pkg
    arch_pkg=$(echo "${response_data}" | jq -r '
        (
            first(.[] | # Get the package list from the first project in the response dictionary
            select(.!=null)) |
            (
                # Try to find the official Arch package first
                (map(select(.repo == "arch")) | .[0].visiblename) //
                # If that fails, try to find the AUR package
                (map(select(.repo == "aur")) | .[0].visiblename)
            )
        ) // "" # If the whole chain results in null, return an empty string
    ')

    if [[ -z "${arch_pkg}" ]]; then
        log_message "No corresponding Arch package found for '${fedora_pkg}'. Caching as not found."
        touch "${cache_file}"
        echo ""
    else
        log_message "Mapped '${fedora_pkg}' -> '${arch_pkg}'. Caching result."
        echo "${arch_pkg}" > "${cache_file}"
        echo "${arch_pkg}"
    fi
}

# --- Main Execution Logic ---
main() {
    while getopts ":i:o:vch" opt; do
        case "${opt}" in
            i) INPUT_FILE="${OPTARG}" ;;
            o) OUTPUT_FILE="${OPTARG}" ;;
            v) VERBOSE=1 ;;
            c) CLEAR_CACHE=1 ;;
            h) usage ;;
            \?) error_message "Invalid option: -${OPTARG}"; exit 1 ;;
            :) error_message "Option -${OPTARG} requires an argument."; exit 1 ;;
        esac
    done

    check_dependencies

    log_message "Using cache directory: ${CACHE_DIR}"
    # FIX: Corrected syntax for the if statement
    if [[ "${CLEAR_CACHE}" -eq 1 ]]; then
        log_message "Clearing cache."
        rm -rf "${CACHE_DIR}"
    fi
    mkdir -p "${CACHE_DIR}"

    log_message "Performing network connectivity test to repology.org..."
    # FIX: Corrected syntax for the if statement
    if ! curl --connect-timeout 5 -sSL "https://repology.org" > /dev/null; then
        error_message "Network Failure: Could not connect to repology.org."
        error_message "Please check your internet connection, firewall rules, and DNS settings."
        exit 1
    fi
    log_message "Network test successful."

    local input_source="/dev/stdin"
    # FIX: Corrected syntax for the if statement
    if [[ -n "${INPUT_FILE}" ]]; then
        # FIX: Corrected syntax for the if statement
        if [[ ! -f "${INPUT_FILE}" ]]; then
            error_message "Input file not found: ${INPUT_FILE}"
            exit 1
        fi
        input_source="${INPUT_FILE}"
        log_message "Reading packages from file: ${INPUT_FILE}"
    else
        log_message "Reading packages from stdin..."
    fi

    local temp_output_file
    temp_output_file=$(mktemp)

    # FIX: Corrected syntax for the while loop and its conditions
    while IFS= read -r pkg_name || [[ -n "$pkg_name" ]]; do
        if [[ -z "${pkg_name}" || "${pkg_name}" =~ ^# ]]; then
            continue
        fi

        local mapped_name
        mapped_name=$(map_package "${pkg_name}")

        if [[ -n "${mapped_name}" ]]; then
            echo "${pkg_name} -> ${mapped_name}" >> "${temp_output_file}"
        else
            log_message "Failed to map package: '${pkg_name}'"
            echo "${pkg_name} -> [NOT FOUND]" >> "${temp_output_file}"
        fi
    done < "${input_source}"

    # FIX: Corrected syntax for the if statement
    if [[ -n "${OUTPUT_FILE}" ]]; then
        log_message "Writing mapped packages to ${OUTPUT_FILE}."
        cat "${temp_output_file}" > "${OUTPUT_FILE}"
    else
        cat "${temp_output_file}"
    fi

    rm -f "${temp_output_file}"
    log_message "Processing complete."
}

main "$@"
