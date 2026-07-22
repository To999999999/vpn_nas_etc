#!/usr/bin/env bash

# folder-sync.sh
#
# Synchronize selected local directories with a remote server.
#
# Default usage:
#   ./folder-sync.sh
#
# Synchronize selected directories only:
#   ./folder-sync.sh Developer
#   ./folder-sync.sh Developer Papiers
#
# Show help:
#   ./folder-sync.sh --help
#
# macOS behavior:
#   - Runs without opening Terminal.
#   - Uses native dialogs for confirmations.
#   - Uses native notifications for results.
#   - Exports the gpg-agent SSH socket so pinentry-mac can request
#     Touch ID authentication when needed.
#
# Other systems:
#   - Uses terminal prompts and terminal messages.
#
# Requirements:
#   bash, ssh, scp, rsync, gpgconf
#
# The SSH host alias configured below must already exist in ~/.ssh/config.
# The remote host key should also already be present in ~/.ssh/known_hosts.

set -uo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

readonly SERVER_SSH_CONNECTION="wg"
readonly SERVER_BASE_PATH="/srv/nfs/Backup"
readonly CLIENT_BASE_PATH="${HOME}"

readonly -a DEFAULT_DIRECTORIES=(
    "Developer"
    "Papiers"
)

readonly SSH_CONNECT_TIMEOUT=5
readonly SSH_SERVER_ALIVE_INTERVAL=15
readonly SSH_SERVER_ALIVE_COUNT_MAX=2

readonly SCRIPT_NAME="${0##*/}"
readonly OPERATING_SYSTEM="$(uname -s 2>/dev/null || printf 'Unknown')"

# Set during runtime initialization.
IS_MACOS=false
HAS_TERMINAL=false

# Set by configure_runtime_directories.
LOG_DIR=""
RUN_LOG=""
ERROR_LOG=""
STATE_DIR=""
LOCK_DIR=""

# Per-run counters.
SYNC_SUCCESS_COUNT=0
SYNC_SKIPPED_COUNT=0
SYNC_FAILURE_COUNT=0

# Paths to remove when the process exits.
TEMPORARY_FILES=()

# SSH options are initialized after runtime setup.
SSH_OPTIONS=()

# ==============================================================================
# Runtime initialization
# ==============================================================================

initialize_runtime() {
    case "$OPERATING_SYSTEM" in
        Darwin)
            IS_MACOS=true

            # SwiftBar and other GUI applications usually receive a reduced PATH.
            PATH="/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"
            ;;

        *)
            PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:${PATH}}"
            ;;
    esac

    export PATH

    if [[ -t 0 && -t 1 ]]; then
        HAS_TERMINAL=true
    fi

    configure_runtime_directories
    configure_ssh_options

    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod 700 "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
}

configure_runtime_directories() {
    if $IS_MACOS; then
        LOG_DIR="${HOME}/Library/Logs/folder-sync"
        STATE_DIR="${HOME}/Library/Caches/folder-sync"
    else
        LOG_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/folder-sync"
        STATE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/folder-sync"
    fi

    RUN_LOG="${LOG_DIR}/sync.log"
    ERROR_LOG="${LOG_DIR}/errors.log"
    LOCK_DIR="${STATE_DIR}/lock"
}

configure_ssh_options() {
    SSH_OPTIONS=(
        -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
        -o "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL}"
        -o "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX}"

        # Only use public-key authentication. The key operation may still
        # trigger graphical pinentry through gpg-agent.
        -o "PreferredAuthentications=publickey"
        -o "PasswordAuthentication=no"
        -o "KbdInteractiveAuthentication=no"

        # A background process cannot answer a new-host confirmation.
        # Existing known-host entries continue to be checked normally.
        -o "StrictHostKeyChecking=yes"
    )
}

# ==============================================================================
# Cleanup and signal handling
# ==============================================================================

register_temporary_file() {
    TEMPORARY_FILES+=("$1")
}

cleanup() {
    local temporary_file

    for temporary_file in "${TEMPORARY_FILES[@]}"; do
        rm -f -- "$temporary_file"
    done

    if [[ -n "$LOCK_DIR" ]]; then
        rm -rf -- "$LOCK_DIR" 2>/dev/null || true
    fi
}

