#!/bin/bash
#
# [Automatic installation on Linux for KVS Conversion Server]
#
# GitHub : https://github.com/MaximeMichaud/kvs-conversion-server
# URL : https://www.kernel-video-sharing.com
#
# This script is intended for a quick and easy installation :
# bash <(curl -s https://raw.githubusercontent.com/MaximeMichaud/kvs-conversion-server/main/kvs-conversion-server.sh)
#
# kvs-conversion-server Copyright (c) 2023 Maxime Michaud
# Licensed under MIT License
#
#   Permission is hereby granted, free of charge, to any person obtaining a copy
#   of this software and associated documentation files (the "Software"), to deal
#   in the Software without restriction, including without limitation the rights
#   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the Software is
#   furnished to do so, subject to the following conditions:
#
#   The above copyright notice and this permission notice shall be included in all
#   copies or substantial portions of the Software.
#
#################################################################################

# Check Operating System
os_type=$(uname -s)
if [[ "$os_type" == "CYGWIN"* || "$os_type" == "MINGW"* || "$os_type" == "MSYS"* ]]; then
  echo "Warning: You are running this script on a Windows system. This script is not fully compatible with Windows environments."
  read -p "Do you wish to continue anyway? (yes/no): " response
  case "$response" in
  [Yy]*)
    echo "Proceeding with installation..."
    ;;
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

# Function to install Docker
install_docker() {
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com -o install-docker.sh
  sh install-docker.sh
  rm install-docker.sh
}

# Check if the Docker image already exists
container_id=$(docker ps -q -f ancestor=maximemichaud/kvs-conversion-server:latest)

if [[ ! -z "$container_id" ]]; then
  echo "A Docker container using 'maximemichaud/kvs-conversion-server:latest' already exists with ID $container_id."
  read -p "Do you wish to stop this container before proceeding? (yes/no): " stop_response
  case "$stop_response" in
  [Yy]*)
    echo "Stopping the existing container..."
    docker stop $container_id
    echo "Container has been stopped successfully."
    ;;
  [Nn]*)
    echo "Proceeding without stopping the existing container."
    ;;
  *)
    echo "Invalid input. Please answer yes (y) or no (n). Exiting script."
    exit 1
    ;;
  esac
fi

# Function to get the total number of CPU cores available on the host
get_total_cores() {
  total_cores=$(grep -c ^processor /proc/cpuinfo)
  echo "Total CPU cores available: $total_cores"
}

# Function to ask for CPU limits
get_cpu_limits() {
  while true; do
    echo "Do you want to limit CPU usage for the Docker container? (yes/no)"
    read -r -p "Enter your choice (default no): " limit_cpu
    case $limit_cpu in
    [Yy] | [Yy][Ee][Ss])
      get_total_cores
      read -r -p "Enter the number of CPU cores to use (e.g., 0.5 for half a core, up to $total_cores cores): " cpu_cores
      # Using awk to handle decimal comparison
      is_greater=$(awk -v num="$cpu_cores" -v max="$total_cores" 'BEGIN {print (num > max) ? "1" : "0"}')
      if [ "$is_greater" -eq 1 ]; then
        echo "Error: You cannot allocate more than $total_cores cores."
        continue
      fi
      CPU_LIMIT="--cpus=$cpu_cores"
      break
      ;;
    [Nn] | [Nn][Oo] | "")
      CPU_LIMIT=""
      break
      ;;
    *)
      echo "Invalid input. Please enter 'yes' or 'no'."
      ;;
    esac
  done
}

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
  echo -e "Docker is not installed \xE2\x9D\x8C"
  read -p "Do you want to install Docker? (y/N): " -r
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    install_docker
  else
    echo "Docker installation declined. Exiting script."
    exit 1
  fi
else
  echo -e "Docker is installed \xE2\x9C\x85"
fi

# Function to ask for IPv4 acquisition mode
get_ipv4_mode() {
  echo "Choose the method to acquire an IPv4 address:"
  echo "1. Automatic (detect via Internet)"
  echo "2. Manual (user input)"
  echo "Note: This script does not support IPv6. If you are operating on a network with restrictions, manual intervention might be required for the script to function properly."
  echo "Using the server locally or in a network with special configurations? Option 2 (Manual input) is more appropriate."
  echo "Additionally, running multiple instances of this Docker image has not been extensively tested and is not recommended. If you need to handle multiple workloads, consider creating more directories rather than multiple instances."
  read -p "Enter your choice (1 or 2, default is 1): " ipv4_mode_choice
  ipv4_mode_choice=${ipv4_mode_choice:-1}
}

