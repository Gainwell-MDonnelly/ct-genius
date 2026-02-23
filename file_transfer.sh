#!/bin/bash
#===============================================================================
# Script Name: file_transfer.sh
# Description: Scans directory for new files, compresses to tar.gz, and 
#              transfers to SFTP server with comprehensive logging
# Author:      DevOps Team
# Date:        2026-02-23
# Version:     1.0
#===============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Safer word splitting

#-------------------------------------------------------------------------------
# CONFIGURATION - Modify these variables for your environment
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Directory settings
readonly SOURCE_DIR="${SOURCE_DIR:-/data/incoming}"
readonly ARCHIVE_DIR="${ARCHIVE_DIR:-/data/archive}"
readonly PROCESSED_DIR="${PROCESSED_DIR:-/data/processed}"
readonly TEMP_DIR="${TEMP_DIR:-/tmp/file_transfer}"

# SFTP settings
readonly SFTP_HOST="${SFTP_HOST:-sftp.example.com}"
readonly SFTP_PORT="${SFTP_PORT:-22}"
readonly SFTP_USER="${SFTP_USER:-sftpuser}"
readonly SFTP_REMOTE_DIR="${SFTP_REMOTE_DIR:-/upload}"
readonly SFTP_KEY_FILE="${SFTP_KEY_FILE:-/home/${SFTP_USER}/.ssh/id_rsa}"

# Logging settings
readonly LOG_DIR="${LOG_DIR:-/var/log/file_transfer}"
readonly LOG_FILE="${LOG_DIR}/file_transfer_$(date +%Y%m%d).log"
readonly LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Lock file to prevent concurrent execution
readonly LOCK_FILE="/var/run/${SCRIPT_NAME%.sh}.lock"

# File patterns (comma-separated list of patterns to include)
readonly FILE_PATTERNS="${FILE_PATTERNS:-*}"

#-------------------------------------------------------------------------------
# FUNCTIONS
#-------------------------------------------------------------------------------

# Logging function with timestamp and severity level
log() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    printf "[%s] [%-5s] [%s] %s\n" "$timestamp" "$level" "$$" "$message" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO" "$1"; }
log_warn()  { log "WARN" "$1"; }
log_error() { log "ERROR" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# Error handler
error_exit() {
    log_error "$1"
    cleanup
    exit "${2:-1}"
}

# Cleanup function
cleanup() {
    log_info "Performing cleanup..."
    
    # Remove lock file
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        log_debug "Removed lock file: $LOCK_FILE"
    fi
    
    # Clean up temp directory
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_debug "Cleaned up temp directory: $TEMP_DIR"
    fi
}

# Trap signals for cleanup
trap cleanup EXIT
trap 'error_exit "Script interrupted by signal" 130' INT TERM

# Check if another instance is running
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error_exit "Another instance is running (PID: $pid). Exiting." 1
        else
            log_warn "Stale lock file found. Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Create lock file with current PID
    echo $$ > "$LOCK_FILE"
    log_debug "Created lock file with PID: $$"
}

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    # Check required commands
    local required_commands=("tar" "gzip" "sftp" "ssh" "find" "mktemp")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            error_exit "Required command not found: $cmd" 2
        fi
    done
    
    # Create directories if they don't exist
    local directories=("$SOURCE_DIR" "$ARCHIVE_DIR" "$PROCESSED_DIR" "$LOG_DIR" "$TEMP_DIR")
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || error_exit "Failed to create directory: $dir" 3
            log_info "Created directory: $dir"
        fi
    done
    
    # Check SFTP key file exists and has correct permissions
    if [[ ! -f "$SFTP_KEY_FILE" ]]; then
        error_exit "SFTP key file not found: $SFTP_KEY_FILE" 4
    fi
    
    # Verify key file permissions (should be 600 or 400)
    local key_perms
    key_perms=$(stat -c %a "$SFTP_KEY_FILE" 2>/dev/null || stat -f %Lp "$SFTP_KEY_FILE" 2>/dev/null)
    if [[ "$key_perms" != "600" && "$key_perms" != "400" ]]; then
        log_warn "SFTP key file permissions ($key_perms) are not secure. Consider chmod 600."
    fi
    
    log_info "Prerequisites validated successfully"
}

