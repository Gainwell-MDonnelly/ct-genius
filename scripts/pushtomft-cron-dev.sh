#!/bin/bash
#
# SFTP File Transfer Script — Automated (Cron-compatible)
# Non-interactive version of pushtomft.sh for scheduled/automated use.
#
# Usage:
#   pushtomft-cron.sh [OPTIONS]
#
# Required:
#   -s SRC_DIR       Source directory containing files to upload
#   -u SFTP_USER     SFTP username (or set SFTP_USER env var)
#
# Optional:
#   -e ENV           Environment: prod (default) | dev
#   -d DEST_DIR      Destination directory (required for dev, ignored for prod)
#   -m MODE          Upload mode: wildcard (default) | single
#   -x EXT           File extension to match in wildcard mode (default: dat)
#   -f FILENAME      Filename for single-file mode
#   -p SFTP_PASS     SFTP password (or set SFTP_PASS env var; omit to use SSH key)
#   -k KEY_FILE      Path to SSH private key (default: ~/.ssh/id_ed25519)
#   -c CLEANUP       Post-upload action: move (default) | keep | delete
#                    move = move .gz to processed dir and remove original .dat
#   -P PROCESSED_DIR Base directory for processed files when cleanup=move
#                    Files are placed in PROCESSED_DIR/mmDDyyyy/
#                    (default: /delphix/DeIdentified/processed)
#   -h               Show this help message
#
# Environment Variables (override defaults):
#   SFTP_USER        SFTP username
#   SFTP_PASS        SFTP password (if not set, SSH key auth is used)
#
# Examples:
#   # Upload all .dat files from /data/export using SSH key auth (prod)
#   pushtomft-cron.sh -s /data/export -u svc_account -x dat -c move
#
#   # Upload a single file to dev, delete after upload
#   pushtomft-cron.sh -e dev -d /genius/test/inbound/ -s /data/export \
#                     -m single -f myfile.dat -u svc_account -c delete
#

set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================
SFTP_HOST="54.80.94.146"
PROD_DEST_DIR="/genius/ctedw/stg/inbound/"
BATCH_SIZE=50
DEFAULT_EXT="dat"
DEFAULT_CLEANUP="move"
DEFAULT_KEY_FILE="$HOME/.ssh/id_ed25519"
DEFAULT_PROCESSED_DIR="/delphix/DeIdentified/processed"

# =============================================================================
# Logging
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/logs"
LOG_FILE="$LOG_DIR/sftp_transfer_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"
if [ ! -d "$LOG_DIR" ]; then
    echo "Error: Could not create log directory '$LOG_DIR'. Aborting." >&2
    exit 1
fi

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# =============================================================================
# Usage
# =============================================================================
usage() {
    sed -n '2,/^$/s/^#//p' "$0" | sed 's/^ //'
    exit 0
}

# =============================================================================
# Parse Arguments
# =============================================================================
ENV="prod"
DEST_DIR=""
MODE="wildcard"
SRC_DIR=""
FILE_EXT=""
FILENAME=""
KEY_FILE="$DEFAULT_KEY_FILE"
CLEANUP="$DEFAULT_CLEANUP"
PROCESSED_DIR="$DEFAULT_PROCESSED_DIR"

while getopts "e:d:s:m:x:f:u:p:k:c:P:h" opt; do
    case $opt in
        e) ENV="$OPTARG" ;;
        d) DEST_DIR="$OPTARG" ;;
        s) SRC_DIR="$OPTARG" ;;
        m) MODE="$OPTARG" ;;
        x) FILE_EXT="$OPTARG" ;;
        f) FILENAME="$OPTARG" ;;
        u) SFTP_USER="$OPTARG" ;;
        p) SFTP_PASS="$OPTARG" ;;
        k) KEY_FILE="$OPTARG" ;;
        c) CLEANUP="$OPTARG" ;;
        P) PROCESSED_DIR="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# =============================================================================
# Validate Parameters
# =============================================================================
ERRORS=()

# SFTP_USER can come from -u flag or env var
SFTP_USER="${SFTP_USER:-}"
if [ -z "$SFTP_USER" ]; then
    ERRORS+=("SFTP username is required (-u flag or SFTP_USER env var)")
