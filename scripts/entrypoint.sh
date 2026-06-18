#!/bin/bash
set -e

# Entrypoint script for KVS conversion server container
# Handles initialization and starts services

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

FTP_USER=${FTP_USER:-user}
FTP_PASS=${FTP_PASS:-}
PHP_VERSION=${PHP_VERSION:-$DEFAULT_PHP_VERSION}
NUM_FOLDERS=${NUM_FOLDERS:-$DEFAULT_NUM_FOLDERS}
FTP_MODE=${FTP_MODE:-ftp}
LOG_STDOUT=${LOG_STDOUT:-NO}
PASV_ENABLE=${PASV_ENABLE:-YES}
PASV_ADDRESS=${PASV_ADDRESS:-}
PASV_ADDR_RESOLVE=${PASV_ADDR_RESOLVE:-NO}
PASV_MIN_PORT=${PASV_MIN_PORT:-21100}
PASV_MAX_PORT=${PASV_MAX_PORT:-21110}
USER_ID=${USER_ID:-1000}
GROUP_ID=${GROUP_ID:-1000}

validate_php_version() {
  local value="$1"

  if ! is_supported_php_version "$value"; then
    echo "PHP_VERSION must be $(format_supported_php_versions quoted)"
    exit 1
  fi

  if [[ ! -x "/usr/bin/$value" ]]; then
    echo "PHP binary not found or not executable: /usr/bin/$value"
    exit 1
  fi
}

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

validate_pasv_interface() {
  local interface="$1"
  local address

  address=$(ip -o -4 addr list "$interface" | head -n1 | awk '{print $4}' | cut -d/ -f1)
  if [[ -z "$address" ]]; then
    echo "Could not find IP for interface '$interface', exiting"
    exit 1
  fi
}

validate_pasv_address() {
  local address="$1"
  local resolve="$2"
  local enabled="$3"
  local interface="$4"

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

  if [[ -z "$address" && -z "$interface" ]]; then
    echo "PASV_ADDRESS or PASV_ADDRESS_INTERFACE is required when passive FTP is enabled"
    exit 1
  fi

  if [[ -n "$address" && "$resolve" == "NO" ]]; then
    validate_ipv4_address "$address"
  elif [[ -n "$address" ]]; then
    validate_pasv_hostname "$address"
    validate_pasv_hostname_resolution "$address"
  else
    validate_pasv_interface "$interface"
  fi
}

validate_ftp_username "$FTP_USER"
validate_ftp_password "$FTP_PASS"
validate_php_version "$PHP_VERSION"
validate_num_folders "$NUM_FOLDERS"
validate_ftp_mode "$FTP_MODE"
validate_log_stdout "$LOG_STDOUT"
validate_pasv_enable "$PASV_ENABLE"
if [[ "$PASV_ENABLE" == "YES" ]]; then
  validate_passive_ports "$PASV_MIN_PORT" "$PASV_MAX_PORT"
fi
validate_pasv_address "$PASV_ADDRESS" "$PASV_ADDR_RESOLVE" "$PASV_ENABLE" "$PASV_ADDRESS_INTERFACE"
validate_account_ids
ensure_ftp_account

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