# Scan directory for new files
scan_for_files() {
    log_info "Scanning for new files in: $SOURCE_DIR"
    
    local -a files=()
    local pattern
    
    # Split FILE_PATTERNS by comma and find matching files
    IFS=',' read -ra patterns <<< "$FILE_PATTERNS"
    
    for pattern in "${patterns[@]}"; do
        pattern=$(echo "$pattern" | xargs)  # Trim whitespace
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name "$pattern" -print0 2>/dev/null)
    done
    
    # Remove duplicates
    local -a unique_files=()
    if [[ ${#files[@]} -gt 0 ]]; then
        readarray -t unique_files < <(printf '%s\n' "${files[@]}" | sort -u)
    fi
    
    log_info "Found ${#unique_files[@]} file(s) to process"
    
    printf '%s\n' "${unique_files[@]}"
}

# Create tar.gz archive
create_archive() {
    local source_file="$1"
    local filename
    local archive_name
    local archive_path
    
    filename=$(basename "$source_file")
    archive_name="${filename%.*}_$(date +%Y%m%d_%H%M%S).tar.gz"
    archive_path="${TEMP_DIR}/${archive_name}"
    
    log_info "Creating archive: $archive_name"
    
    # Create tar.gz archive
    if tar -czf "$archive_path" -C "$(dirname "$source_file")" "$filename" 2>/dev/null; then
        log_info "Archive created successfully: $archive_path"
        echo "$archive_path"
        return 0
    else
        log_error "Failed to create archive for: $source_file"
        return 1
    fi
}

# Transfer file via SFTP
transfer_to_sftp() {
    local archive_file="$1"
    local archive_name
    local sftp_batch_file
    local retry_count=0
    local max_retries=3
    
    archive_name=$(basename "$archive_file")
    
    log_info "Transferring to SFTP: $archive_name -> ${SFTP_HOST}:${SFTP_REMOTE_DIR}"
    
    # Create SFTP batch file
    sftp_batch_file=$(mktemp)
    cat > "$sftp_batch_file" << EOF
cd ${SFTP_REMOTE_DIR}
put ${archive_file}
bye
EOF
    
    # Attempt transfer with retries
    while [[ $retry_count -lt $max_retries ]]; do
        if sftp -i "$SFTP_KEY_FILE" \
                -P "$SFTP_PORT" \
                -o StrictHostKeyChecking=accept-new \
                -o BatchMode=yes \
                -o ConnectTimeout=30 \
                -b "$sftp_batch_file" \
                "${SFTP_USER}@${SFTP_HOST}" 2>&1 | tee -a "$LOG_FILE"; then
            
            log_info "Transfer successful: $archive_name"
            rm -f "$sftp_batch_file"
            return 0
        else
            retry_count=$((retry_count + 1))
            log_warn "Transfer attempt $retry_count failed for: $archive_name"
            
            if [[ $retry_count -lt $max_retries ]]; then
                log_info "Retrying in 10 seconds..."
                sleep 10
            fi
        fi
    done
    
    rm -f "$sftp_batch_file"
    log_error "Transfer failed after $max_retries attempts: $archive_name"
    return 1
}

# Move processed file to archive directory
archive_source_file() {
    local source_file="$1"
    local filename
    local archive_dest
    
    filename=$(basename "$source_file")
    archive_dest="${PROCESSED_DIR}/${filename}.processed_$(date +%Y%m%d_%H%M%S)"
    
    if mv "$source_file" "$archive_dest"; then
        log_info "Source file archived: $filename -> $archive_dest"
        return 0
    else
        log_error "Failed to archive source file: $source_file"
        return 1
    fi
}

# Rotate old log files
rotate_logs() {
    log_info "Rotating logs older than $LOG_RETENTION_DAYS days..."
    
    local deleted_count
    deleted_count=$(find "$LOG_DIR" -name "file_transfer_*.log" -type f -mtime +$LOG_RETENTION_DAYS -delete -print 2>/dev/null | wc -l)
    
    if [[ $deleted_count -gt 0 ]]; then
        log_info "Deleted $deleted_count old log file(s)"
    fi
}

# Print usage information
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Scans a directory for new files, compresses them to tar.gz archives,
and transfers them to an SFTP server.

OPTIONS:
    -h, --help          Show this help message and exit
    -d, --dry-run       Run without making changes (simulation mode)
    -v, --verbose       Enable verbose/debug output
    -c, --config FILE   Source configuration from FILE

ENVIRONMENT VARIABLES:
    SOURCE_DIR          Directory to scan for files (default: /data/incoming)
    ARCHIVE_DIR         Directory for tar archives (default: /data/archive)
    PROCESSED_DIR       Directory for processed files (default: /data/processed)
    SFTP_HOST           SFTP server hostname (default: sftp.example.com)
    SFTP_PORT           SFTP server port (default: 22)
    SFTP_USER           SFTP username (default: sftpuser)
    SFTP_REMOTE_DIR     Remote directory on SFTP (default: /upload)
    SFTP_KEY_FILE       Path to SSH private key
    LOG_DIR             Directory for log files (default: /var/log/file_transfer)
    FILE_PATTERNS       Comma-separated file patterns (default: *)

EXAMPLES:
    # Run with default settings
    $SCRIPT_NAME

    # Run with custom source directory
    SOURCE_DIR=/custom/path $SCRIPT_NAME

    # Run in dry-run mode
    $SCRIPT_NAME --dry-run

    # Run with config file
    $SCRIPT_NAME --config /etc/file_transfer.conf

EOF
}

# Main function
main() {
    local dry_run=false
    local verbose=false
    local config_file=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
    
    # Source config file if provided
    if [[ -n "$config_file" ]]; then
        if [[ -f "$config_file" ]]; then
            # shellcheck source=/dev/null
            source "$config_file"
        else
            echo "Config file not found: $config_file" >&2
            exit 1
        fi
    fi
    
    # Ensure log directory exists for initial logging
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    log_info "=========================================="
    log_info "Starting $SCRIPT_NAME"
    log_info "=========================================="
    log_info "Source Directory: $SOURCE_DIR"
    log_info "SFTP Host: $SFTP_HOST:$SFTP_PORT"
    log_info "Remote Directory: $SFTP_REMOTE_DIR"
    [[ "$dry_run" == true ]] && log_warn "DRY RUN MODE - No changes will be made"
    
    # Check for concurrent execution
    check_lock
    
    # Validate prerequisites
    validate_prerequisites
    
    # Rotate old logs
    rotate_logs
    
    # Scan for files
    local -a files_to_process=()
    readarray -t files_to_process < <(scan_for_files)
    
    if [[ ${#files_to_process[@]} -eq 0 ]]; then
        log_info "No files found to process. Exiting."
        exit 0
    fi
    
    # Process each file
    local success_count=0
    local fail_count=0
    
    for source_file in "${files_to_process[@]}"; do
        [[ -z "$source_file" ]] && continue
        
        log_info "Processing: $source_file"
        
        if [[ "$dry_run" == true ]]; then
            log_info "[DRY RUN] Would process: $source_file"
            ((success_count++))
            continue
        fi
        
        # Create archive
        local archive_file
        if archive_file=$(create_archive "$source_file"); then
            
            # Transfer to SFTP
            if transfer_to_sftp "$archive_file"; then
                
                # Archive the source file
                archive_source_file "$source_file"
                
                # Keep a copy of the tar.gz in archive dir
                cp "$archive_file" "$ARCHIVE_DIR/" 2>/dev/null || true
                
                ((success_count++))
                log_info "Successfully processed: $source_file"
            else
                ((fail_count++))
                log_error "Failed to transfer: $source_file"
            fi
        else
            ((fail_count++))
            log_error "Failed to archive: $source_file"
        fi
    done
    
    # Summary
    log_info "=========================================="
    log_info "Processing complete"
    log_info "  Successful: $success_count"
    log_info "  Failed: $fail_count"
    log_info "=========================================="
    
    # Exit with error if any failures
    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

# Execute main function
main "$@"
