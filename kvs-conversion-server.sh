#!/bin/bash
#
# [Automatic installation on Linux for KVS Conversion Server]
#
# GitHub: https://github.com/MaximeMichaud/kvs-conversion-server
# URL: https://www.kernel-video-sharing.com
#
# This script is intended for a quick and easy installation:
# bash <(curl -s https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/main/kvs-conversion-server.sh)
#
# Copyright (c) 2023 MaximeMichaud
# Licensed under MIT License
#
set -e

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

setup_colors() {
  CYAN=""
  BLUE=""
  GREEN=""
  YELLOW=""
  RED=""
  BOLD=""
  RESET=""

  if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]] || [[ -z "${TERM:-}" ]] || ! command_exists tput; then
    return 0
  fi

  local color_count
  color_count=$(tput colors 2>/dev/null || echo 0)
  if [[ "$color_count" =~ ^[0-9]+$ ]] && ((color_count >= 8)); then
    CYAN=$(tput setaf 6)
    BLUE=$(tput setaf 4)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RED=$(tput setaf 1)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
  fi
}

setup_colors

# Global variables for headless mode
HEADLESS_MODE=false

# CLI Management Constants
CONTAINER_NAME="conversion-server"
CONFIG_FILE=".kvs-server.conf"
CONFIG_FILE_PATH=""
CONFIG_DIR=""
MANAGEMENT_SCRIPT_NAME="kvs-conversion-server.sh"
IMAGE_REPOSITORY="maximemichaud/kvs-conversion-server"
DEFAULT_IMAGE_TAG="1.3.8"
IMAGE_TAG="$DEFAULT_IMAGE_TAG"
MAX_FTP_PASSWORD_LENGTH=511
SUPPORTED_PHP_VERSIONS="php7.4 php8.1"
DEFAULT_PHP_VERSION="${SUPPORTED_PHP_VERSIONS##* }"
SUPPORTED_FTP_MODES="ftp ftps ftps_implicit ftps_tls"
DEFAULT_NUM_FOLDERS=5
# shellcheck disable=SC2034
MAX_CRONTAB_LINES=10000
MAX_NUM_FOLDERS=9998
# shellcheck disable=SC2034
DEFAULT_CRON_LOG_BYTES=10485760
# shellcheck disable=SC2034
MAX_CRON_LOG_BYTES=1099511627776

apply_headless_env() {
  if [[ "${KVS_HEADLESS:-false}" == "true" ]]; then
    HEADLESS_MODE=true
  fi
}

# CLI Management Functions
# Inspired by docker-compose CLI design

print_error() {
  echo "${RED}Error: $*${RESET}" >&2
}

require_option_value() {
  local option="$1"
  local value="${2-}"

  if [[ -z "$value" ]] || [[ "$value" == --* ]]; then
    print_error "Option '$option' requires a value"
    exit 1
  fi
}

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

php_version_label() {
  local version="$1"
  printf 'PHP %s' "${version#php}"
}

validate_php_version() {
  local value="$1"

  if ! is_supported_php_version "$value"; then
    print_error "PHP version must be $(format_supported_php_versions quoted)"
    exit 1
  fi
}

