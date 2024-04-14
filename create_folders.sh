#!/bin/sh

# Read the environment variables
NUM_FOLDERS=${NUM_FOLDERS:-5}     # Default value of 5 if not defined
FTP_USER=${FTP_USER:-user}        # Default FTP user if not defined
PHP_VERSION=${PHP_VERSION:-php7.4} # Default to php7.4, can be set to php8.1

# Base location for FTP user's folders
USER_HOME="/home/vsftpd/${FTP_USER}"

# Create folders with leading zero in folder names if the number is less than 10
for i in $(seq 1 "$NUM_FOLDERS"); do
  DIR_PATH="$USER_HOME/$(printf "%02d" "$i")"
  mkdir -p "$DIR_PATH"
done

# Add cron jobs
CRON_FILE=$(mktemp)
crontab -l > "$CRON_FILE" 2>/dev/null
echo "#KVS Folders Cron Jobs" >> "$CRON_FILE"
for i in $(seq 1 "$NUM_FOLDERS"); do
  FOLDER_NUM=$(printf "%02d" "$i")
  echo "* * * * * [ -f $USER_HOME/$FOLDER_NUM/remote_cron.php ] && /usr/bin/$PHP_VERSION $USER_HOME/$FOLDER_NUM/remote_cron.php >> /var/log/cron${FOLDER_NUM}.log 2>&1" >> "$CRON_FILE"
done
crontab "$CRON_FILE"
rm "$CRON_FILE"