fi

# SFTP_PASS can come from -p flag or env var (empty means SSH key auth)
SFTP_PASS="${SFTP_PASS:-}"

# Determine auth method
if [ -n "$SFTP_PASS" ]; then
    AUTH_METHOD="password"
elif [ -f "$KEY_FILE" ]; then
    AUTH_METHOD="key"
else
    ERRORS+=("No authentication method: set SFTP_PASS or provide a valid SSH key via -k (default: $DEFAULT_KEY_FILE)")
fi

# Source directory
if [ -z "$SRC_DIR" ]; then
    ERRORS+=("Source directory is required (-s)")
elif [ ! -d "$SRC_DIR" ]; then
    ERRORS+=("Source directory '$SRC_DIR' does not exist")
fi
SRC_DIR="${SRC_DIR%/}"

# Environment / Destination
case "$ENV" in
    prod)
        DEST_DIR="$PROD_DEST_DIR"
        ;;
    dev)
        if [ -z "$DEST_DIR" ]; then
            ERRORS+=("Destination directory (-d) is required when environment is 'dev'")
        else
            DEST_DIR="${DEST_DIR%/}/"
        fi
        ;;
    *)
        ERRORS+=("Invalid environment '$ENV'. Must be 'prod' or 'dev'")
        ;;
esac

# Upload mode
case "$MODE" in
    wildcard)
        FILE_EXT="${FILE_EXT:-$DEFAULT_EXT}"
        FILE_EXT="${FILE_EXT#.}"   # strip leading dot
        ;;
    single)
        if [ -z "$FILENAME" ]; then
            ERRORS+=("Filename (-f) is required in single-file mode")
        fi
        ;;
    *)
        ERRORS+=("Invalid mode '$MODE'. Must be 'wildcard' or 'single'")
        ;;
esac

# Cleanup action
case "$CLEANUP" in
    keep|delete|move) ;;
    *)
        ERRORS+=("Invalid cleanup action '$CLEANUP'. Must be 'keep', 'delete', or 'move'")
        ;;
esac

# Abort if there are validation errors
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "Error: Invalid arguments:" >&2
    for err in "${ERRORS[@]}"; do
        echo "  - $err" >&2
    done
    echo "" >&2
    echo "Run with -h for usage information." >&2
    exit 1
fi

# =============================================================================
# Session Banner
# =============================================================================
log_message "INFO" "=== Starting Automated SFTP Transfer Session ==="
log_message "INFO" "Environment: $ENV | Destination: $DEST_DIR"
log_message "INFO" "Server: $SFTP_HOST | User: $SFTP_USER | Auth: $AUTH_METHOD"
log_message "INFO" "Mode: $MODE | Source: $SRC_DIR | Cleanup: $CLEANUP"
log_message "INFO" "Log File: $LOG_FILE"

# =============================================================================
# CSV Output Setup
# =============================================================================
CSV_DATE_DIR=$(date +"%m%d%Y")
CSV_BASE_DIR="/delphix/DeIdentified/processed"
CSV_DIR="$CSV_BASE_DIR/$CSV_DATE_DIR"
CSV_DATETIME=$(date +"%m%d%Y_%H%M%S")
CSV_FILE="$CSV_DIR/genius_${CSV_DATETIME}.csv"

mkdir -p "$CSV_DIR"
if [ ! -d "$CSV_DIR" ]; then
    log_message "ERROR" "Could not create CSV output directory '$CSV_DIR'. Aborting."
    exit 1
fi

# Write CSV header
echo "filename,date,timestamp" > "$CSV_FILE"
log_message "INFO" "CSV output file: $CSV_FILE"

# Helper: append a row to the CSV
csv_record() {
    local fname="$1"
    local fname_no_ext
    local row_date
    local row_time
    fname_no_ext="${fname%.*}"
    row_date=$(date +"%m/%d/%Y")
    row_time=$(date +"%H:%M:%S")
    echo "$fname_no_ext,$row_date,$row_time" >> "$CSV_FILE"
}

# =============================================================================
# Resolve File List
# =============================================================================
MULTI_FILE=false

