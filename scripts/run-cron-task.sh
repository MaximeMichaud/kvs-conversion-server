#!/bin/bash
set -euo pipefail

runtime_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f /usr/local/lib/kvs/php-support.sh ]]; then
  # shellcheck source=scripts/php-support.sh
  source /usr/local/lib/kvs/php-support.sh
else
  # shellcheck source=scripts/php-support.sh
  source "$runtime_script_dir/php-support.sh"
fi

CRON_LOG_MAX_BYTES=${CRON_LOG_MAX_BYTES:-$DEFAULT_CRON_LOG_BYTES}

shell_quote() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

validate_log_limit() {
  validate_cron_log_max_bytes "$CRON_LOG_MAX_BYTES" >&2
}

truncate_log_if_needed() {
  local log_path="$1"
  local current_size

  if [[ ! -f "$log_path" ]]; then
    return 0
  fi

  current_size=$(wc -c < "$log_path" | tr -d '[:space:]')
  if [[ "$current_size" =~ ^[0-9]+$ ]] && ((current_size >= CRON_LOG_MAX_BYTES)); then
    : > "$log_path"
  fi
}

trim_log_to_limit() {
  local log_path="$1"
  local current_size
  local log_dir
  local log_base
  local temp_log

  if [[ ! -f "$log_path" ]]; then
    return 0
  fi

  current_size=$(wc -c < "$log_path" | tr -d '[:space:]')
  if [[ ! "$current_size" =~ ^[0-9]+$ ]] || ((current_size <= CRON_LOG_MAX_BYTES)); then
    return 0
  fi

  log_dir=$(dirname -- "$log_path")
  log_base=$(basename -- "$log_path")
  temp_log=$(mktemp "$log_dir/.${log_base}.tmp.XXXXXX") || return 1
  if ! tail -c "$CRON_LOG_MAX_BYTES" "$log_path" > "$temp_log"; then
    rm -f -- "$temp_log"
    return 1
  fi
  cat "$temp_log" > "$log_path"
  rm -f -- "$temp_log"
}

lock_task_directory() {
  local script_dir="$1"
  local lock_name
  local lock_path

  if ! command -v flock >/dev/null 2>&1; then
    echo "flock command is required to guard cron task execution" >&2
    exit 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    lock_name=$(printf '%s' "$script_dir" | sha256sum | awk '{print $1}')
  else
    lock_name=$(printf '%s' "$script_dir" | cksum | awk '{print $1 "-" $2}')
  fi
  lock_path="/tmp/kvs-cron-${lock_name}.lock"

  exec 9>"$lock_path"
  if ! flock -n 9; then
    echo "Skipping $script_dir because a previous cron task is still running"
    exit 0
  fi
}

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 SCRIPT_DIR PHP_VERSION FTP_USER LOG_PATH" >&2
  exit 1
fi

script_dir="$1"
php_version="$2"
ftp_user="$3"
log_path="$4"
script_path="$script_dir/remote_cron.php"

if [[ ! -f "$script_path" ]]; then
  exit 0
fi

validate_log_limit
if ! is_supported_php_version "$php_version"; then
  echo "PHP_VERSION must be $(format_supported_php_versions quoted)" >&2
  exit 1
fi
lock_task_directory "$script_dir"
truncate_log_if_needed "$log_path"

php_binary="/usr/bin/$php_version"

set +e
su -s /bin/sh -c "cd $(shell_quote "$script_dir") && $(shell_quote "$php_binary") $(shell_quote "$script_path")" "$ftp_user"
task_status=$?
set -e

trim_log_to_limit "$log_path"
exit "$task_status"
