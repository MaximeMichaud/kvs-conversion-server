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

# Functions

check_os_compatibility() {
  local os_type=$(uname -s)
  if [[ "$os_type" == "CYGWIN"* || "$os_type" == "MINGW"* || "$os_type" == "MSYS"* ]]; then
    echo "Warning: You are running this script on a Windows system. This script is not fully compatible with Windows environments."
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
}

install_docker() {
  if ! command -v docker &>/dev/null; then
    echo -e "Docker is not installed \xE2\x9D\x8C"
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o install-docker.sh
    sh install-docker.sh
    rm install-docker.sh
    echo -e "Docker has been installed \xE2\x9C\x85"
  else
    echo -e "Docker is already installed \xE2\x9C\x85"
  fi
}

stop_existing_container() {
  local container_id=$(docker ps -q -f ancestor=maximemichaud/kvs-conversion-server:latest)
  if [[ -n "$container_id" ]]; then
    echo "A Docker container using 'maximemichaud/kvs-conversion-server:latest' already exists with ID $container_id."
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
}

configure_environment() {
  read_php_version
  choose_ipv4_acquisition_mode
  get_ipv4_address
  get_network_interface
  get_cpu_limits
  prompt_ftp_credentials
  prompt_for_directory_number
}

read_php_version() {
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
}

choose_ipv4_acquisition_mode() {
  echo "Choose the method to acquire an IPv4 address:"
  echo "1. Automatic (detect via Internet)"
  echo "2. Manual (user input)"
  read -rp "Enter your choice (1 or 2, default is 1): " ipv4_mode_choice
  ipv4_mode_choice=${ipv4_mode_choice:-1}
}

get_ipv4_address() {
  if [[ $ipv4_mode_choice == 2 ]]; then
    read -rp "Enter the IPv4 address: " ipv4_address
  else
    ipv4_address=$(curl 'https://api.ipify.org')
  fi
  echo "Public IPv4 address: $ipv4_address"
}

get_network_interface() {
  local ip_route_info=$(ip route get 1.1.1.1)
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
  local total_cores=$(grep -c ^processor /proc/cpuinfo)
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
}

prompt_ftp_credentials() {
  echo "Please enter FTP configuration details:"
  read -rp "Enter FTP username (leave blank to use default 'user'): " input_ftp_user
  input_ftp_user=${input_ftp_user:-user}
  echo "Using FTP username: $input_ftp_user"

  read -rsp "Enter FTP password (leave blank to generate a secure one): " input_ftp_pass
  echo # New line
  if [ -z "$input_ftp_pass" ]; then
    input_ftp_pass=$(openssl rand -base64 12)
    echo "No password entered. A secure password has been generated for you: $input_ftp_pass"
  else
    echo "Using entered password."
  fi
}

prompt_for_directory_number() {
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

  # Format the folder number with leading zeros for numbers less than 10
  formatted_num_folders=$(printf "%02d" "$num_folders")
}

run_docker_container() {
  local host_dir=$(pwd)
  local env_vars=(-e FTP_USER="$input_ftp_user" -e FTP_PASS="$input_ftp_pass" -e PASV_ADDRESS="$ipv4_address" -e PASV_ADDRESS_INTERFACE="$network_interface" -e NUM_FOLDERS="$num_folders" -e PHP_VERSION="$PHP_VERSION")
  echo "Pulling the Docker image maximemichaud/kvs-conversion-server:latest..."
  docker pull maximemichaud/kvs-conversion-server:latest

  echo "Running the Docker image in detached mode..."
  docker run --rm -d --name conversion-server --cpus="$CPU_LIMIT" -v "${host_dir}/data:/home/vsftpd" "${env_vars[@]}" -p 21:21 -p 21100-21110:21100-21110 maximemichaud/kvs-conversion-server:latest
  echo "(DEBUG) Environment variables to be passed: ${env_vars[*]}"
  echo "The Docker container is running with '${host_dir}/data' mounted to '/home/vsftpd' inside the container."
  cat <<EOB
KVS Conversion Server Configuration:
------------------------------------
  . PHP Version: ${PHP_VERSION}
  . Maximum tasks: 5 (Default)
  . CPU usage: Realtime
  . Optimize Content Copying: Allow Pulling Source Files from Primary Server: true
  . Optimize Content Copying: allow this server to pull source files from primary server: true
  . Connection Type: FTP
  . Force SSL Connection: False
  . FTP Host: ${ipv4_address}
  . FTP Port: 21
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
  -p 21:21 -p 21100-21110:21100-21110 \\
  maximemichaud/kvs-conversion-server:latest

EOB
}

# Main Execution Flow
check_os_compatibility
install_docker
stop_existing_container
read_php_version
choose_ipv4_acquisition_mode
get_ipv4_address
get_network_interface
get_cpu_limits
prompt_ftp_credentials
prompt_for_directory_number
run_docker_container
