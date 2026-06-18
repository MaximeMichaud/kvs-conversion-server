#!/usr/bin/env bash

kvs_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

read_script_assignment() {
  local name="$1"
  local script_path
  script_path="$(kvs_repo_root)/kvs-conversion-server.sh"

  awk -v name="$name" '
    index($0, name "=") == 1 {
      value = substr($0, length(name) + 2)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$script_path"
}

read_script_default() {
  local name="$1"
  local value
  local derived_default_php_expression="\${SUPPORTED_PHP_VERSIONS##* }"
  local supported_php_versions

  value=$(read_script_assignment "$name")

  case "$value" in
    "$derived_default_php_expression")
      supported_php_versions=$(read_script_assignment SUPPORTED_PHP_VERSIONS)
      value="${supported_php_versions##* }"
      ;;
  esac

  printf '%s\n' "$value"
}

require_script_default() {
  local name="$1"
  local value
  value=$(read_script_default "$name")

  if [[ -z "$value" ]]; then
    echo "Missing script default: $name" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

format_quoted_or_list() {
  local -a values=("$@")
  local count=${#values[@]}
  local index
  local item
  local output=""

  for index in "${!values[@]}"; do
    item="'${values[$index]}'"
    if ((index == 0)); then
      output="$item"
    elif ((index == count - 1)); then
      output="$output, or $item"
    else
      output="$output, $item"
    fi
  done

  printf '%s' "$output"
}

read_runtime_default() {
  local name="$1"
  local repo_root
  repo_root=$(kvs_repo_root)

  KVS_PROJECT_DEFAULTS_PATH="$repo_root/kvs-conversion-server.sh" bash -c '
    set -e
    source "$1"
    name="$2"
    printf "%s\n" "${!name:-}"
  ' bash "$repo_root/scripts/php-support.sh" "$name"
}

require_runtime_default() {
  local name="$1"
  local value
  value=$(read_runtime_default "$name")

  if [[ -z "$value" ]]; then
    echo "Missing runtime default: $name" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

write_kvs_config() {
  local config_path="$1"
  shift

  local php_version
  local ftp_mode="ftp"
  local ftp_user="testuser"
  local ftp_pass="testpass123"
  local ipv4_address="127.0.0.1"
  local network_interface="eth0"
  local num_folders
  local cpu_limit="1"
  local image_tag
  local container_name="conversion-server"

  php_version=$(require_script_default DEFAULT_PHP_VERSION)
  num_folders=$(require_script_default DEFAULT_NUM_FOLDERS)
  image_tag=$(require_script_default DEFAULT_IMAGE_TAG)

  while (($#)); do
    case "$1" in
      --php-version)
        php_version="$2"
        shift 2
        ;;
      --ftp-mode)
        ftp_mode="$2"
        shift 2
        ;;
      --ftp-user)
        ftp_user="$2"
        shift 2
        ;;
      --ftp-pass)
        ftp_pass="$2"
        shift 2
        ;;
      --ipv4-address)
        ipv4_address="$2"
        shift 2
        ;;
      --network-interface)
        network_interface="$2"
        shift 2
        ;;
      --num-folders)
        num_folders="$2"
        shift 2
        ;;
      --cpu-limit)
        cpu_limit="$2"
        shift 2
        ;;
      --image-tag)
        image_tag="$2"
        shift 2
        ;;
      --container-name)
        container_name="$2"
        shift 2
        ;;
      *)
        echo "Unknown write_kvs_config option: $1" >&2
        return 1
        ;;
    esac
  done

  mkdir -p "$(dirname "$config_path")"
  cat > "$config_path" <<CONFIG
PHP_VERSION=$php_version
FTP_MODE=$ftp_mode
FTP_USER=$ftp_user
FTP_PASS=$ftp_pass
IPV4_ADDRESS=$ipv4_address
NETWORK_INTERFACE=$network_interface
NUM_FOLDERS=$num_folders
CPU_LIMIT=$cpu_limit
IMAGE_TAG=$image_tag
CONTAINER_NAME=$container_name
CONFIG
}

