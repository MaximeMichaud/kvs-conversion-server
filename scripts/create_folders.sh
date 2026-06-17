#!/bin/bash
set -e

# Read the environment variables
NUM_FOLDERS=${NUM_FOLDERS:-5}     # Default value of 5 if not defined
FTP_USER=${FTP_USER:-user}        # Default FTP user if not defined
PHP_VERSION=${PHP_VERSION:-php7.4} # Default to php7.4, can be set to php8.1

# Base location for FTP user's folders
USER_HOME="/home/vsftpd/${FTP_USER}"
CRON_BEGIN_MARKER="# BEGIN KVS Folders Cron Jobs"
CRON_END_MARKER="# END KVS Folders Cron Jobs"

# Create folders with leading zero in folder names if the number is less than 10
for i in $(seq 1 "$NUM_FOLDERS"); do
  DIR_PATH="$USER_HOME/$(printf "%02d" "$i")"
  mkdir -p "$DIR_PATH"
done

# Add cron jobs
CRON_FILE=$(mktemp)
NEW_CRON_FILE=$(mktemp)
trap 'rm -f "$CRON_FILE" "$NEW_CRON_FILE"' EXIT

crontab -l > "$CRON_FILE" 2>/dev/null || true
sed \
  -e "/^${CRON_BEGIN_MARKER}$/,/^${CRON_END_MARKER}$/d" \
  -e '/^#KVS Folders Cron Jobs$/d' \
  -e '/remote_cron\.php.*\/var\/log\/cron[0-9][0-9]\.log/d' \
  "$CRON_FILE" > "$NEW_CRON_FILE"

echo "$CRON_BEGIN_MARKER" >> "$NEW_CRON_FILE"
for i in $(seq 1 "$NUM_FOLDERS"); do
  FOLDER_NUM=$(printf "%02d" "$i")
  SCRIPT_PATH="$USER_HOME/$FOLDER_NUM/remote_cron.php"
  LOG_PATH="/var/log/cron${FOLDER_NUM}.log"
  printf '* * * * * [ -f %q ] && su -s /bin/sh -c %q %q >> %q 2>&1\n' \
    "$SCRIPT_PATH" \
    "/usr/bin/$PHP_VERSION $SCRIPT_PATH" \
    "$FTP_USER" \
    "$LOG_PATH" >> "$NEW_CRON_FILE"
done
echo "$CRON_END_MARKER" >> "$NEW_CRON_FILE"
crontab "$NEW_CRON_FILE"
