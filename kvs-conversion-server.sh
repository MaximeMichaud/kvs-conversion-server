#!/bin/bash

# Function to install Docker
install_docker() {
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com -o install-docker.sh
  sh install-docker.sh
  rm install-docker.sh
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
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
    echo "Choose the method to acquire IPv4 address:"
    echo "1. Automatic (detect via Internet)"
    echo "2. Manual (user input)"
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

# Prompt for FTP user and password
echo "Please enter FTP configuration details:"
read -p "Enter FTP username: " input_ftp_user
read -p "Enter FTP password: " input_ftp_pass

# Ask for IPv4 acquisition mode
get_ipv4_mode

# Get the IPv4 address
get_ipv4_address

# Get the primary network interface
get_network_interface

# Prepare environment variables for Docker run command
env_vars=()
[ -n "$input_ftp_user" ] && env_vars+=(-e FTP_USER="$input_ftp_user")
[ -n "$input_ftp_pass" ] && env_vars+=(-e FTP_PASS="$input_ftp_pass")
[ -n "$ipv4_address" ] && env_vars+=(-e PASV_ADDRESS="$ipv4_address")
[ -n "$network_interface" ] && env_vars+=(-e PASV_ADDRESS_INTERFACE="$network_interface")

# Download and run the Docker image
echo "Pulling the Docker image maximemichaud/kvs-conversion-server:latest..."
docker pull maximemichaud/kvs-conversion-server:latest

echo "Running the Docker image..."
docker run "${env_vars[@]}" -p 21:21 -p 21100-21110:21100-21110 maximemichaud/kvs-conversion-server:latest