validate_ftp_mode() {
  local value="$1"

  if ! is_supported_ftp_mode "$value"; then
    print_error "FTP mode must be $(format_supported_ftp_modes quoted)"
    exit 1
  fi
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

ftp_mode_requires_ssl() {
  case "$1" in
    ftps|ftps_tls|ftps_implicit)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_reserved_ftp_username() {
  case "$1" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|_apt|nobody|systemd-network|ftp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_ftp_username() {
  local value="$1"

  if ((${#value} > 32)); then
    print_error "FTP username must be 32 characters or fewer"
    exit 1
  fi

  if [[ "$value" == "." || "$value" == ".." ]]; then
    print_error "FTP username cannot be '.' or '..'"
    exit 1
  fi

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    print_error "FTP username cannot be purely numeric"
    exit 1
  fi

  if [[ ! "$value" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]]; then
    print_error "FTP username may only contain letters, digits, underscores, dots, and dashes, and must not start with a dash"
    exit 1
  fi

  if is_reserved_ftp_username "$value"; then
    print_error "FTP username '$value' is reserved by the container image"
    exit 1
  fi
}

validate_ftp_password() {
  local value="$1"

  if [[ -z "$value" ]]; then
    print_error "FTP password is required"
    exit 1
  fi

  if ((${#value} > MAX_FTP_PASSWORD_LENGTH)); then
    print_error "FTP password must be $MAX_FTP_PASSWORD_LENGTH characters or fewer"
    exit 1
  fi

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    print_error "FTP password must not contain CR or LF characters"
    exit 1
  fi
}

validate_ipv4_address() {
  local value="$1"
  local octet
  local -a octets
  local all_zero=true

  if [[ ! "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    print_error "IPv4 address must use dotted decimal notation"
    exit 1
  fi

  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    if ((10#$octet < 0 || 10#$octet > 255)); then
      print_error "IPv4 address contains an invalid octet: $octet"
      exit 1
    fi
    if ((10#$octet != 0)); then
      all_zero=false
    fi
  done

  if [[ "$all_zero" == true ]]; then
    print_error "IPv4 address must not be 0.0.0.0 because FTP passive mode advertises it to clients"
    exit 1
  fi
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

validate_folder_count() {
  local value="$1"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    print_error "Number of folders must be a positive integer"
    exit 1
  fi

  if value_exceeds_max "$value" "$MAX_NUM_FOLDERS"; then
    print_error "Number of folders must be between 1 and $MAX_NUM_FOLDERS"
    exit 1
  fi
}

validate_cpu_limit() {
  local value="$1"
  local total_cores

  if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
    print_error "CPU limit must be a positive number"
    exit 1
  fi

  validate_cpu_limit_minimum "$value"

  total_cores=$(host_cpu_count)
  if ! awk -v value="$value" -v total="$total_cores" 'BEGIN { exit !(value >= 0.01 && value <= total) }'; then
    print_error "CPU limit must be between 0.01 and $total_cores"
    exit 1
  fi
}

validate_saved_cpu_limit() {
  local value="$1"

  if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
    print_error "CPU limit must be a positive number"
    exit 1
  fi

  validate_cpu_limit_minimum "$value"
}

validate_cpu_limit_minimum() {
  local value="$1"

  if ! awk -v value="$value" 'BEGIN { exit !(value >= 0.01) }'; then
    print_error "CPU limit must be at least 0.01"
    exit 1
  fi
}

host_cpu_count() {
  local total_cores=""

  if command_exists nproc; then
    total_cores=$(nproc 2>/dev/null || true)
  fi

  if [[ -z "$total_cores" && -r /proc/cpuinfo ]]; then
    total_cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || true)
  fi

  if [[ ! "$total_cores" =~ ^[1-9][0-9]*$ ]]; then
    total_cores=1
  fi

  printf '%s\n' "$total_cores"
}

validate_image_tag() {
  local value="$1"

  if ! image_tag_is_valid "$value"; then
    print_error "Docker image tag contains invalid characters"
    exit 1
  fi
}

image_tag_is_valid() {
  local value="$1"

  [[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

validate_container_name() {
  local value="$1"

  if [[ -z "$value" ]]; then
    print_error "Container name is required"
    exit 1
  fi

  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    print_error "Container name may only contain letters, digits, underscores, dots, and dashes, and must start with a letter or digit"
    exit 1
  fi
}

reject_unexpected_args() {
  local command="$1"
  shift

  if (($# > 0)); then
    print_error "Unknown option for $command: $1"
    echo "Run '$0 --help' for usage information"
    return 1
  fi
}

is_affirmative() {
  local value="$1"

  [[ "$value" == "true" || "$value" =~ ^[Yy]([Ee][Ss])?$ ]]
}

docker_image_ref() {
  printf '%s:%s' "$IMAGE_REPOSITORY" "$IMAGE_TAG"
}

regex_escape() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?{}()|]/\\&/g'
}

docker_bind_mount_arg() {
  local source_path="$1"
  local target_path="$2"
  local mount_source="$source_path"

  if [[ "$source_path" == *,* ]]; then
    mount_source=$(docker_bind_mount_source_alias "$source_path") || return 1
  fi

  printf 'type=bind,source=%s,target=%s' "$mount_source" "$target_path"
}

docker_bind_mount_alias_base_dir() {
  local candidate

  for candidate in "${TMPDIR:-}" /tmp /var/tmp; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" == *,* ]] && continue

    printf '%s' "$candidate"
    return 0
  done

  print_error "No comma-free temporary directory is available for Docker mount aliases"
  return 1
}

docker_bind_mount_source_alias() {
  local source_path="$1"
  local alias_base alias_root source_hash alias_path

  alias_base=$(docker_bind_mount_alias_base_dir) || return 1
  alias_root="$alias_base/kvs-conversion-server-mounts-$(id -u)"
  mkdir -p "$alias_root"
  chmod 700 "$alias_root"

  if command_exists sha256sum; then
    source_hash=$(printf '%s' "$source_path" | sha256sum | awk '{print $1}')
  else
    source_hash=$(printf '%s' "$source_path" | cksum | awk '{print $1 "-" $2}')
  fi

  alias_path="$alias_root/$source_hash"
  if [[ -e "$alias_path" && ! -L "$alias_path" ]]; then
    print_error "Docker mount alias path already exists and is not a symlink: $alias_path"
    return 1
  fi

  ln -sfn "$source_path" "$alias_path"
  printf '%s' "$alias_path"
}

prepare_data_directory() {
  local data_dir="$1"

  mkdir -p "$data_dir"
}

required_host_ports_for_mode() {
  if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
    echo "990"
  else
    echo "21"
  fi

  seq 21100 21110
}

container_published_host_ports() {
  if ! container_exists; then
    return 0
  fi

  docker inspect --format='{{range $containerPort, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostPort}}{{"\n"}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true
}

container_publishes_host_port() {
  local port="$1"

  container_published_host_ports | grep -Fxq "$port"
}

mask_secret() {
  printf '********'
}

write_config_var() {
  local name="$1"
  local value="$2"

  printf '%s=%q\n' "$name" "$value"
}

decode_ansi_c_config_value() {
  local raw="$1"
  local value=""
  local index char next sequence decoded_escape

  for ((index = 0; index < ${#raw}; index++)); do
    char="${raw:index:1}"
    if [[ "$char" != "\\" ]]; then
      value+="$char"
      continue
    fi

    ((index++))
    if ((index >= ${#raw})); then
      print_error "Invalid trailing escape in configuration value"
      return 1
    fi

    next="${raw:index:1}"
    case "$next" in
      a)
        value+=$'\a'
        ;;
      b)
        value+=$'\b'
        ;;
      e|E)
        value+=$'\e'
        ;;
      f)
        value+=$'\f'
        ;;
      n)
        value+=$'\n'
        ;;
      r)
        value+=$'\r'
        ;;
      t)
        value+=$'\t'
        ;;
      v)
        value+=$'\v'
        ;;
      "\\"|"'"|'"'|\?)
        value+="$next"
        ;;
      [0-7])
        sequence="$next"
        while ((index + 1 < ${#raw} && ${#sequence} < 3)); do
          next="${raw:index + 1:1}"
          [[ "$next" =~ ^[0-7]$ ]] || break
          sequence+="$next"
          ((index++))
        done
        printf -v decoded_escape '%b' "\\$sequence"
        value+="$decoded_escape"
        ;;
      x)
        sequence=""
        while ((index + 1 < ${#raw} && ${#sequence} < 2)); do
          next="${raw:index + 1:1}"
          [[ "$next" =~ ^[0-9A-Fa-f]$ ]] || break
          sequence+="$next"
          ((index++))
        done
        if [[ -z "$sequence" ]]; then
          value+="x"
        else
          printf -v decoded_escape '%b' "\\x$sequence"
          value+="$decoded_escape"
        fi
        ;;
      u|U)
        local width
        width=4
        if [[ "$next" == "U" ]]; then
          width=8
        fi

        sequence=""
        while ((index + 1 < ${#raw} && ${#sequence} < width)); do
          char="${raw:index + 1:1}"
          [[ "$char" =~ ^[0-9A-Fa-f]$ ]] || break
          sequence+="$char"
          ((index++))
        done
        if [[ ${#sequence} -ne "$width" ]]; then
          print_error "Invalid Unicode escape in configuration value"
          return 1
        fi
        printf -v decoded_escape '%b' "\\$next$sequence"
        value+="$decoded_escape"
        ;;
      *)
        value+="$next"
        ;;
    esac
  done

  CONFIG_DECODED_VALUE="$value"
}

decode_config_value() {
  local raw="$1"
  local value=""
  local index char next

  if [[ "$raw" == "\$'"*"'" ]]; then
    decode_ansi_c_config_value "${raw:2:${#raw}-3}"
    return $?
  fi

  if [[ "$raw" == "'"* ]]; then
    if [[ ${#raw} -lt 2 || "$raw" != *"'" ]]; then
      print_error "Invalid single-quoted configuration value"
      return 1
    fi

    value="${raw:1:${#raw}-2}"
    if [[ "$value" == *"'"* ]]; then
      print_error "Invalid single-quoted configuration value"
      return 1
    fi

    CONFIG_DECODED_VALUE="$value"
    return 0
  fi

  if [[ "$raw" == '"'* ]]; then
    if [[ ${#raw} -lt 2 || "$raw" != *'"' ]]; then
      print_error "Invalid double-quoted configuration value"
      return 1
    fi

    raw="${raw:1:${#raw}-2}"
    for ((index = 0; index < ${#raw}; index++)); do
      char="${raw:index:1}"
      if [[ "$char" == "\\" ]]; then
        ((index++))
        if ((index >= ${#raw})); then
          print_error "Invalid trailing escape in double-quoted configuration value"
          return 1
        fi
        next="${raw:index:1}"
        if [[ "$next" == '$' || "$next" == '`' || "$next" == '"' || "$next" == "\\" ]]; then
          value+="$next"
        else
          value+="\\$next"
        fi
      else
        value+="$char"
      fi
    done

    CONFIG_DECODED_VALUE="$value"
    return 0
  fi

  for ((index = 0; index < ${#raw}; index++)); do
    char="${raw:index:1}"
    if [[ "$char" == "\\" ]]; then
      ((index++))
      if ((index >= ${#raw})); then
        print_error "Invalid trailing escape in configuration value"
        return 1
      fi
      next="${raw:index:1}"
      value+="$next"
    else
      value+="$char"
    fi
  done

  CONFIG_DECODED_VALUE="$value"
}

assign_config_value() {
  local key="$1"
  local value="$2"

  case "$key" in
    PHP_VERSION)
      PHP_VERSION="$value"
      ;;
    FTP_MODE)
      FTP_MODE="$value"
      ;;
    FTP_USER)
      FTP_USER="$value"
      ;;
    FTP_PASS)
      FTP_PASS="$value"
      ;;
    IPV4_ADDRESS)
      IPV4_ADDRESS="$value"
      ;;
    NETWORK_INTERFACE)
      NETWORK_INTERFACE="$value"
      ;;
    NUM_FOLDERS)
      NUM_FOLDERS="$value"
      ;;
    CPU_LIMIT)
      CPU_LIMIT="$value"
      ;;
    IMAGE_TAG)
      IMAGE_TAG="$value"
      ;;
    CONTAINER_NAME)
      CONTAINER_NAME="$value"
      ;;
    *)
      print_error "Unsupported configuration key: $key"
      return 1
      ;;
  esac
}

is_supported_config_key() {
  case "$1" in
    PHP_VERSION|FTP_MODE|FTP_USER|FTP_PASS|IPV4_ADDRESS|NETWORK_INTERFACE|NUM_FOLDERS|CPU_LIMIT|IMAGE_TAG|CONTAINER_NAME)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_config_file() {
  local config_file="$1"
  local unknown_key_mode="${2:-reject_unknown}"
  local line line_number=0 key raw_value

  PHP_VERSION=""
  FTP_MODE=""
  FTP_USER=""
  FTP_PASS=""
  IPV4_ADDRESS=""
  NETWORK_INTERFACE=""
  NUM_FOLDERS=""
  CPU_LIMIT=""
  IMAGE_TAG=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number++))

    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ ! "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      print_error "Invalid configuration line $line_number in $config_file"
      return 1
    fi

    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"

    if ! is_supported_config_key "$key"; then
      if [[ "$unknown_key_mode" == "allow_unknown" ]]; then
        continue
      fi
      print_error "Unsupported configuration key: $key"
      print_error "Invalid configuration key on line $line_number in $config_file"
      return 1
    fi

    if ! decode_config_value "$raw_value"; then
      print_error "Invalid configuration value for $key on line $line_number in $config_file"
      return 1
    fi

    if ! assign_config_value "$key" "$CONFIG_DECODED_VALUE"; then
      print_error "Invalid configuration key on line $line_number in $config_file"
      return 1
    fi
  done < "$config_file"
}

read_management_config_file() {
  local config_file="$1"
  local line line_number=0 key raw_value

  IMAGE_TAG="$DEFAULT_IMAGE_TAG"

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number++))

    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ ! "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      if [[ "$line" =~ ^[[:space:]]*CONTAINER_NAME([^A-Z0-9_]|$) ]]; then
        print_error "Invalid container name configuration line $line_number in $config_file"
        return 1
      fi
      echo "${YELLOW}[WARNING]${RESET} Ignoring invalid configuration line $line_number in $config_file for management command" >&2
      continue
    fi

    key="${BASH_REMATCH[1]}"
    raw_value="${BASH_REMATCH[2]}"

    case "$key" in
      CONTAINER_NAME)
        if ! decode_config_value "$raw_value"; then
          print_error "Invalid configuration value for $key on line $line_number in $config_file"
          return 1
        fi
        CONTAINER_NAME="$CONFIG_DECODED_VALUE"
        ;;
      IMAGE_TAG)
        # Management commands can stop, inspect, or remove a container even if
        # unrelated operational settings in the config are no longer parseable.
        IMAGE_TAG="$raw_value"
        ;;
    esac
  done < "$config_file"
}

shell_quote() {
  local value="$1"

  printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Find config file (explicit KVS_CONFIG first, then current dir and parent dirs)
find_config_file_from_dir() {
  local dir="$1"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$CONFIG_FILE" ]]; then
      readlink -f -- "$dir/$CONFIG_FILE"
      return 0
    fi
    dir=$(dirname "$dir")
  done

  return 1
}

find_config_file() {
  if [[ -n "${KVS_CONFIG:-}" ]]; then
    if [[ -f "$KVS_CONFIG" ]]; then
      readlink -f -- "$KVS_CONFIG"
      return 0
    fi

    return 1
  fi

  local config_file physical_pwd
  if config_file=$(find_config_file_from_dir "$PWD"); then
    printf '%s\n' "$config_file"
    return 0
  fi

  if physical_pwd=$(pwd -P 2>/dev/null) && [[ "$physical_pwd" != "$PWD" ]] \
    && config_file=$(find_config_file_from_dir "$physical_pwd"); then
    printf '%s\n' "$config_file"
    return 0
  fi

  return 1
}

# Load configuration from file
load_config() {
  local cpu_validation_mode="${1:-strict}"
  local validate_tag="${2:-true}"
  local config_file
  config_file=$(find_config_file)

  if [[ -z "$config_file" ]]; then
    echo "${RED}Error: Configuration file not found (.kvs-server.conf)${RESET}"
    echo "Run './kvs-conversion-server.sh' to install first"
    return 1
  fi

  CONFIG_FILE_PATH="$config_file"
  CONFIG_DIR=$(dirname "$config_file")

  if ! read_config_file "$config_file"; then
    return 1
  fi
  IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"

  validate_php_version "${PHP_VERSION:-}"
  validate_ftp_mode "${FTP_MODE:-}"
  validate_ftp_username "${FTP_USER:-}"
  validate_ftp_password "${FTP_PASS:-}"
  validate_ipv4_address "${IPV4_ADDRESS:-}"
  if [[ "$cpu_validation_mode" == "saved_cpu" ]]; then
    validate_saved_cpu_limit "${CPU_LIMIT:-}"
  else
    validate_cpu_limit "${CPU_LIMIT:-}"
  fi
  validate_folder_count "${NUM_FOLDERS:-}"
  if [[ "$validate_tag" == "true" ]]; then
    validate_image_tag "$IMAGE_TAG"
  fi
  validate_container_name "${CONTAINER_NAME:-}"
  return 0
}

load_management_config_if_present() {
  local config_file
  config_file=$(find_config_file || true)

  if [[ -z "$config_file" ]]; then
    if [[ -n "${KVS_CONFIG:-}" ]]; then
      print_error "Configuration file not found: $KVS_CONFIG"
      return 1
    fi
    return 0
  fi

  CONFIG_FILE_PATH="$config_file"
  CONFIG_DIR=$(dirname "$config_file")
  if ! read_management_config_file "$config_file"; then
    return 1
  fi
  validate_container_name "${CONTAINER_NAME:-}"
}

require_management_config() {
  if ! load_management_config_if_present; then
    return 1
  fi

  if [[ -z "$CONFIG_FILE_PATH" ]]; then
    print_error "Configuration file not found (.kvs-server.conf)"
    echo "Run './kvs-conversion-server.sh' to install first"
    return 1
  fi
}

preflight_config_path() {
  local config_path="${1:-.kvs-server.conf}"
  local config_dir

  config_dir=$(dirname -- "$config_path")

  if [[ ! -d "$config_dir" ]]; then
    print_error "Configuration directory does not exist: $config_dir"
    return 1
  fi

  if [[ ! -w "$config_dir" ]]; then
    print_error "Configuration directory is not writable: $config_dir"
    return 1
  fi

  if [[ -e "$config_path" || -L "$config_path" ]]; then
    if [[ -L "$config_path" ]]; then
      print_error "Configuration path must not be a symbolic link: $config_path"
      return 1
    fi

    if [[ ! -f "$config_path" ]]; then
      print_error "Configuration path exists and is not a regular file: $config_path"
      return 1
    fi

    if [[ ! -w "$config_path" ]]; then
      print_error "Configuration file is not writable: $config_path"
      return 1
    fi
  fi
}

# Save configuration to file
save_config() {
  local config_path="${1:-.kvs-server.conf}"
  local php_version="${2:-${PHP_VERSION}}"
  local ftp_mode="${3:-${FTP_MODE}}"
  local ftp_user="${4:-${FTP_USER}}"
  local ftp_pass="${5:-${FTP_PASS}}"
  local ipv4="${6:-${IPV4_ADDRESS}}"
  local network_if="${7:-${NETWORK_INTERFACE}}"
  local folders="${8:-${NUM_FOLDERS}}"
  local cpu="${9:-${CPU_LIMIT}}"
  local image_tag="${10:-${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}}"
  local config_dir config_base temp_config

  config_dir=$(dirname -- "$config_path")
  config_base=$(basename -- "$config_path")
  temp_config=$(mktemp "${config_dir}/.${config_base}.tmp.XXXXXX") || return 1

  if ! {
    echo "# KVS Conversion Server Configuration"
    echo "# Generated on $(date)"
    write_config_var "PHP_VERSION" "$php_version"
    write_config_var "FTP_MODE" "$ftp_mode"
    write_config_var "FTP_USER" "$ftp_user"
    write_config_var "FTP_PASS" "$ftp_pass"
    write_config_var "IPV4_ADDRESS" "$ipv4"
    write_config_var "NETWORK_INTERFACE" "$network_if"
    write_config_var "NUM_FOLDERS" "$folders"
    write_config_var "CPU_LIMIT" "$cpu"
    write_config_var "IMAGE_TAG" "$image_tag"
    write_config_var "CONTAINER_NAME" "$CONTAINER_NAME"
  } > "$temp_config"; then
    rm -f -- "$temp_config"
    return 1
  fi

  if [[ -L "$config_path" ]]; then
    rm -f -- "$temp_config"
    print_error "Configuration path must not be a symbolic link: $config_path"
    return 1
  fi

  if ! chmod 600 "$temp_config"; then
    rm -f -- "$temp_config"
    return 1
  fi
  if ! mv -f -- "$temp_config" "$config_path"; then
    rm -f -- "$temp_config"
    return 1
  fi
  echo "${GREEN}✓ Configuration saved to $config_path${RESET}"
  echo "Keep $config_path private. It contains the FTP password required by KVS."
  echo "To recover it later, read FTP_PASS from $config_path or run the script with 'info --show-password'."
}

# Check if container exists
container_exists() {
  local names
  if ! names=$(docker ps -a --format '{{.Names}}'); then
    print_error "Unable to query Docker containers"
    exit 1
  fi

  grep -Fxq "$CONTAINER_NAME" <<< "$names"
}

# Check if container is running
container_running() {
  local names
  if ! names=$(docker ps --format '{{.Names}}'); then
    print_error "Unable to query Docker containers"
    exit 1
  fi

  grep -Fxq "$CONTAINER_NAME" <<< "$names"
}

container_name_running() {
  local container_name="$1"
  local names

  if ! names=$(docker ps --format '{{.Names}}'); then
    print_error "Unable to query Docker containers"
    exit 1
  fi

  grep -Fxq "$container_name" <<< "$names"
}

info_container_state() {
  local names

  if ! names=$(docker ps --format '{{.Names}}'); then
    print_error "Unable to query Docker containers; showing saved configuration only"
    return 2
  fi

  if grep -Fxq "$CONTAINER_NAME" <<< "$names"; then
    echo "running"
    return 0
  fi

  if ! names=$(docker ps -a --format '{{.Names}}'); then
    print_error "Unable to query Docker containers; showing saved configuration only"
    return 2
  fi

  if grep -Fxq "$CONTAINER_NAME" <<< "$names"; then
    echo "stopped"
  else
    echo "not_created"
  fi
}

require_container_running_after_start() {
  for _ in 1 2 3 4 5; do
    if container_running; then
      return 0
    fi
    sleep 1
  done

  print_error "Docker reported that container '$CONTAINER_NAME' started, but it is not running"
  echo "Check the selected Docker image tag and container logs, then retry." >&2
  return 1
}

container_auto_remove() {
  docker inspect --format='{{.HostConfig.AutoRemove}}' "$CONTAINER_NAME" 2>/dev/null | grep -q '^true$'
}

cleanup_started_container_after_install_failure() {
  print_error "Configuration could not be saved after the container started; stopping '$CONTAINER_NAME' to avoid an unmanaged installation"
  if docker stop "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "Stopped container '$CONTAINER_NAME'"
  else
    print_error "Unable to stop container '$CONTAINER_NAME' automatically"
  fi

  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

wait_for_container_removed() {
  wait_for_named_container_removed "$CONTAINER_NAME"
}

wait_for_named_container_removed() {
  local container_name="$1"
  local names

  for _ in {1..10}; do
    if ! names=$(docker ps -a --format '{{.Names}}'); then
      print_error "Unable to query Docker containers"
      return 1
    fi
    if ! grep -Fxq "$container_name" <<< "$names"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_named_container_running() {
  local container_name="$1"

  for _ in {1..5}; do
    if container_name_running "$container_name"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

remove_stopped_container_for_recreate() {
  if ! container_exists; then
    return 0
  fi

  if container_running; then
    print_error "Cannot remove running container '$CONTAINER_NAME'"
    return 1
  fi

  echo "${BLUE}Removing existing container '$CONTAINER_NAME' before recreating it...${RESET}"
  if ! docker rm "$CONTAINER_NAME"; then
    if wait_for_container_removed; then
      echo "Container removed"
    else
      return 1
    fi
  fi
  echo "${GREEN}✓ Existing container removed successfully${RESET}"
}

cleanup_replacement_start_data() {
  local data_dir="$1"
  local data_mount="$2"
  local image_ref="$3"

  if rm -rf -- "$data_dir" 2>/dev/null; then
    return 0
  fi

  docker run --rm --entrypoint /bin/chown --mount "$data_mount" "$image_ref" -R "$(id -u):$(id -g)" /home/vsftpd >/dev/null 2>&1 || true
  rm -rf -- "$data_dir" 2>/dev/null || true
}

preflight_replacement_start_for_config() {
  local ftp_user="$1"
  local ftp_pass="$2"
  local pasv_address="$3"
  local pasv_interface="$4"
  local folder_count="$5"
  local php_version="$6"
  local ftp_mode="$7"
  local check_data_dir data_mount image_ref check_container run_status
  local -a env_vars

  check_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/kvs-start-check.XXXXXX") || return 1
  data_mount=$(docker_bind_mount_arg "$check_data_dir" "/home/vsftpd") || {
    rm -rf -- "$check_data_dir"
    return 1
  }
  env_vars=(-e FTP_USER="$ftp_user" -e FTP_PASS="$ftp_pass" -e PASV_ADDRESS="$pasv_address" -e PASV_ADDRESS_INTERFACE="$pasv_interface" -e NUM_FOLDERS="$folder_count" -e PHP_VERSION="$php_version" -e FTP_MODE="$ftp_mode")
  image_ref=$(docker_image_ref)
  check_container="${CONTAINER_NAME}-start-check-$$"

  echo "${BLUE}Checking replacement container startup before stopping the existing container...${RESET}"
  set +e
  docker run --rm -d --name "$check_container" --cpus="$CPU_LIMIT" --mount "$data_mount" "${env_vars[@]}" "$image_ref" >/dev/null
  run_status=$?
  set -e

  if ((run_status != 0)); then
    cleanup_replacement_start_data "$check_data_dir" "$data_mount" "$image_ref"
    print_error "Replacement container failed to start. Existing container was left running."
    return "$run_status"
  fi

  if ! wait_for_named_container_running "$check_container"; then
    print_error "Replacement container exited before passing startup check. Existing container was left running."
    docker rm -f "$check_container" >/dev/null 2>&1 || true
    cleanup_replacement_start_data "$check_data_dir" "$data_mount" "$image_ref"
    return 1
  fi

  if ! docker stop "$check_container" >/dev/null; then
    print_error "Unable to stop replacement startup check container. Existing container was left running."
    docker rm -f "$check_container" >/dev/null 2>&1 || true
    cleanup_replacement_start_data "$check_data_dir" "$data_mount" "$image_ref"
    return 1
  fi

  if ! wait_for_named_container_removed "$check_container"; then
    print_error "Replacement startup check container was not removed. Existing container was left running."
    docker rm -f "$check_container" >/dev/null 2>&1 || true
    cleanup_replacement_start_data "$check_data_dir" "$data_mount" "$image_ref"
    return 1
  fi

  cleanup_replacement_start_data "$check_data_dir" "$data_mount" "$image_ref"
  echo "${GREEN}✓ Replacement container startup check passed${RESET}"
}

preflight_replacement_start() {
  preflight_replacement_start_for_config "$FTP_USER" "$FTP_PASS" "$IPV4_ADDRESS" "$NETWORK_INTERFACE" "$NUM_FOLDERS" "$PHP_VERSION" "$FTP_MODE"
}

load_cleanup_image_tag() {
  IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  if ! image_tag_is_valid "$IMAGE_TAG"; then
    print_error "Saved Docker image tag '$IMAGE_TAG' is invalid; using default tag '$DEFAULT_IMAGE_TAG' for data cleanup"
    IMAGE_TAG="$DEFAULT_IMAGE_TAG"
  fi
}

remove_data_directory() {
  local data_dir="$1"
  local image_ref data_mount

  if [[ ! -e "$data_dir" ]]; then
    echo "Data directory not found: $data_dir"
    return 0
  fi

  if rm -rf -- "$data_dir" 2>/dev/null; then
    echo "Data directory removed: $data_dir"
    return 0
  fi

  load_cleanup_image_tag
  image_ref=$(docker_image_ref)
  data_mount=$(docker_bind_mount_arg "$data_dir" "/data")
  echo "${YELLOW}Direct removal failed. Retrying through Docker for container-owned files...${RESET}"
  docker run --rm --entrypoint /bin/chown --mount "$data_mount" "$image_ref" -R "$(id -u):$(id -g)" /data
  rm -rf -- "$data_dir"
  echo "Data directory removed: $data_dir"
}

# Command: status/ps
cmd_status() {
  local container_name_pattern

  if ! reject_unexpected_args "status" "$@"; then
    return 1
  fi

  if ! require_management_config; then
    return 1
  fi

  if ! container_exists; then
    echo "Container '$CONTAINER_NAME' does not exist"
    echo "Run './kvs-conversion-server.sh' to install first"
    return 1
  fi

  echo "${CYAN}${BOLD}=== Container Status ===${RESET}"
  container_name_pattern=$(regex_escape "$CONTAINER_NAME")
  docker ps -a --filter "name=^${container_name_pattern}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

  echo ""
  echo "${CYAN}${BOLD}=== Health Status ===${RESET}"
  local health_status
  health_status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "no healthcheck")
  echo "Health: $health_status"

  if container_running; then
    echo ""
    echo "${CYAN}${BOLD}=== Resource Usage ===${RESET}"
    docker stats "$CONTAINER_NAME" --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
  fi
}

show_status_best_effort() {
  if ! cmd_status; then
    print_error "Unable to display current container status"
  fi
}

# Command: logs
cmd_logs() {
  local arg
  local follow_flag=""

  for arg in "$@"; do
    case "$arg" in
      -f|--follow)
        follow_flag="-f"
        ;;
      *)
        print_error "Unknown option for logs: $arg"
        echo "Run '$0 --help' for usage information"
        return 1
        ;;
    esac
  done

  if ! require_management_config; then
    return 1
  fi

  if ! container_exists; then
    echo "${RED}Error: Container '$CONTAINER_NAME' does not exist${RESET}"
    return 1
  fi

  # shellcheck disable=SC2086
  docker logs $follow_flag "$CONTAINER_NAME"
}

# Command: start/up
cmd_start() {
  if ! reject_unexpected_args "start" "$@"; then
    return 1
  fi

  if ! require_management_config; then
    return 1
  fi

  if container_running; then
    echo "${BLUE}[INFO]${RESET} Container '$CONTAINER_NAME' is already running"
    show_status_best_effort
    return 0
  fi

  if container_exists; then
    echo "${YELLOW}[WARNING]${RESET} Container exists but is stopped. Recreating from saved configuration..."
  else
    echo "${YELLOW}[WARNING]${RESET} Container doesn't exist. Recreating from configuration..."
  fi

  if ! load_config; then
    return 1
  fi

  if container_exists; then
    preflight_replacement_ports
    preflight_replacement_start
    remove_stopped_container_for_recreate
  fi

  local host_dir port_mapping data_mount
  host_dir="${CONFIG_DIR:-$PWD}"
  prepare_data_directory "${host_dir}/data"
  data_mount=$(docker_bind_mount_arg "${host_dir}/data" "/home/vsftpd")

  # Determine port mapping based on FTP_MODE
  if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
    port_mapping="-p 990:990"
  else
    port_mapping="-p 21:21"
  fi

  local image_ref container_id
  image_ref=$(docker_image_ref)

  echo "${BLUE}Creating and starting container with saved configuration...${RESET}"
  # shellcheck disable=SC2086
  container_id=$(docker run --rm -d --name "$CONTAINER_NAME" --cpus="$CPU_LIMIT" --mount "$data_mount" -e FTP_USER="$FTP_USER" -e FTP_PASS="$FTP_PASS" -e PASV_ADDRESS="$IPV4_ADDRESS" -e PASV_ADDRESS_INTERFACE="$NETWORK_INTERFACE" -e NUM_FOLDERS="$NUM_FOLDERS" -e PHP_VERSION="$PHP_VERSION" -e FTP_MODE="$FTP_MODE" $port_mapping -p 21100-21110:21100-21110 "$image_ref")
  echo "$container_id"
  require_container_running_after_start

  echo "${GREEN}✓ Container created and started successfully${RESET}"
  show_status_best_effort
}

# Command: stop/down
cmd_stop() {
  if ! reject_unexpected_args "stop" "$@"; then
    return 1
  fi

  if ! require_management_config; then
    return 1
  fi

  if ! container_running; then
    echo "${BLUE}[INFO]${RESET} Container '$CONTAINER_NAME' is not running"
    return 0
  fi

  local was_auto_remove=false
  if container_auto_remove; then
    was_auto_remove=true
  fi

  echo "${BLUE}Stopping container '$CONTAINER_NAME'...${RESET}"
  if ! docker stop "$CONTAINER_NAME"; then
    return 1
  fi
  if [[ "$was_auto_remove" == true ]] && ! wait_for_container_removed; then
    return 1
  fi
  echo "${GREEN}✓ Container stopped successfully${RESET}"
}

# Command: restart
cmd_restart() {
  if ! reject_unexpected_args "restart" "$@"; then
    return 1
  fi

  if ! require_management_config; then
    return 1
  fi

  if ! load_config; then
    return 1
  fi

  if ! container_exists; then
    echo "${RED}Error: Container '$CONTAINER_NAME' does not exist${RESET}"
    return 1
  fi

  if ! container_running; then
    cmd_start
    return $?
  fi

  echo "${BLUE}Restarting container '$CONTAINER_NAME' from saved configuration...${RESET}"
  preflight_replacement_ports
  preflight_replacement_start
  if ! cmd_stop; then
    return 1
  fi
  cmd_start
}

# Command: info
cmd_info() {
  local arg show_password=false container_state

  for arg in "$@"; do
    case "$arg" in
      --show-password)
        show_password=true
        ;;
      *)
        print_error "Unknown option for info: $arg"
        echo "Run '$0 --help' for usage information"
        return 1
        ;;
    esac
  done

  if ! load_config saved_cpu false; then
    return 1
  fi

  echo "${CYAN}${BOLD}=== KVS Conversion Server Configuration ===${RESET}"
  echo ""
  echo "Container:"
  echo "  Name: $CONTAINER_NAME"
  if ! container_state=$(info_container_state); then
    container_state="unknown"
  fi
  case "$container_state" in
    running)
      echo "  Status: Running"
      ;;
    stopped)
      echo "  Status: Stopped"
      ;;
    not_created)
      echo "  Status: Not created"
      ;;
    *)
      echo "  Status: Unknown (Docker unavailable)"
      ;;
  esac

  echo ""
  echo "Configuration:"
  echo "  PHP Version: $PHP_VERSION"
  echo "  FTP Mode: $FTP_MODE"
  echo "  FTP Host: $IPV4_ADDRESS"
  echo "  FTP User: $FTP_USER"
  if [[ "$show_password" == true ]]; then
    echo "  FTP Password: $FTP_PASS"
  else
    echo "  FTP Password: $(mask_secret) (stored in $CONFIG_FILE_PATH; use info --show-password to reveal)"
  fi
  echo "  Network Interface: $NETWORK_INTERFACE"
  echo "  CPU Limit: $CPU_LIMIT cores"
  echo "  Folders: $NUM_FOLDERS"
  echo "  Docker Image: $(docker_image_ref)"

  if [[ "$container_state" == "running" ]]; then
    echo ""
    echo "${CYAN}${BOLD}=== Live Container Info ===${RESET}"
    local container_ip
    local uptime
    if container_ip=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME") \
      && uptime=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER_NAME"); then
      echo "  Container IP: $container_ip"
      echo "  Started: $uptime"
    else
      print_error "Unable to inspect running container; live details skipped"
    fi
  fi

  echo ""
  echo "Config file: ${CONFIG_FILE_PATH:-$(find_config_file || echo 'not found')}"
}

# Command: update
cmd_update() {
  if ! reject_unexpected_args "update" "$@"; then
    return 1
  fi

  if ! load_config; then
    return 1
  fi

  echo "${CYAN}${BOLD}=== Updating KVS Conversion Server ===${RESET}"
  echo ""
  local image_ref restart_choice restart_after_pull
  image_ref=$(docker_image_ref)
  restart_choice=""
  restart_after_pull=false

  if container_running && [[ "$HEADLESS_MODE" != "true" ]]; then
    echo ""
    if ! read -rp "Container is running. Restart with new image after pull? (yes/no): " restart_choice; then
      print_error "Unable to read restart choice. Re-run with --headless or provide yes/no on stdin."
      return 1
    fi

    case "$restart_choice" in
      [Yy]*)
        restart_after_pull=true
        ;;
    esac
  fi

  echo "${BLUE}Pulling Docker image ${image_ref}...${RESET}"
  docker pull "$image_ref"

  if container_running; then
    echo ""
    if [[ "$HEADLESS_MODE" == "true" ]]; then
      echo "Headless mode: Restarting container with new image..."
      prepare_data_directory "${CONFIG_DIR}/data"
      preflight_replacement_ports
      preflight_replacement_start
      cmd_stop
      remove_stopped_container_for_recreate
      cmd_start
      echo "Update completed and container restarted"
    else
      if [[ "$restart_after_pull" == "true" ]]; then
        prepare_data_directory "${CONFIG_DIR}/data"
        preflight_replacement_ports
        preflight_replacement_start
        cmd_stop
        remove_stopped_container_for_recreate
        cmd_start
        echo "Update completed and container restarted"
      else
        echo "Update completed. Stop and start the container to recreate it with the new image."
      fi
    fi
  elif container_exists; then
    preflight_replacement_ports
    preflight_replacement_start
    remove_stopped_container_for_recreate
    echo "Update completed. Start container to use new image."
  else
    echo "Update completed. Start container to use new image."
  fi
}

# Command: remove
cmd_remove() {
  local config_file config_dir data_dir confirm remove_data remove_config

  if ! reject_unexpected_args "remove" "$@"; then
    return 1
  fi

  if ! require_management_config; then
    return 1
  fi

  config_file="$CONFIG_FILE_PATH"
  config_dir="$CONFIG_DIR"
  data_dir="$config_dir/data"

  echo "${YELLOW}${BOLD}WARNING: This will remove the container and can optionally remove local data/config files!${RESET}"
  if [[ "$HEADLESS_MODE" == "true" ]]; then
    if [[ "${KVS_CONFIRM_REMOVE:-false}" != "true" ]]; then
      print_error "Headless remove requires KVS_CONFIRM_REMOVE=true before removing anything"
      return 1
    fi
    confirm=yes
  else
    read -rp "Are you sure you want to continue? (yes/no): " confirm
  fi

  case "$confirm" in
    [Yy][Ee][Ss])
      if [[ "$HEADLESS_MODE" == "true" ]]; then
        remove_data="${KVS_REMOVE_DATA:-false}"
        remove_config="${KVS_REMOVE_CONFIG:-false}"
      else
        if ! read -rp "Also remove data directory ($data_dir)? (yes/no): " remove_data; then
          print_error "Remove cancelled because input ended before choosing whether to remove the data directory"
          return 1
        fi
        if ! read -rp "Remove configuration file? (yes/no): " remove_config; then
          print_error "Remove cancelled because input ended before choosing whether to remove the configuration file"
          return 1
        fi
      fi

      if container_running; then
        cmd_stop
      fi

      if container_exists; then
        echo "${BLUE}Removing container...${RESET}"
        if ! docker rm "$CONTAINER_NAME"; then
          if wait_for_container_removed; then
            echo "Container removed"
          else
            return 1
          fi
        fi
      fi

      if is_affirmative "$remove_data"; then
        remove_data_directory "$data_dir"
      elif [[ "$HEADLESS_MODE" == "true" ]]; then
        echo "Headless mode: Keeping data directory: $data_dir"
      fi

      if is_affirmative "$remove_config"; then
        if [[ -n "$config_file" ]]; then
          rm -f -- "$config_file"
          echo "Configuration file removed: $config_file"
        else
          echo "Configuration file not found"
        fi
      elif [[ "$HEADLESS_MODE" == "true" ]]; then
        echo "Headless mode: Keeping configuration file: $config_file"
      fi

      echo "${GREEN}✓ Cleanup completed${RESET}"
      ;;
    *)
      echo "Removal cancelled"
      return 1
      ;;
  esac
}

# Route commands
route_command() {
  local command="$1"
  shift

  case "$command" in
    status|ps)
      cmd_status "$@"
      ;;
    logs)
      cmd_logs "$@"
      ;;
    start|up)
      cmd_start "$@"
      ;;
    stop|down)
      cmd_stop "$@"
      ;;
    restart)
      cmd_restart "$@"
      ;;
    info)
      cmd_info "$@"
      ;;
    update)
      cmd_update "$@"
      ;;
    remove|rm)
      cmd_remove "$@"
      ;;
    *)
      echo "${RED}Error: Unknown command '$command'${RESET}"
      echo "Run '$0 --help' to see available commands"
      return 1
      ;;
  esac
}

show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS|COMMAND]

KVS Conversion Server installation script with optional headless mode.

INSTALLATION OPTIONS:
  --headless              Enable non-interactive headless mode
  --php-version VERSION   PHP version ($(format_supported_php_versions), default: $DEFAULT_PHP_VERSION)
  --ftp-mode MODE         FTP mode ($(format_supported_ftp_modes), default: ftp)
  --ipv4 ADDRESS          IPv4 address (default: auto-detect)
  --cpu-limit CORES       CPU core limit (default: all cores)
  --ftp-user USERNAME     FTP username (default: user)
  --ftp-pass PASSWORD     FTP password (default: auto-generated)
  --num-folders NUMBER    Number of FTP folders (1-$MAX_NUM_FOLDERS, default: $DEFAULT_NUM_FOLDERS)
  --image-tag TAG         Docker image tag (default: $DEFAULT_IMAGE_TAG)
  --auto-stop-container   Auto-stop and replace existing container (default: no)
  -h, --help              Show this help message

MANAGEMENT COMMANDS:
  status, ps              Show container status and resource usage
  logs [-f|--follow]      Show container logs (use -f to follow)
  start, up               Start the container
  stop, down              Stop the container
  restart                 Restart the container
  info [--show-password] Show configuration and container info
  update                  Pull the configured Docker image tag
  remove, rm              Remove container and optionally data/config

INSTALLATION EXAMPLES:
  # Interactive mode (default)
  $0

  # Headless mode with defaults
  $0 --headless

  # Headless mode with custom configuration
  $0 --headless --php-version $DEFAULT_PHP_VERSION --ftp-user myuser --image-tag $DEFAULT_IMAGE_TAG

  # Using environment variables
  export KVS_HEADLESS=true
  export KVS_FTP_USER=myuser
  $0

MANAGEMENT EXAMPLES:
  # Check container status
  $0 status

  # View logs in real-time
  $0 logs -f

  # Stop and start container
  $0 stop
  $0 start

ENVIRONMENT VARIABLES:
  KVS_HEADLESS            Enable headless mode (true/false)
  KVS_PHP_VERSION         PHP version ($(format_supported_php_versions))
  KVS_FTP_MODE            FTP mode ($(format_supported_ftp_modes))
  KVS_IPV4_ADDRESS        IPv4 address
  KVS_CPU_LIMIT           CPU core limit
  KVS_FTP_USER            FTP username
  KVS_FTP_PASS            FTP password
  KVS_NUM_FOLDERS         Number of FTP folders (1-$MAX_NUM_FOLDERS)
  KVS_IMAGE_TAG           Docker image tag
  KVS_AUTO_STOP_CONTAINER Auto-stop and replace existing container (true/false)
  KVS_CONFIRM_REMOVE      Confirm headless remove before deleting anything (true/false)
  KVS_REMOVE_DATA         Remove data directory during confirmed headless remove (true/false)
  KVS_REMOVE_CONFIG       Remove config file during confirmed headless remove (true/false)

Note: CLI arguments take precedence over environment variables.

EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --headless)
        HEADLESS_MODE=true
        shift
        ;;
      --php-version)
        require_option_value "$1" "${2-}"
        KVS_PHP_VERSION="$2"
        shift 2
        ;;
      --ftp-mode)
        require_option_value "$1" "${2-}"
        KVS_FTP_MODE="$2"
        shift 2
        ;;
      --ipv4)
        require_option_value "$1" "${2-}"
        KVS_IPV4_ADDRESS="$2"
        shift 2
        ;;
      --cpu-limit)
        require_option_value "$1" "${2-}"
        KVS_CPU_LIMIT="$2"
        shift 2
        ;;
      --ftp-user)
        require_option_value "$1" "${2-}"
        KVS_FTP_USER="$2"
        shift 2
        ;;
      --ftp-pass)
        require_option_value "$1" "${2-}"
        KVS_FTP_PASS="$2"
        shift 2
        ;;
      --ftp-pass=*)
        KVS_FTP_PASS="${1#*=}"
        if [[ -z "$KVS_FTP_PASS" ]]; then
          print_error "Option '--ftp-pass' requires a value"
          exit 1
        fi
        shift
        ;;
      --num-folders)
        require_option_value "$1" "${2-}"
        KVS_NUM_FOLDERS="$2"
        shift 2
        ;;
      --image-tag)
        require_option_value "$1" "${2-}"
        KVS_IMAGE_TAG="$2"
        shift 2
        ;;
      --auto-stop-container)
        KVS_AUTO_STOP_CONTAINER=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        echo "${RED}Error: Unknown option: $1${RESET}"
        echo ""
        show_usage
        exit 1
        ;;
    esac
  done

  apply_headless_env
}

