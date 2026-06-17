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
IMAGE_REPOSITORY="maximemichaud/kvs-conversion-server"
DEFAULT_IMAGE_TAG="1.3.0"
IMAGE_TAG="$DEFAULT_IMAGE_TAG"

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

validate_php_version() {
  local value="$1"
  if [[ ! "$value" =~ ^(php7\.4|php8\.1)$ ]]; then
    print_error "PHP version must be 'php7.4' or 'php8.1'"
    exit 1
  fi
}

validate_ftp_mode() {
  local value="$1"
  if [[ ! "$value" =~ ^(ftp|ftps|ftps_implicit)$ ]]; then
    print_error "FTP mode must be 'ftp', 'ftps', or 'ftps_implicit'"
    exit 1
  fi
}

validate_ipv4_address() {
  local value="$1"
  local octet
  local -a octets

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
  done
}

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    print_error "$name must be a positive integer"
    exit 1
  fi
}

validate_cpu_limit() {
  local value="$1"

  if [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
    print_error "CPU limit must be a positive number"
    exit 1
  fi
}

validate_image_tag() {
  local value="$1"

  if [[ ! "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    print_error "Docker image tag contains invalid characters"
    exit 1
  fi
}

docker_image_ref() {
  printf '%s:%s' "$IMAGE_REPOSITORY" "$IMAGE_TAG"
}

mask_secret() {
  printf '********'
}

write_config_var() {
  local name="$1"
  local value="$2"

  printf '%s=%q\n' "$name" "$value"
}

# Find config file (explicit KVS_CONFIG first, then current dir and parent dirs)
find_config_file() {
  if [[ -n "${KVS_CONFIG:-}" ]]; then
    if [[ -f "$KVS_CONFIG" ]]; then
      echo "$KVS_CONFIG"
      return 0
    fi

    return 1
  fi

  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$CONFIG_FILE" ]]; then
      echo "$dir/$CONFIG_FILE"
      return 0
    fi
    dir=$(dirname "$dir")
  done

  return 1
}

# Load configuration from file
load_config() {
  local config_file
  config_file=$(find_config_file)

  if [[ -z "$config_file" ]]; then
    echo "${RED}Error: Configuration file not found (.kvs-server.conf)${RESET}"
    echo "Run './kvs-conversion-server.sh' to install first"
    return 1
  fi

  CONFIG_FILE_PATH="$config_file"
  CONFIG_DIR=$(dirname "$config_file")

  # shellcheck disable=SC1090
  source "$config_file"
  if [[ -n "${KVS_IMAGE_TAG:-}" ]]; then
    IMAGE_TAG="$KVS_IMAGE_TAG"
  else
    IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
  fi
  validate_image_tag "$IMAGE_TAG"
  return 0
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

  {
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
  } > "$config_path"

  chmod 600 "$config_path"
  echo "${GREEN}✓ Configuration saved to $config_path${RESET}"
  echo "Keep $config_path private. It contains the FTP password required by KVS."
  echo "To recover it later, read FTP_PASS from $config_path or run the script with 'info --show-password'."
}

# Check if container exists
container_exists() {
  docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Check if container is running
container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Command: status/ps
cmd_status() {
  if ! container_exists; then
    echo "Container '$CONTAINER_NAME' does not exist"
    echo "Run './kvs-conversion-server.sh' to install first"
    return 1
  fi

  echo "${CYAN}${BOLD}=== Container Status ===${RESET}"
  docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

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

# Command: logs
cmd_logs() {
  local follow_flag=""

  if [[ "$1" == "-f" ]] || [[ "$1" == "--follow" ]]; then
    follow_flag="-f"
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
  if container_running; then
    echo "${BLUE}[INFO]${RESET} Container '$CONTAINER_NAME' is already running"
    cmd_status
    return 0
  fi

  if container_exists; then
    echo "${BLUE}Starting existing container '$CONTAINER_NAME'...${RESET}"
    docker start "$CONTAINER_NAME"
    echo "${GREEN}✓ Container started successfully${RESET}"
    sleep 2
    cmd_status
  else
    # Container doesn't exist, recreate from config file
    echo "${YELLOW}[WARNING]${RESET} Container doesn't exist. Recreating from configuration..."

    if ! load_config; then
      return 1
    fi

    local host_dir port_mapping
    host_dir="${CONFIG_DIR:-$PWD}"

    # Determine port mapping based on FTP_MODE
    if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
      port_mapping="-p 990:990"
    else
      port_mapping="-p 21:21"
    fi

    local image_ref
    image_ref=$(docker_image_ref)

    echo "${BLUE}Creating and starting container with saved configuration...${RESET}"
    # shellcheck disable=SC2086
    docker run --rm -d --name "$CONTAINER_NAME" --cpus="$CPU_LIMIT" -v "${host_dir}/data:/home/vsftpd" -e FTP_USER="$FTP_USER" -e FTP_PASS="$FTP_PASS" -e PASV_ADDRESS="$IPV4_ADDRESS" -e PASV_ADDRESS_INTERFACE="$NETWORK_INTERFACE" -e NUM_FOLDERS="$NUM_FOLDERS" -e PHP_VERSION="$PHP_VERSION" -e FTP_MODE="$FTP_MODE" $port_mapping -p 21100-21110:21100-21110 "$image_ref"

    echo "${GREEN}✓ Container created and started successfully${RESET}"
    sleep 2
    cmd_status
  fi
}

# Command: stop/down
cmd_stop() {
  if ! container_running; then
    echo "${BLUE}[INFO]${RESET} Container '$CONTAINER_NAME' is not running"
    return 0
  fi

  echo "${BLUE}Stopping container '$CONTAINER_NAME'...${RESET}"
  docker stop "$CONTAINER_NAME"
  echo "${GREEN}✓ Container stopped successfully${RESET}"
}

# Command: restart
cmd_restart() {
  if ! container_exists; then
    echo "${RED}Error: Container '$CONTAINER_NAME' does not exist${RESET}"
    return 1
  fi

  echo "${BLUE}Restarting container '$CONTAINER_NAME'...${RESET}"
  docker restart "$CONTAINER_NAME"
  echo "${GREEN}✓ Container restarted successfully${RESET}"
  sleep 2
  cmd_status
}

# Command: info
cmd_info() {
  local show_password=false

  case "${1:-}" in
    "")
      ;;
    --show-password)
      show_password=true
      ;;
    *)
      print_error "Unknown option for info: $1"
      echo "Run '$0 --help' for usage information"
      return 1
      ;;
  esac

  if ! load_config; then
    return 1
  fi

  echo "${CYAN}${BOLD}=== KVS Conversion Server Configuration ===${RESET}"
  echo ""
  echo "Container:"
  echo "  Name: $CONTAINER_NAME"
  if container_running; then
    echo "  Status: Running"
  elif container_exists; then
    echo "  Status: Stopped"
  else
    echo "  Status: Not created"
  fi

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

  if container_running; then
    echo ""
    echo "${CYAN}${BOLD}=== Live Container Info ===${RESET}"
    local container_ip
    container_ip=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
    echo "  Container IP: $container_ip"

    local uptime
    uptime=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER_NAME")
    echo "  Started: $uptime"
  fi

  echo ""
  echo "Config file: ${CONFIG_FILE_PATH:-$(find_config_file || echo 'not found')}"
}

# Command: update
cmd_update() {
  if ! load_config; then
    return 1
  fi

  echo "${CYAN}${BOLD}=== Updating KVS Conversion Server ===${RESET}"
  echo ""
  local image_ref
  image_ref=$(docker_image_ref)

  echo "${BLUE}Pulling Docker image ${image_ref}...${RESET}"
  docker pull "$image_ref"

  if container_running; then
    echo ""
    read -rp "Container is running. Restart with new image? (yes/no): " restart_choice
    case "$restart_choice" in
      [Yy]*)
        cmd_stop
        cmd_start
        echo "Update completed and container restarted"
        ;;
      *)
        echo "Update completed. Restart manually to use new image."
        ;;
    esac
  else
    echo "Update completed. Start container to use new image."
  fi
}