handle_signal() {
    log_error "Synchronization interrupted by a signal"
    show_error "Folder Sync" "Synchronization interrupted."
    exit 130
}

trap cleanup EXIT
trap handle_signal HUP INT TERM

# ==============================================================================
# General helpers
# ==============================================================================

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

uppercase() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

shell_quote() {
    printf '%q' "$1"
}

register_new_temporary_file() {
    local temporary_file

    temporary_file="$(mktemp)" || {
        show_error "Folder Sync" "Could not create a temporary file."
        return 1
    }

    register_temporary_file "$temporary_file"
    printf '%s\n' "$temporary_file"
}

# ==============================================================================
# Logging
# ==============================================================================

log_info() {
    mkdir -p "$LOG_DIR"

    printf '[%s] INFO: %s\n' \
        "$(timestamp)" \
        "$*" \
        >> "$RUN_LOG"
}

log_warning() {
    mkdir -p "$LOG_DIR"

    printf '[%s] WARNING: %s\n' \
        "$(timestamp)" \
        "$*" \
        >> "$RUN_LOG"
}

log_error() {
    mkdir -p "$LOG_DIR"

    printf '[%s] ERROR: %s\n' \
        "$(timestamp)" \
        "$*" \
        >> "$ERROR_LOG"
}

append_file_to_log() {
    local source_file="$1"
    local destination_log="$2"

    if [[ -s "$source_file" ]]; then
        cat "$source_file" >> "$destination_log"
    fi
}

# ==============================================================================
# macOS user interface
# ==============================================================================

escape_applescript_string() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\r'/}
    value=${value//$'\n'/\\n}

    printf '%s' "$value"
}

macos_notification() {
    local title
    local message

    title="$(escape_applescript_string "$1")"
    message="$(escape_applescript_string "$2")"

    /usr/bin/osascript \
        -e "display notification \"${message}\" with title \"${title}\"" \
        >/dev/null 2>&1 ||
        true
}

macos_error_dialog() {
    local title
    local message

    title="$(escape_applescript_string "$1")"
    message="$(escape_applescript_string "$2")"

    /usr/bin/osascript <<EOF >/dev/null 2>&1 || true
tell application "System Events"
    activate
    display dialog "${message}" \
        buttons {"OK"} \
        default button "OK" \
        with icon stop \
        with title "${title}"
end tell
EOF
}

macos_confirm_dialog() {
    local title
    local message
    local result

    title="$(escape_applescript_string "$1")"
    message="$(escape_applescript_string "$2")"

    result="$(
        /usr/bin/osascript <<EOF 2>/dev/null
tell application "System Events"
    activate

    try
        set dialogResult to display dialog "${message}" \
            buttons {"Cancel", "Continue"} \
            default button "Continue" \
            cancel button "Cancel" \
            with title "${title}"

        return button returned of dialogResult
    on error number -128
        return "Cancel"
    end try
end tell
EOF
    )" || return 1

    [[ "$result" == "Continue" ]]
}

# ==============================================================================
# Cross-platform user interface
# ==============================================================================

show_info() {
    local title="$1"
    local message="$2"

    log_info "${title}: ${message}"

    if $IS_MACOS; then
        macos_notification "$title" "$message"
    else
        printf '%s: %s\n' "$title" "$message"
    fi
}

show_warning() {
    local title="$1"
    local message="$2"

    log_warning "${title}: ${message}"

    if $IS_MACOS; then
        macos_notification "$title" "$message"

        if $HAS_TERMINAL; then
            printf 'WARNING: %s\n' "$message" >&2
        fi
    else
        printf 'WARNING: %s\n' "$message" >&2
    fi
}

show_error() {
    local title="$1"
    local message="$2"

    log_error "${title}: ${message}"

    if $IS_MACOS; then
        macos_notification "$title" "$message"

        if $HAS_TERMINAL; then
            printf 'ERROR: %s\n' "$message" >&2
        else
            macos_error_dialog "$title" "$message"
        fi
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi
}

