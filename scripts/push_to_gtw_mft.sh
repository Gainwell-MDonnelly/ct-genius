#!/bin/bash
#
# SFTP File Transfer Script
# Connects to SFTP server and uploads a file to the specified destination
#

# SFTP Server Configuration
SFTP_HOST="54.80.94.146"
DEST_DIR="/genius/ctedw/stg/inbound/"

# Logging Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/sftp_transfer_$(date +%Y%m%d).log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

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

    echo "Uploading ${#MATCHED_FILES[@]} file(s) to $SFTP_HOST:$DEST_DIR ..."
else
    # ---- Single-file mode ----
    read -p "Enter the full path to the file to upload: " FILE_PATH

    if [ ! -f "$FILE_PATH" ]; then
        log_message "ERROR" "File '$FILE_PATH' does not exist. Aborting."
        echo "Error: File '$FILE_PATH' does not exist."
        exit 1
    fi

    FILENAME=$(basename "$FILE_PATH")
    FILESIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null || echo "unknown")

    log_message "INFO" "File to upload: $FILE_PATH (Size: $FILESIZE bytes)"

    echo ""
    echo "Uploading '$FILENAME' to $SFTP_HOST:$DEST_DIR ..."
    log_message "INFO" "Starting upload of '$FILENAME' to $SFTP_HOST:$DEST_DIR"
fi

# Use sshpass for password-based SFTP (if available)
if command -v sshpass &> /dev/null; then
    if [ "$MULTI_FILE" = true ]; then
        sshpass -p "$SFTP_PASS" sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
mput $GLOB_PATTERN
bye
EOF
    else
        sshpass -p "$SFTP_PASS" sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
put "$FILE_PATH"
bye
EOF
    fi
else
    # Fallback: Use expect if sshpass is not available
    if command -v expect &> /dev/null; then
        if [ "$MULTI_FILE" = true ]; then
            expect <<EOF
spawn sftp -o StrictHostKeyChecking=no $SFTP_USER@$SFTP_HOST
expect "password:"
send "$SFTP_PASS\r"
expect "sftp>"
send "cd $DEST_DIR\r"
expect "sftp>"
send "mput $GLOB_PATTERN\r"
expect "sftp>"
send "bye\r"
expect eof
EOF
        else
            expect <<EOF
spawn sftp -o StrictHostKeyChecking=no $SFTP_USER@$SFTP_HOST
expect "password:"
send "$SFTP_PASS\r"
expect "sftp>"
send "cd $DEST_DIR\r"
expect "sftp>"
send "put $FILE_PATH\r"
expect "sftp>"
send "bye\r"
expect eof
EOF
        fi
    else
        echo ""
        echo "Note: sshpass or expect not found. Using interactive SFTP."
        echo "You will be prompted for your password again."
        echo ""
        if [ "$MULTI_FILE" = true ]; then
            sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
mput $GLOB_PATTERN
bye
EOF
        else
            sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
put "$FILE_PATH"
bye
EOF
        fi
    fi
fi

# Check if upload was successful
if [ $? -eq 0 ]; then
    echo ""
    if [ "$MULTI_FILE" = true ]; then
        echo "${#MATCHED_FILES[@]} file(s) matching '*.$FILE_EXT' uploaded successfully to $DEST_DIR"
        log_message "SUCCESS" "${#MATCHED_FILES[@]} file(s) matching '$GLOB_PATTERN' uploaded successfully to $DEST_DIR"
        for f in "${MATCHED_FILES[@]}"; do
            log_message "SUCCESS" "  Uploaded: $(basename "$f")"
        done
    else
        echo "File '$FILENAME' uploaded successfully to $DEST_DIR"
        log_message "SUCCESS" "File '$FILENAME' uploaded successfully to $DEST_DIR"
    fi
else
    echo ""
    if [ "$MULTI_FILE" = true ]; then
        echo "Error: Wildcard upload failed for pattern '$GLOB_PATTERN'."
        log_message "ERROR" "Wildcard upload failed for pattern '$GLOB_PATTERN'"
    else
        echo "Error: File upload failed."
        log_message "ERROR" "File upload failed for '$FILENAME'"
    fi
    exit 1
fi

# --- Post-upload cleanup ---
read -p "Delete source file(s) after successful upload? [y/N]: " DELETE_CONFIRM
if [[ "$DELETE_CONFIRM" =~ ^[Yy]$ ]]; then
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
        log_message "INFO" "Post-upload cleanup: $DELETED deleted, $FAILED failed"
    else
        if rm -f "$FILE_PATH" 2>/dev/null; then
            echo "Source file '$FILENAME' deleted."
            log_message "INFO" "Deleted source file: $FILE_PATH"
        else
            echo "Warning: Could not delete '$FILE_PATH'."
            log_message "ERROR" "Failed to delete source file: $FILE_PATH"
        fi
    fi
else
    log_message "INFO" "Source file(s) retained (user opted not to delete)."
fi

echo ""
echo "Transfer complete."
log_message "INFO" "=== SFTP Transfer Session Completed ==="