# Command: remove
cmd_remove() {
  local config_file config_dir data_dir
  config_file=$(find_config_file || true)
  if [[ -n "$config_file" ]]; then
    config_dir=$(dirname "$config_file")
  else
    config_dir="$PWD"
  fi
  data_dir="$config_dir/data"

  echo "${YELLOW}${BOLD}WARNING: This will remove the container and all its data!${RESET}"
  read -rp "Are you sure you want to continue? (yes/no): " confirm

  case "$confirm" in
    [Yy][Ee][Ss])
      if container_running; then
        cmd_stop
      fi

      if container_exists; then
        echo "${BLUE}Removing container...${RESET}"
        docker rm "$CONTAINER_NAME"
      fi

      read -rp "Also remove data directory ($data_dir)? (yes/no): " remove_data
      if [[ "$remove_data" =~ ^[Yy] ]]; then
        rm -rf -- "$data_dir"
        echo "Data directory removed: $data_dir"
      fi

      read -rp "Remove configuration file? (yes/no): " remove_config
      if [[ "$remove_config" =~ ^[Yy] ]]; then
        if [[ -n "$config_file" ]]; then
          rm -f -- "$config_file"
          echo "Configuration file removed: $config_file"
        else
          echo "Configuration file not found"
        fi
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
  --php-version VERSION   PHP version (php7.4 or php8.1, default: php8.1)
  --ftp-mode MODE         FTP mode (ftp, ftps, or ftps_implicit, default: ftp)
  --ipv4 ADDRESS          IPv4 address (default: auto-detect)
  --cpu-limit CORES       CPU core limit (default: all cores)
  --ftp-user USERNAME     FTP username (default: user)
  --ftp-pass PASSWORD     FTP password (default: auto-generated)
  --num-folders NUMBER    Number of FTP folders (default: 5)
  --image-tag TAG         Docker image tag (default: 1.3.0)
  --auto-stop-container   Auto-stop existing container (default: no)
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
  $0 --headless --php-version php8.1 --ftp-user myuser --image-tag 1.3.0

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
  KVS_PHP_VERSION         PHP version (php7.4 or php8.1)
  KVS_FTP_MODE            FTP mode (ftp, ftps, or ftps_implicit)
  KVS_IPV4_ADDRESS        IPv4 address
  KVS_CPU_LIMIT           CPU core limit
  KVS_FTP_USER            FTP username
  KVS_FTP_PASS            FTP password
  KVS_NUM_FOLDERS         Number of FTP folders
  KVS_IMAGE_TAG           Docker image tag
  KVS_AUTO_STOP_CONTAINER Auto-stop existing container (true/false)

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

  # Check if headless mode is enabled via environment variable
  if [[ "${KVS_HEADLESS:-false}" == "true" ]]; then
    HEADLESS_MODE=true
  fi
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
  if ! command_exists docker; then
    echo -e "${RED}Docker is not installed \xE2\x9D\x8C${RESET}"
    echo "${BLUE}Installing Docker...${RESET}"
    curl -fsSL https://get.docker.com -o install-docker.sh
    sh install-docker.sh
    rm -f install-docker.sh
    echo -e "${GREEN}Docker has been installed \xE2\x9C\x85${RESET}"
  else
    echo -e "${GREEN}Docker is already installed \xE2\x9C\x85${RESET}"
  fi
}