confirm_action() {
    local title="$1"
    local message="$2"
    local answer

    if $IS_MACOS; then
        macos_confirm_dialog "$title" "$message"
        return
    fi

    if ! $HAS_TERMINAL; then
        show_error \
            "$title" \
            "This operation requires confirmation, but no terminal is available."

        return 1
    fi

    printf '\n%s\n\n%s\n\n' "$title" "$message"
    printf 'Continue? [y/N] '

    IFS= read -r answer || return 1

    case "$answer" in
        y | Y | yes | Yes | YES)
            return 0
            ;;

        *)
            return 1
            ;;
    esac
}

# ==============================================================================
# Dependencies and locking
# ==============================================================================

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        show_error \
            "Missing dependency" \
            "Required command not found: ${command_name}"

        return 1
    fi
}

check_dependencies() {
    local command_name

    local -a required_commands=(
        awk
        cat
        date
        gpgconf
        grep
        mkdir
        mktemp
        rm
        rsync
        scp
        ssh
        tr
    )

    if $HAS_TERMINAL; then
        required_commands+=("tee")
    fi

    if $IS_MACOS; then
        required_commands+=("osascript")
    fi

    for command_name in "${required_commands[@]}"; do
        require_command "$command_name" || return 1
    done
}

acquire_lock() {
    local existing_pid="unknown"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        return 0
    fi

    if [[ -r "${LOCK_DIR}/pid" ]]; then
        existing_pid="$(
            cat "${LOCK_DIR}/pid" 2>/dev/null ||
                printf 'unknown'
        )"
    fi

    show_warning \
        "Folder Sync" \
        "Another synchronization is already running (PID: ${existing_pid})."

    return 1
}

# ==============================================================================
# GnuPG SSH-agent setup
# ==============================================================================

configure_gpg_ssh_agent() {
    local agent_socket

    log_info "Configuring the GnuPG SSH agent"

    if ! gpgconf --launch gpg-agent >/dev/null 2>&1; then
        show_error \
            "GPG agent failure" \
            "Could not launch gpg-agent."

        return 1
    fi

    agent_socket="$(
        gpgconf --list-dirs agent-ssh-socket 2>/dev/null
    )"

    if [[ -z "$agent_socket" ]]; then
        show_error \
            "GPG agent failure" \
            "gpgconf did not return an SSH-agent socket."

        return 1
    fi

    if [[ ! -S "$agent_socket" ]]; then
        show_error \
            "GPG agent failure" \
            "The GPG SSH-agent socket does not exist: ${agent_socket}"

        return 1
    fi

    export SSH_AUTH_SOCK="$agent_socket"
    unset SSH_AGENT_PID

    log_info "Using SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"
}

# ==============================================================================
# SSH helpers
# ==============================================================================

run_ssh() {
    ssh \
        "${SSH_OPTIONS[@]}" \
        "$SERVER_SSH_CONNECTION" \
        "$@"
}

run_scp_from_server() {
    local remote_path="$1"
    local local_path="$2"

    scp \
        "${SSH_OPTIONS[@]}" \
        "${SERVER_SSH_CONNECTION}:${remote_path}" \
        "$local_path"
}

run_scp_to_server() {
    local local_path="$1"
    local remote_path="$2"

    scp \
        "${SSH_OPTIONS[@]}" \
        "$local_path" \
        "${SERVER_SSH_CONNECTION}:${remote_path}"
}

build_rsync_ssh_command() {
    printf 'ssh'

    printf ' -o %q' \
        "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"

    printf ' -o %q' \
        "ServerAliveInterval=${SSH_SERVER_ALIVE_INTERVAL}"

    printf ' -o %q' \
        "ServerAliveCountMax=${SSH_SERVER_ALIVE_COUNT_MAX}"

    printf ' -o %q' \
        "PreferredAuthentications=publickey"

    printf ' -o %q' \
        "PasswordAuthentication=no"

    printf ' -o %q' \
        "KbdInteractiveAuthentication=no"

    printf ' -o %q' \
        "StrictHostKeyChecking=yes"
}