check_os_compatibility() {
  local os_type
  os_type=$(uname -s)
  if [[ "$os_type" == "CYGWIN"* || "$os_type" == "MINGW"* || "$os_type" == "MSYS"* ]]; then
    echo "${YELLOW}${BOLD}Warning: You are running this script on a Windows system. This script is not fully compatible with Windows environments.${RESET}"

    if [[ "$HEADLESS_MODE" == "true" ]]; then
      echo "Headless mode: Proceeding with installation..."
    else
      read -rp "Do you wish to continue anyway? (yes/no): " response
      case "$response" in
      [Yy]*) echo "Proceeding with installation..." ;;
      [Nn]*)
        echo "Exiting installation as per user request."
        exit 1
        ;;
      *)
        echo "Invalid input. Please answer yes (y) or no (n)."
        exit 1
        ;;
      esac
    fi
  fi
}

install_docker() {
  local installer

  if ! command_exists docker; then
    echo -e "${RED}Docker is not installed \xE2\x9D\x8C${RESET}"
    echo "${BLUE}Installing Docker...${RESET}"
    installer=$(mktemp "${TMPDIR:-/tmp}/kvs-install-docker.XXXXXX")
    if ! curl -fsSL https://get.docker.com -o "$installer"; then
      rm -f -- "$installer"
      return 1
    fi
    if ! sh "$installer"; then
      rm -f -- "$installer"
      return 1
    fi
    rm -f -- "$installer"
    echo -e "${GREEN}Docker has been installed \xE2\x9C\x85${RESET}"
  else
    echo -e "${GREEN}Docker is already installed \xE2\x9C\x85${RESET}"
  fi
}

