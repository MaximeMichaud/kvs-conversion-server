#!/bin/bash

# shellcheck disable=SC2034
project_defaults_path=${KVS_PROJECT_DEFAULTS_PATH:-}
if [[ -z "$project_defaults_path" ]]; then
  php_support_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f /usr/local/lib/kvs/kvs-conversion-server.sh ]]; then
    project_defaults_path=/usr/local/lib/kvs/kvs-conversion-server.sh
  else
    project_defaults_path="$php_support_dir/../kvs-conversion-server.sh"
  fi
fi

read_project_assignment() {
  local name="$1"
  local value

  if [[ ! -r "$project_defaults_path" ]]; then
    echo "Project defaults file is missing or unreadable: $project_defaults_path" >&2
    exit 1
  fi

  value=$(awk -v name="$name" '
    index($0, name "=") == 1 {
      value = substr($0, length(name) + 2)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$project_defaults_path")

  if [[ -z "$value" ]]; then
    echo "Missing project default: $name" >&2
    exit 1
  fi

  printf '%s\n' "$value"
}

read_project_default() {
  local name="$1"
  local value
  local derived_default_php_expression="\${SUPPORTED_PHP_VERSIONS##* }"
  local supported_php_versions

  value=$(read_project_assignment "$name")

  case "$value" in
    "$derived_default_php_expression")
      supported_php_versions=$(read_project_assignment SUPPORTED_PHP_VERSIONS)
      value="${supported_php_versions##* }"
      ;;
  esac

  printf '%s\n' "$value"
}

DEFAULT_PHP_VERSION=$(read_project_default DEFAULT_PHP_VERSION)
SUPPORTED_PHP_VERSIONS=$(read_project_default SUPPORTED_PHP_VERSIONS)
SUPPORTED_FTP_MODES=$(read_project_default SUPPORTED_FTP_MODES)
DEFAULT_NUM_FOLDERS=$(read_project_default DEFAULT_NUM_FOLDERS)
MAX_NUM_FOLDERS=$(read_project_default MAX_NUM_FOLDERS)
DEFAULT_CRON_LOG_BYTES=$(read_project_default DEFAULT_CRON_LOG_BYTES)
MAX_CRON_LOG_BYTES=$(read_project_default MAX_CRON_LOG_BYTES)

is_supported_php_version() {
  local value="$1"
  local -a versions
  local version

  read -r -a versions <<< "$SUPPORTED_PHP_VERSIONS"
  for version in "${versions[@]}"; do
    if [[ "$value" == "$version" ]]; then
      return 0
    fi
  done

  return 1
}

format_supported_php_versions() {
  local quote="${1:-}"
  local -a versions
  local version_count
  local index
  local version
  local item
  local output=""

  read -r -a versions <<< "$SUPPORTED_PHP_VERSIONS"
  version_count=${#versions[@]}

  for index in "${!versions[@]}"; do
    version="${versions[$index]}"
    item="$version"
    if [[ "$quote" == "quoted" ]]; then
      item="'$version'"
    fi

    if ((index == 0)); then
      output="$item"
    elif ((index == version_count - 1)); then
      output="$output or $item"
    else
      output="$output, $item"
    fi
  done

  printf '%s' "$output"
}

is_supported_ftp_mode() {
  local value="$1"
  local mode

  for mode in $SUPPORTED_FTP_MODES; do
    if [[ "$value" == "$mode" ]]; then
      return 0
    fi
  done

  return 1
}

format_supported_ftp_modes() {
  local quote="${1:-}"
  local -a modes
  local mode_count
  local index
  local mode
  local item
  local output=""

  read -r -a modes <<< "$SUPPORTED_FTP_MODES"
  mode_count=${#modes[@]}

  for index in "${!modes[@]}"; do
    mode="${modes[$index]}"
    item="$mode"
    if [[ "$quote" == "quoted" ]]; then
      item="'$mode'"
    fi

    if ((index == 0)); then
      output="$item"
    elif ((index == mode_count - 1)); then
      output="$output, or $item"
    else
      output="$output, $item"
    fi
  done

  printf '%s' "$output"
}

value_exceeds_max() {
  local value="$1"
  local max="$2"

  if ((${#value} > ${#max})); then
    return 0
  fi

  if ((${#value} < ${#max})); then
    return 1
  fi

  ((value > max))
}

validate_num_folders() {
  local value="$1"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "NUM_FOLDERS must be a positive integer"
    exit 1
  fi

  if value_exceeds_max "$value" "$MAX_NUM_FOLDERS"; then
    echo "NUM_FOLDERS must be between 1 and $MAX_NUM_FOLDERS"
    exit 1
  fi
}

validate_cron_log_max_bytes() {
  local value="$1"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "CRON_LOG_MAX_BYTES must be a positive integer"
    exit 1
  fi

  if value_exceeds_max "$value" "$MAX_CRON_LOG_BYTES"; then
    echo "CRON_LOG_MAX_BYTES must be between 1 and $MAX_CRON_LOG_BYTES"
    exit 1
  fi
}

validate_pasv_hostname_resolution() {
  local value="$1"
  local addresses

  if ! addresses=$(getent ahostsv4 "$value" 2>/dev/null | awk '{print $1}'); then
    echo "PASV_ADDRESS hostname must resolve to an IPv4 address when PASV_ADDR_RESOLVE is YES: $value"
    exit 1
  fi

  if [[ -z "$addresses" ]]; then
    echo "PASV_ADDRESS hostname must resolve to an IPv4 address when PASV_ADDR_RESOLVE is YES: $value"
    exit 1
  fi

  if grep -Fxq "0.0.0.0" <<< "$addresses"; then
    echo "PASV_ADDRESS hostname must not resolve to 0.0.0.0 when PASV_ADDR_RESOLVE is YES: $value"
    exit 1
  fi
}
