#!/bin/bash

# Define default values of Environment Variables
FTP_USER=${FTP_USER:-user}
FTP_PASS=${FTP_PASS:-pass}
PASV_ENABLE=${PASV_ENABLE:-YES}
PASV_ADDRESS=${PASV_ADDRESS:-}
PASV_ADDRESS_INTERFACE=${PASV_ADDRESS_INTERFACE:-eth0}
PASV_ADDR_RESOLVE=${PASV_ADDR_RESOLVE:-NO}
PASV_MIN_PORT=${PASV_MIN_PORT:-21100}
PASV_MAX_PORT=${PASV_MAX_PORT:-21110}
FTP_MODE=${FTP_MODE:-ftp}
LOG_STDOUT=${LOG_STDOUT:-NO}
#USER_ID=${USER_ID:-433}
#GROUP_ID=${GROUP_ID:-431}
USER_ID=${USER_ID:-1000}
GROUP_ID=${GROUP_ID:-1000}
ENABLE_IONCUBE=${ENABLE_IONCUBE:-YES}  # Default to YES
PHP_VERSION=${PHP_VERSION:-php8.1}     # Default PHP version

# Check for PASV_ADDRESS_INTERFACE to set PASV_ADDRESS
if [ -z "$PASV_ADDRESS" ]; then
  echo "PASV_ADDRESS env variable is not set"
  if [ -n "$PASV_ADDRESS_INTERFACE" ]; then
    echo "Attempting to guess the PASV_ADDRESS from PASV_ADDRESS_INTERFACE"
    PASV_ADDRESS=$(ip -o -4 addr list "$PASV_ADDRESS_INTERFACE" | head -n1 | awk '{print $4}' | cut -d/ -f1)
    if [ -z "$PASV_ADDRESS" ]; then
      echo "Could not find IP for interface '$PASV_ADDRESS_INTERFACE', exiting"
      exit 1
    fi
    echo "==> Found address '$PASV_ADDRESS' for interface '$PASV_ADDRESS_INTERFACE', setting PASV_ADDRESS env variable..."
  fi
else
  echo "PASV_ADDRESS is set so we use it directly"
fi

# Create FTP user group if it doesn't exist
if getent group "$FTP_USER" >/dev/null 2>&1; then
  echo "Group $FTP_USER already exists."
else
  echo "Creating group $FTP_USER."
  groupadd -g "$GROUP_ID" "$FTP_USER"
fi

# Create FTP user
if id "$FTP_USER" >/dev/null 2>&1; then
  echo "User $FTP_USER already exists."
else
  echo "Creating user $FTP_USER."
  useradd -u "$USER_ID" -g "$FTP_USER" -d "/home/vsftpd/$FTP_USER" "$FTP_USER"
  echo "$FTP_USER:$FTP_PASS" | chpasswd
fi

# Set ownership for the user's home directory
chown -R "$FTP_USER:$FTP_USER" "/home/vsftpd/$FTP_USER"

# Configure IonCube loader based on environment variable
if [[ "$ENABLE_IONCUBE" == "YES" ]]; then
    PHP_VERSION_NUM=$(echo "$PHP_VERSION" | sed 's/php//')
    PHP_EXT_DIR=$($PHP_VERSION -i | grep extension_dir | awk '{print $3}')
    
    if [ -f "${PHP_EXT_DIR}/ioncube_loader_lin_${PHP_VERSION_NUM}.so" ]; then
        if ! grep -q "ioncube_loader_lin" "/etc/php/${PHP_VERSION_NUM}/cli/php.ini" 2>/dev/null; then
            echo "zend_extension=${PHP_EXT_DIR}/ioncube_loader_lin_${PHP_VERSION_NUM}.so" >> "/etc/php/${PHP_VERSION_NUM}/cli/php.ini"
            echo "IonCube loader enabled for PHP ${PHP_VERSION_NUM}"
        fi
    fi
else
    echo "IonCube loader disabled"
fi

# Building the configuration file
VSFTPD_CONF=/etc/vsftpd.conf
cat /etc/vsftpd-base.conf >$VSFTPD_CONF

if [[ "$FTP_MODE" =~ ^(ftp|ftps|ftps_implicit|ftps_tls)$ ]]; then
  echo "FTP mode is $FTP_MODE"
  cat /etc/vsftpd-"${FTP_MODE}".conf >>$VSFTPD_CONF
else
  echo "$FTP_MODE is not a supported FTP mode"
  echo "FTP_MODE env var must be ftp, ftps, ftps_implicit or ftps_tls"
  echo "exiting"
  exit 1
fi

# Update the vsftpd-ftp.conf according to env variables
echo "Update the vsftpd.conf according to env variables"

{
  echo ""
  echo "# the following config lines are added by the script for passive mode"
  echo "anonymous_enable=NO"
  echo "pasv_enable=$PASV_ENABLE"
  echo "pasv_address=$PASV_ADDRESS"
  echo "pasv_addr_resolve=$PASV_ADDR_RESOLVE"
  echo "pasv_max_port=$PASV_MAX_PORT"
  echo "pasv_min_port=$PASV_MIN_PORT"
} >>$VSFTPD_CONF

# Get log file path
LOG_FILE=$(grep ^vsftpd_log_file $VSFTPD_CONF | cut -d= -f2)

cat <<EOB
  SERVER SETTINGS
  ---------------
  . FTP_USER: "${FTP_USER}"
  . FTP_PASS: "${FTP_PASS}"
  . PASV_ENABLE: "${PASV_ENABLE}"
  . PASV_ADDRESS: "${PASV_ADDRESS}"
  . PASV_ADDRESS_INTERFACE: "${PASV_ADDRESS_INTERFACE}"
  . PASV_ADDR_RESOLVE: "${PASV_ADDR_RESOLVE}"
  . PASV_MIN_PORT: "${PASV_MIN_PORT}"
  . PASV_MAX_PORT: "${PASV_MAX_PORT}"
  . FTP_MODE: "${FTP_MODE}"
  . PHP_VERSION: "${PHP_VERSION}"
  . IONCUBE: "${ENABLE_IONCUBE}"
  . LOG_STDOUT: "${LOG_STDOUT}"
  . LOG_FILE: "${LOG_FILE}"
EOB

if [[ "${LOG_STDOUT}" == "YES" ]]; then
  touch "${LOG_FILE}"
  tail -f "${LOG_FILE}" >>/dev/stdout &
elif [[ "${LOG_STDOUT}" != "NO" ]]; then
  echo "LOG_STDOUT available options are 'YES' or 'NO'"
  exit 1
fi

# Run the vsftpd server
echo "Running vsftpd"
/usr/sbin/vsftpd $VSFTPD_CONF