download_management_script() {
  local target="$1"
  local url
  local -a urls=()

  if [[ -n "${KVS_SCRIPT_DOWNLOAD_URL:-}" ]]; then
    urls+=("$KVS_SCRIPT_DOWNLOAD_URL")
  else
    urls+=("https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/v${DEFAULT_IMAGE_TAG}/${MANAGEMENT_SCRIPT_NAME}")
    urls+=("https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/main/${MANAGEMENT_SCRIPT_NAME}")
  fi

  if ! command_exists curl; then
    print_error "Cannot create local management script because curl is not available"
    return 1
  fi

  for url in "${urls[@]}"; do
    if curl -fsSL "$url" -o "$target" 2>/dev/null; then
      return 0
    fi
  done

  print_error "Unable to download local management script"
  return 1
}

install_management_script() {
  local destination="./${MANAGEMENT_SCRIPT_NAME}"
  local script_source="${BASH_SOURCE[0]}"
  local tmp_file

  if [[ -e "$destination" && -n "$script_source" && -e "$script_source" && "$script_source" -ef "$destination" ]]; then
    return 0
  fi

  if [[ -L "$destination" ]]; then
    print_error "Management script path must not be a symbolic link: $destination"
    return 1
  fi

  if [[ -e "$destination" && ! -f "$destination" ]]; then
    print_error "Management script path must be a regular file: $destination"
    return 1
  fi

  tmp_file=$(mktemp ".${MANAGEMENT_SCRIPT_NAME}.XXXXXX")

  if [[ -n "$script_source" && -f "$script_source" && -r "$script_source" && -s "$script_source" ]]; then
    cp -- "$script_source" "$tmp_file"
  elif ! download_management_script "$tmp_file"; then
    rm -f -- "$tmp_file"
    return 1
  fi

  if ! grep -Fq "KVS Conversion Server" "$tmp_file" || ! grep -Fq "DEFAULT_IMAGE_TAG=" "$tmp_file"; then
    rm -f -- "$tmp_file"
    print_error "Local management script content did not pass validation"
    return 1
  fi

  chmod 700 "$tmp_file"
  mv -f -- "$tmp_file" "$destination"
}

