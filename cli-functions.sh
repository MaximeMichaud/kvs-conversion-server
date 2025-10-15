#!/bin/bash
# CLI Management Functions for KVS Conversion Server
# Inspired by docker-compose CLI design

# Constants
CONTAINER_NAME="conversion-server"
CONFIG_FILE=".kvs-server.conf"

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
# Call this from main script with: save_config path php_version ftp_mode ftp_user ftp_pass ipv4 network_interface num_folders cpu_limit
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
    echo "Run './kvs-conversion-server.sh install' to create it"
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
