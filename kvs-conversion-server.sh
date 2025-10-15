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

# Global variables for headless mode
HEADLESS_MODE=false

# CLI Management Constants
CONTAINER_NAME="conversion-server"
CONFIG_FILE=".kvs-server.conf"

# Functions

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# CLI Management Functions
# Inspired by docker-compose CLI design

# Find config file (check current dir, then parent dirs)
find_config_file() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$CONFIG_FILE" ]]; then
      echo "$dir/$CONFIG_FILE"
      return 0
    fi
    dir=$(dirname "$dir")
  done

  # Check KVS_CONFIG env variable
  if [[ -n "${KVS_CONFIG:-}" ]] && [[ -f "$KVS_CONFIG" ]]; then
    echo "$KVS_CONFIG"
    return 0
  fi

  return 1
}

# Load configuration from file
load_config() {
  local config_file
  config_file=$(find_config_file)

  if [[ -z "$config_file" ]]; then
    echo "Error: Configuration file not found (.kvs-server.conf)"
    echo "Run './kvs-conversion-server.sh' to install first"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$config_file"
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

  cat > "$config_path" <<EOF
# KVS Conversion Server Configuration
# Generated on $(date)
PHP_VERSION=$php_version
FTP_MODE=$ftp_mode
FTP_USER=$ftp_user
FTP_PASS=$ftp_pass
IPV4_ADDRESS=$ipv4
NETWORK_INTERFACE=$network_if
NUM_FOLDERS=$folders
CPU_LIMIT=$cpu
CONTAINER_NAME=$CONTAINER_NAME
EOF

  chmod 600 "$config_path"
  echo "Configuration saved to $config_path"
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

  echo "=== Container Status ==="
  docker ps -a --filter "name=^${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

  echo ""
  echo "=== Health Status ==="
  local health_status
  health_status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "no healthcheck")
  echo "Health: $health_status"

  if container_running; then
    echo ""
    echo "=== Resource Usage ==="
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
    echo "Error: Container '$CONTAINER_NAME' does not exist"
    return 1
  fi

  # shellcheck disable=SC2086
  docker logs $follow_flag "$CONTAINER_NAME"
}

# Command: start/up
cmd_start() {
  if container_running; then
    echo "Container '$CONTAINER_NAME' is already running"
    cmd_status
    return 0
  fi

  if container_exists; then
    echo "Starting existing container '$CONTAINER_NAME'..."
    docker start "$CONTAINER_NAME"
    echo "Container started successfully"
    sleep 2
    cmd_status
  else
    # Container doesn't exist, recreate from config file
    echo "Container doesn't exist. Recreating from configuration..."

    if ! load_config; then
      return 1
    fi

    local host_dir port_mapping
    host_dir=$(pwd)

    # Determine port mapping based on FTP_MODE
    if [[ "$FTP_MODE" == "ftps_implicit" ]]; then
      port_mapping="-p 990:990"
    else
      port_mapping="-p 21:21"
    fi

    echo "Creating and starting container with saved configuration..."
    # shellcheck disable=SC2086
    docker run --rm -d --name "$CONTAINER_NAME" --cpus="$CPU_LIMIT" -v "${host_dir}/data:/home/vsftpd" -e FTP_USER="$FTP_USER" -e FTP_PASS="$FTP_PASS" -e PASV_ADDRESS="$IPV4_ADDRESS" -e PASV_ADDRESS_INTERFACE="$NETWORK_INTERFACE" -e NUM_FOLDERS="$NUM_FOLDERS" -e PHP_VERSION="$PHP_VERSION" -e FTP_MODE="$FTP_MODE" $port_mapping -p 21100-21110:21100-21110 maximemichaud/kvs-conversion-server:latest

    echo "Container created and started successfully"
    sleep 2
    cmd_status
  fi
}

# Command: stop/down
cmd_stop() {
  if ! container_running; then
    echo "Container '$CONTAINER_NAME' is not running"
    return 0
  fi

  echo "Stopping container '$CONTAINER_NAME'..."
  docker stop "$CONTAINER_NAME"
  echo "Container stopped successfully"
}

# Command: restart
cmd_restart() {
  if ! container_exists; then
    echo "Error: Container '$CONTAINER_NAME' does not exist"
    return 1
  fi

  echo "Restarting container '$CONTAINER_NAME'..."
  docker restart "$CONTAINER_NAME"
  echo "Container restarted successfully"
  sleep 2
  cmd_status
}

# Command: info
cmd_info() {
  if ! load_config; then
    return 1
  fi

  echo "=== KVS Conversion Server Configuration ==="
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
  echo "  FTP Password: ${FTP_PASS:0:3}***"
  echo "  Network Interface: $NETWORK_INTERFACE"
  echo "  CPU Limit: $CPU_LIMIT cores"
  echo "  Folders: $NUM_FOLDERS"

  if container_running; then
    echo ""
    echo "=== Live Container Info ==="
    local container_ip
    container_ip=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
    echo "  Container IP: $container_ip"

    local uptime
    uptime=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER_NAME")
    echo "  Started: $uptime"
  fi

  echo ""
  echo "Config file: $(find_config_file || echo 'not found')"
}

