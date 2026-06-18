#!/bin/bash
set -e

runtime_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f /usr/local/lib/kvs/php-support.sh ]]; then
  # shellcheck source=scripts/php-support.sh
  source /usr/local/lib/kvs/php-support.sh
else
  # shellcheck source=scripts/php-support.sh
  source "$runtime_script_dir/php-support.sh"
fi
if [[ -f /usr/local/lib/kvs/user-support.sh ]]; then
  # shellcheck source=scripts/user-support.sh
  source /usr/local/lib/kvs/user-support.sh
else
  # shellcheck source=scripts/user-support.sh
  source "$runtime_script_dir/user-support.sh"
fi

# Define default values of Environment Variables
FTP_USER=${FTP_USER:-user}
FTP_PASS=${FTP_PASS:-}
PASV_ENABLE=${PASV_ENABLE:-YES}
PASV_ADDRESS=${PASV_ADDRESS:-}
PASV_ADDRESS_INTERFACE=${PASV_ADDRESS_INTERFACE:-}
PASV_ADDR_RESOLVE=${PASV_ADDR_RESOLVE:-NO}
PASV_MIN_PORT=${PASV_MIN_PORT:-21100}
PASV_MAX_PORT=${PASV_MAX_PORT:-21110}
FTP_MODE=${FTP_MODE:-ftp}
LOG_STDOUT=${LOG_STDOUT:-NO}
USER_ID=${USER_ID:-1000}
GROUP_ID=${GROUP_ID:-1000}

validate_ftp_mode() {
  local value="$1"

  if ! is_supported_ftp_mode "$value"; then
    echo "FTP_MODE must be $(format_supported_ftp_modes quoted)"
    exit 1
  fi
}

validate_log_stdout() {
  local value="$1"

  if [[ "$value" != "YES" && "$value" != "NO" ]]; then
    echo "LOG_STDOUT available options are 'YES' or 'NO'"
    exit 1
  fi
}

validate_ftp_username "$FTP_USER"

validate_ftp_password "$FTP_PASS"

validate_account_ids

validate_ftp_mode "$FTP_MODE"
validate_log_stdout "$LOG_STDOUT"

validate_passive_ports() {
  local min_port="$1"
  local max_port="$2"

  if [[ ! "$min_port" =~ ^[1-9][0-9]*$ ]] || [[ ! "$max_port" =~ ^[1-9][0-9]*$ ]]; then
    echo "PASV_MIN_PORT and PASV_MAX_PORT must be positive integers"
    exit 1
  fi

  if ((min_port < 1024 || max_port < 1024 || min_port > 65535 || max_port > 65535)); then
    echo "PASV_MIN_PORT and PASV_MAX_PORT must be valid passive TCP ports (1024-65535)"
    exit 1
  fi

  if ((min_port > max_port)); then
    echo "PASV_MIN_PORT must be less than or equal to PASV_MAX_PORT"
    exit 1
  fi
}

validate_pasv_enable() {
  local value="$1"

  if [[ "$value" != "YES" && "$value" != "NO" ]]; then
    echo "PASV_ENABLE must be 'YES' or 'NO'"
    exit 1
  fi
}

validate_pasv_enable "$PASV_ENABLE"
if [[ "$PASV_ENABLE" == "YES" ]]; then
  validate_passive_ports "$PASV_MIN_PORT" "$PASV_MAX_PORT"
fi