stop_existing_container() {
  local container_id replace_existing=false replacement_start_checked=false was_auto_remove=false
  container_id=$(docker ps -a --format '{{.ID}} {{.Names}}' | awk -v name="$CONTAINER_NAME" '$2 == name { print $1; exit }')
  if [[ -n "$container_id" ]]; then
    echo "${CYAN}A Docker container named '$CONTAINER_NAME' already exists with ID $container_id.${RESET}"

    if container_running && [[ "${KVS_AUTO_STOP_CONTAINER:-false}" == "true" ]]; then
      if container_auto_remove; then
        was_auto_remove=true
      fi
      preflight_replacement_start_for_config "$input_ftp_user" "$input_ftp_pass" "$ipv4_address" "$network_interface" "$num_folders" "$PHP_VERSION" "$FTP_MODE"
      replacement_start_checked=true
      echo "${BLUE}Auto-stopping the existing container...${RESET}"
      docker stop "$CONTAINER_NAME"
      echo "${GREEN}✓ Container has been stopped successfully.${RESET}"
      if [[ "$was_auto_remove" == true ]]; then
        wait_for_container_removed || true
      fi
      replace_existing=true
    elif container_running && [[ "$HEADLESS_MODE" == "true" ]]; then
      print_error "Container name '$CONTAINER_NAME' is already in use. Re-run with --auto-stop-container to replace it in headless mode."
      exit 1
    elif container_running; then
      read -rp "Do you wish to stop and replace this container before proceeding? (yes/no): " stop_response
      case "$stop_response" in
      [Yy]*)
        if container_auto_remove; then
          was_auto_remove=true
        fi
        preflight_replacement_start_for_config "$input_ftp_user" "$input_ftp_pass" "$ipv4_address" "$network_interface" "$num_folders" "$PHP_VERSION" "$FTP_MODE"
        replacement_start_checked=true
        echo "${BLUE}Stopping the existing container...${RESET}"
        docker stop "$CONTAINER_NAME"
        echo "${GREEN}✓ Container has been stopped successfully.${RESET}"
        if [[ "$was_auto_remove" == true ]]; then
          wait_for_container_removed || true
        fi
        replace_existing=true
        ;;
      [Nn]*)
        echo "Installation cancelled because container name '$CONTAINER_NAME' is already in use."
        exit 1
        ;;
      *)
        echo "Invalid input. Please answer yes (y) or no (n). Exiting script."
        exit 1
        ;;
      esac
    fi

    if container_exists; then
      if [[ "$replace_existing" == true || "${KVS_AUTO_STOP_CONTAINER:-false}" == "true" ]]; then
        if [[ "$replacement_start_checked" != true ]]; then
          preflight_replacement_start_for_config "$input_ftp_user" "$input_ftp_pass" "$ipv4_address" "$network_interface" "$num_folders" "$PHP_VERSION" "$FTP_MODE"
        fi
        remove_stopped_container_for_recreate
      elif [[ "$HEADLESS_MODE" == "true" ]]; then
        print_error "Container name '$CONTAINER_NAME' is already in use. Re-run with --auto-stop-container to replace it in headless mode."
        exit 1
      else
        echo "${RED}Container name '$CONTAINER_NAME' is still in use. Remove it with './kvs-conversion-server.sh remove' or rename it before installing.${RESET}"
        exit 1
      fi
    fi
  fi
}