# Function to get IPv4 address based on the chosen mode
get_ipv4_address() {
  if [[ $ipv4_mode_choice == 2 ]]; then
    read -p "Enter the IPv4 address: " ipv4_address
  else
    ipv4_address=$(curl 'https://api.ipify.org')
  fi
}

# Function to get the primary network interface used for outbound traffic
get_network_interface() {
  network_interface=$(ip route get 1.1.1.1 | grep -oP 'dev \K\S+')

  if [ -z "$network_interface" ]; then
    echo "Could not find the primary network interface."
    network_interface="not_found"
  else
    echo "Primary network interface: $network_interface"
    echo "Associated IP address: $ipv4_address"
  fi
}

get_php_version() {
  echo "Choose the PHP version to use:"
  echo "1. PHP 7.4 - Recommended if your KVS version is below 6.2."
  echo "2. PHP 8.1 - Recommended if your KVS version is 6.2 or higher."
  read -p "Enter your choice (1 or 2, default is 2 for PHP 8.1): " php_version_choice
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

# Prompt for FTP user and password
echo "Please enter FTP configuration details:"
read -p "Enter FTP username (leave blank to use default 'user'): " input_ftp_user

# Check if the username is empty and set default if necessary
if [ -z "$input_ftp_user" ]; then
  input_ftp_user="user"
  echo "No username entered. Using default username 'user'."
fi

echo "Enter FTP password (leave blank to generate a secure one):"
read -s -p "Password: " input_ftp_pass
echo # Move to a new line

# Check if the password is empty and generate a secure one if necessary
if [ -z "$input_ftp_pass" ]; then
  # Generates a random password that includes 12 characters from the base64 character set
  input_ftp_pass=$(openssl rand -base64 12)
  echo "No password entered. A secure password has been generated for you."
  echo "Generated Password: $input_ftp_pass"
fi

# Prompt for number of folders to create
echo "Please enter the number of FTP directories to create:"
echo "Each directory corresponds to one instance of use you plan for this server."
echo "You can only use one directory at a time. Having multiple directories can be useful"
echo "if you intend to use this server for different KVS installations, or to better utilize CPU power"
echo "for a single KVS installation."
echo "If unsure, opt for a higher number of directories since the script does not dynamically support folder creation."
echo "The site will create directories as needed, but it's crucial that each directory operates under its own cron task."
echo "Future improvements may automate this part to simplify setup."
read -p "Enter the number of folders (default is 5): " num_folders
num_folders=${num_folders:-5} # If no input, default to 5

# Format the folder number with leading zeros for numbers less than 10
formatted_num_folders=$(printf "%02d" $num_folders)

# Ask for PHP version
get_php_version

# Ask for IPv4 acquisition mode
get_ipv4_mode

# Get the IPv4 address
get_ipv4_address

# Get the primary network interface
get_network_interface

# Download required files for Docker image
#download_docker_files

# Ask for CPU limits
get_cpu_limits

# Prepare environment variables for Docker run command
env_vars=()
[ -n "$input_ftp_user" ] && env_vars+=(-e FTP_USER="$input_ftp_user")
[ -n "$input_ftp_pass" ] && env_vars+=(-e FTP_PASS="$input_ftp_pass")
[ -n "$ipv4_address" ] && env_vars+=(-e PASV_ADDRESS="$ipv4_address")
[ -n "$network_interface" ] && env_vars+=(-e PASV_ADDRESS_INTERFACE="$network_interface")
env_vars+=(-e NUM_FOLDERS="$num_folders") # Set number of folders based on user input
env_vars+=(-e PHP_VERSION="$PHP_VERSION")

# Download and run the Docker image
echo "Pulling the Docker image maximemichaud/kvs-conversion-server:latest..."
docker pull maximemichaud/kvs-conversion-server:latest

# Get the current working directory
host_dir=$(pwd)

echo "(DEBUG) Environment variables to be passed: ${env_vars[@]}"

echo "Running the Docker image in detached mode..."

docker run --rm -d \
  --name conversion-server \
  --cpus="${CPU_LIMIT}" \
  -v "${host_dir}/data:/home/vsftpd" \
  "${env_vars[@]}" \
  -p 21:21 -p 21100-21110:21100-21110 \
  maximemichaud/kvs-conversion-server:latest

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
