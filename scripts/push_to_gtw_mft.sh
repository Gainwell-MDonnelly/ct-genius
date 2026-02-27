#!/bin/bash
#
# SFTP File Transfer Script
# Connects to SFTP server and uploads a file to the specified destination
#

# SFTP Server Configuration
SFTP_HOST="54.80.94.146"
DEST_DIR="/genius/ctedw/stg/inbound/"
BATCH_SIZE=50   # Max files per SFTP session in wildcard mode

# Logging Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/sftp_transfer_$(date +%Y%m%d_%H%M%S).log"

# Create log directory — abort if it fails
mkdir -p "$LOG_DIR"
if [ ! -d "$LOG_DIR" ]; then
    echo "Error: Could not create log directory '$LOG_DIR'. Aborting."
    exit 1
fi

# Function to write to log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Prompt for SFTP credentials
echo "=== SFTP File Transfer ==="
echo "Server: $SFTP_HOST"
echo "Destination: $DEST_DIR"
echo "Log File: $LOG_FILE"
echo ""

log_message "INFO" "=== Starting SFTP Transfer Session ==="
log_message "INFO" "Server: $SFTP_HOST | Destination: $DEST_DIR"

read -p "Enter SFTP Username: " SFTP_USER
if [ -z "$SFTP_USER" ]; then
    log_message "ERROR" "Username cannot be empty. Aborting."
    echo "Error: Username cannot be empty."
    exit 1
fi

log_message "INFO" "User: $SFTP_USER"

read -s -p "Enter SFTP Password: " SFTP_PASS
echo ""
if [ -z "$SFTP_PASS" ]; then
    log_message "ERROR" "Password cannot be empty. Aborting."
    echo "Error: Password cannot be empty."
    exit 1
fi

# --- File Selection Mode ---
echo "Select upload mode:"
echo "  1) Single file"
echo "  2) Wildcard pattern (e.g. all *.tar.gz in a directory)"
read -p "Choice [1/2]: " UPLOAD_MODE

UPLOAD_MODE=${UPLOAD_MODE:-1}   # default to single file
MULTI_FILE=false

