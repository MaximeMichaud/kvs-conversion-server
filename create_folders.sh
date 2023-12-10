#!/bin/sh

# Read the environment variable
NUM_FOLDERS=${NUM_FOLDERS:-10} # Default value of 10 if not defined

# Base location for user "user" folders
USER_HOME="/home/vsftpd/user"

# Create folders and set up cron jobs
for i in $(seq 1 $NUM_FOLDERS); do
  # Create the folder in the "user" user's directory
  DIR_PATH="$USER_HOME/$i"
  mkdir -p "$DIR_PATH"

  # Add a cron job for this folder
  echo "* * * * * [ -f $DIR_PATH/remote_cron.php ] && php $DIR_PATH/remote_cron.php >> /var/log/cron$i.log 2>&1" >>/etc/crontabs/root
done

# Restart the cron service to apply new tasks
crond