# Command: update
cmd_update() {
  if ! load_config; then
    return 1
  fi

  echo "=== Updating KVS Conversion Server ==="
  echo ""
  echo "Pulling latest Docker image..."
  docker pull maximemichaud/kvs-conversion-server:latest

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
  echo "WARNING: This will remove the container and all its data!"
  read -rp "Are you sure you want to continue? (yes/no): " confirm

  case "$confirm" in
    [Yy][Ee][Ss])
      if container_running; then
        cmd_stop
      fi

      if container_exists; then
        echo "Removing container..."
        docker rm "$CONTAINER_NAME"
      fi

      read -rp "Also remove data directory? (yes/no): " remove_data
      if [[ "$remove_data" =~ ^[Yy] ]]; then
        rm -rf ./data
        echo "Data directory removed"
      fi

      read -rp "Remove configuration file? (yes/no): " remove_config
      if [[ "$remove_config" =~ ^[Yy] ]]; then
        local config_file
        config_file=$(find_config_file)
        if [[ -n "$config_file" ]]; then
          rm -f "$config_file"
          echo "Configuration file removed"
        fi
      fi

      echo "Cleanup completed"
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
      echo "Error: Unknown command '$command'"
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
  --auto-stop-container   Auto-stop existing container (default: no)
  -h, --help              Show this help message

MANAGEMENT COMMANDS:
  status, ps              Show container status and resource usage
  logs [-f|--follow]      Show container logs (use -f to follow)
  start, up               Start the container
  stop, down              Stop the container
  restart                 Restart the container
  info                    Show configuration and container info
  update                  Update to latest Docker image
  remove, rm              Remove container and optionally data/config

INSTALLATION EXAMPLES:
  # Interactive mode (default)
  $0

  # Headless mode with defaults
  $0 --headless

  # Headless mode with custom configuration
  $0 --headless --php-version php8.1 --ftp-user myuser --ftp-pass secret123

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
        KVS_PHP_VERSION="$2"
        shift 2
        ;;
      --ftp-mode)
        KVS_FTP_MODE="$2"
        shift 2
        ;;
      --ipv4)
        KVS_IPV4_ADDRESS="$2"
        shift 2
        ;;
      --cpu-limit)
        KVS_CPU_LIMIT="$2"
        shift 2
        ;;
      --ftp-user)
        KVS_FTP_USER="$2"
        shift 2
        ;;
      --ftp-pass)
        KVS_FTP_PASS="$2"
        shift 2
        ;;
      --num-folders)
        KVS_NUM_FOLDERS="$2"
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
        echo "Error: Unknown option: $1"
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
    echo "Warning: You are running this script on a Windows system. This script is not fully compatible with Windows environments."

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
    echo -e "Docker is not installed \xE2\x9D\x8C"
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o install-docker.sh
    sh install-docker.sh
    rm -f install-docker.sh
    echo -e "Docker has been installed \xE2\x9C\x85"
  else
    echo -e "Docker is already installed \xE2\x9C\x85"
  fi
}

stop_existing_container() {
  local container_id
  container_id=$(docker ps -q -f ancestor=maximemichaud/kvs-conversion-server:latest)
  if [[ -n "$container_id" ]]; then
    echo "A Docker container using 'maximemichaud/kvs-conversion-server:latest' already exists with ID $container_id."

    if [[ "$HEADLESS_MODE" == "true" ]] || [[ "${KVS_AUTO_STOP_CONTAINER:-false}" == "true" ]]; then
      echo "Headless mode: Auto-stopping the existing container..."
      docker stop "$container_id"
      echo "Container has been stopped successfully."
    else
      read -rp "Do you wish to stop this container before proceeding? (yes/no): " stop_response
      case "$stop_response" in
      [Yy]*)
        echo "Stopping the existing container..."
        docker stop "$container_id"
        echo "Container has been stopped successfully."
        ;;
      [Nn]*) echo "Proceeding without stopping the existing container." ;;
      *)
        echo "Invalid input. Please answer yes (y) or no (n). Exiting script."
        exit 1
        ;;
      esac
    fi
  fi
}