validate_ipv4_address() {
  local value="$1"
  local octet
  local -a octets
  local all_zero=true

  if [[ ! "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "PASV_ADDRESS must be a valid IPv4 address when PASV_ADDR_RESOLVE is NO"
    exit 1
  fi

  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    if ((10#$octet < 0 || 10#$octet > 255)); then
      echo "PASV_ADDRESS must be a valid IPv4 address when PASV_ADDR_RESOLVE is NO"
      exit 1
    fi
    if ((10#$octet != 0)); then
      all_zero=false
    fi
  done

  if [[ "$all_zero" == true ]]; then
    echo "PASV_ADDRESS must not be 0.0.0.0 because FTP passive mode advertises it to clients"
    exit 1
  fi
}

pasv_address_is_unspecified_ipv4() {
  local value="$1"
  local octet
  local -a octets

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    if ((10#$octet < 0 || 10#$octet > 255 || 10#$octet != 0)); then
      return 1
    fi
  done

  return 0
}

validate_pasv_hostname() {
  local value="$1"
  local hostname="${value%.}"
  local label
  local -a labels

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "PASV_ADDRESS must not contain CR or LF characters"
    exit 1
  fi

  if [[ -z "$hostname" || ${#value} -gt 253 ]]; then
    echo "PASV_ADDRESS must be a valid hostname when PASV_ADDR_RESOLVE is YES"
    exit 1
  fi

  IFS=. read -r -a labels <<< "$hostname"
  for label in "${labels[@]}"; do
    if [[ -z "$label" || ${#label} -gt 63 || ! "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      echo "PASV_ADDRESS must be a valid hostname when PASV_ADDR_RESOLVE is YES"
      exit 1
    fi
  done
}

validate_pasv_address() {
  local address="$1"
  local resolve="$2"
  local enabled="$3"

  if [[ "$enabled" == "NO" ]]; then
    return 0
  fi

  if [[ "$resolve" != "YES" && "$resolve" != "NO" ]]; then
    echo "PASV_ADDR_RESOLVE must be 'YES' or 'NO'"
    exit 1
  fi

  if pasv_address_is_unspecified_ipv4 "$address"; then
    echo "PASV_ADDRESS must not be 0.0.0.0 because FTP passive mode advertises it to clients"
    exit 1
  fi

  if [[ -n "$address" && "$resolve" == "NO" ]]; then
    validate_ipv4_address "$address"
  elif [[ -n "$address" ]]; then
    validate_pasv_hostname "$address"
    validate_pasv_hostname_resolution "$address"
  fi
}

# Check for PASV_ADDRESS_INTERFACE to set PASV_ADDRESS
if [[ "$PASV_ENABLE" == "YES" ]]; then
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
    else
      echo "PASV_ADDRESS or PASV_ADDRESS_INTERFACE is required when passive FTP is enabled"
      exit 1
    fi
  else
    echo "PASV_ADDRESS is set so we use it directly"
  fi
else
  echo "Passive FTP is disabled"
fi

validate_pasv_address "$PASV_ADDRESS" "$PASV_ADDR_RESOLVE" "$PASV_ENABLE"
ensure_ftp_account

# Create user home directory if it doesn't exist
ensure_ftp_directory "/home/vsftpd/$FTP_USER" "FTP user home"

# Keep the home directory writable without rewriting existing uploaded files.
ensure_ftp_base_traverse_access /home/vsftpd "FTP base directory"
chown "$FTP_USER:$FTP_USER" "/home/vsftpd/$FTP_USER"

# Building the configuration file
VSFTPD_CONF=/etc/vsftpd.conf
cat /etc/vsftpd-base.conf >$VSFTPD_CONF

echo "FTP mode is $FTP_MODE"
cat /etc/vsftpd-"${FTP_MODE}".conf >>$VSFTPD_CONF

# Update the vsftpd-ftp.conf according to env variables
echo "Update the vsftpd.conf according to env variables"

{
  echo ""
  echo "# the following config lines are added by the script for passive mode"
  echo "anonymous_enable=NO"
  echo "pasv_enable=$PASV_ENABLE"
  if [[ "$PASV_ENABLE" == "YES" ]]; then
    echo "pasv_address=$PASV_ADDRESS"
    echo "pasv_addr_resolve=$PASV_ADDR_RESOLVE"
    echo "pasv_max_port=$PASV_MAX_PORT"
    echo "pasv_min_port=$PASV_MIN_PORT"
  fi
} >>$VSFTPD_CONF

# Get log file path
LOG_FILE=$(grep ^vsftpd_log_file $VSFTPD_CONF | cut -d= -f2)

cat <<EOB
  SERVER SETTINGS
  ---------------
  . FTP_USER: "${FTP_USER}"
  . FTP_PASS: "********"
  . PASV_ENABLE: "${PASV_ENABLE}"
  . PASV_ADDRESS: "${PASV_ADDRESS}"
  . PASV_ADDRESS_INTERFACE: "${PASV_ADDRESS_INTERFACE}"
  . PASV_ADDR_RESOLVE: "${PASV_ADDR_RESOLVE}"
  . PASV_MIN_PORT: "${PASV_MIN_PORT}"
  . PASV_MAX_PORT: "${PASV_MAX_PORT}"
  . FTP_MODE: "${FTP_MODE}"
  . LOG_STDOUT: "${LOG_STDOUT}"
  . LOG_FILE: "${LOG_FILE}"
EOB

if [[ "${LOG_STDOUT}" == "YES" ]]; then
  touch "${LOG_FILE}"
  tail -f "${LOG_FILE}" >>/dev/stdout &
fi

shutdown_vsftpd() {
  echo "Stopping vsftpd"
  if kill -0 "$VSFTPD_PID" 2>/dev/null; then
    kill "$VSFTPD_PID" 2>/dev/null || true
    sleep 1
  fi

  if kill -0 "$VSFTPD_PID" 2>/dev/null; then
    kill -KILL "$VSFTPD_PID" 2>/dev/null || true
  fi

  wait "$VSFTPD_PID" 2>/dev/null || true
  exit 0
}

# Run the vsftpd server
echo "Running vsftpd"
/usr/sbin/vsftpd "$VSFTPD_CONF" &
VSFTPD_PID=$!
trap shutdown_vsftpd TERM INT QUIT HUP
wait "$VSFTPD_PID"