configure_environment() {
  read_php_version
  read_ftp_mode
  set_image_tag
  choose_ipv4_acquisition_mode
  get_ipv4_address
  get_network_interface
  get_cpu_limits
  prompt_ftp_credentials
  prompt_for_directory_number
  validate_configuration
}

validate_configuration() {
  validate_php_version "$PHP_VERSION"
  validate_ftp_mode "$FTP_MODE"
  validate_ipv4_address "$ipv4_address"
  validate_cpu_limit "$CPU_LIMIT"
  validate_ftp_username "$input_ftp_user"
  validate_ftp_password "$input_ftp_pass"
  validate_folder_count "$num_folders"
  validate_image_tag "$IMAGE_TAG"

  formatted_num_folders=$(printf "%02d" "$num_folders")
}

validate_provided_options() {
  if [[ -n "${KVS_PHP_VERSION:-}" ]]; then
    validate_php_version "$KVS_PHP_VERSION"
  fi

  if [[ -n "${KVS_FTP_MODE:-}" ]]; then
    validate_ftp_mode "$KVS_FTP_MODE"
  fi

  if [[ -n "${KVS_IPV4_ADDRESS:-}" ]]; then
    validate_ipv4_address "$KVS_IPV4_ADDRESS"
  fi

  if [[ -n "${KVS_CPU_LIMIT:-}" ]]; then
    validate_cpu_limit "$KVS_CPU_LIMIT"
  fi

  if [[ -n "${KVS_FTP_USER:-}" ]]; then
    validate_ftp_username "$KVS_FTP_USER"
  fi

  if [[ -n "${KVS_FTP_PASS:-}" ]]; then
    validate_ftp_password "$KVS_FTP_PASS"
  fi

  if [[ -n "${KVS_NUM_FOLDERS:-}" ]]; then
    validate_folder_count "$KVS_NUM_FOLDERS"
  fi

  if [[ -n "${KVS_IMAGE_TAG:-}" ]]; then
    validate_image_tag "$KVS_IMAGE_TAG"
  fi
}

set_image_tag() {
  if [[ -n "${KVS_IMAGE_TAG:-}" ]]; then
    IMAGE_TAG="$KVS_IMAGE_TAG"
    echo "Using Docker image tag: $IMAGE_TAG"
  else
    IMAGE_TAG="$DEFAULT_IMAGE_TAG"
    echo "Using default Docker image tag: $IMAGE_TAG"
  fi
}