check_server_connection() {
    local error_file
    local status

    error_file="$(register_new_temporary_file)" || return 1

    log_info "Checking SSH connection to ${SERVER_SSH_CONNECTION}"

    if $HAS_TERMINAL; then
        printf 'Checking connection to %s...\n' \
            "$SERVER_SSH_CONNECTION"
    fi

    run_ssh exit 2>"$error_file"
    status=$?

    if [[ $status -eq 0 ]]; then
        log_info "SSH connection succeeded"
        return 0
    fi

    append_file_to_log "$error_file" "$ERROR_LOG"

    if grep -Eqi \
        'host key verification failed|no .* host key is known' \
        "$error_file"; then
        show_error \
            "SSH host verification failed" \
            "The server host key is missing or has changed. Connect to '${SERVER_SSH_CONNECTION}' manually and verify its host key."

    elif grep -Eqi \
        'permission denied|agent refused operation|sign_and_send_pubkey|no identities' \
        "$error_file"; then
        show_error \
            "SSH authentication failed" \
            "The GPG authentication key could not be used. Check gpg-agent, pinentry-mac, your authentication device, and the key configuration for '${SERVER_SSH_CONNECTION}'."

    elif grep -Eqi \
        'could not resolve hostname|name or service not known|nodename nor servname provided' \
        "$error_file"; then
        show_error \
            "Connection failure" \
            "The SSH host '${SERVER_SSH_CONNECTION}' could not be resolved."

    elif grep -Eqi \
        'connection timed out|operation timed out|no route to host|network is unreachable|connection refused' \
        "$error_file"; then
        show_error \
            "Connection failure" \
            "The server is unreachable. Confirm that the WireGuard VPN is connected."

    else
        show_error \
            "Connection failure" \
            "Cannot connect to '${SERVER_SSH_CONNECTION}'. See ${ERROR_LOG}."
    fi

    return 1
}

# ==============================================================================
# Synchronization metadata
# ==============================================================================

ensure_local_directory_exists() {
    local client_path="$1"

    if [[ ! -d "$client_path" ]]; then
        show_error \
            "Missing directory" \
            "Local directory does not exist: ${client_path}"

        return 1
    fi
}

ensure_sync_metadata() {
    local client_path="$1"
    local server_path="$2"

    local client_config_directory
    local client_state_directory
    local policy_file
    local excludes_file
    local quoted_server_config_directory
    local quoted_server_state_directory

    client_config_directory="${client_path}.sync/config"
    client_state_directory="${client_path}.sync/state"

    policy_file="${client_config_directory}/policy"
    excludes_file="${client_config_directory}/excludes"

    mkdir -p \
        "$client_config_directory" \
        "$client_state_directory" ||
        return 1

    if [[ ! -e "$policy_file" ]]; then
        cat > "$policy_file" <<'EOF'
# Permit an exact pull from the server.
#
# When enabled, files that no longer exist on the server may be deleted
# from the local directory during a server-to-client synchronization.
ALLOW_DELETE_FROM_SERVER=yes
EOF
    fi

    if [[ ! -e "$excludes_file" ]]; then
        cat > "$excludes_file" <<'EOF'
.sync/state/

._*
.DS_Store
.DS*

.env
.env.*
EOF
    fi

    quoted_server_config_directory="$(
        shell_quote "${server_path}.sync/config"
    )"

    quoted_server_state_directory="$(
        shell_quote "${server_path}.sync/state"
    )"

    run_ssh \
        "mkdir -p -- ${quoted_server_config_directory} ${quoted_server_state_directory}" \
        >/dev/null
}

policy_allows_delete_from_server() {
    local policy_file="$1"

    grep -Eq \
        '^[[:space:]]*ALLOW_DELETE_FROM_SERVER=yes[[:space:]]*$' \
        "$policy_file"
}

copy_server_last_change() {
    local server_path="$1"
    local destination="$2"

    run_scp_from_server \
        "${server_path}.sync/state/server_last_change" \
        "$destination" \
        >/dev/null 2>&1
}

read_number_file() {
    local file_path="$1"
    local value

    if [[ ! -r "$file_path" ]]; then
        printf '0\n'
        return
    fi

    value="$(
        cat "$file_path" 2>/dev/null ||
            true
    )"

    case "$value" in
        '' | *[!0-9]*)
            printf '0\n'
            ;;

        *)
            printf '%s\n' "$value"
            ;;
    esac
}

mark_client_synced() {
    local client_path="$1"
    local client_state_directory

    client_state_directory="${client_path}.sync/state"

    mkdir -p "$client_state_directory" || return 1

    date +%s \
        > "${client_state_directory}/client_last_sync"

    date '+%Y-%m-%d %H:%M:%S' \
        > "${client_state_directory}/last_successful_sync"
}