stop_existing_container() {
  local container_id
  container_id=$(docker ps -aq --format '{{.ID}} {{.Names}}' | awk -v name="$CONTAINER_NAME" '$2 == name { print $1; exit }')
  if [[ -n "$container_id" ]]; then
    echo "${CYAN}A Docker container named '$CONTAINER_NAME' already exists with ID $container_id.${RESET}"

    if container_running && { [[ "$HEADLESS_MODE" == "true" ]] || [[ "${KVS_AUTO_STOP_CONTAINER:-false}" == "true" ]]; }; then
      echo "${BLUE}Headless mode: Auto-stopping the existing container...${RESET}"
      docker stop "$CONTAINER_NAME"
      echo "${GREEN}✓ Container has been stopped successfully.${RESET}"
    elif container_running; then
      read -rp "Do you wish to stop this container before proceeding? (yes/no): " stop_response
      case "$stop_response" in
      [Yy]*)
        echo "${BLUE}Stopping the existing container...${RESET}"
        docker stop "$CONTAINER_NAME"
        echo "${GREEN}✓ Container has been stopped successfully.${RESET}"
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
      echo "${RED}Container name '$CONTAINER_NAME' is still in use. Remove it with './kvs-conversion-server.sh remove' or rename it before installing.${RESET}"
      exit 1
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
  validate_positive_integer "Number of folders" "$num_folders"
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

  if [[ -n "${KVS_NUM_FOLDERS:-}" ]]; then
    validate_positive_integer "Number of folders" "$KVS_NUM_FOLDERS"
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
  if [[ -n "${KVS_PHP_VERSION:-}" ]]; then
    PHP_VERSION="$KVS_PHP_VERSION"
    echo "Using PHP version: $PHP_VERSION"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    PHP_VERSION="php8.1"
    echo "Headless mode: Using default PHP 8.1 (suitable for KVS 6.2 or higher)"
  else
    echo "${CYAN}Choose the PHP version to use:${RESET}"
    echo "${CYAN}1. PHP 7.4 - Recommended if your KVS version is below 6.2.${RESET}"
    echo "${CYAN}2. PHP 8.1 - Recommended if your KVS version is 6.2 or higher.${RESET}"
    read -rp "Enter your choice (1 or 2, default is 2 for PHP 8.1): " php_version_choice
    case "$php_version_choice" in
    1)
      PHP_VERSION="php7.4"
      echo "${GREEN}You have selected PHP 7.4, suitable for KVS versions below 6.2.${RESET}"
      ;;
    *)
      PHP_VERSION="php8.1"
      echo "${GREEN}PHP 8.1 is the default selection, suitable for KVS 6.2 or higher.${RESET}"
      ;;
    esac
  fi
}