if [ "$UPLOAD_MODE" = "2" ]; then
    # ---- Wildcard / glob mode ----
    read -p "Enter the source directory: " SRC_DIR
    # Strip trailing slash for consistency
    SRC_DIR="${SRC_DIR%/}"
    if [ ! -d "$SRC_DIR" ]; then
        log_message "ERROR" "Directory '$SRC_DIR' does not exist. Aborting."
        echo "Error: Directory '$SRC_DIR' does not exist."
        exit 1
    fi

    read -p "Enter file extension to match (e.g. tar.gz, csv, gz): " FILE_EXT
    FILE_EXT="${FILE_EXT#.}"   # strip leading dot if provided
    if [ -z "$FILE_EXT" ]; then
        log_message "ERROR" "File extension cannot be empty. Aborting."
        echo "Error: File extension cannot be empty."
        exit 1
    fi

    GLOB_PATTERN="$SRC_DIR/*.$FILE_EXT"
    MATCHED_FILES=( $GLOB_PATTERN )

    # Check that the glob actually expanded to real files
    if [ ${#MATCHED_FILES[@]} -eq 0 ] || [ ! -e "${MATCHED_FILES[0]}" ]; then
        log_message "ERROR" "No files matching '$GLOB_PATTERN' found. Aborting."
        echo "Error: No files matching '$GLOB_PATTERN'."
        exit 1
    fi

    echo ""
    echo "Matched ${#MATCHED_FILES[@]} file(s):"
    TOTAL_SIZE=0
    for f in "${MATCHED_FILES[@]}"; do
        sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        TOTAL_SIZE=$((TOTAL_SIZE + sz))
        echo "  $(basename "$f")  ($sz bytes)"
    done
    echo "Total size: $TOTAL_SIZE bytes"
    echo ""

    read -p "Proceed with upload? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message "INFO" "Upload cancelled by user."
        echo "Upload cancelled."
        exit 0
    fi

    MULTI_FILE=true
    log_message "INFO" "Wildcard upload: pattern='$GLOB_PATTERN' matched=${#MATCHED_FILES[@]} files, total=$TOTAL_SIZE bytes"

    # --- Compress matched files to .gz before upload ---
    echo ""
    echo "Compressing ${#MATCHED_FILES[@]} file(s) to .gz ..."
    GZ_FILES=()
    for f in "${MATCHED_FILES[@]}"; do
        fname=$(basename "$f")
        base="${fname%.dat}"
        gz_path="$SRC_DIR/${base}.gz"
        gzip -c "$f" > "$gz_path"
        if [ $? -ne 0 ]; then
            log_message "ERROR" "Failed to compress '$f'. Aborting."
            echo "Error: Compression failed for '$fname'."
            exit 1
        fi
        gz_sz=$(stat -c%s "$gz_path" 2>/dev/null || stat -f%z "$gz_path" 2>/dev/null || echo "unknown")
        log_message "INFO" "Compressed: $fname -> ${base}.gz ($gz_sz bytes)"
        echo "  $fname -> ${base}.gz ($gz_sz bytes)"
        GZ_FILES+=("$gz_path")
    done

    # Update references to point at .gz files for upload
    MATCHED_FILES=("${GZ_FILES[@]}")
    GLOB_PATTERN="$SRC_DIR/*.gz"
    log_message "INFO" "Compression complete. ${#MATCHED_FILES[@]} .gz file(s) ready for upload."

    echo "Uploading ${#MATCHED_FILES[@]} .gz file(s) to $SFTP_HOST:$DEST_DIR ..."
else
    # ---- Single-file mode ----
    read -p "Enter the source directory: " SRC_DIR
    SRC_DIR="${SRC_DIR%/}"
    if [ ! -d "$SRC_DIR" ]; then
        log_message "ERROR" "Directory '$SRC_DIR' does not exist. Aborting."
        echo "Error: Directory '$SRC_DIR' does not exist."
        exit 1
    fi

    # List files in the directory for reference
    echo ""
    echo "Files in $SRC_DIR:"
    ls -lh "$SRC_DIR" | tail -n +2
    echo ""

    read -p "Enter the filename to upload: " FILENAME_INPUT
    FILE_PATH="$SRC_DIR/$FILENAME_INPUT"

    if [ ! -f "$FILE_PATH" ]; then
        log_message "ERROR" "File '$FILE_PATH' does not exist. Aborting."
        echo "Error: File '$FILE_PATH' does not exist."
        exit 1
    fi

    FILENAME=$(basename "$FILE_PATH")
    FILESIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null || echo "unknown")

    log_message "INFO" "File to upload: $FILE_PATH (Size: $FILESIZE bytes)"

    # --- Compress to .gz before upload ---
    # Strip .dat extension if present, then append .gz
    BASE_NAME="${FILENAME%.dat}"
    GZ_NAME="${BASE_NAME}.gz"
    GZ_PATH="$SRC_DIR/$GZ_NAME"

    echo ""
    echo "Compressing '$FILENAME' -> '$GZ_NAME' ..."
    log_message "INFO" "Compressing: $FILE_PATH -> $GZ_PATH"

    gzip -c "$FILE_PATH" > "$GZ_PATH"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to compress '$FILENAME'. Aborting."
        echo "Error: Compression failed."
        exit 1
    fi

    GZ_SIZE=$(stat -c%s "$GZ_PATH" 2>/dev/null || stat -f%z "$GZ_PATH" 2>/dev/null || echo "unknown")
    log_message "INFO" "Compressed: $GZ_NAME (Size: $GZ_SIZE bytes)"
    echo "Compressed '$GZ_NAME' ($GZ_SIZE bytes)"

    # Upload the .gz instead of the original
    FILE_PATH="$GZ_PATH"
    FILENAME="$GZ_NAME"

    echo ""
    echo "Uploading '$FILENAME' to $SFTP_HOST:$DEST_DIR ..."
    log_message "INFO" "Starting upload of '$FILENAME' to $SFTP_HOST:$DEST_DIR"
fi

# =============================================================================
# SFTP Upload
# =============================================================================

# --- Helper: upload a list of files in a single SFTP session ---
# Usage: sftp_put_files file1 file2 ...
sftp_put_files() {
    local files=("$@")
    # Build put commands
    local put_cmds=""
    for f in "${files[@]}"; do
        put_cmds+="put \"$f\"
"
    done

    if command -v sshpass &> /dev/null; then
        sshpass -p "$SFTP_PASS" sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
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
        sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
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
    echo ""
    echo "Uploading $TOTAL_FILES file(s) in batches of $BATCH_SIZE ($TOTAL_BATCHES batch(es)) ..."
    echo ""

    for (( batch=0; batch<TOTAL_BATCHES; batch++ )); do
        start=$(( batch * BATCH_SIZE ))
        end=$(( start + BATCH_SIZE ))
        if [ $end -gt $TOTAL_FILES ]; then
            end=$TOTAL_FILES
        fi
        batch_count=$(( end - start ))
        batch_num=$(( batch + 1 ))

        BATCH_FILES=("${MATCHED_FILES[@]:$start:$batch_count}")

        echo "--- Batch $batch_num/$TOTAL_BATCHES ($batch_count files) ---"
        log_message "INFO" "Batch $batch_num/$TOTAL_BATCHES: uploading files $((start+1))-$end of $TOTAL_FILES"

        sftp_put_files "${BATCH_FILES[@]}"
        BATCH_RC=$?

        if [ $BATCH_RC -eq 0 ]; then
            UPLOADED_OK=$(( UPLOADED_OK + batch_count ))
            log_message "SUCCESS" "Batch $batch_num/$TOTAL_BATCHES: $batch_count file(s) uploaded successfully"
            echo "  Batch $batch_num complete — $batch_count file(s) OK"
        else
            UPLOADED_FAIL=$(( UPLOADED_FAIL + batch_count ))
            log_message "ERROR" "Batch $batch_num/$TOTAL_BATCHES: upload failed"
            echo "  Batch $batch_num FAILED"
        fi
    done

    echo ""
    echo "Upload summary: $UPLOADED_OK succeeded, $UPLOADED_FAIL failed (out of $TOTAL_FILES)"
    log_message "INFO" "Upload summary: $UPLOADED_OK succeeded, $UPLOADED_FAIL failed (out of $TOTAL_FILES)"

    if [ $UPLOADED_FAIL -gt 0 ]; then
        log_message "ERROR" "$UPLOADED_FAIL file(s) failed to upload"
        if [ $UPLOADED_OK -eq 0 ]; then
            echo "Error: All uploads failed."
            exit 1
        else
            echo "Warning: Some batches failed. Continuing with cleanup for successfully uploaded files."
        fi
    fi

else
    # ---- Single-file upload ----
    sftp_put_files "$FILE_PATH"

    if [ $? -eq 0 ]; then
        echo ""
        echo "File '$FILENAME' uploaded successfully to $DEST_DIR"
        log_message "SUCCESS" "File '$FILENAME' uploaded successfully to $DEST_DIR"
    else
        echo ""
        echo "Error: File upload failed."
        log_message "ERROR" "File upload failed for '$FILENAME'"
        exit 1
    fi
fi

# --- Post-upload cleanup ---
PROCESSED_DIR="/delphix/DeIdentified/processed"

echo ""
echo "What would you like to do with the source file(s)?"
echo "  1) Keep (no action)"
echo "  2) Delete"
echo "  3) Move to $PROCESSED_DIR"
read -p "Choice [1/2/3]: " CLEANUP_ACTION

CLEANUP_ACTION=${CLEANUP_ACTION:-1}   # default to keep

if [ "$CLEANUP_ACTION" = "2" ]; then
    # ---- Delete source files ----
    if [ "$MULTI_FILE" = true ]; then
        DELETED=0
        FAILED=0
        for f in "${MATCHED_FILES[@]}"; do
            if rm -f "$f" 2>/dev/null; then
                log_message "INFO" "Deleted source file: $f"
                ((DELETED++))
            else
                log_message "ERROR" "Failed to delete source file: $f"
                ((FAILED++))
            fi
        done
        echo "$DELETED file(s) deleted, $FAILED failed."
        log_message "INFO" "Post-upload cleanup (delete): $DELETED deleted, $FAILED failed"
    else
        if rm -f "$FILE_PATH" 2>/dev/null; then
            echo "Source file '$FILENAME' deleted."
            log_message "INFO" "Deleted source file: $FILE_PATH"
        else
            echo "Warning: Could not delete '$FILE_PATH'."
            log_message "ERROR" "Failed to delete source file: $FILE_PATH"
        fi
    fi

elif [ "$CLEANUP_ACTION" = "3" ]; then
    # ---- Move source files to processed folder ----
    if [ ! -d "$PROCESSED_DIR" ]; then
        mkdir -p "$PROCESSED_DIR" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo "Error: Could not create directory '$PROCESSED_DIR'."
            log_message "ERROR" "Failed to create processed directory: $PROCESSED_DIR"
            echo "Source file(s) retained in original location."
            log_message "INFO" "Source file(s) retained (processed dir creation failed)."
        fi
    fi

    if [ -d "$PROCESSED_DIR" ]; then
        if [ "$MULTI_FILE" = true ]; then
            MOVED=0
            FAILED=0
            for f in "${MATCHED_FILES[@]}"; do
                if mv "$f" "$PROCESSED_DIR/" 2>/dev/null; then
                    log_message "INFO" "Moved source file to processed: $f -> $PROCESSED_DIR/$(basename "$f")"
                    ((MOVED++))
                else
                    log_message "ERROR" "Failed to move source file: $f"
                    ((FAILED++))
                fi
            done
            echo "$MOVED file(s) moved to $PROCESSED_DIR, $FAILED failed."
            log_message "INFO" "Post-upload cleanup (move): $MOVED moved, $FAILED failed"
        else
            if mv "$FILE_PATH" "$PROCESSED_DIR/" 2>/dev/null; then
                echo "Source file '$FILENAME' moved to $PROCESSED_DIR/"
                log_message "INFO" "Moved source file: $FILE_PATH -> $PROCESSED_DIR/$FILENAME"
            else
                echo "Warning: Could not move '$FILE_PATH' to $PROCESSED_DIR/"
                log_message "ERROR" "Failed to move source file: $FILE_PATH -> $PROCESSED_DIR/"
            fi
        fi
    fi

else
    echo "Source file(s) retained."
    log_message "INFO" "Source file(s) retained (user opted to keep)."
fi

echo ""
echo "Transfer complete."
log_message "INFO" "=== SFTP Transfer Session Completed ==="
