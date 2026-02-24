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

# Prompt for file to upload
read -p "Enter the full path to the file to upload: " FILE_PATH

# Validate file exists
if [ ! -f "$FILE_PATH" ]; then
    log_message "ERROR" "File '$FILE_PATH' does not exist. Aborting."
    echo "Error: File '$FILE_PATH' does not exist."
    exit 1
fi

# Get the filename from the path
FILENAME=$(basename "$FILE_PATH")
FILESIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH" 2>/dev/null || echo "unknown")

log_message "INFO" "File to upload: $FILE_PATH (Size: $FILESIZE bytes)"

echo ""
echo "Uploading '$FILENAME' to $SFTP_HOST:$DEST_DIR ..."
log_message "INFO" "Starting upload of '$FILENAME' to $SFTP_HOST:$DEST_DIR"

# Use sshpass for password-based SFTP (if available)
if command -v sshpass &> /dev/null; then
    sshpass -p "$SFTP_PASS" sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
put "$FILE_PATH"
bye
EOF
else
    # Fallback: Use expect if sshpass is not available
    if command -v expect &> /dev/null; then
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
    else
        echo ""
        echo "Note: sshpass or expect not found. Using interactive SFTP."
        echo "You will be prompted for your password again."
        echo ""
        sftp -o StrictHostKeyChecking=no "$SFTP_USER@$SFTP_HOST" <<EOF
cd $DEST_DIR
put "$FILE_PATH"
bye
EOF
    fi
fi

# Check if upload was successful
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

echo ""
echo "Transfer complete."
log_message "INFO" "=== SFTP Transfer Session Completed ==="