read_php_version() {
  # Priority: CLI/ENV variable > Headless default > Interactive prompt
  local -a versions
  local default_php_label
  local version_count
  local default_index=1
  local index
  local version
  local label
  local php_version_choice
  local selected_php_label

  read -r -a versions <<< "$SUPPORTED_PHP_VERSIONS"
  version_count=${#versions[@]}
  default_php_label=$(php_version_label "$DEFAULT_PHP_VERSION")
  for index in "${!versions[@]}"; do
    if [[ "${versions[$index]}" == "$DEFAULT_PHP_VERSION" ]]; then
      default_index=$((index + 1))
      break
    fi
  done

  if [[ -n "${KVS_PHP_VERSION:-}" ]]; then
    PHP_VERSION="$KVS_PHP_VERSION"
    echo "Using PHP version: $PHP_VERSION"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    PHP_VERSION="$DEFAULT_PHP_VERSION"
    echo "Headless mode: Using default $default_php_label (suitable for KVS 6.2 or higher)"
  else
    echo "${CYAN}Choose the PHP version to use:${RESET}"
    for index in "${!versions[@]}"; do
      version="${versions[$index]}"
      label="$(php_version_label "$version")"
      if [[ "$version" == "$DEFAULT_PHP_VERSION" ]]; then
        label="$label - Recommended if your KVS version is 6.2 or higher."
      elif ((index == 0)); then
        label="$label - Recommended if your KVS version is below 6.2."
      fi
      echo "${CYAN}$((index + 1)). $label${RESET}"
    done

    read -rp "Enter your choice (1-$version_count, default is $default_index for $default_php_label): " php_version_choice
    if [[ "$php_version_choice" =~ ^[0-9]+$ ]] && ((php_version_choice >= 1 && php_version_choice <= version_count)); then
      PHP_VERSION="${versions[$((php_version_choice - 1))]}"
    else
      PHP_VERSION="$DEFAULT_PHP_VERSION"
    fi

    selected_php_label=$(php_version_label "$PHP_VERSION")
    if [[ "$PHP_VERSION" == "$DEFAULT_PHP_VERSION" ]]; then
      echo "${GREEN}$default_php_label is the default selection, suitable for KVS 6.2 or higher.${RESET}"
    elif [[ "$PHP_VERSION" == "${versions[0]}" ]]; then
      echo "${GREEN}You have selected $selected_php_label, suitable for KVS versions below 6.2.${RESET}"
    else
      echo "${GREEN}You have selected $selected_php_label.${RESET}"
    fi
  fi
}

read_ftp_mode() {
  # Priority: CLI/ENV variable > Headless default > Interactive prompt
  local -a modes
  local mode_count index mode label ftp_mode_choice

  if [[ -n "${KVS_FTP_MODE:-}" ]]; then
    FTP_MODE="$KVS_FTP_MODE"
    echo "Using FTP mode: $FTP_MODE"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    FTP_MODE="ftp"
    echo "Headless mode: Using default FTP mode (no encryption)"
  else
    read -r -a modes <<< "$SUPPORTED_FTP_MODES"
    mode_count=${#modes[@]}

    echo "${CYAN}Choose the FTP mode to use:${RESET}"
    for index in "${!modes[@]}"; do
      mode="${modes[$index]}"
      case "$mode" in
        ftp)
          label="FTP (no encryption) - Standard FTP without SSL/TLS"
          ;;
        ftps)
          label="FTPS Explicit - SSL/TLS encryption via AUTH TLS on port 21 (recommended)"
          ;;
        ftps_implicit)
          label="FTPS Implicit - SSL/TLS from connection start on port 990"
          ;;
        ftps_tls)
          label="FTPS TLS - Alias for explicit FTPS via AUTH TLS on port 21"
          ;;
        *)
          label="$mode"
          ;;
      esac
      echo "${CYAN}$((index + 1)). $label${RESET}"
    done

    read -rp "Enter your choice (1-$mode_count, default is 1 for standard FTP): " ftp_mode_choice
    if [[ "$ftp_mode_choice" =~ ^[0-9]+$ ]] && ((ftp_mode_choice >= 1 && ftp_mode_choice <= mode_count)); then
      FTP_MODE="${modes[$((ftp_mode_choice - 1))]}"
    else
      FTP_MODE="ftp"
    fi

    case "$FTP_MODE" in
    ftps)
      echo "${GREEN}You have selected FTPS Explicit mode (AUTH TLS on port 21).${RESET}"
      echo "${BLUE}SSL certificates will be generated automatically.${RESET}"
      ;;
    ftps_implicit)
      echo "${GREEN}You have selected FTPS Implicit mode (SSL on port 990).${RESET}"
      echo "${BLUE}SSL certificates will be generated automatically.${RESET}"
      echo "${YELLOW}Note: You will need to expose port 990 instead of port 21.${RESET}"
      ;;
    ftps_tls)
      echo "${GREEN}You have selected FTPS TLS mode (AUTH TLS on port 21).${RESET}"
      echo "${BLUE}SSL certificates will be generated automatically.${RESET}"
      ;;
    *)
      echo "${GREEN}Standard FTP mode selected (no encryption).${RESET}"
      ;;
    esac
  fi
}

choose_ipv4_acquisition_mode() {
  # Priority: CLI/ENV variable > Headless auto-detect > Interactive prompt
  if [[ -n "${KVS_IPV4_ADDRESS:-}" ]]; then
    ipv4_mode_choice=2  # Manual mode (from CLI/ENV)
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    ipv4_mode_choice=1  # Auto-detect in headless mode
  else
    echo "Choose the method to acquire an IPv4 address:"
    echo "1. Automatic (detect via Internet)"
    echo "2. Manual (user input)"
    read -rp "Enter your choice (1 or 2, default is 1): " ipv4_mode_choice
    ipv4_mode_choice=${ipv4_mode_choice:-1}
  fi
}

get_ipv4_address() {
  if [[ -n "${KVS_IPV4_ADDRESS:-}" ]]; then
    ipv4_address="$KVS_IPV4_ADDRESS"
    echo "Using IPv4 address: $ipv4_address"
  elif [[ $ipv4_mode_choice == 2 ]]; then
    read -rp "Enter the IPv4 address: " ipv4_address
    echo "Public IPv4 address: $ipv4_address"
  else
    ipv4_address=$(curl -s 'https://api.ipify.org')
    echo "Auto-detected public IPv4 address: $ipv4_address"
  fi
}

get_network_interface() {
  local ip_route_info
  ip_route_info=""

  if command_exists ip; then
    ip_route_info=$(ip route get 1.1.1.1 2>/dev/null || true)
  fi

  network_interface=$(awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<< "$ip_route_info")

  if [ -z "$network_interface" ]; then
    echo "Could not find the primary network interface. Using default 'eth0'."
    network_interface="eth0"
  else
    echo "Primary network interface: $network_interface"
  fi
}

get_cpu_limits() {
  local total_cores
  total_cores=$(host_cpu_count)

  # Priority: CLI/ENV variable > Headless default (all cores) > Interactive prompt
  if [[ -n "${KVS_CPU_LIMIT:-}" ]]; then
    CPU_LIMIT="$KVS_CPU_LIMIT"
    echo "Total CPU cores available: $total_cores"
    echo "Using CPU core limit: $CPU_LIMIT"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    CPU_LIMIT="$total_cores"
    echo "Total CPU cores available: $total_cores"
    echo "Headless mode: Using all available cores ($CPU_LIMIT)"
  else
    echo "Total CPU cores available: $total_cores"
    echo "Do you want to limit CPU usage for the Docker container? (yes/no)"
    read -r -p "Enter your choice (default no, which uses all available cores): " limit_cpu

    case $limit_cpu in
    [Yy] | [Yy][Ee][Ss])
      read -r -p "Enter the number of CPU cores to use (up to $total_cores cores): " cpu_cores
      CPU_LIMIT="$cpu_cores"
      ;;
    [Nn] | [Nn][Oo] | "")
      CPU_LIMIT="$total_cores" # Use all available cores if no limit is specified
      ;;
    esac
  fi
}

prompt_ftp_credentials() {
  # Priority: CLI/ENV variable > Headless defaults > Interactive prompt
  if [[ -n "${KVS_FTP_USER:-}" ]]; then
    input_ftp_user="$KVS_FTP_USER"
    echo "Using FTP username: $input_ftp_user"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    input_ftp_user="user"
    echo "Headless mode: Using default FTP username: $input_ftp_user"
  else
    echo "Please enter FTP configuration details:"
    read -rp "Enter FTP username (leave blank to use default 'user'): " input_ftp_user
    input_ftp_user=${input_ftp_user:-user}
    echo "Using FTP username: $input_ftp_user"
  fi

  if [[ -n "${KVS_FTP_PASS:-}" ]]; then
    input_ftp_pass="$KVS_FTP_PASS"
    echo "Using FTP password from configuration"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    input_ftp_pass=$(openssl rand -base64 12)
    echo "Headless mode: Generated secure FTP password: $input_ftp_pass"
  else
    read -rsp "Enter FTP password (leave blank to generate a secure one): " input_ftp_pass
    echo # New line
    if [ -z "$input_ftp_pass" ]; then
      input_ftp_pass=$(openssl rand -base64 12)
      echo "No password entered. A secure password has been generated for you: $input_ftp_pass"
    else
      echo "Using entered password."
    fi
  fi
}

prompt_for_directory_number() {
  # Priority: CLI/ENV variable > Headless default > Interactive prompt
  if [[ -n "${KVS_NUM_FOLDERS:-}" ]]; then
    num_folders="$KVS_NUM_FOLDERS"
    echo "Using number of folders: $num_folders"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    num_folders="$DEFAULT_NUM_FOLDERS"
    echo "Headless mode: Using default number of folders: $num_folders"
  else
    echo "Please enter the number of FTP directories to create:"
    echo "Each directory corresponds to one instance of use you plan for this server."
    echo "You can only use one directory at a time. Having multiple directories can be useful"
    echo "if you intend to use this server for different KVS installations, or to better utilize CPU power"
    echo "for a single KVS installation."
    echo "If unsure, opt for a higher number of directories since the script does not dynamically support folder creation."
    echo "The site will create directories as needed, but it's crucial that each directory operates under its own cron task."
    echo "Future improvements may automate this part to simplify setup."
    read -rp "Enter the number of folders (default is $DEFAULT_NUM_FOLDERS): " num_folders
    num_folders=${num_folders:-$DEFAULT_NUM_FOLDERS}
  fi
}