mark_server_changed() {
    local client_path="$1"
    local server_path="$2"

    local state_file
    local now

    state_file="${client_path}.sync/state/server_last_change"
    now="$(date +%s)"

    printf '%s\n' "$now" > "$state_file" || return 1

    run_scp_to_server \
        "$state_file" \
        "${server_path}.sync/state/server_last_change" \
        >/dev/null
}

# ==============================================================================
# Rsync execution
# ==============================================================================

run_rsync_command() {
    local output_file="$1"
    local error_file="$2"

    shift 2

    if $HAS_TERMINAL; then
        "$@" \
            > >(tee "$output_file") \
            2> >(tee "$error_file" >&2)
    else
        "$@" \
            > "$output_file" \
            2> "$error_file"
    fi
}

run_rsync() {
    local title="$1"
    local client_path="$2"
    local server_path="$3"
    local marks_server_changed="$4"

    shift 4

    local output_file
    local error_file
    local status

    output_file="$(register_new_temporary_file)" || return 1
    error_file="$(register_new_temporary_file)" || return 1

    log_info "${title}: starting rsync"

    if $HAS_TERMINAL; then
        printf '\nSynchronizing %s...\n' "$title"
    fi

    run_rsync_command \
        "$output_file" \
        "$error_file" \
        "$@"

    status=$?

    append_file_to_log "$output_file" "$RUN_LOG"
    append_file_to_log "$error_file" "$ERROR_LOG"

    if [[ $status -ne 0 ]]; then
        log_error "${title}: rsync exited with status ${status}"

        show_error \
            "Synchronization failed" \
            "${title} failed with rsync status ${status}. See ${ERROR_LOG}."

        ((SYNC_FAILURE_COUNT += 1))
        return 1
    fi

    if ! mark_client_synced "$client_path"; then
        show_error \
            "Metadata update failed" \
            "${title} synchronized, but the local synchronization marker could not be updated."

        ((SYNC_FAILURE_COUNT += 1))
        return 1
    fi

    if [[ "$marks_server_changed" == "yes" ]] &&
        grep -Eq '^[<>ch.*][^[:space:]]*' "$output_file"; then

        if ! mark_server_changed "$client_path" "$server_path"; then
            show_error \
                "Metadata update failed" \
                "${title} synchronized, but the server change marker could not be updated."

            ((SYNC_FAILURE_COUNT += 1))
            return 1
        fi
    fi

    log_info "${title}: synchronization succeeded"

    show_info \
        "Folder Sync" \
        "${title} updated successfully."

    ((SYNC_SUCCESS_COUNT += 1))
    return 0
}

rsync_to_server_exact() {
    local title="$1"
    local client_path="$2"
    local server_address="$3"
    local server_path="$4"

    local rsync_ssh_command

    rsync_ssh_command="$(build_rsync_ssh_command)"

    run_rsync \
        "$title" \
        "$client_path" \
        "$server_path" \
        "yes" \
        rsync \
        --archive \
        --human-readable \
        --itemize-changes \
        --delete \
        --ignore-errors \
        --exclude-from="${client_path}.sync/config/excludes" \
        -e "$rsync_ssh_command" \
        -- \
        "$client_path" \
        "$server_address"
}

rsync_from_server_exact() {
    local title="$1"
    local client_path="$2"
    local server_address="$3"
    local server_path="$4"

    local rsync_ssh_command

    rsync_ssh_command="$(build_rsync_ssh_command)"

    run_rsync \
        "$title" \
        "$client_path" \
        "$server_path" \
        "no" \
        rsync \
        --archive \
        --human-readable \
        --delete \
        --ignore-errors \
        --exclude-from="${client_path}.sync/config/excludes" \
        -e "$rsync_ssh_command" \
        -- \
        "$server_address" \
        "$client_path"
}

rsync_from_server_update_only() {
    local title="$1"
    local client_path="$2"
    local server_address="$3"
    local server_path="$4"

    local rsync_ssh_command

    rsync_ssh_command="$(build_rsync_ssh_command)"

    run_rsync \
        "$title" \
        "$client_path" \
        "$server_path" \
        "no" \
        rsync \
        --archive \
        --human-readable \
        --update \
        --exclude-from="${client_path}.sync/config/excludes" \
        -e "$rsync_ssh_command" \
        -- \
        "$server_address" \
        "$client_path"
}