if [ "$MODE" = "wildcard" ]; then
    GLOB_PATTERN="$SRC_DIR/*.$FILE_EXT"
    MATCHED_FILES=( $GLOB_PATTERN )

    if [ ${#MATCHED_FILES[@]} -eq 0 ] || [ ! -e "${MATCHED_FILES[0]}" ]; then
        log_message "ERROR" "No files matching '$GLOB_PATTERN' found. Aborting."
        exit 1
    fi

    TOTAL_SIZE=0
    for f in "${MATCHED_FILES[@]}"; do
        sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        TOTAL_SIZE=$((TOTAL_SIZE + sz))
    done

    MULTI_FILE=true
    log_message "INFO" "Wildcard upload: pattern='$GLOB_PATTERN' matched=${#MATCHED_FILES[@]} files, total=$TOTAL_SIZE bytes"

    # --- Compress matched files to .gz before upload ---
    TOTAL_TO_COMPRESS=${#MATCHED_FILES[@]}
    log_message "INFO" "Compressing $TOTAL_TO_COMPRESS file(s) to .gz ..."
    ORIGINAL_DAT_FILES=("${MATCHED_FILES[@]}")
    GZ_FILES=()
    COMPRESS_NUM=0
    for f in "${MATCHED_FILES[@]}"; do
        COMPRESS_NUM=$((COMPRESS_NUM + 1))
        fname=$(basename "$f")
        base="${fname%.dat}"
        gz_path="$SRC_DIR/${base}.gz"
        log_message "INFO" "Compressing file $COMPRESS_NUM of $TOTAL_TO_COMPRESS: $fname"
        gzip -c "$f" > "$gz_path"
        if [ $? -ne 0 ]; then
            log_message "ERROR" "Failed to compress '$f'. Aborting."
            exit 1
        fi
        gz_sz=$(stat -c%s "$gz_path" 2>/dev/null || stat -f%z "$gz_path" 2>/dev/null || echo "unknown")
        log_message "INFO" "Compressed $COMPRESS_NUM of $TOTAL_TO_COMPRESS: $fname -> ${base}.gz ($gz_sz bytes)"
        GZ_FILES+=("$gz_path")
    done

    MATCHED_FILES=("${GZ_FILES[@]}")
    log_message "INFO" "Compression complete. ${#MATCHED_FILES[@]} .gz file(s) ready for upload."

else
    # ---- Single-file mode ----
    FILE_PATH="$SRC_DIR/$FILENAME"

    if [ ! -f "$FILE_PATH" ]; then
        log_message "ERROR" "File '$FILE_PATH' does not exist. Aborting."
        exit 1
    fi

    FILESIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null || echo "unknown")
    log_message "INFO" "File to upload: $FILE_PATH (Size: $FILESIZE bytes)"

    ORIGINAL_DAT_FILE="$FILE_PATH"

    # --- Compress to .gz before upload ---
    BASE_NAME="$(basename "$FILE_PATH")"
    BASE_NAME="${BASE_NAME%.dat}"
    GZ_NAME="${BASE_NAME}.gz"
    GZ_PATH="$SRC_DIR/$GZ_NAME"

    log_message "INFO" "Compressing: $FILE_PATH -> $GZ_PATH"
    gzip -c "$FILE_PATH" > "$GZ_PATH"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to compress '$FILENAME'. Aborting."
        exit 1
    fi

    GZ_SIZE=$(stat -c%s "$GZ_PATH" 2>/dev/null || stat -f%z "$GZ_PATH" 2>/dev/null || echo "unknown")
    log_message "INFO" "Compressed: $GZ_NAME (Size: $GZ_SIZE bytes)"

    FILE_PATH="$GZ_PATH"
    FILENAME="$GZ_NAME"
    log_message "INFO" "Starting upload of '$FILENAME' to $SFTP_HOST:$DEST_DIR"
fi

# =============================================================================
# SFTP Upload
# =============================================================================

# Build SFTP connection args based on auth method
sftp_connect_args() {
    echo "-o StrictHostKeyChecking=no -o BatchMode=yes"
    if [ "$AUTH_METHOD" = "key" ]; then
        echo "-i $KEY_FILE"
    fi
}

# --- Helper: upload a list of files in a single SFTP session ---
sftp_put_files() {
    local files=("$@")
    local put_cmds=""
    for f in "${files[@]}"; do
        put_cmds+="put \"$f\"
"
    done

    local CONN_ARGS
    CONN_ARGS=$(sftp_connect_args)

    if [ "$AUTH_METHOD" = "password" ]; then
        if command -v sshpass &> /dev/null; then
            sshpass -p "$SFTP_PASS" sftp $CONN_ARGS "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
$put_cmds
bye
EOF
        elif command -v expect &> /dev/null; then
            expect <<EOF
spawn sftp -o StrictHostKeyChecking=no $SFTP_USER@$SFTP_HOST
expect "password:"
send "$SFTP_PASS\r"
expect "sftp>"
send "cd $DEST_DIR\r"
$(for f in "${files[@]}"; do echo "expect \"sftp>\""; echo "send \"put $f\r\""; done)
expect "sftp>"
send "bye\r"
expect eof
EOF
        else
            log_message "ERROR" "Password auth requires 'sshpass' or 'expect'. Neither found."
            return 1
        fi
    else
        # SSH key authentication (preferred for cron)
        sftp $CONN_ARGS "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
$put_cmds
bye
EOF
    fi
    return $?
}

if [ "$MULTI_FILE" = true ]; then
    # ---- Batched upload for wildcard mode ----
    TOTAL_FILES=${#MATCHED_FILES[@]}
    TOTAL_BATCHES=$(( (TOTAL_FILES + BATCH_SIZE - 1) / BATCH_SIZE ))
    UPLOADED_OK=0
    UPLOADED_FAIL=0

    log_message "INFO" "Starting batched upload: $TOTAL_FILES files in $TOTAL_BATCHES batch(es) of up to $BATCH_SIZE"

    for (( batch=0; batch<TOTAL_BATCHES; batch++ )); do
        start=$(( batch * BATCH_SIZE ))
        end=$(( start + BATCH_SIZE ))
        if [ $end -gt $TOTAL_FILES ]; then
            end=$TOTAL_FILES
        fi
        batch_count=$(( end - start ))
        batch_num=$(( batch + 1 ))

        BATCH_FILES=("${MATCHED_FILES[@]:$start:$batch_count}")

        log_message "INFO" "Batch $batch_num/$TOTAL_BATCHES: uploading files $((start+1))-$end of $TOTAL_FILES"

        for (( fi_idx=0; fi_idx<batch_count; fi_idx++ )); do
            file_num=$(( start + fi_idx + 1 ))
            log_message "INFO" "Uploading file $file_num of $TOTAL_FILES: $(basename "${BATCH_FILES[$fi_idx]}")"
        done

        sftp_put_files "${BATCH_FILES[@]}"
        BATCH_RC=$?

        if [ $BATCH_RC -eq 0 ]; then
            UPLOADED_OK=$(( UPLOADED_OK + batch_count ))
            log_message "SUCCESS" "Batch $batch_num/$TOTAL_BATCHES: $batch_count file(s) uploaded successfully"
            for (( csv_i=0; csv_i<batch_count; csv_i++ )); do
                csv_record "$(basename "${BATCH_FILES[$csv_i]}")"
            done
            # Remove original .dat files for this batch
            for (( dat_i=0; dat_i<batch_count; dat_i++ )); do
                orig_dat="${ORIGINAL_DAT_FILES[$((start + dat_i))]}"
                if [ -f "$orig_dat" ]; then
                    if rm -f "$orig_dat" 2>/dev/null; then
                        log_message "INFO" "Removed original .dat after successful upload: $orig_dat"
                    else
                        log_message "ERROR" "Failed to remove original .dat: $orig_dat"
                    fi
                fi
            done
        else
            UPLOADED_FAIL=$(( UPLOADED_FAIL + batch_count ))
            log_message "ERROR" "Batch $batch_num/$TOTAL_BATCHES: upload failed"
        fi
    done

    log_message "INFO" "Upload summary: $UPLOADED_OK succeeded, $UPLOADED_FAIL failed (out of $TOTAL_FILES)"

    if [ $UPLOADED_FAIL -gt 0 ]; then
        log_message "ERROR" "$UPLOADED_FAIL file(s) failed to upload"
        if [ $UPLOADED_OK -eq 0 ]; then
            log_message "ERROR" "All uploads failed."
            exit 1
        else
            log_message "WARN" "Some batches failed. Continuing with cleanup for successfully uploaded files."
        fi
    fi

else
    # ---- Single-file upload ----
    sftp_put_files "$FILE_PATH"

    if [ $? -eq 0 ]; then
        log_message "SUCCESS" "File '$FILENAME' uploaded successfully to $DEST_DIR"
        csv_record "$FILENAME"
        # Remove original .dat file after successful upload
        if [ -f "$ORIGINAL_DAT_FILE" ]; then
            if rm -f "$ORIGINAL_DAT_FILE" 2>/dev/null; then
                log_message "INFO" "Removed original .dat after successful upload: $ORIGINAL_DAT_FILE"
            else
                log_message "ERROR" "Failed to remove original .dat: $ORIGINAL_DAT_FILE"
            fi
        fi
    else
        log_message "ERROR" "File upload failed for '$FILENAME'"
        exit 1
    fi
fi

# =============================================================================
# Post-upload Cleanup
# =============================================================================

# Build the date-based processed directory (used by "move" action)
PROCESSED_DATE_DIR="$PROCESSED_DIR/$(date +"%m%d%Y")"

if [ "$CLEANUP" = "delete" ]; then
    # Delete .gz files (original .dat files already removed after successful upload)
    if [ "$MULTI_FILE" = true ]; then
        DELETED=0
        FAILED=0
        for f in "${MATCHED_FILES[@]}"; do
            if rm -f "$f" 2>/dev/null; then
                log_message "INFO" "Deleted .gz file: $f"
                ((DELETED++))
            else
                log_message "ERROR" "Failed to delete .gz file: $f"
                ((FAILED++))
            fi
        done
        log_message "INFO" "Post-upload cleanup (delete): $DELETED .gz deleted, $FAILED failed"
    else
        if rm -f "$FILE_PATH" 2>/dev/null; then
            log_message "INFO" "Deleted .gz file: $FILE_PATH"
        else
            log_message "ERROR" "Failed to delete .gz file: $FILE_PATH"
        fi
    fi

elif [ "$CLEANUP" = "move" ]; then
    # Move .gz files to date-based processed directory (original .dat already removed after upload)
    mkdir -p "$PROCESSED_DATE_DIR" 2>/dev/null
    if [ ! -d "$PROCESSED_DATE_DIR" ]; then
        log_message "ERROR" "Failed to create processed directory: $PROCESSED_DATE_DIR"
        log_message "INFO" "Source file(s) retained (processed dir creation failed)."
    fi

    if [ -d "$PROCESSED_DATE_DIR" ]; then
        if [ "$MULTI_FILE" = true ]; then
            MOVED=0
            FAILED=0
            for f in "${MATCHED_FILES[@]}"; do
                if mv "$f" "$PROCESSED_DATE_DIR/" 2>/dev/null; then
                    log_message "INFO" "Moved .gz to processed: $f -> $PROCESSED_DATE_DIR/$(basename "$f")"
                    ((MOVED++))
                else
                    log_message "ERROR" "Failed to move .gz file: $f"
                    ((FAILED++))
                fi
            done
            log_message "INFO" "Post-upload cleanup (move): $MOVED .gz moved, $FAILED failed"
        else
            if mv "$FILE_PATH" "$PROCESSED_DATE_DIR/" 2>/dev/null; then
                log_message "INFO" "Moved .gz to processed: $FILE_PATH -> $PROCESSED_DATE_DIR/$FILENAME"
            else
                log_message "ERROR" "Failed to move .gz file: $FILE_PATH -> $PROCESSED_DATE_DIR/"
            fi
        fi
    fi

else
    log_message "INFO" "Source file(s) retained (cleanup=keep)."
fi

# CSV row count (subtract 1 for header)
CSV_ROW_COUNT=$(( $(wc -l < "$CSV_FILE") - 1 ))
log_message "INFO" "CSV report written: $CSV_FILE ($CSV_ROW_COUNT file(s) recorded)"

log_message "INFO" "=== Automated SFTP Transfer Session Completed ==="
exit 0
