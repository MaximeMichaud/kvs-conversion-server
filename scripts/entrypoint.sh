#!/bin/bash
set -e

# Entrypoint script for KVS conversion server container
# Handles initialization and starts services

# Generate SSL certificates for FTPS if they don't exist
if [ ! -f /etc/ssl/private/vsftpd.pem ] || [ ! -f /etc/ssl/private/vsftpd.key ]; then
  echo "Generating self-signed SSL certificate for FTPS..."
  mkdir -p /etc/ssl/private
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/private/vsftpd.key \
    -out /etc/ssl/private/vsftpd.pem \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=vsftpd"
  chmod 600 /etc/ssl/private/vsftpd.key
  chmod 644 /etc/ssl/private/vsftpd.pem
  echo "SSL certificate generated successfully"
fi

# Create FTP folders and configure cron jobs
/usr/local/bin/create_folders.sh

# Start cron daemon
cron

# Start vsftpd (runs in foreground)
exec /usr/sbin/run-vsftpd.sh