configure_environment() {
  read_php_version
  read_ftp_mode
  choose_ipv4_acquisition_mode
  get_ipv4_address
  get_network_interface
  get_cpu_limits
  prompt_ftp_credentials
  prompt_for_directory_number
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
    echo "Choose the PHP version to use:"
    echo "1. PHP 7.4 - Recommended if your KVS version is below 6.2."
    echo "2. PHP 8.1 - Recommended if your KVS version is 6.2 or higher."
    read -rp "Enter your choice (1 or 2, default is 2 for PHP 8.1): " php_version_choice
    case "$php_version_choice" in
    1)
      PHP_VERSION="php7.4"
      echo "You have selected PHP 7.4, suitable for KVS versions below 6.2."
      ;;
    *)
      PHP_VERSION="php8.1"
      echo "PHP 8.1 is the default selection, suitable for KVS 6.2 or higher."
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
    echo "Choose the FTP mode to use:"
    echo "1. FTP (no encryption) - Standard FTP without SSL/TLS"
    echo "2. FTPS Explicit - SSL/TLS encryption via AUTH TLS on port 21 (recommended)"
    echo "3. FTPS Implicit - SSL/TLS from connection start on port 990"
    read -rp "Enter your choice (1, 2, or 3, default is 1 for standard FTP): " ftp_mode_choice
    case "$ftp_mode_choice" in
    2)
      FTP_MODE="ftps"
      echo "You have selected FTPS Explicit mode (AUTH TLS on port 21)."
      echo "SSL certificates will be generated automatically."
      ;;
    3)
      FTP_MODE="ftps_implicit"
      echo "You have selected FTPS Implicit mode (SSL on port 990)."
      echo "SSL certificates will be generated automatically."
      echo "Note: You will need to expose port 990 instead of port 21."
      ;;
    *)
      FTP_MODE="ftp"
      echo "Standard FTP mode selected (no encryption)."
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
  local network_interface
  local ipv4_address
  ip_route_info=$(ip route get 1.1.1.1)
  network_interface=$(echo "$ip_route_info" | grep -oP 'dev \K\S+')

  if [ -z "$network_interface" ]; then
    echo "Could not find the primary network interface. Using default 'eth0'."
    network_interface="eth0"
  else
    echo "Primary network interface: $network_interface"
    echo "Associated IP address: $ipv4_address"
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
  # Format the folder number with leading zeros for numbers less than 10
  formatted_num_folders=$(printf "%02d" "$num_folders")
}

run_docker_container() {
  local host_dir env_vars ftp_port ftp_ssl port_mapping
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
  echo "Pulling the Docker image maximemichaud/kvs-conversion-server:latest..."
  docker pull maximemichaud/kvs-conversion-server:latest

  echo "Running the Docker image in detached mode..."
  # shellcheck disable=SC2086
  docker run --rm -d --name conversion-server --cpus="$CPU_LIMIT" -v "${host_dir}/data:/home/vsftpd" "${env_vars[@]}" $port_mapping -p 21100-21110:21100-21110 maximemichaud/kvs-conversion-server:latest
  echo "(DEBUG) Environment variables to be passed: ${env_vars[*]}"
  echo "The Docker container is running with '${host_dir}/data' mounted to '/home/vsftpd' inside the container."
  cat <<EOB
KVS Conversion Server Configuration:
------------------------------------
  . PHP Version: ${PHP_VERSION}
  . FTP Mode: ${FTP_MODE}
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
  docker logs conversion-server

For specific cron task logs from a particular folder, execute:
  docker exec conversion-server tail -f /var/log/cron02.log  # Replace '02' with your folder number

To check the vsftpd logs for FTP activities, use:
  docker exec conversion-server tail -f /var/log/vsftpd/vsftpd.log

If you need to perform debugging or access the container's shell, you can use the following command:
  docker exec -it conversion-server /bin/bash
This will provide interactive shell access to the container, allowing you to execute commands and inspect the container's environment directly.

Before attempting to restart the Docker container with the same configuration, make sure to stop the currently running container. This prevents configuration conflicts and ensures that the container can be restarted cleanly with the desired settings.

To stop the existing Docker container, run:
  docker stop conversion-server

Once the container is stopped, you can restart it with the same configuration using the following command:

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
  maximemichaud/kvs-conversion-server:latest

EOB
}

check_port_accessibility() {
  echo ""
  echo "========================================"
  echo "Network Port Accessibility Check"
  echo "========================================"
  echo ""
  echo "Checking if Docker is listening on required ports..."

  local all_listening=true

  # Check FTP port 21
  if command_exists ss; then
    if ss -tlnp 2>/dev/null | grep -q ":21 "; then
      echo "✓ Port 21 (FTP) is listening locally"
    else
      echo "✗ Port 21 (FTP) is NOT listening locally"
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
  echo "  telnet $ipv4_address 21"
  echo "  nc -zv $ipv4_address 21"
  echo ""
  echo "Or use an online port checker:"
  echo "  https://www.yougetsignal.com/tools/open-ports/"
  echo "  Enter IP: $ipv4_address, Port: 21"
  echo ""

  if [[ "$all_listening" == false ]]; then
    echo "⚠️  Warning: Some ports are not listening. Please check Docker logs:"
    echo "  docker logs conversion-server"
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
check_os_compatibility
install_docker
stop_existing_container
configure_environment
run_docker_container

# Save configuration for CLI commands
if command -v save_config > /dev/null 2>&1; then
  save_config ".kvs-server.conf" "$PHP_VERSION" "$FTP_MODE" "$input_ftp_user" "$input_ftp_pass" "$ipv4_address" "$network_interface" "$num_folders" "$CPU_LIMIT"
fi

check_port_accessibility
