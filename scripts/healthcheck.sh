#!/bin/bash
set -euo pipefail

has_live_process() {
  local process_name="$1"
  local pids
  local pid
  local state

  if ! pids=$(pgrep -x "$process_name"); then
    echo "$process_name is not running"
    return 1
  fi

  for pid in $pids; do
    if [[ ! -r "/proc/$pid/stat" ]]; then
      continue
    fi

    state=$(awk '{ print $3 }' "/proc/$pid/stat" 2>/dev/null || true)
    case "$state" in
      T | t | X | x | Z | "")
        ;;
      *)
        return 0
        ;;
    esac
  done

  echo "$process_name has no live process"
  return 1
}

vsftpd_listen_port() {
  local port="21"

  if [[ -r /etc/vsftpd.conf ]]; then
    port=$(awk -F= '$1 == "listen_port" { print $2; exit }' /etc/vsftpd.conf)
    port="${port:-21}"
  fi

  if [[ ! "$port" =~ ^[1-9][0-9]*$ ]] || ((port > 65535)); then
    echo "vsftpd listen_port is invalid: $port"
    return 1
  fi

  printf '%s\n' "$port"
}

has_listening_tcp_port() {
  local service_name="$1"
  local port="$2"

  if ! command -v ss >/dev/null 2>&1; then
    echo "ss command is required to verify $service_name TCP listener"
    return 1
  fi

  if ss -H -ltn | awk -v port="$port" '
    $1 == "LISTEN" {
      address = $4
      if (address ~ ":" port "$") {
        found = 1
      }
    }
    END {
      exit found ? 0 : 1
    }
  '; then
    return 0
  fi

  echo "$service_name is not listening on TCP port $port"
  return 1
}

has_live_process vsftpd
has_live_process cron
has_listening_tcp_port vsftpd "$(vsftpd_listen_port)"