pick_unsupported_php_version() {
  local supported_versions
  local version
  local number
  local major
  local minor
  local max_major=0
  local max_minor=0
  local candidate

  supported_versions=$(require_script_default SUPPORTED_PHP_VERSIONS)

  for version in $supported_versions; do
    number="${version#php}"
    major="${number%%.*}"
    minor="${number#*.}"

    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
      echo "Unsupported PHP version format in project defaults: $version" >&2
      return 1
    fi

    if ((major > max_major || (major == max_major && minor > max_minor))); then
      max_major="$major"
      max_minor="$minor"
    fi
  done

  while true; do
    candidate="php$((max_major + 1)).0"
    if [[ " $supported_versions " != *" $candidate "* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    max_major=$((max_major + 1))
  done
}

read_dockerfile_arg() {
  local name="$1"
  local dockerfile_path
  dockerfile_path="$(kvs_repo_root)/Dockerfile"

  awk -v name="$name" '
    $1 == "ARG" {
      value = $0
      sub(/^[[:space:]]*ARG[[:space:]]+/, "", value)
      if (index(value, name "=") != 1) {
        next
      }
      value = substr(value, length(name) + 2)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$dockerfile_path"
}

require_dockerfile_arg() {
  local name="$1"
  local value
  value=$(read_dockerfile_arg "$name")

  if [[ -z "$value" ]]; then
    echo "Missing Dockerfile ARG: $name" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

read_shell_assignment() {
  local relative_path="$1"
  local name="$2"
  local file_path
  file_path="$(kvs_repo_root)/$relative_path"

  awk -v name="$name" '
    index($0, name "=") == 1 {
      value = substr($0, length(name) + 2)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$file_path"
}

require_shell_assignment() {
  local relative_path="$1"
  local name="$2"
  local value
  value=$(read_shell_assignment "$relative_path" "$name")

  if [[ -z "$value" ]]; then
    echo "Missing shell assignment: $relative_path $name" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

read_env_default() {
  local relative_path="$1"
  local name="$2"
  local file_path
  file_path="$(kvs_repo_root)/$relative_path"

  awk -v name="$name" '
    index($0, name "=${" name ":-") == 1 {
      value = substr($0, length(name "=${" name ":-") + 1)
      sub(/\}.*/, "", value)
      print value
      exit
    }
  ' "$file_path"
}

require_env_default() {
  local relative_path="$1"
  local name="$2"
  local value
  value=$(read_env_default "$relative_path" "$name")

  if [[ -z "$value" ]]; then
    echo "Missing environment default: $relative_path $name" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

read_dockerfile_php_cli_versions() {
  local dockerfile_path
  local package_versions
  local version
  local output=""
  dockerfile_path="$(kvs_repo_root)/Dockerfile"

  package_versions=$(read_dockerfile_arg PHP_PACKAGE_VERSIONS)
  if [[ -n "$package_versions" ]]; then
    for version in $package_versions; do
      output="${output:+$output }php$version"
    done
    printf '%s\n' "$output"
    return 0
  fi

  if grep -Fq "SUPPORTED_PHP_VERSIONS" "$dockerfile_path" \
    && grep -Fq "kvs-conversion-server.sh /usr/local/lib/kvs/kvs-conversion-server.sh" "$dockerfile_path"; then
    require_script_default SUPPORTED_PHP_VERSIONS
    return 0
  fi

  awk '
    match($0, /php[0-9]+\.[0-9]+-cli/) {
      version = substr($0, RSTART, RLENGTH - 4)
      if (!seen[version]++) {
        versions = versions " " version
      }
    }
    END {
      sub(/^ /, "", versions)
      print versions
    }
  ' "$dockerfile_path"
}