pull_docker_image() {
  local image_ref
  image_ref=$(docker_image_ref)

  echo "${BLUE}Pulling the Docker image ${image_ref}...${RESET}"
  docker pull "$image_ref"
}

preflight_replacement_ports() {
  local image_ref check_container port
  local -a port_args=()

  if ! container_exists; then
    return 0
  fi

  while IFS= read -r port; do
    if container_running && container_publishes_host_port "$port"; then
      continue
    fi
    port_args+=(-p "${port}:${port}")
  done < <(required_host_ports_for_mode)

  if ((${#port_args[@]} == 0)); then
    return 0
  fi

  image_ref=$(docker_image_ref)
  check_container="${CONTAINER_NAME}-port-check-$$"

  echo "${BLUE}Checking Docker port availability before replacing the existing container...${RESET}"
  if ! docker run --rm --name "$check_container" "${port_args[@]}" --entrypoint /bin/true "$image_ref"; then
    print_error "Required Docker ports are not available. Existing container was left untouched."
    return 1
  fi
}

run_docker_container() {
  local host_dir data_mount env_vars ftp_port ftp_ssl port_mapping image_ref container_id
  host_dir=$(pwd)
  prepare_data_directory "${host_dir}/data"
  data_mount=$(docker_bind_mount_arg "${host_dir}/data" "/home/vsftpd")

  # Determine FTP port and SSL setting based on mode
  if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
    ftp_port="990"
    ftp_ssl="True"
    port_mapping="-p 990:990"
  else
    ftp_port="21"
    if ftp_mode_requires_ssl "$FTP_MODE"; then
      ftp_ssl="True"
    else
      ftp_ssl="False"
    fi
    port_mapping="-p 21:21"
  fi

  env_vars=(-e FTP_USER="$input_ftp_user" -e FTP_PASS="$input_ftp_pass" -e PASV_ADDRESS="$ipv4_address" -e PASV_ADDRESS_INTERFACE="$network_interface" -e NUM_FOLDERS="$num_folders" -e PHP_VERSION="$PHP_VERSION" -e FTP_MODE="$FTP_MODE")
  image_ref=$(docker_image_ref)

  echo "${BLUE}Running the Docker image in detached mode...${RESET}"
  # shellcheck disable=SC2086
  container_id=$(docker run --rm -d --name "$CONTAINER_NAME" --cpus="$CPU_LIMIT" --mount "$data_mount" "${env_vars[@]}" $port_mapping -p 21100-21110:21100-21110 "$image_ref")
  echo "$container_id"
  require_container_running_after_start
  echo "The Docker container is running with '${host_dir}/data' mounted to '/home/vsftpd' inside the container."
  cat <<EOB
${CYAN}${BOLD}KVS Conversion Server Configuration:${RESET}
${CYAN}------------------------------------${RESET}
  . PHP Version: ${PHP_VERSION}
  . FTP Mode: ${FTP_MODE}
  . Docker Image: ${image_ref}
  . Maximum tasks: ${num_folders}
  . CPU usage: Realtime
  . Optimize Content Copying: Allow Pulling Source Files from Primary Server: true
  . Optimize Content Copying: allow this server to pull source files from primary server: true
  . Connection Type: FTP
  . Force SSL Connection: ${ftp_ssl}
  . FTP Host: ${ipv4_address}
  . FTP Port: ${ftp_port}
  . FTP User: ${input_ftp_user}
  . FTP Password: ${input_ftp_pass}
  . FTP Directory Range: 01 to ${formatted_num_folders} (Each directory is for single-use only)

To add a conversion server, please enter these settings into your website. Note that each FTP directory is designated for single use to ensure isolated processing environments for different tasks or video batches.

For detailed technical logs from the FTP server, use the following command:
  ./kvs-conversion-server.sh logs

To follow logs in real-time:
  ./kvs-conversion-server.sh logs -f

For specific cron task logs from a particular folder, execute:
  docker exec conversion-server tail -f /var/log/cron02.log  # Replace '02' with your folder number

To check the vsftpd logs for FTP activities, use:
  docker exec conversion-server tail -f /var/log/vsftpd/vsftpd.log

If you need to perform debugging or access the container's shell, you can use the following command:
  docker exec -it conversion-server /bin/bash
This will provide interactive shell access to the container, allowing you to execute commands and inspect the container's environment directly.

To manage the container, use the script commands:
  ./kvs-conversion-server.sh status    # Show container status
  ./kvs-conversion-server.sh stop      # Stop the container
  ./kvs-conversion-server.sh start     # Start the container
  ./kvs-conversion-server.sh restart   # Restart the container
  ./kvs-conversion-server.sh info      # Show full configuration

For advanced users who need to recreate the container manually with the same configuration:

  docker run --rm -d \\
  --name conversion-server \\
  --cpus=$(shell_quote "$CPU_LIMIT") \\
  --mount $(shell_quote "$data_mount") \\
  -e FTP_USER=$(shell_quote "$input_ftp_user") \\
  -e FTP_PASS=$(shell_quote "$input_ftp_pass") \\
  -e PASV_ADDRESS=$(shell_quote "$ipv4_address") \\
  -e PASV_ADDRESS_INTERFACE=$(shell_quote "$network_interface") \\
  -e NUM_FOLDERS=$(shell_quote "$num_folders") \\
  -e PHP_VERSION=$(shell_quote "$PHP_VERSION") \\
  -e FTP_MODE=$(shell_quote "$FTP_MODE") \\
  ${port_mapping} -p 21100-21110:21100-21110 \\
  $(shell_quote "$image_ref")

EOB
}

check_port_accessibility() {
  local ftp_port ftp_label

  if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
    ftp_port="990"
    ftp_label="FTPS implicit"
  else
    ftp_port="21"
    ftp_label="FTP/FTPS explicit"
  fi

  echo ""
  echo "${CYAN}${BOLD}========================================"
  echo "Network Port Accessibility Check"
  echo "========================================${RESET}"
  echo ""
  echo "Checking if Docker is listening on required ports..."

  local all_listening=true

  # Check the active control port
  if command_exists ss; then
    if ss -tlnp 2>/dev/null | grep -q ":$ftp_port "; then
      echo "✓ Port $ftp_port ($ftp_label) is listening locally"
    else
      echo "✗ Port $ftp_port ($ftp_label) is NOT listening locally"
      all_listening=false
    fi

    # Check passive mode ports
    echo "Checking passive mode ports (21100-21110)..."
    local pasv_ports_ok=false
    for port in 21100 21105 21110; do
      if ss -tlnp 2>/dev/null | grep -q ":$port "; then
        pasv_ports_ok=true
        break
      fi
    done

    if [[ "$pasv_ports_ok" == true ]]; then
      echo "✓ Passive mode ports (21100-21110) are listening"
    else
      echo "✗ Passive mode ports are NOT listening"
      all_listening=false
    fi
  else
    echo "⚠ Command 'ss' not found, skipping local port check"
  fi

  echo ""
  echo "⚠️  IMPORTANT: External Accessibility Check Required"
  echo ""
  echo "The checks above only verify that Docker is listening locally."
  echo "To verify that ports are accessible from the Internet, you must"
  echo "test from a different computer or network."
  echo ""
  echo "From another computer, run:"
  echo "  telnet $ipv4_address $ftp_port"
  echo "  nc -zv $ipv4_address $ftp_port"
  echo ""
  echo "Or use an online port checker:"
  echo "  https://www.yougetsignal.com/tools/open-ports/"
  echo "  Enter IP: $ipv4_address, Port: $ftp_port"
  echo ""

  if [[ "$all_listening" == false ]]; then
    echo "${YELLOW}⚠️  Warning: Some ports are not listening. Please check container logs:${RESET}"
    echo "${CYAN}  ./kvs-conversion-server.sh logs${RESET}"
    echo ""
  fi

  if [[ "$HEADLESS_MODE" != "true" ]]; then
    read -rp "Press Enter to continue..."
  fi
}

# Main Execution Flow

apply_headless_env

if [[ "${1:-}" == "--headless" ]]; then
  HEADLESS_MODE=true
  shift
fi

# Check if this is a CLI command
if [[ $# -gt 0 ]]; then
  case "$1" in
    status|ps|logs|start|up|stop|down|restart|info|update|remove|rm)
      # Route to CLI command handler
      if command -v route_command > /dev/null 2>&1; then
        route_command "$@"
        exit $?
      else
        echo "Error: CLI functions not available. Make sure cli-functions.sh is present."
        exit 1
      fi
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    --*)
      # Installation with options, continue to parse_arguments
      ;;
    *)
      echo "Error: Unknown command or option '$1'"
      echo "Run '$0 --help' for usage information"
      exit 1
      ;;
  esac
fi

# Installation flow
parse_arguments "$@"
validate_provided_options
preflight_config_path ".kvs-server.conf"
check_os_compatibility
install_docker
configure_environment
pull_docker_image
install_management_script
preflight_replacement_ports
stop_existing_container
run_docker_container

# Save configuration for CLI commands
if command -v save_config > /dev/null 2>&1; then
  if ! save_config ".kvs-server.conf" "$PHP_VERSION" "$FTP_MODE" "$input_ftp_user" "$input_ftp_pass" "$ipv4_address" "$network_interface" "$num_folders" "$CPU_LIMIT" "$IMAGE_TAG"; then
    cleanup_started_container_after_install_failure
    exit 1
  fi
fi

check_port_accessibility
