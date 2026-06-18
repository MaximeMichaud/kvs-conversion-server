#!/bin/bash
set -e

# Read the environment variables
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

NUM_FOLDERS=${NUM_FOLDERS:-$DEFAULT_NUM_FOLDERS}
FTP_USER=${FTP_USER:-user}        # Default FTP user if not defined
PHP_VERSION=${PHP_VERSION:-$DEFAULT_PHP_VERSION}
CRON_LOG_MAX_BYTES=${CRON_LOG_MAX_BYTES:-$DEFAULT_CRON_LOG_BYTES}

validate_ftp_username "$FTP_USER"

if ! is_supported_php_version "$PHP_VERSION"; then
  echo "PHP_VERSION must be $(format_supported_php_versions quoted)"
  exit 1
fi

if [[ ! -x "/usr/bin/$PHP_VERSION" ]]; then
  echo "PHP binary not found or not executable: /usr/bin/$PHP_VERSION"
  exit 1
fi

validate_num_folders "$NUM_FOLDERS"

validate_cron_log_max_bytes "$CRON_LOG_MAX_BYTES"

# Base location for FTP user's folders
BASE_HOME="/home/vsftpd"
USER_HOME="${BASE_HOME}/${FTP_USER}"
CRON_RUNNER="/usr/local/bin/run-cron-task.sh"
CRON_BEGIN_MARKER="# BEGIN KVS Folders Cron Jobs"
CRON_END_MARKER="# END KVS Folders Cron Jobs"

set_directory_owner() {
  local path="$1"

  if id "$FTP_USER" >/dev/null 2>&1 && getent group "$FTP_USER" >/dev/null 2>&1; then
    chown "$FTP_USER:$FTP_USER" "$path"
  fi
}

regex_escape() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|]/\\&/g'
}

ensure_ftp_directory "$BASE_HOME" "FTP base directory"
ensure_ftp_directory "$USER_HOME" "FTP user home"
ensure_ftp_base_traverse_access "$BASE_HOME" "FTP base directory"
set_directory_owner "$USER_HOME"

# Create folders with leading zero in folder names if the number is less than 10
for i in $(seq 1 "$NUM_FOLDERS"); do
  DIR_PATH="$USER_HOME/$(printf "%02d" "$i")"
  ensure_ftp_directory "$DIR_PATH" "FTP folder"
  set_directory_owner "$DIR_PATH"
done

# Add cron jobs
CRON_FILE=$(mktemp)
NEW_CRON_FILE=$(mktemp)
trap 'rm -f "$CRON_FILE" "$NEW_CRON_FILE"' EXIT
USER_HOME_REGEX=$(regex_escape "$USER_HOME")
LEGACY_CRON_PATTERN="^\\* \\* \\* \\* \\* \\[ -f ${USER_HOME_REGEX}/[0-9][0-9]*/remote_cron\\.php \\] && /usr/bin/php[0-9]+\\.[0-9]+ ${USER_HOME_REGEX}/[0-9][0-9]*/remote_cron\\.php >> /var/log/cron[0-9][0-9]*\\.log 2>&1$"

crontab -l > "$CRON_FILE" 2>/dev/null || true
awk \
  -v begin_marker="$CRON_BEGIN_MARKER" \
  -v end_marker="$CRON_END_MARKER" \
  -v legacy_cron_pattern="$LEGACY_CRON_PATTERN" '
    $0 == begin_marker {
      in_kvs_block = 1
      next
    }
    $0 == end_marker {
      in_kvs_block = 0
      next
    }
    in_kvs_block {
      next
    }
    $0 == "#KVS Folders Cron Jobs" {
      next
    }
    $0 ~ legacy_cron_pattern {
      next
    }
    {
      print
    }
  ' "$CRON_FILE" > "$NEW_CRON_FILE"

echo "$CRON_BEGIN_MARKER" >> "$NEW_CRON_FILE"
for i in $(seq 1 "$NUM_FOLDERS"); do
  FOLDER_NUM=$(printf "%02d" "$i")
  SCRIPT_DIR="$USER_HOME/$FOLDER_NUM"
  SCRIPT_PATH="$USER_HOME/$FOLDER_NUM/remote_cron.php"
  LOG_PATH="/var/log/cron${FOLDER_NUM}.log"
  printf '* * * * * [ -f %q ] && CRON_LOG_MAX_BYTES=%q %q %q %q %q %q >> %q 2>&1\n' \
    "$SCRIPT_PATH" \
    "$CRON_LOG_MAX_BYTES" \
    "$CRON_RUNNER" \
    "$SCRIPT_DIR" \
    "$PHP_VERSION" \
    "$FTP_USER" \
    "$LOG_PATH" \
    "$LOG_PATH" >> "$NEW_CRON_FILE"
done
echo "$CRON_END_MARKER" >> "$NEW_CRON_FILE"
crontab "$NEW_CRON_FILE"