rsync_to_server_update_only() {
    local title="$1"
    local client_path="$2"
    local server_address="$3"
    local server_path="$4"

    local rsync_ssh_command

    rsync_ssh_command="$(build_rsync_ssh_command)"

    run_rsync \
        "$title" \
        "$client_path" \
        "$server_path" \
        "yes" \
        rsync \
        --archive \
        --human-readable \
        --itemize-changes \
        --update \
        --exclude-from="${client_path}.sync/config/excludes" \
        -e "$rsync_ssh_command" \
        -- \
        "$client_path" \
        "$server_address"
}

# ==============================================================================
# Directory synchronization
# ==============================================================================

sync_directory() {
    local directory_name="$1"

    local client_path
    local server_path
    local server_address

    local client_last_sync_file
    local server_last_change_copy
    local policy_file

    local client_last_sync
    local server_last_change
    local title

    client_path="${CLIENT_BASE_PATH%/}/${directory_name}/"
    server_path="${SERVER_BASE_PATH%/}/${directory_name}/"
    server_address="${SERVER_SSH_CONNECTION}:${server_path}"

    client_last_sync_file="${client_path}.sync/state/client_last_sync"
    server_last_change_copy="${client_path}.sync/state/server_last_change.copy"
    policy_file="${client_path}.sync/config/policy"

    title="$(uppercase "$directory_name")"

    log_info "------------------------------------------------------------"
    log_info "${title}: local path: ${client_path}"
    log_info "${title}: server path: ${server_address}"

    if $HAS_TERMINAL; then
        printf '\n============================================================\n'
        printf 'Directory: %s\n' "$directory_name"
        printf 'Local:     %s\n' "$client_path"
        printf 'Remote:    %s\n' "$server_address"
        printf '============================================================\n'
    fi

    if ! ensure_local_directory_exists "$client_path"; then
        ((SYNC_FAILURE_COUNT += 1))
        return 1
    fi

    if ! ensure_sync_metadata "$client_path" "$server_path"; then
        show_error \
            "Metadata failure" \
            "Could not initialize synchronization metadata for ${title}."

        ((SYNC_FAILURE_COUNT += 1))
        return 1
    fi

    if ! copy_server_last_change \
        "$server_path" \
        "$server_last_change_copy"; then

        printf '0\n' > "$server_last_change_copy"

        log_warning \
            "${title}: no remote server_last_change marker; using 0"
    fi

    client_last_sync="$(
        read_number_file "$client_last_sync_file"
    )"

    server_last_change="$(
        read_number_file "$server_last_change_copy"
    )"

    rm -f -- "$server_last_change_copy"

    log_info \
        "${title}: client_last_sync=${client_last_sync}; server_last_change=${server_last_change}"

    if ((server_last_change <= client_last_sync)); then
        if confirm_action \
            "${title} — Send to server" \
            "The local directory is up to date relative to the server.

Send the exact local state to the server?

Files removed locally will also be removed from the server."; then

            rsync_to_server_exact \
                "$title" \
                "$client_path" \
                "$server_address" \
                "$server_path"
        else
            log_info "${title}: upload declined"
            ((SYNC_SKIPPED_COUNT += 1))
        fi

        return
    fi

    if policy_allows_delete_from_server "$policy_file"; then
        if confirm_action \
            "${title} — Receive from server" \
            "The server has changed since the last successful local synchronization.

Replace the local state with the exact server state?

Files removed from the server will also be removed locally."; then

            rsync_from_server_exact \
                "$title" \
                "$client_path" \
                "$server_address" \
                "$server_path"
        else
            log_info "${title}: destructive download declined"
            ((SYNC_SKIPPED_COUNT += 1))
        fi

        return
    fi

    if confirm_action \
        "${title} — Merge without deletion" \
        "The server has changed since the last successful local synchronization.

Destructive download is disabled by policy.

