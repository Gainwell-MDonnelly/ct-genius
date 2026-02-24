#!/bin/bash

# Destination server and path
DEST_SERVER="oracle@10.40.26.175"
DEST_PATH="/delphix/DeIdentified/dev/"

# Logging Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/copy_tar_$(date +%Y%m%d).log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to write to log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Start session
log_message "INFO" "=== Starting Copy Session ==="
log_message "INFO" "Destination: $DEST_SERVER:$DEST_PATH"

# Prompt for source file
read -p "Enter the source file name: " SOURCE_FILE

# Check if input is empty
if [ -z "$SOURCE_FILE" ]; then
    log_message "ERROR" "No file name provided. Aborting."
    echo "Error: No file name provided!"
    exit 1
fi

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    log_message "ERROR" "File '$SOURCE_FILE' not found. Aborting."
    echo "Error: File $SOURCE_FILE not found!"
    exit 1
fi

# Get the base name without extension for the tar file
BASENAME=$(basename "$SOURCE_FILE")
TAR_FILE="${BASENAME}.tar.gz"
FILESIZE=$(stat -c%s "$SOURCE_FILE" 2>/dev/null || stat -f%z "$SOURCE_FILE" 2>/dev/null || echo "unknown")

log_message "INFO" "Source file: $SOURCE_FILE (Size: $FILESIZE bytes)"
log_message "INFO" "Creating tar archive: $TAR_FILE"

# Tar and gzip the file
echo "Compressing $SOURCE_FILE to $TAR_FILE..."
tar -czvf "$TAR_FILE" "$SOURCE_FILE"

if [ $? -eq 0 ]; then
    TAR_SIZE=$(stat -c%s "$TAR_FILE" 2>/dev/null || stat -f%z "$TAR_FILE" 2>/dev/null || echo "unknown")
    log_message "SUCCESS" "Compression complete. Archive size: $TAR_SIZE bytes"
else
    log_message "ERROR" "Failed to create tar archive"
    exit 1
fi

# Copy to remote server
log_message "INFO" "Starting SCP transfer to ${DEST_SERVER}:${DEST_PATH}"
echo "Copying ${TAR_FILE} to ${DEST_SERVER}:${DEST_PATH}..."
scp "${TAR_FILE}" "${DEST_SERVER}:${DEST_PATH}/"

# Check if copy was successful
if [ $? -eq 0 ]; then
    log_message "SUCCESS" "File '$TAR_FILE' successfully copied to ${DEST_SERVER}:${DEST_PATH}"
    echo "File successfully copied!"
else
    log_message "ERROR" "Failed to copy file to remote server"
    echo "Error: Failed to copy file to remote server."
    exit 1
fi

log_message "INFO" "=== Copy Session Completed ==="

# TODO: Add logging - DONE
# TODO: Add interactive prompt for source file - DONE
