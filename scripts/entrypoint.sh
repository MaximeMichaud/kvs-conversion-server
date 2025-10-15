#!/bin/bash
set -e

# Entrypoint script for KVS conversion server container
# Handles initialization and starts services

# Create FTP folders and configure cron jobs
/usr/local/bin/create_folders.sh

# Start cron daemon
cron

# Start vsftpd (runs in foreground)
exec /usr/sbin/run-vsftpd.sh