Receive newer server files and then send newer local files, without deleting anything?"; then

        if rsync_from_server_update_only \
            "$title" \
            "$client_path" \
            "$server_address" \
            "$server_path"; then

            rsync_to_server_update_only \
                "$title" \
                "$client_path" \
                "$server_address" \
                "$server_path"
        fi
    else
        log_info "${title}: non-destructive merge declined"
        ((SYNC_SKIPPED_COUNT += 1))
    fi
}

# ==============================================================================
# Arguments
# ==============================================================================

print_usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} [DIRECTORY ...]

With no arguments, these directories are synchronized:
$(printf '  - %s\n' "${DEFAULT_DIRECTORIES[@]}")

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} Developer
  ${SCRIPT_NAME} Developer Papiers

Options:
  -h, --help    Show this help.
EOF
}

validate_directory_name() {
    local directory_name="$1"

    if [[ -z "$directory_name" ]]; then
        show_error \
            "Invalid argument" \
            "Directory names cannot be empty."

        return 1
    fi

    if [[ "$directory_name" == /* ]]; then
        show_error \
            "Invalid argument" \
            "Use a path relative to ${CLIENT_BASE_PATH}, not an absolute path: ${directory_name}"

        return 1
    fi

    case "/${directory_name}/" in
        */../*)
            show_error \
                "Invalid argument" \
                "Parent-directory traversal is not permitted: ${directory_name}"

            return 1
            ;;
    esac

    if [[ "$directory_name" == *$'\n'* ||
          "$directory_name" == *$'\r'* ]]; then
        show_error \
            "Invalid argument" \
            "Directory names cannot contain line breaks."

        return 1
    fi
}

resolve_directories() {
    local directory_name

    RESOLVED_DIRECTORIES=()

    if (($# == 0)); then
        for directory_name in "${DEFAULT_DIRECTORIES[@]}"; do
            RESOLVED_DIRECTORIES+=("$directory_name")
        done

        return
    fi

    for directory_name in "$@"; do
        validate_directory_name "$directory_name" || return 1
        RESOLVED_DIRECTORIES+=("$directory_name")
    done
}

# Bash 3.2-compatible global array used by resolve_directories.
RESOLVED_DIRECTORIES=()

# ==============================================================================
# Summary
# ==============================================================================

show_summary() {
    local summary

    summary="Successful: ${SYNC_SUCCESS_COUNT}
Skipped: ${SYNC_SKIPPED_COUNT}
Failed: ${SYNC_FAILURE_COUNT}"

    log_info "Folder Sync complete: ${summary//$'\n'/; }"

    if $HAS_TERMINAL; then
        printf '\n============================================================\n'
        printf 'Folder Sync complete\n'
        printf '%s\n' "$summary"
        printf 'Run log:   %s\n' "$RUN_LOG"
        printf 'Error log: %s\n' "$ERROR_LOG"
        printf '============================================================\n'
    fi

    if ((SYNC_FAILURE_COUNT > 0)); then
        show_error \
            "Folder Sync completed with errors" \
            "$summary"
    else
        show_info \
            "Folder Sync complete" \
            "$summary"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    local directory_name

    initialize_runtime

    case "${1:-}" in
        -h | --help)
            print_usage
            exit 0
            ;;
    esac

    if ! check_dependencies; then
        exit 1
    fi

    if ! resolve_directories "$@"; then
        exit 2
    fi

    if ! acquire_lock; then
        exit 0
    fi

    if ! configure_gpg_ssh_agent; then
        exit 1
    fi

    log_info "============================================================"
    log_info "Folder Sync started"
    log_info "Operating system: ${OPERATING_SYSTEM}"
    log_info "SSH destination: ${SERVER_SSH_CONNECTION}"
    log_info "Directories: ${RESOLVED_DIRECTORIES[*]}"

    if $HAS_TERMINAL; then
        printf 'Folder Sync\n'
        printf 'SSH destination: %s\n' "$SERVER_SSH_CONNECTION"
        printf 'Directories: %s\n' "${RESOLVED_DIRECTORIES[*]}"
    fi

    if ! check_server_connection; then
        exit 1
    fi

    for directory_name in "${RESOLVED_DIRECTORIES[@]}"; do
        sync_directory "$directory_name" || true
    done

    show_summary

    if ((SYNC_FAILURE_COUNT > 0)); then
        exit 1
    fi
}

main "$@"