read_ftp_mode() {
  # Priority: CLI/ENV variable > Headless default > Interactive prompt
  if [[ -n "${KVS_FTP_MODE:-}" ]]; then
    FTP_MODE="$KVS_FTP_MODE"
    echo "Using FTP mode: $FTP_MODE"
  elif [[ "$HEADLESS_MODE" == "true" ]]; then
    FTP_MODE="ftp"
    echo "Headless mode: Using default FTP mode (no encryption)"
  else
    echo "${CYAN}Choose the FTP mode to use:${RESET}"
    echo "${CYAN}1. FTP (no encryption) - Standard FTP without SSL/TLS${RESET}"
    echo "${CYAN}2. FTPS Explicit - SSL/TLS encryption via AUTH TLS on port 21 (recommended)${RESET}"
    echo "${CYAN}3. FTPS Implicit - SSL/TLS from connection start on port 990${RESET}"
    read -rp "Enter your choice (1, 2, or 3, default is 1 for standard FTP): " ftp_mode_choice
    case "$ftp_mode_choice" in
    2)
      FTP_MODE="ftps"
      echo "${GREEN}You have selected FTPS Explicit mode (AUTH TLS on port 21).${RESET}"
      echo "${BLUE}SSL certificates will be generated automatically.${RESET}"
      ;;
    3)
      FTP_MODE="ftps_implicit"
      echo "${GREEN}You have selected FTPS Implicit mode (SSL on port 990).${RESET}"
      echo "${BLUE}SSL certificates will be generated automatically.${RESET}"
      echo "${YELLOW}Note: You will need to expose port 990 instead of port 21.${RESET}"
      ;;
    *)
      FTP_MODE="ftp"
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
  total_cores=$(grep -c ^processor /proc/cpuinfo)

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
    num_folders=5
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
    read -rp "Enter the number of folders (default is 5): " num_folders
    num_folders=${num_folders:-5} # If no input, default to 5
  fi
}

run_docker_container() {
  local host_dir env_vars ftp_port ftp_ssl port_mapping image_ref
  host_dir=$(pwd)

  # Determine FTP port and SSL setting based on mode
  if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
    ftp_port="990"
    ftp_ssl="True"
    port_mapping="-p 990:990"
  else
    ftp_port="21"
    if [[ "$FTP_MODE" == "ftps" ]]; then
      ftp_ssl="True"
    else
      ftp_ssl="False"
    fi
    port_mapping="-p 21:21"
  fi

  env_vars=(-e FTP_USER="$input_ftp_user" -e FTP_PASS="$input_ftp_pass" -e PASV_ADDRESS="$ipv4_address" -e PASV_ADDRESS_INTERFACE="$network_interface" -e NUM_FOLDERS="$num_folders" -e PHP_VERSION="$PHP_VERSION" -e FTP_MODE="$FTP_MODE")
  image_ref=$(docker_image_ref)
  echo "${BLUE}Pulling the Docker image ${image_ref}...${RESET}"
  docker pull "$image_ref"

  echo "${BLUE}Running the Docker image in detached mode...${RESET}"
  # shellcheck disable=SC2086
  docker run --rm -d --name conversion-server --cpus="$CPU_LIMIT" -v "${host_dir}/data:/home/vsftpd" "${env_vars[@]}" $port_mapping -p 21100-21110:21100-21110 "$image_ref"
  echo "The Docker container is running with '${host_dir}/data' mounted to '/home/vsftpd' inside the container."
  cat <<EOB
${CYAN}${BOLD}KVS Conversion Server Configuration:${RESET}
${CYAN}------------------------------------${RESET}
  . PHP Version: ${PHP_VERSION}
  . FTP Mode: ${FTP_MODE}
  . Docker Image: ${image_ref}
  . Maximum tasks: 5 (Default)
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
  docker exec conversion-server tail -f /var/log/vsftpd.log

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
  --cpus="${CPU_LIMIT}" \\
  -v "${host_dir}/data:/home/vsftpd" \\
  -e FTP_USER='${input_ftp_user}' \\
  -e FTP_PASS='${input_ftp_pass}' \\
  -e PASV_ADDRESS='${ipv4_address}' \\
  -e PASV_ADDRESS_INTERFACE='${network_interface}' \\
  -e NUM_FOLDERS='${num_folders}' \\
  -e PHP_VERSION='${PHP_VERSION}' \\
  -e FTP_MODE='${FTP_MODE}' \\
  ${port_mapping} -p 21100-21110:21100-21110 \\
  ${image_ref}

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
check_os_compatibility
install_docker
stop_existing_container
configure_environment
run_docker_container

# Save configuration for CLI commands
if command -v save_config > /dev/null 2>&1; then
  save_config ".kvs-server.conf" "$PHP_VERSION" "$FTP_MODE" "$input_ftp_user" "$input_ftp_pass" "$ipv4_address" "$network_interface" "$num_folders" "$CPU_LIMIT" "$IMAGE_TAG"
fi

check_port_accessibility
