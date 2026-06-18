#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/testlib.bash
source "$script_dir/testlib.bash"
repo_root=$(kvs_repo_root)
default_image_tag=$(require_script_default DEFAULT_IMAGE_TAG)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$tmpdir/bin/docker"

make_config() {
  local config_path="$1"
  local ftp_user="$2"
  local ftp_pass="$3"
  local container_name="${4:-conversion-server}"

  write_kvs_config "$config_path" \
    --ftp-user "$ftp_user" \
    --ftp-pass "$ftp_pass" \
    --num-folders 2 \
    --container-name "$container_name"
}

run_from() {
  local cwd="$1"
  shift

  (cd "$cwd" && PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" "$@")
}

mkdir -p "$tmpdir/install/sub" "$tmpdir/external"
make_config "$tmpdir/install/.kvs-server.conf" parentuser parentpass
make_config "$tmpdir/external/.kvs-server.conf" externaluser externalpass

config_output=$(KVS_CONFIG="$tmpdir/external/.kvs-server.conf" run_from "$tmpdir/install/sub" info --show-password)
[[ "$config_output" == *"FTP User: externaluser"* ]]
[[ "$config_output" == *"FTP Password: externalpass"* ]]
[[ "$config_output" == *"Config file: $tmpdir/external/.kvs-server.conf"* ]]
[[ "$config_output" != *"parentuser"* ]]
[[ "$config_output" != *"parentpass"* ]]

symlink_config_dir="$tmpdir/symlink-config"
mkdir -p "$symlink_config_dir/install/data" "$symlink_config_dir/ops/data"
make_config "$symlink_config_dir/install/.kvs-server.conf" symlinkuser symlinkpass
printf 'real data\n' > "$symlink_config_dir/install/data/real.txt"
printf 'ops data\n' > "$symlink_config_dir/ops/data/wrong.txt"
ln -s "$symlink_config_dir/install/.kvs-server.conf" "$symlink_config_dir/ops/kvs.conf"

(
  cd /
  printf 'yes\nyes\nno\n' | \
    KVS_CONFIG="$symlink_config_dir/ops/kvs.conf" PATH="$tmpdir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$symlink_config_dir/remove.out" 2>&1

[[ ! -e "$symlink_config_dir/install/data/real.txt" ]]
[[ -e "$symlink_config_dir/ops/data/wrong.txt" ]]
grep -q "Data directory removed: $symlink_config_dir/install/data" "$symlink_config_dir/remove.out"

auto_symlink_config_dir="$tmpdir/auto-symlink-config"
mkdir -p "$auto_symlink_config_dir/install/data" "$auto_symlink_config_dir/ops/data"
make_config "$auto_symlink_config_dir/install/.kvs-server.conf" autosymlinkuser autosymlinkpass
printf 'real data\n' > "$auto_symlink_config_dir/install/data/real.txt"
printf 'ops data\n' > "$auto_symlink_config_dir/ops/data/wrong.txt"
ln -s "$auto_symlink_config_dir/install/.kvs-server.conf" "$auto_symlink_config_dir/ops/.kvs-server.conf"

(
  cd "$auto_symlink_config_dir/ops"
  printf 'yes\nyes\nno\n' | PATH="$tmpdir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$auto_symlink_config_dir/remove.out" 2>&1

[[ ! -e "$auto_symlink_config_dir/install/data/real.txt" ]]
[[ -e "$auto_symlink_config_dir/ops/data/wrong.txt" ]]
grep -q "Data directory removed: $auto_symlink_config_dir/install/data" "$auto_symlink_config_dir/remove.out"

physical_symlink_config_dir="$tmpdir/physical-symlink-config"
mkdir -p "$physical_symlink_config_dir/real/install/sub" "$physical_symlink_config_dir/link"
make_config "$physical_symlink_config_dir/real/install/.kvs-server.conf" physicaluser physicalpass
ln -s "$physical_symlink_config_dir/real/install/sub" "$physical_symlink_config_dir/link/sub"

physical_symlink_output=$(run_from "$physical_symlink_config_dir/link/sub" info --show-password)
[[ "$physical_symlink_output" == *"FTP User: physicaluser"* ]]
[[ "$physical_symlink_output" == *"FTP Password: physicalpass"* ]]
[[ "$physical_symlink_output" == *"Config file: $physical_symlink_config_dir/real/install/.kvs-server.conf"* ]]

logical_symlink_config_dir="$tmpdir/logical-symlink-config"
mkdir -p "$logical_symlink_config_dir/real/install/sub" "$logical_symlink_config_dir/link"
make_config "$logical_symlink_config_dir/real/install/.kvs-server.conf" physicaluser physicalpass
make_config "$logical_symlink_config_dir/link/.kvs-server.conf" logicaluser logicalpass
ln -s "$logical_symlink_config_dir/real/install/sub" "$logical_symlink_config_dir/link/sub"

logical_symlink_output=$(run_from "$logical_symlink_config_dir/link/sub" info --show-password)
[[ "$logical_symlink_output" == *"FTP User: logicaluser"* ]]
[[ "$logical_symlink_output" == *"FTP Password: logicalpass"* ]]
[[ "$logical_symlink_output" == *"Config file: $logical_symlink_config_dir/link/.kvs-server.conf"* ]]
[[ "$logical_symlink_output" != *"physicaluser"* ]]
[[ "$logical_symlink_output" != *"physicalpass"* ]]

if KVS_CONFIG="$tmpdir/missing.conf" run_from "$tmpdir/install/sub" info >"$tmpdir/missing.out" 2>&1; then
  echo "missing KVS_CONFIG unexpectedly fell back to a parent config"
  exit 1
fi
grep -q "Configuration file not found" "$tmpdir/missing.out"

no_config_remove_dir="$tmpdir/no-config-remove"
mkdir -p "$no_config_remove_dir/data"
printf 'must stay\n' > "$no_config_remove_dir/data/marker.txt"
if printf 'yes\nyes\nno\n' | run_from "$no_config_remove_dir" remove >"$no_config_remove_dir/remove.out" 2>"$no_config_remove_dir/remove.err"; then
  echo "remove succeeded without a configuration file"
  exit 1
fi
grep -q "Configuration file not found" "$no_config_remove_dir/remove.err"
[[ -f "$no_config_remove_dir/data/marker.txt" ]]

no_config_state_dir="$tmpdir/no-config-state-commands"
mkdir -p "$no_config_state_dir/bin" "$no_config_state_dir/work"
cat > "$no_config_state_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    fi
    ;;
  stop|restart|run)
    echo "state command should not run without a config" >&2
    exit 1
    ;;
esac
DOCKER
chmod +x "$no_config_state_dir/bin/docker"

for command in start stop restart status logs; do
  command_dir="$no_config_state_dir/$command"
  mkdir -p "$command_dir"
  rm -f "$no_config_state_dir/docker.log"

  if (
    cd "$command_dir"
    KVS_DOCKER_LOG="$no_config_state_dir/docker.log" PATH="$no_config_state_dir/bin:$PATH" NO_COLOR=1 \
      "$repo_root/kvs-conversion-server.sh" "$command"
  ) >"$command_dir/$command.out" 2>"$command_dir/$command.err"; then
    echo "$command succeeded without a configuration file"
    exit 1
  fi

  grep -q "Configuration file not found" "$command_dir/$command.err"
  if [[ -e "$no_config_state_dir/docker.log" ]]; then
    echo "$command queried or modified Docker without a configuration file"
    cat "$no_config_state_dir/docker.log"
    exit 1
  fi
done

empty_container_dir="$tmpdir/empty-container-name"
mkdir -p "$empty_container_dir/bin" "$empty_container_dir/install"
make_config "$empty_container_dir/install/.kvs-server.conf" emptyuser emptypass
sed -i 's/^CONTAINER_NAME=.*/CONTAINER_NAME=/' "$empty_container_dir/install/.kvs-server.conf"
cat > "$empty_container_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$empty_container_dir/bin/docker"

if (
  cd "$empty_container_dir/install"
  KVS_DOCKER_LOG="$empty_container_dir/docker.log" PATH="$empty_container_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$empty_container_dir/start.out" 2>"$empty_container_dir/start.err"; then
  echo "start accepted an empty container name"
  exit 1
fi
grep -q "Container name is required" "$empty_container_dir/start.err"
if [[ -e "$empty_container_dir/docker.log" ]]; then
  echo "start touched Docker with an empty container name"
  cat "$empty_container_dir/docker.log"
  exit 1
fi

future_key_management_dir="$tmpdir/future-key-management"
mkdir -p "$future_key_management_dir/bin" "$future_key_management_dir/install"
make_config "$future_key_management_dir/install/.kvs-server.conf" futureuser futurepass
printf 'FUTURE_OPTION=value\n' >> "$future_key_management_dir/install/.kvs-server.conf"
cat > "$future_key_management_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    fi
    ;;
  stop)
    echo "conversion-server"
    ;;
esac
DOCKER
chmod +x "$future_key_management_dir/bin/docker"

(
  cd "$future_key_management_dir/install"
  KVS_DOCKER_LOG="$future_key_management_dir/docker.log" PATH="$future_key_management_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" stop
) >"$future_key_management_dir/stop.out" 2>"$future_key_management_dir/stop.err"

grep -q "Container stopped successfully" "$future_key_management_dir/stop.out"
grep -q "docker stop conversion-server" "$future_key_management_dir/docker.log"
if grep -q "Unsupported configuration key" "$future_key_management_dir/stop.err"; then
  echo "stop rejected an unknown future config key"
  exit 1
fi

malformed_management_dir="$tmpdir/malformed-management"
mkdir -p "$malformed_management_dir/bin" "$malformed_management_dir/install"
make_config "$malformed_management_dir/install/.kvs-server.conf" malformeduser malformedpass
printf 'this is not a valid config line\n' >> "$malformed_management_dir/install/.kvs-server.conf"
cat > "$malformed_management_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    fi
    ;;
  stop)
    echo "conversion-server"
    ;;
esac
DOCKER
chmod +x "$malformed_management_dir/bin/docker"

(
  cd "$malformed_management_dir/install"
  KVS_DOCKER_LOG="$malformed_management_dir/docker.log" PATH="$malformed_management_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" stop
) >"$malformed_management_dir/stop.out" 2>"$malformed_management_dir/stop.err"

grep -q "Container stopped successfully" "$malformed_management_dir/stop.out"
grep -q "Ignoring invalid configuration line" "$malformed_management_dir/stop.err"
grep -q "docker stop conversion-server" "$malformed_management_dir/docker.log"
if grep -q "Error: Invalid configuration line" "$malformed_management_dir/stop.err"; then
  echo "stop rejected an unrelated malformed config line"
  exit 1
fi

malformed_container_name_dir="$tmpdir/malformed-container-name"
mkdir -p "$malformed_container_name_dir/bin" "$malformed_container_name_dir/install"
make_config "$malformed_container_name_dir/install/.kvs-server.conf" malformedcontaineruser malformedcontainerpass
sed -i 's/^CONTAINER_NAME=.*/CONTAINER_NAME conversion-server/' "$malformed_container_name_dir/install/.kvs-server.conf"
cat > "$malformed_container_name_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$malformed_container_name_dir/bin/docker"

if (
  cd "$malformed_container_name_dir/install"
  KVS_DOCKER_LOG="$malformed_container_name_dir/docker.log" PATH="$malformed_container_name_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" stop
) >"$malformed_container_name_dir/stop.out" 2>"$malformed_container_name_dir/stop.err"; then
  echo "stop accepted a malformed CONTAINER_NAME line"
  exit 1
fi
grep -q "Invalid container name configuration line" "$malformed_container_name_dir/stop.err"
if [[ -e "$malformed_container_name_dir/docker.log" ]]; then
  echo "stop touched Docker after a malformed CONTAINER_NAME line"
  cat "$malformed_container_name_dir/docker.log"
  exit 1
fi

invalid_value_management_dir="$tmpdir/invalid-value-management"
mkdir -p "$invalid_value_management_dir/bin" "$invalid_value_management_dir/install"
{
  echo "PHP_VERSION=$(require_script_default DEFAULT_PHP_VERSION)"
  echo "FTP_MODE=ftp"
  echo "FTP_USER=testuser"
  echo "FTP_PASS=\$'\\u12'"
  echo "IPV4_ADDRESS=127.0.0.1"
  echo "NETWORK_INTERFACE=eth0"
  echo "NUM_FOLDERS=2"
  echo "CPU_LIMIT=1"
  echo "IMAGE_TAG=$default_image_tag"
  echo "CONTAINER_NAME=conversion-server"
} > "$invalid_value_management_dir/install/.kvs-server.conf"
cat > "$invalid_value_management_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    elif [[ "$*" == *"table {{.Names}}"* ]]; then
      echo "NAMES STATUS PORTS"
      echo "conversion-server Up 1 second 0.0.0.0:21->21/tcp"
    fi
    ;;
  inspect)
    if [[ "$*" == *"State.Health.Status"* ]]; then
      echo "healthy"
    elif [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    fi
    ;;
  stats)
    echo "conversion-server 0.00% 10MiB / 1GiB 0B / 0B"
    ;;
  logs)
    echo "fake container log"
    ;;
  stop)
    echo "conversion-server"
    ;;
esac
DOCKER
chmod +x "$invalid_value_management_dir/bin/docker"

for command in status logs stop; do
  rm -f "$invalid_value_management_dir/docker.log"
  (
    cd "$invalid_value_management_dir/install"
    KVS_DOCKER_LOG="$invalid_value_management_dir/docker.log" PATH="$invalid_value_management_dir/bin:$PATH" NO_COLOR=1 \
      "$repo_root/kvs-conversion-server.sh" "$command"
  ) >"$invalid_value_management_dir/$command.out" 2>"$invalid_value_management_dir/$command.err"

  if grep -q "Invalid configuration value for FTP_PASS" "$invalid_value_management_dir/$command.err"; then
    echo "$command rejected an unrelated malformed FTP_PASS value"
    exit 1
  fi
done
grep -q "Health: healthy" "$invalid_value_management_dir/status.out"
grep -q "fake container log" "$invalid_value_management_dir/logs.out"
grep -q "Container stopped successfully" "$invalid_value_management_dir/stop.out"
grep -q "docker stop conversion-server" "$invalid_value_management_dir/docker.log"

if (
  cd "$future_key_management_dir/install"
  KVS_DOCKER_LOG="$future_key_management_dir/docker-info.log" PATH="$future_key_management_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" info
) >"$future_key_management_dir/info.out" 2>"$future_key_management_dir/info.err"; then
  echo "info accepted an unknown future config key"
  exit 1
fi
grep -q "Unsupported configuration key: FUTURE_OPTION" "$future_key_management_dir/info.err"
if [[ -e "$future_key_management_dir/docker-info.log" ]]; then
  echo "info touched Docker before rejecting an unknown future config key"
  cat "$future_key_management_dir/docker-info.log"
  exit 1
fi

ftps_tls_management_dir="$tmpdir/ftps-tls-management"
mkdir -p "$ftps_tls_management_dir/install"
write_kvs_config "$ftps_tls_management_dir/install/.kvs-server.conf" \
  --ftp-mode ftps_tls \
  --ftp-user tlsuser \
  --ftp-pass tlspass \
  --num-folders 1

ftps_tls_output=$(run_from "$ftps_tls_management_dir/install" info --show-password)
[[ "$ftps_tls_output" == *"FTP Mode: ftps_tls"* ]]
[[ "$ftps_tls_output" == *"FTP Password: tlspass"* ]]

custom_management_dir="$tmpdir/custom-management"
mkdir -p "$custom_management_dir/bin" "$custom_management_dir/install"
make_config "$custom_management_dir/install/.kvs-server.conf" customuser custompass custom.conversion.server
cat > "$custom_management_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "custom.conversion.server"
    elif [[ "$*" == *"table {{.Names}}"* ]]; then
      echo "NAMES STATUS PORTS"
      echo "custom.conversion.server Up 1 second 0.0.0.0:21->21/tcp"
    fi
    ;;
  inspect)
    if [[ "$*" == *"State.Health.Status"* ]]; then
      echo "healthy"
    fi
    ;;
  stats)
    echo "custom.conversion.server 0.00% 10MiB / 1GiB 0B / 0B"
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$custom_management_dir/bin/docker"

(
  cd "$custom_management_dir/install"
  KVS_DOCKER_STATE_DIR="$custom_management_dir" PATH="$custom_management_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" status
) >"$custom_management_dir/status.out" 2>"$custom_management_dir/status.err"

grep -q "custom.conversion.server" "$custom_management_dir/status.out"
grep -Fq "docker ps -a --filter name=\\^custom\\\\.conversion\\\\.server\\$" "$custom_management_dir/docker.log"
if grep -q "Container 'conversion-server' does not exist" "$custom_management_dir/status.out"; then
  echo "status ignored saved custom container name"
  exit 1
fi
if [[ -s "$custom_management_dir/status.err" ]]; then
  cat "$custom_management_dir/status.err" >&2
  exit 1
fi

custom_remove_dir="$tmpdir/custom-remove"
mkdir -p "$custom_remove_dir/bin" "$custom_remove_dir/install"
make_config "$custom_remove_dir/install/.kvs-server.conf" removeuser removepass removable-conversion-server
cat > "$custom_remove_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* && "$*" == *" -a "* ]]; then
      echo "removable-conversion-server"
    fi
    ;;
  rm)
    if [[ "$2" != "removable-conversion-server" ]]; then
      echo "unexpected container removal: $2" >&2
      exit 1
    fi
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$custom_remove_dir/bin/docker"

(
  cd "$custom_remove_dir/install"
  printf 'yes\nno\nno\n' | \
    KVS_DOCKER_STATE_DIR="$custom_remove_dir" PATH="$custom_remove_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$custom_remove_dir/remove.out" 2>"$custom_remove_dir/remove.err"

grep -q "✓ Cleanup completed" "$custom_remove_dir/remove.out"
grep -q "docker rm removable-conversion-server" "$custom_remove_dir/docker.log"
if grep -q "docker rm conversion-server" "$custom_remove_dir/docker.log"; then
  echo "remove ignored saved custom container name"
  exit 1
fi
if [[ -s "$custom_remove_dir/remove.err" ]]; then
  cat "$custom_remove_dir/remove.err" >&2
  exit 1
fi

truncated_remove_input_dir="$tmpdir/remove-truncated-input"
mkdir -p "$truncated_remove_input_dir/bin" "$truncated_remove_input_dir/install/data"
make_config "$truncated_remove_input_dir/install/.kvs-server.conf" truncateduser truncatedpass
printf 'data marker\n' > "$truncated_remove_input_dir/install/data/marker.txt"
cat > "$truncated_remove_input_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$truncated_remove_input_dir/bin/docker"

if (
  cd "$truncated_remove_input_dir/install"
  printf 'yes\n' | KVS_DOCKER_LOG="$truncated_remove_input_dir/docker.log" PATH="$truncated_remove_input_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$truncated_remove_input_dir/remove.out" 2>"$truncated_remove_input_dir/remove.err"; then
  echo "remove accepted truncated interactive input"
  exit 1
fi
grep -q "Remove cancelled because input ended before choosing whether to remove the data directory" "$truncated_remove_input_dir/remove.err"
[[ ! -e "$truncated_remove_input_dir/docker.log" ]]
[[ -e "$truncated_remove_input_dir/install/.kvs-server.conf" ]]
[[ -e "$truncated_remove_input_dir/install/data/marker.txt" ]]

headless_remove_refusal_dir="$tmpdir/headless-remove-refusal"
mkdir -p "$headless_remove_refusal_dir/bin" "$headless_remove_refusal_dir/install/data"
make_config "$headless_remove_refusal_dir/install/.kvs-server.conf" headlessuser headlesspass
cat > "$headless_remove_refusal_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$headless_remove_refusal_dir/bin/docker"

if (
  cd "$headless_remove_refusal_dir/install"
  KVS_DOCKER_LOG="$headless_remove_refusal_dir/docker.log" PATH="$headless_remove_refusal_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" --headless remove </dev/null
) >"$headless_remove_refusal_dir/remove.out" 2>"$headless_remove_refusal_dir/remove.err"; then
  echo "headless remove succeeded without explicit confirmation"
  exit 1
fi
grep -q "Headless remove requires KVS_CONFIRM_REMOVE=true before removing anything" "$headless_remove_refusal_dir/remove.err"
[[ ! -e "$headless_remove_refusal_dir/docker.log" ]]
[[ -e "$headless_remove_refusal_dir/install/.kvs-server.conf" ]]
[[ -e "$headless_remove_refusal_dir/install/data" ]]

headless_remove_confirmed_dir="$tmpdir/headless-remove-confirmed"
mkdir -p "$headless_remove_confirmed_dir/bin" "$headless_remove_confirmed_dir/install/data"
make_config "$headless_remove_confirmed_dir/install/.kvs-server.conf" headlessuser headlesspass
printf 'data marker\n' > "$headless_remove_confirmed_dir/install/data/marker.txt"
cat > "$headless_remove_confirmed_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* && ! -f "$state_dir/removed" ]]; then
      if [[ "$*" == *" -a "* || ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    echo "false"
    ;;
  stop)
    touch "$state_dir/stopped"
    ;;
  rm)
    touch "$state_dir/removed"
    ;;
esac
DOCKER
chmod +x "$headless_remove_confirmed_dir/bin/docker"

(
  cd "$headless_remove_confirmed_dir/install"
  KVS_CONFIRM_REMOVE=true KVS_DOCKER_STATE_DIR="$headless_remove_confirmed_dir" PATH="$headless_remove_confirmed_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" --headless remove </dev/null
) >"$headless_remove_confirmed_dir/remove.out" 2>"$headless_remove_confirmed_dir/remove.err"

grep -q "Stopping container 'conversion-server'" "$headless_remove_confirmed_dir/remove.out"
grep -q "Removing container" "$headless_remove_confirmed_dir/remove.out"
grep -q "Headless mode: Keeping data directory: $headless_remove_confirmed_dir/install/data" "$headless_remove_confirmed_dir/remove.out"
grep -q "Headless mode: Keeping configuration file: $headless_remove_confirmed_dir/install/.kvs-server.conf" "$headless_remove_confirmed_dir/remove.out"
grep -q "✓ Cleanup completed" "$headless_remove_confirmed_dir/remove.out"
grep -q "docker stop conversion-server" "$headless_remove_confirmed_dir/docker.log"
grep -q "docker rm conversion-server" "$headless_remove_confirmed_dir/docker.log"
[[ -e "$headless_remove_confirmed_dir/install/.kvs-server.conf" ]]
[[ -e "$headless_remove_confirmed_dir/install/data/marker.txt" ]]
[[ ! -s "$headless_remove_confirmed_dir/remove.err" ]]

unsafe_config_dir="$tmpdir/unsafe-config"
mkdir -p "$unsafe_config_dir/install"
write_kvs_config "$unsafe_config_dir/install/.kvs-server.conf" \
  --ftp-user unsafeuser \
  --ftp-pass unsafepass \
  --num-folders 1
sed -i "1i: > \"$unsafe_config_dir/config_executed\"" "$unsafe_config_dir/install/.kvs-server.conf"

if run_from "$unsafe_config_dir/install" info >"$unsafe_config_dir/info.out" 2>"$unsafe_config_dir/info.err"; then
  echo "info accepted an invalid configuration command"
  exit 1
fi
[[ ! -e "$unsafe_config_dir/config_executed" ]]
grep -q "Invalid configuration line 1" "$unsafe_config_dir/info.err"

literal_command_dir="$tmpdir/literal-command-config"
mkdir -p "$literal_command_dir/install"
literal_ftp_pass="\$\\(touch\\ \"$literal_command_dir/config_executed\"\\)"
write_kvs_config "$literal_command_dir/install/.kvs-server.conf" \
  --ftp-user literaluser \
  --ftp-pass "$literal_ftp_pass" \
  --num-folders 1

literal_output=$(run_from "$literal_command_dir/install" info --show-password)
# shellcheck disable=SC2016
literal_password_prefix='FTP Password: $(touch '
[[ ! -e "$literal_command_dir/config_executed" ]]
[[ "$literal_output" == *"$literal_password_prefix"* ]]

relative_config_dir="$tmpdir/relative-config"
mkdir -p "$relative_config_dir/bin" "$relative_config_dir/install/data"
make_config "$relative_config_dir/install/.kvs-server.conf" relativeuser relativepass
cat > "$relative_config_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      [[ -f "$state_dir/running" ]] && echo "conversion-server"
    elif [[ -f "$state_dir/running" ]]; then
      echo "conversion-server Up 1 second"
    fi
    exit 0
    ;;
  run)
    touch "$state_dir/running"
    echo "container-id"
    ;;
  inspect)
    case "$*" in
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *)
        echo "2026-06-18T00:00:00Z"
        ;;
    esac
    ;;
  stats)
    echo "conversion-server 0.00% 10MiB / 1GiB 0B / 0B"
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$relative_config_dir/bin/docker"

(
  cd "$relative_config_dir/install"
  KVS_CONFIG=.kvs-server.conf KVS_DOCKER_STATE_DIR="$relative_config_dir" \
    PATH="$relative_config_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$relative_config_dir/start.out" 2>"$relative_config_dir/start.err"

grep -Fq -- "--mount type=bind\\,source=${relative_config_dir}/install/data\\,target=/home/vsftpd" "$relative_config_dir/docker.log"
if grep -Fq -- "source=./data" "$relative_config_dir/docker.log"; then
  echo "start used a relative Docker bind mount source for a relative KVS_CONFIG"
  exit 1
fi

(
  cd "$relative_config_dir/install"
  KVS_CONFIG=.kvs-server.conf KVS_DOCKER_STATE_DIR="$relative_config_dir" \
    PATH="$relative_config_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" info
) >"$relative_config_dir/info.out" 2>"$relative_config_dir/info.err"
grep -q "Config file: $relative_config_dir/install/.kvs-server.conf" "$relative_config_dir/info.out"

docker_error_dir="$tmpdir/docker-error"
mkdir -p "$docker_error_dir/bin" "$docker_error_dir/install"
make_config "$docker_error_dir/install/.kvs-server.conf" dockeruser dockerpass
cat > "$docker_error_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  ps)
    echo "docker daemon unavailable" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$docker_error_dir/bin/docker"

if (
  cd "$docker_error_dir/install"
  PATH="$docker_error_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" status
) >"$docker_error_dir/status.out" 2>"$docker_error_dir/status.err"; then
  echo "status ignored a Docker daemon error"
  exit 1
fi
grep -q "docker daemon unavailable" "$docker_error_dir/status.err"
grep -q "Unable to query Docker containers" "$docker_error_dir/status.err"
if grep -q "does not exist" "$docker_error_dir/status.out"; then
  echo "status reported a missing container after Docker daemon error"
  exit 1
fi

if (
  cd "$docker_error_dir/install"
  PATH="$docker_error_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" stop
) >"$docker_error_dir/stop.out" 2>"$docker_error_dir/stop.err"; then
  echo "stop ignored a Docker daemon error"
  exit 1
fi
grep -q "docker daemon unavailable" "$docker_error_dir/stop.err"
grep -q "Unable to query Docker containers" "$docker_error_dir/stop.err"
if grep -q "is not running" "$docker_error_dir/stop.out"; then
  echo "stop reported a stopped container after Docker daemon error"
  exit 1
fi

(
  cd "$docker_error_dir/install"
  PATH="$docker_error_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info
) >"$docker_error_dir/info.out" 2>"$docker_error_dir/info.err"
grep -q "docker daemon unavailable" "$docker_error_dir/info.err"
grep -q "Unable to query Docker containers; showing saved configuration only" "$docker_error_dir/info.err"
grep -q "Status: Unknown (Docker unavailable)" "$docker_error_dir/info.out"
grep -q "FTP User: dockeruser" "$docker_error_dir/info.out"
if grep -q "Status: Not created" "$docker_error_dir/info.out"; then
  echo "info reported a missing container after Docker daemon error"
  exit 1
fi

start_stats_failure_dir="$tmpdir/start-running-stats-failure"
mkdir -p "$start_stats_failure_dir/bin" "$start_stats_failure_dir/install"
make_config "$start_stats_failure_dir/install/.kvs-server.conf" statsuser statspass
cat > "$start_stats_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *State.Health.Status*)
        echo "healthy"
        ;;
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
    esac
    ;;
  stats)
    echo "stats unavailable" >&2
    exit 42
    ;;
  run|stop|rm)
    echo "start should not modify an already running container" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$start_stats_failure_dir/bin/docker"

(
  cd "$start_stats_failure_dir/install"
  KVS_DOCKER_LOG="$start_stats_failure_dir/docker.log" PATH="$start_stats_failure_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$start_stats_failure_dir/start.out" 2>"$start_stats_failure_dir/start.err"

grep -q "Container 'conversion-server' is already running" "$start_stats_failure_dir/start.out"
grep -q "stats unavailable" "$start_stats_failure_dir/start.err"
grep -q "Unable to display current container status" "$start_stats_failure_dir/start.err"
if grep -Eq "docker (run|stop|rm)" "$start_stats_failure_dir/docker.log"; then
  echo "start modified an already running container after docker stats failed"
  exit 1
fi

unexpected_args_dir="$tmpdir/unexpected-command-args"
mkdir -p "$unexpected_args_dir/install"
make_config "$unexpected_args_dir/install/.kvs-server.conf" arguser argpass
for command in status logs start stop restart update remove; do
  if run_from "$unexpected_args_dir/install" "$command" --bad-option \
    >"$unexpected_args_dir/$command.out" 2>"$unexpected_args_dir/$command.err"; then
    echo "$command accepted an unknown option"
    exit 1
  fi
  grep -q "Unknown option for $command: --bad-option" "$unexpected_args_dir/$command.err"
done
if grep -q "WARNING: This will remove" "$unexpected_args_dir/remove.out"; then
  echo "remove prompted before rejecting an unknown option"
  exit 1
fi
if grep -q "is not running" "$unexpected_args_dir/stop.out"; then
  echo "stop checked container state before rejecting an unknown option"
  exit 1
fi

invalid_config_dir="$tmpdir/invalid-config"
mkdir -p "$invalid_config_dir/bin" "$invalid_config_dir/install"
cat > "$invalid_config_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$invalid_config_dir/bin/docker"
write_kvs_config "$invalid_config_dir/install/.kvs-server.conf" \
  --ftp-user bad/user \
  --ftp-pass configpass123 \
  --num-folders 1

if (
  cd "$invalid_config_dir/install"
  KVS_DOCKER_LOG="$invalid_config_dir/docker.log" PATH="$invalid_config_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$invalid_config_dir/start.out" 2>"$invalid_config_dir/start.err"; then
  echo "start accepted an invalid saved FTP username"
  exit 1
fi

grep -q "FTP username may only contain" "$invalid_config_dir/start.err"
if grep -q "docker run" "$invalid_config_dir/docker.log"; then
  echo "start attempted docker run before validating saved config"
  exit 1
fi

missing_pass_start_dir="$tmpdir/missing-pass-start"
mkdir -p "$missing_pass_start_dir/bin" "$missing_pass_start_dir/install"
cat > "$missing_pass_start_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    exit 0
    ;;
  run)
    echo "docker run should not execute before FTP_PASS validation" >&2
    exit 1
    ;;
esac
DOCKER
chmod +x "$missing_pass_start_dir/bin/docker"
write_kvs_config "$missing_pass_start_dir/install/.kvs-server.conf" \
  --ftp-user testuser \
  --num-folders 1
sed -i '/^FTP_PASS=/d' "$missing_pass_start_dir/install/.kvs-server.conf"

if (
  cd "$missing_pass_start_dir/install"
  KVS_DOCKER_LOG="$missing_pass_start_dir/docker.log" PATH="$missing_pass_start_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$missing_pass_start_dir/start.out" 2>"$missing_pass_start_dir/start.err"; then
  echo "start accepted a saved config without FTP_PASS"
  exit 1
fi

grep -q "FTP password is required" "$missing_pass_start_dir/start.err"
if grep -q "docker run" "$missing_pass_start_dir/docker.log"; then
  echo "start attempted docker run before validating saved FTP_PASS"
  exit 1
fi

missing_pass_update_dir="$tmpdir/missing-pass-update"
mkdir -p "$missing_pass_update_dir/bin" "$missing_pass_update_dir/install"
cat > "$missing_pass_update_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  pull|stop|rm|run)
    echo "$1 should not execute before FTP_PASS validation" >&2
    exit 1
    ;;
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    fi
    ;;
esac
DOCKER
chmod +x "$missing_pass_update_dir/bin/docker"
write_kvs_config "$missing_pass_update_dir/install/.kvs-server.conf" \
  --ftp-user testuser \
  --num-folders 1
sed -i '/^FTP_PASS=/d' "$missing_pass_update_dir/install/.kvs-server.conf"

if (
  cd "$missing_pass_update_dir/install"
  KVS_HEADLESS=true KVS_DOCKER_LOG="$missing_pass_update_dir/docker.log" PATH="$missing_pass_update_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$missing_pass_update_dir/update.out" 2>"$missing_pass_update_dir/update.err"; then
  echo "update accepted a saved config without FTP_PASS"
  exit 1
fi

grep -q "FTP password is required" "$missing_pass_update_dir/update.err"
if [[ -e "$missing_pass_update_dir/docker.log" ]]; then
  echo "update touched Docker before validating saved FTP_PASS"
  cat "$missing_pass_update_dir/docker.log"
  exit 1
fi

invalid_remove_dir="$tmpdir/remove-invalid-config"
mkdir -p "$invalid_remove_dir/bin" "$invalid_remove_dir/install/data"
cat > "$invalid_remove_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
    esac
    ;;
  stop)
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$invalid_remove_dir/bin/docker"
write_kvs_config "$invalid_remove_dir/install/.kvs-server.conf" \
  --ftp-user bad/user \
  --ftp-pass configpass123 \
  --num-folders 1

(
  cd "$invalid_remove_dir/install"
  printf 'yes\nno\nno\n' | KVS_DOCKER_STATE_DIR="$invalid_remove_dir" PATH="$invalid_remove_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$invalid_remove_dir/remove.out" 2>"$invalid_remove_dir/remove.err"

grep -q "Container stopped successfully" "$invalid_remove_dir/remove.out"
grep -q "Removing container" "$invalid_remove_dir/remove.out"
grep -q "✓ Cleanup completed" "$invalid_remove_dir/remove.out"
grep -q "docker stop conversion-server" "$invalid_remove_dir/docker.log"
grep -q "docker rm conversion-server" "$invalid_remove_dir/docker.log"
if grep -q "FTP username may only contain" "$invalid_remove_dir/remove.err"; then
  echo "remove validated operational config before cleanup"
  exit 1
fi

missing_explicit_config_dir="$tmpdir/remove-missing-explicit-config"
mkdir -p "$missing_explicit_config_dir/data"
printf 'must stay\n' > "$missing_explicit_config_dir/data/marker.txt"

if printf 'yes\nyes\nno\n' | KVS_CONFIG="$missing_explicit_config_dir/missing.conf" \
  run_from "$missing_explicit_config_dir" remove >"$missing_explicit_config_dir/remove.out" 2>"$missing_explicit_config_dir/remove.err"; then
  echo "remove accepted a missing explicit KVS_CONFIG"
  exit 1
fi
grep -q "Configuration file not found: $missing_explicit_config_dir/missing.conf" "$missing_explicit_config_dir/remove.err"
[[ -e "$missing_explicit_config_dir/data/marker.txt" ]]
if grep -q "Data directory removed" "$missing_explicit_config_dir/remove.out"; then
  echo "remove deleted local data after missing explicit KVS_CONFIG"
  exit 1
fi

mkdir -p "$tmpdir/remove/install/sub/data" "$tmpdir/remove/install/data"
printf 'wrong directory marker\n' > "$tmpdir/remove/install/sub/data/wrong.txt"
printf 'installation directory marker\n' > "$tmpdir/remove/install/data/right.txt"
make_config "$tmpdir/remove/install/.kvs-server.conf" removeuser removepass

printf 'yes\nyes\nno\n' | run_from "$tmpdir/remove/install/sub" remove >"$tmpdir/remove-data.out"
[[ ! -e "$tmpdir/remove/install/data/right.txt" ]]
[[ -e "$tmpdir/remove/install/sub/data/wrong.txt" ]]
grep -q "Data directory removed: $tmpdir/remove/install/data" "$tmpdir/remove-data.out"

mkdir -p "$tmpdir/remove-config/install/sub" "$tmpdir/remove-config/install/data"
make_config "$tmpdir/remove-config/install/.kvs-server.conf" configuser configpass

printf 'yes\nno\nyes\n' | run_from "$tmpdir/remove-config/install/sub" remove >"$tmpdir/remove-config.out"
[[ ! -e "$tmpdir/remove-config/install/.kvs-server.conf" ]]
grep -q "Configuration file removed: $tmpdir/remove-config/install/.kvs-server.conf" "$tmpdir/remove-config.out"

race_dir="$tmpdir/remove-race"
mkdir -p "$race_dir/bin" "$race_dir/install/data"
make_config "$race_dir/install/.kvs-server.conf" raceuser racepass
cat > "$race_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

case "$1" in
  ps)
    if [[ "${2:-}" == "-a" ]]; then
      [[ -f "$state_dir/removed" ]] || echo "conversion-server"
    else
      [[ -f "$state_dir/stopped" ]] || echo "conversion-server"
    fi
    ;;
  stop)
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  rm)
    touch "$state_dir/removed"
    echo "Error response from daemon: removal of container conversion-server is already in progress" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$race_dir/bin/docker"

(
  cd "$race_dir/install"
  printf 'yes\nno\nno\n' | \
    KVS_DOCKER_STATE_DIR="$race_dir" PATH="$race_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$race_dir/remove.out" 2>"$race_dir/remove.err"

grep -q "removal of container conversion-server is already in progress" "$race_dir/remove.err"
grep -q "Container removed" "$race_dir/remove.out"
grep -q "✓ Cleanup completed" "$race_dir/remove.out"

owned_dir="$tmpdir/container-owned,data"
mkdir -p "$owned_dir/bin" "$owned_dir/install/data"
make_config "$owned_dir/install/.kvs-server.conf" owneduser ownedpass
sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=cleanup-tag/' "$owned_dir/install/.kvs-server.conf"
cat > "$owned_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    exit 0
    ;;
  run)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$owned_dir/bin/docker"
cat > "$owned_dir/bin/rm" <<'RM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "$KVS_FAIL_RM_PATH" ]] && [[ ! -f "$KVS_RM_FAILED_ONCE" ]]; then
    touch "$KVS_RM_FAILED_ONCE"
    exit 1
  fi
done
exec /bin/rm "$@"
RM
chmod +x "$owned_dir/bin/rm"

(
  cd "$owned_dir/install"
  printf 'yes\nyes\nno\n' | \
    KVS_DOCKER_LOG="$owned_dir/docker.log" \
    KVS_FAIL_RM_PATH="$owned_dir/install/data" \
    KVS_RM_FAILED_ONCE="$owned_dir/rm-failed-once" \
    TMPDIR="$tmpdir" \
    PATH="$owned_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$owned_dir/remove.out" 2>&1

[[ ! -e "$owned_dir/install/data" ]]
grep -q "Direct removal failed. Retrying through Docker for container-owned files" "$owned_dir/remove.out"
grep -q "docker run --rm --entrypoint /bin/chown" "$owned_dir/docker.log"
grep -q "maximemichaud/kvs-conversion-server:cleanup-tag" "$owned_dir/docker.log"
if grep -q "maximemichaud/kvs-conversion-server:$default_image_tag" "$owned_dir/docker.log"; then
  echo "remove used the default image tag instead of the saved cleanup tag"
  exit 1
fi
owned_alias_root="$tmpdir/kvs-conversion-server-mounts-$(id -u)"
owned_alias_link=$(find "$owned_alias_root" -maxdepth 1 -type l | head -n 1)
[[ -n "$owned_alias_link" ]]
[[ "$(readlink "$owned_alias_link")" == "$owned_dir/install/data" ]]
grep -Fq -- "--mount type=bind\\,source=${owned_alias_link}\\,target=/data" "$owned_dir/docker.log"
if grep -Fq -- "source=${owned_dir}/install/data" "$owned_dir/docker.log"; then
  echo "remove passed an unescaped comma path directly to Docker --mount"
  exit 1
fi
if grep -q -- " -v " "$owned_dir/docker.log"; then
  echo "remove used -v for a data path that may contain colons"
  exit 1
fi
grep -q "Data directory removed: $owned_dir/install/data" "$owned_dir/remove.out"

missing_cleanup_tag_dir="$tmpdir/container-owned-missing-image-tag"
mkdir -p "$missing_cleanup_tag_dir/bin" "$missing_cleanup_tag_dir/install/data"
make_config "$missing_cleanup_tag_dir/install/.kvs-server.conf" missingtaguser missingtagpass
sed -i '/^IMAGE_TAG=/d' "$missing_cleanup_tag_dir/install/.kvs-server.conf"
cat > "$missing_cleanup_tag_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    exit 0
    ;;
  run)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$missing_cleanup_tag_dir/bin/docker"
cat > "$missing_cleanup_tag_dir/bin/rm" <<'RM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "$KVS_FAIL_RM_PATH" ]] && [[ ! -f "$KVS_RM_FAILED_ONCE" ]]; then
    touch "$KVS_RM_FAILED_ONCE"
    exit 1
  fi
done
exec /bin/rm "$@"
RM
chmod +x "$missing_cleanup_tag_dir/bin/rm"

(
  cd "$missing_cleanup_tag_dir/install"
  printf 'yes\nyes\nno\n' | \
    KVS_DOCKER_LOG="$missing_cleanup_tag_dir/docker.log" \
    KVS_FAIL_RM_PATH="$missing_cleanup_tag_dir/install/data" \
    KVS_RM_FAILED_ONCE="$missing_cleanup_tag_dir/rm-failed-once" \
    PATH="$missing_cleanup_tag_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$missing_cleanup_tag_dir/remove.out" 2>&1

[[ ! -e "$missing_cleanup_tag_dir/install/data" ]]
grep -q "Direct removal failed. Retrying through Docker for container-owned files" "$missing_cleanup_tag_dir/remove.out"
grep -q "docker run --rm --entrypoint /bin/chown" "$missing_cleanup_tag_dir/docker.log"
grep -q "maximemichaud/kvs-conversion-server:$default_image_tag" "$missing_cleanup_tag_dir/docker.log"
if grep -q "maximemichaud/kvs-conversion-server: " "$missing_cleanup_tag_dir/docker.log"; then
  echo "remove used an empty image tag for Docker cleanup"
  exit 1
fi
grep -q "Data directory removed: $missing_cleanup_tag_dir/install/data" "$missing_cleanup_tag_dir/remove.out"

invalid_cleanup_tag_dir="$tmpdir/container-owned-invalid-image-tag"
mkdir -p "$invalid_cleanup_tag_dir/bin" "$invalid_cleanup_tag_dir/install/data"
make_config "$invalid_cleanup_tag_dir/install/.kvs-server.conf" invalidtaguser invalidtagpass
sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=bad/tag|' "$invalid_cleanup_tag_dir/install/.kvs-server.conf"
cat > "$invalid_cleanup_tag_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    exit 0
    ;;
  run)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$invalid_cleanup_tag_dir/bin/docker"
cat > "$invalid_cleanup_tag_dir/bin/rm" <<'RM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "$KVS_FAIL_RM_PATH" ]] && [[ ! -f "$KVS_RM_FAILED_ONCE" ]]; then
    touch "$KVS_RM_FAILED_ONCE"
    exit 1
  fi
done
exec /bin/rm "$@"
RM
chmod +x "$invalid_cleanup_tag_dir/bin/rm"

(
  cd "$invalid_cleanup_tag_dir/install"
  printf 'yes\nyes\nno\n' | \
    KVS_DOCKER_LOG="$invalid_cleanup_tag_dir/docker.log" \
    KVS_FAIL_RM_PATH="$invalid_cleanup_tag_dir/install/data" \
    KVS_RM_FAILED_ONCE="$invalid_cleanup_tag_dir/rm-failed-once" \
    PATH="$invalid_cleanup_tag_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$invalid_cleanup_tag_dir/remove.out" 2>"$invalid_cleanup_tag_dir/remove.err"

[[ ! -e "$invalid_cleanup_tag_dir/install/data" ]]
grep -q "Saved Docker image tag 'bad/tag' is invalid; using default tag '$default_image_tag' for data cleanup" "$invalid_cleanup_tag_dir/remove.err"
grep -q "Direct removal failed. Retrying through Docker for container-owned files" "$invalid_cleanup_tag_dir/remove.out"
grep -q "docker run --rm --entrypoint /bin/chown" "$invalid_cleanup_tag_dir/docker.log"
grep -q "maximemichaud/kvs-conversion-server:$default_image_tag" "$invalid_cleanup_tag_dir/docker.log"
if grep -q "maximemichaud/kvs-conversion-server:bad/tag" "$invalid_cleanup_tag_dir/docker.log"; then
  echo "remove used an invalid image tag for Docker cleanup"
  exit 1
fi
grep -q "Data directory removed: $invalid_cleanup_tag_dir/install/data" "$invalid_cleanup_tag_dir/remove.out"

duplicate_cleanup_tag_dir="$tmpdir/container-owned-duplicate-image-tag"
mkdir -p "$duplicate_cleanup_tag_dir/bin" "$duplicate_cleanup_tag_dir/install/data"
make_config "$duplicate_cleanup_tag_dir/install/.kvs-server.conf" duplicatetaguser duplicatetagpass
sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=old-tag/' "$duplicate_cleanup_tag_dir/install/.kvs-server.conf"
printf 'IMAGE_TAG=new-tag\n' >> "$duplicate_cleanup_tag_dir/install/.kvs-server.conf"
cat > "$duplicate_cleanup_tag_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    exit 0
    ;;
  run)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$duplicate_cleanup_tag_dir/bin/docker"
cat > "$duplicate_cleanup_tag_dir/bin/rm" <<'RM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "$KVS_FAIL_RM_PATH" ]] && [[ ! -f "$KVS_RM_FAILED_ONCE" ]]; then
    touch "$KVS_RM_FAILED_ONCE"
    exit 1
  fi
done
exec /bin/rm "$@"
RM
chmod +x "$duplicate_cleanup_tag_dir/bin/rm"

(
  cd "$duplicate_cleanup_tag_dir/install"
  printf 'yes\nyes\nno\n' | \
    KVS_DOCKER_LOG="$duplicate_cleanup_tag_dir/docker.log" \
    KVS_FAIL_RM_PATH="$duplicate_cleanup_tag_dir/install/data" \
    KVS_RM_FAILED_ONCE="$duplicate_cleanup_tag_dir/rm-failed-once" \
    PATH="$duplicate_cleanup_tag_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" remove
) >"$duplicate_cleanup_tag_dir/remove.out" 2>&1

[[ ! -e "$duplicate_cleanup_tag_dir/install/data" ]]
grep -q "maximemichaud/kvs-conversion-server:new-tag" "$duplicate_cleanup_tag_dir/docker.log"
if grep -q "maximemichaud/kvs-conversion-server:old-tag" "$duplicate_cleanup_tag_dir/docker.log"; then
  echo "remove used the first duplicate image tag instead of the parsed image tag"
  exit 1
fi
grep -q "Data directory removed: $duplicate_cleanup_tag_dir/install/data" "$duplicate_cleanup_tag_dir/remove.out"

update_dir="$tmpdir/update-auto-remove"
mkdir -p "$update_dir/bin" "$update_dir/install"
make_config "$update_dir/install/.kvs-server.conf" updateuser updatepass
cat > "$update_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ "$args" == *"-a"* ]]; then
        if [[ -f "$state_dir/stopped" ]]; then
          if [[ ! -f "$state_dir/removal-observed" ]]; then
            touch "$state_dir/removal-observed"
            echo "conversion-server"
          else
            touch "$state_dir/removed"
          fi
        else
          echo "conversion-server"
        fi
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "true"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  pull)
    echo "pulled"
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  start)
    echo "Error response from daemon: container is marked for removal and cannot be started" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    touch "$state_dir/new-running"
    printf 'docker' >> "$state_dir/docker.log"
    for arg in "$@"; do
      printf ' %q' "$arg" >> "$state_dir/docker.log"
    done
    printf '\n' >> "$state_dir/docker.log"
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_dir/bin/docker"

(
  cd "$update_dir/install"
  printf 'yes\n' | \
    KVS_DOCKER_STATE_DIR="$update_dir" PATH="$update_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$update_dir/update.out" 2>"$update_dir/update.err"

grep -q "Container stopped successfully" "$update_dir/update.out"
grep -q "Creating and starting container with saved configuration" "$update_dir/update.out"
grep -q "Update completed and container restarted" "$update_dir/update.out"
grep -q "docker run --rm -d --name conversion-server --cpus" "$update_dir/docker.log"
[[ ! -s "$update_dir/update.err" ]]

stop_start_dir="$tmpdir/stop-start-auto-remove"
mkdir -p "$stop_start_dir/bin" "$stop_start_dir/install"
make_config "$stop_start_dir/install/.kvs-server.conf" stopstartuser stopstartpass
cat > "$stop_start_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ "$args" == *"-a"* ]]; then
        if [[ -f "$state_dir/stopped" ]]; then
          if [[ ! -f "$state_dir/removal-observed" ]]; then
            touch "$state_dir/removal-observed"
            echo "conversion-server"
          else
            touch "$state_dir/removed"
          fi
        else
          echo "conversion-server"
        fi
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "true"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  stop)
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  start)
    echo "Error response from daemon: container is marked for removal and cannot be started" >&2
    exit 1
    ;;
  run)
    touch "$state_dir/new-running"
    printf 'docker' >> "$state_dir/docker.log"
    for arg in "$@"; do
      printf ' %q' "$arg" >> "$state_dir/docker.log"
    done
    printf '\n' >> "$state_dir/docker.log"
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$stop_start_dir/bin/docker"

(
  cd "$stop_start_dir/install"
  KVS_DOCKER_STATE_DIR="$stop_start_dir" PATH="$stop_start_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" stop
) >"$stop_start_dir/stop.out" 2>"$stop_start_dir/stop.err"

(
  cd "$stop_start_dir/install"
  KVS_DOCKER_STATE_DIR="$stop_start_dir" PATH="$stop_start_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$stop_start_dir/start.out" 2>"$stop_start_dir/start.err"

grep -q "Container stopped successfully" "$stop_start_dir/stop.out"
grep -q "Creating and starting container with saved configuration" "$stop_start_dir/start.out"
grep -q "docker run --rm -d --name conversion-server --cpus" "$stop_start_dir/docker.log"
[[ ! -s "$stop_start_dir/stop.err" ]]
[[ ! -s "$stop_start_dir/start.err" ]]

start_stopped_dir="$tmpdir/start-stopped-recreate"
mkdir -p "$start_stopped_dir/bin" "$start_stopped_dir/install"
make_config "$start_stopped_dir/install/.kvs-server.conf" startuser startpass
cat > "$start_stopped_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  start)
    echo "docker start should not be used for stopped container recreation" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    touch "$state_dir/new-running"
    echo "new-container-id"
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    exit 0
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$start_stopped_dir/bin/docker"

(
  cd "$start_stopped_dir/install"
  KVS_DOCKER_STATE_DIR="$start_stopped_dir" PATH="$start_stopped_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$start_stopped_dir/start.out" 2>"$start_stopped_dir/start.err"

grep -q "Container exists but is stopped. Recreating from saved configuration" "$start_stopped_dir/start.out"
grep -q "Removing existing container 'conversion-server' before recreating it" "$start_stopped_dir/start.out"
grep -q "Creating and starting container with saved configuration" "$start_stopped_dir/start.out"
grep -q "docker rm conversion-server" "$start_stopped_dir/docker.log"
grep -q "docker run --rm -d --name conversion-server --cpus" "$start_stopped_dir/docker.log"
if grep -q "docker start conversion-server" "$start_stopped_dir/docker.log"; then
  echo "start used docker start instead of recreating stopped container"
  exit 1
fi
[[ ! -s "$start_stopped_dir/start.err" ]]

start_preflight_failure_dir="$tmpdir/start-stopped-preflight-failure"
mkdir -p "$start_preflight_failure_dir/bin" "$start_preflight_failure_dir/install"
make_config "$start_preflight_failure_dir/install/.kvs-server.conf" startfailuser startfailpass
cat > "$start_preflight_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* && "$args" == *"-a"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
    esac
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      echo "docker: simulated stopped-container startup failure" >&2
      exit 125
    fi
    echo "final replacement run should not execute after failed start startup preflight" >&2
    exit 1
    ;;
  rm)
    touch "$state_dir/rm-called"
    echo "docker rm should not run after failed start startup preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$start_preflight_failure_dir/bin/docker"

if (
  cd "$start_preflight_failure_dir/install"
  KVS_DOCKER_STATE_DIR="$start_preflight_failure_dir" PATH="$start_preflight_failure_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$start_preflight_failure_dir/start.out" 2>"$start_preflight_failure_dir/start.err"; then
  echo "start continued after replacement startup preflight failed"
  exit 1
fi

grep -q "Container exists but is stopped. Recreating from saved configuration" "$start_preflight_failure_dir/start.out"
grep -q "Checking replacement container startup before stopping the existing container" "$start_preflight_failure_dir/start.out"
grep -q "simulated stopped-container startup failure" "$start_preflight_failure_dir/start.err"
grep -q "Replacement container failed to start. Existing container was left running." "$start_preflight_failure_dir/start.err"
grep -q -- "--name conversion-server-start-check-" "$start_preflight_failure_dir/docker.log"
if grep -q "docker rm conversion-server" "$start_preflight_failure_dir/docker.log"; then
  echo "start removed the stopped container after failed startup preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$start_preflight_failure_dir/docker.log"; then
  echo "start attempted final replacement after failed startup preflight"
  exit 1
fi
if grep -Fq -- "source=${start_preflight_failure_dir}/install/data" "$start_preflight_failure_dir/docker.log"; then
  echo "start startup preflight mounted the live data directory"
  exit 1
fi
[[ ! -e "$start_preflight_failure_dir/rm-called" ]]

restart_stopped_dir="$tmpdir/restart-stopped-recreate"
mkdir -p "$restart_stopped_dir/bin" "$restart_stopped_dir/install"
make_config "$restart_stopped_dir/install/.kvs-server.conf" restartuser restartpass
cat > "$restart_stopped_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  restart)
    echo "docker restart should not be used for stopped container recreation" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    touch "$state_dir/new-running"
    echo "new-container-id"
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    exit 0
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$restart_stopped_dir/bin/docker"

(
  cd "$restart_stopped_dir/install"
  KVS_DOCKER_STATE_DIR="$restart_stopped_dir" PATH="$restart_stopped_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" restart
) >"$restart_stopped_dir/restart.out" 2>"$restart_stopped_dir/restart.err"

grep -q "Container exists but is stopped. Recreating from saved configuration" "$restart_stopped_dir/restart.out"
grep -q "Removing existing container 'conversion-server' before recreating it" "$restart_stopped_dir/restart.out"
grep -q "Creating and starting container with saved configuration" "$restart_stopped_dir/restart.out"
grep -q "docker rm conversion-server" "$restart_stopped_dir/docker.log"
grep -q "docker run --rm -d --name conversion-server --cpus" "$restart_stopped_dir/docker.log"
if grep -q "docker restart conversion-server" "$restart_stopped_dir/docker.log"; then
  echo "restart used docker restart instead of recreating stopped container"
  exit 1
fi
[[ ! -s "$restart_stopped_dir/restart.err" ]]

restart_running_dir="$tmpdir/restart-running-recreate"
mkdir -p "$restart_running_dir/bin" "$restart_running_dir/install"
make_config "$restart_running_dir/install/.kvs-server.conf" runningrestartuser runningrestartpass
cat > "$restart_running_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  restart)
    echo "docker restart should not be used because it reruns the entrypoint in a dirty container filesystem" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    if [[ ! -f "$state_dir/removed" ]]; then
      echo 'docker: Error response from daemon: Conflict. The container name "/conversion-server" is already in use.' >&2
      exit 125
    fi
    touch "$state_dir/new-running"
    echo "new-container-id"
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$restart_running_dir/bin/docker"

(
  cd "$restart_running_dir/install"
  KVS_DOCKER_STATE_DIR="$restart_running_dir" PATH="$restart_running_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" restart
) >"$restart_running_dir/restart.out" 2>"$restart_running_dir/restart.err"

grep -q "Restarting container 'conversion-server' from saved configuration" "$restart_running_dir/restart.out"
grep -q "Stopping container 'conversion-server'" "$restart_running_dir/restart.out"
grep -q "Removing existing container 'conversion-server' before recreating it" "$restart_running_dir/restart.out"
grep -q "Creating and starting container with saved configuration" "$restart_running_dir/restart.out"
grep -q "docker stop conversion-server" "$restart_running_dir/docker.log"
grep -q "docker rm conversion-server" "$restart_running_dir/docker.log"
grep -q "docker run --rm -d --name conversion-server --cpus" "$restart_running_dir/docker.log"
if grep -q "docker restart conversion-server" "$restart_running_dir/docker.log"; then
  echo "restart used docker restart instead of recreating the running container"
  exit 1
fi
[[ ! -s "$restart_running_dir/restart.err" ]]

restart_preflight_failure_dir="$tmpdir/restart-start-preflight-failure"
mkdir -p "$restart_preflight_failure_dir/bin" "$restart_preflight_failure_dir/install"
make_config "$restart_preflight_failure_dir/install/.kvs-server.conf" preflightfailuser preflightfailpass
cat > "$restart_preflight_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "true"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
    esac
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      echo "docker: simulated replacement startup failure" >&2
      exit 125
    fi
    echo "replacement docker run should not execute after failed startup preflight" >&2
    exit 1
    ;;
  stop|rm)
    touch "$state_dir/$1-called"
    echo "docker $1 should not run after failed startup preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$restart_preflight_failure_dir/bin/docker"

if (
  cd "$restart_preflight_failure_dir/install"
  KVS_DOCKER_STATE_DIR="$restart_preflight_failure_dir" PATH="$restart_preflight_failure_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" restart
) >"$restart_preflight_failure_dir/restart.out" 2>"$restart_preflight_failure_dir/restart.err"; then
  echo "restart continued after replacement startup preflight failed"
  exit 1
fi

grep -q "Restarting container 'conversion-server' from saved configuration" "$restart_preflight_failure_dir/restart.out"
grep -q "Checking replacement container startup before stopping the existing container" "$restart_preflight_failure_dir/restart.out"
grep -q "simulated replacement startup failure" "$restart_preflight_failure_dir/restart.err"
grep -q "Replacement container failed to start. Existing container was left running." "$restart_preflight_failure_dir/restart.err"
grep -q -- "--name conversion-server-start-check-" "$restart_preflight_failure_dir/docker.log"
if grep -q "docker stop conversion-server" "$restart_preflight_failure_dir/docker.log"; then
  echo "restart stopped the existing container after failed startup preflight"
  exit 1
fi
if grep -q "docker rm conversion-server" "$restart_preflight_failure_dir/docker.log"; then
  echo "restart removed the existing container after failed startup preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$restart_preflight_failure_dir/docker.log"; then
  echo "restart attempted final replacement after failed startup preflight"
  exit 1
fi
if grep -Fq -- "source=${restart_preflight_failure_dir}/install/data" "$restart_preflight_failure_dir/docker.log"; then
  echo "restart startup preflight mounted the live data directory"
  exit 1
fi
[[ ! -e "$restart_preflight_failure_dir/stop-called" ]]
[[ ! -e "$restart_preflight_failure_dir/rm-called" ]]

restart_invalid_config_dir="$tmpdir/restart-invalid-config"
mkdir -p "$restart_invalid_config_dir/bin" "$restart_invalid_config_dir/install"
make_config "$restart_invalid_config_dir/install/.kvs-server.conf" "bad/user" restartpass
cat > "$restart_invalid_config_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
    esac
    ;;
  stop)
    echo "restart stopped a container before validating saved configuration" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$restart_invalid_config_dir/bin/docker"

if (
  cd "$restart_invalid_config_dir/install"
  KVS_DOCKER_STATE_DIR="$restart_invalid_config_dir" PATH="$restart_invalid_config_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" restart
) >"$restart_invalid_config_dir/restart.out" 2>"$restart_invalid_config_dir/restart.err"; then
  echo "restart succeeded with invalid saved configuration"
  exit 1
fi

grep -q "FTP username may only contain letters" "$restart_invalid_config_dir/restart.err"
if [[ -f "$restart_invalid_config_dir/docker.log" ]]; then
  echo "restart touched Docker before validating saved configuration"
  cat "$restart_invalid_config_dir/docker.log"
  exit 1
fi

restart_stop_failure_dir="$tmpdir/restart-stop-failure"
mkdir -p "$restart_stop_failure_dir/bin" "$restart_stop_failure_dir/install"
make_config "$restart_stop_failure_dir/install/.kvs-server.conf" stopfailuser stopfailpass
cat > "$restart_stop_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      else
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
    esac
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    echo "simulated stop failure" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    echo "restart recreated a container after docker stop failed" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$restart_stop_failure_dir/bin/docker"

if (
  cd "$restart_stop_failure_dir/install"
  KVS_DOCKER_STATE_DIR="$restart_stop_failure_dir" PATH="$restart_stop_failure_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" restart
) >"$restart_stop_failure_dir/restart.out" 2>"$restart_stop_failure_dir/restart.err"; then
  echo "restart succeeded after docker stop failed"
  exit 1
fi

grep -q "simulated stop failure" "$restart_stop_failure_dir/restart.err"
grep -q "docker stop conversion-server" "$restart_stop_failure_dir/docker.log"
if grep -q "Container stopped successfully" "$restart_stop_failure_dir/restart.out"; then
  echo "restart reported a successful stop after docker stop failed"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$restart_stop_failure_dir/docker.log"; then
  echo "restart recreated a container after docker stop failed"
  exit 1
fi

start_busy_port_dir="$tmpdir/start-stopped-busy-port"
mkdir -p "$start_busy_port_dir/bin" "$start_busy_port_dir/install"
make_config "$start_busy_port_dir/install/.kvs-server.conf" portuser portpass
cat > "$start_busy_port_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* && "$args" == *"-a"* ]]; then
      echo "conversion-server"
    fi
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      echo "docker: Error response from daemon: Bind for 0.0.0.0:21 failed: port is already allocated" >&2
      exit 125
    fi
    echo "replacement docker run should not execute after failed start port preflight" >&2
    exit 1
    ;;
  rm)
    echo "docker rm should not run after a failed start port preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$start_busy_port_dir/bin/docker"

if (
  cd "$start_busy_port_dir/install"
  KVS_DOCKER_STATE_DIR="$start_busy_port_dir" PATH="$start_busy_port_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$start_busy_port_dir/start.out" 2>"$start_busy_port_dir/start.err"; then
  echo "start continued after required port preflight failed"
  exit 1
fi

grep -q "Container exists but is stopped. Recreating from saved configuration" "$start_busy_port_dir/start.out"
grep -q "Checking Docker port availability before replacing the existing container" "$start_busy_port_dir/start.out"
grep -q "Bind for 0.0.0.0:21 failed" "$start_busy_port_dir/start.err"
grep -q "Required Docker ports are not available. Existing container was left untouched." "$start_busy_port_dir/start.err"
grep -q -- "-p 21:21" "$start_busy_port_dir/docker.log"
if grep -q "docker rm conversion-server" "$start_busy_port_dir/docker.log"; then
  echo "start removed the existing container after failed port preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$start_busy_port_dir/docker.log"; then
  echo "start attempted replacement after failed port preflight"
  exit 1
fi

update_recreate_dir="$tmpdir/update-recreate-non-auto-remove"
mkdir -p "$update_recreate_dir/bin" "$update_recreate_dir/install"
make_config "$update_recreate_dir/install/.kvs-server.conf" updateuser updatepass
cat > "$update_recreate_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  pull)
    echo "image pulled"
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  start)
    echo "docker start should not be used during update recreation" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    if [[ ! -f "$state_dir/removed" ]]; then
      echo 'docker: Error response from daemon: Conflict. The container name "/conversion-server" is already in use.' >&2
      exit 125
    fi
    touch "$state_dir/new-running"
    echo "new-container-id"
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_recreate_dir/bin/docker"

(
  cd "$update_recreate_dir/install"
  printf 'yes\n' | \
    KVS_DOCKER_STATE_DIR="$update_recreate_dir" PATH="$update_recreate_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$update_recreate_dir/update.out" 2>"$update_recreate_dir/update.err"

grep -q "Removing existing container 'conversion-server' before recreating it" "$update_recreate_dir/update.out"
grep -q "Creating and starting container with saved configuration" "$update_recreate_dir/update.out"
grep -q "Update completed and container restarted" "$update_recreate_dir/update.out"
grep -q "docker rm conversion-server" "$update_recreate_dir/docker.log"
grep -q "docker run --rm -d --name conversion-server --cpus" "$update_recreate_dir/docker.log"
if grep -q "docker start conversion-server" "$update_recreate_dir/docker.log"; then
  echo "update restarted the old container instead of recreating it"
  exit 1
fi
[[ ! -s "$update_recreate_dir/update.err" ]]

update_deferred_dir="$tmpdir/update-deferred-restart-message"
mkdir -p "$update_deferred_dir/bin" "$update_deferred_dir/install"
make_config "$update_deferred_dir/install/.kvs-server.conf" deferuser deferpass
cat > "$update_deferred_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
    esac
    ;;
  pull|stats)
    exit 0
    ;;
  run|stop|rm|restart)
    echo "docker $1 should not run when update restart is deferred" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_deferred_dir/bin/docker"

(
  cd "$update_deferred_dir/install"
  printf 'no\n' | \
    KVS_DOCKER_STATE_DIR="$update_deferred_dir" PATH="$update_deferred_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$update_deferred_dir/update.out" 2>"$update_deferred_dir/update.err"

grep -q "Update completed. Stop and start the container to recreate it with the new image." "$update_deferred_dir/update.out"
if grep -q "Restart manually to use new image" "$update_deferred_dir/update.out"; then
  echo "update suggested restart even though restart does not recreate the container"
  exit 1
fi
grep -q "docker pull maximemichaud/kvs-conversion-server:$default_image_tag" "$update_deferred_dir/docker.log"
if grep -Eq "docker (run|stop|rm|restart)" "$update_deferred_dir/docker.log"; then
  echo "update modified the running container after restart was deferred"
  exit 1
fi
[[ ! -s "$update_deferred_dir/update.err" ]]

update_closed_stdin_dir="$tmpdir/update-closed-stdin"
mkdir -p "$update_closed_stdin_dir/bin" "$update_closed_stdin_dir/install"
make_config "$update_closed_stdin_dir/install/.kvs-server.conf" closedstdinuser closedstdinpass
cat > "$update_closed_stdin_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  pull|run|stop|rm|restart)
    echo "docker $1 should not run when update cannot read the restart choice" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_closed_stdin_dir/bin/docker"

if (
  cd "$update_closed_stdin_dir/install"
  KVS_DOCKER_STATE_DIR="$update_closed_stdin_dir" PATH="$update_closed_stdin_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update </dev/null
) >"$update_closed_stdin_dir/update.out" 2>"$update_closed_stdin_dir/update.err"; then
  echo "update succeeded even though it could not read the restart choice"
  exit 1
fi

grep -q "Unable to read restart choice" "$update_closed_stdin_dir/update.err"
if grep -Eq "docker (pull|run|stop|rm|restart)" "$update_closed_stdin_dir/docker.log"; then
  echo "update touched Docker after failing to read the restart choice"
  cat "$update_closed_stdin_dir/docker.log"
  exit 1
fi

update_headless_dir="$tmpdir/update-headless"
mkdir -p "$update_headless_dir/bin" "$update_headless_dir/install"
make_config "$update_headless_dir/install/.kvs-server.conf" headlessuser headlesspass
cat > "$update_headless_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  pull)
    echo "image pulled"
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    touch "$state_dir/stopped"
    echo "conversion-server"
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  start)
    echo "docker start should not be used during headless update recreation" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    if [[ ! -f "$state_dir/removed" ]]; then
      echo 'docker: Error response from daemon: Conflict. The container name "/conversion-server" is already in use.' >&2
      exit 125
    fi
    touch "$state_dir/new-running"
    echo "new-container-id"
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_headless_dir/bin/docker"

(
  cd "$update_headless_dir/install"
  KVS_DOCKER_STATE_DIR="$update_headless_dir" PATH="$update_headless_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" --headless update </dev/null
) >"$update_headless_dir/update.out" 2>"$update_headless_dir/update.err"

grep -q "Headless mode: Restarting container with new image" "$update_headless_dir/update.out"
grep -q "Removing existing container 'conversion-server' before recreating it" "$update_headless_dir/update.out"
grep -q "Creating and starting container with saved configuration" "$update_headless_dir/update.out"
grep -q "Update completed and container restarted" "$update_headless_dir/update.out"
grep -q "docker rm conversion-server" "$update_headless_dir/docker.log"
grep -q "docker run --rm -d --name conversion-server --cpus" "$update_headless_dir/docker.log"
if grep -q "docker start conversion-server" "$update_headless_dir/docker.log"; then
  echo "headless update restarted the old container instead of recreating it"
  exit 1
fi
[[ ! -s "$update_headless_dir/update.err" ]]

update_busy_port_dir="$tmpdir/update-busy-port-preflight"
mkdir -p "$update_busy_port_dir/bin" "$update_busy_port_dir/install"
make_config "$update_busy_port_dir/install/.kvs-server.conf" busyupdateuser busyupdatepass
sed -i 's/^FTP_MODE=.*/FTP_MODE=ftps_implicit/' "$update_busy_port_dir/install/.kvs-server.conf"
cat > "$update_busy_port_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *NetworkSettings.Ports*)
        echo "21"
        seq 21100 21110
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  pull)
    echo "image pulled"
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      echo "docker: Error response from daemon: Bind for 0.0.0.0:990 failed: port is already allocated" >&2
      exit 125
    fi
    echo "replacement docker run should not execute after failed update port preflight" >&2
    exit 1
    ;;
  stop|rm)
    echo "docker $1 should not run after a failed update port preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_busy_port_dir/bin/docker"

if (
  cd "$update_busy_port_dir/install"
  KVS_HEADLESS=true KVS_DOCKER_STATE_DIR="$update_busy_port_dir" PATH="$update_busy_port_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update </dev/null
) >"$update_busy_port_dir/update.out" 2>"$update_busy_port_dir/update.err"; then
  echo "headless update continued after required port preflight failed"
  exit 1
fi

grep -q "Headless mode: Restarting container with new image" "$update_busy_port_dir/update.out"
grep -q "Checking Docker port availability before replacing the existing container" "$update_busy_port_dir/update.out"
grep -q "Bind for 0.0.0.0:990 failed" "$update_busy_port_dir/update.err"
grep -q "Required Docker ports are not available. Existing container was left untouched." "$update_busy_port_dir/update.err"
grep -q "docker pull maximemichaud/kvs-conversion-server:$default_image_tag" "$update_busy_port_dir/docker.log"
grep -q -- "-p 990:990" "$update_busy_port_dir/docker.log"
if grep -q "docker stop conversion-server" "$update_busy_port_dir/docker.log"; then
  echo "headless update stopped the existing container after failed port preflight"
  exit 1
fi
if grep -q "docker rm conversion-server" "$update_busy_port_dir/docker.log"; then
  echo "headless update removed the existing container after failed port preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$update_busy_port_dir/docker.log"; then
  echo "headless update attempted replacement after failed port preflight"
  exit 1
fi

update_stopped_busy_port_dir="$tmpdir/update-stopped-busy-port"
mkdir -p "$update_stopped_busy_port_dir/bin" "$update_stopped_busy_port_dir/install"
make_config "$update_stopped_busy_port_dir/install/.kvs-server.conf" stoppedbusyuser stoppedbusypass
cat > "$update_stopped_busy_port_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* && "$args" == *"-a"* ]]; then
      echo "conversion-server"
    fi
    ;;
  pull)
    echo "image pulled"
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      echo "docker: Error response from daemon: Bind for 0.0.0.0:21 failed: port is already allocated" >&2
      exit 125
    fi
    echo "replacement docker run should not execute after failed stopped update port preflight" >&2
    exit 1
    ;;
  rm)
    echo "docker rm should not run after a failed stopped update port preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_stopped_busy_port_dir/bin/docker"

if (
  cd "$update_stopped_busy_port_dir/install"
  KVS_HEADLESS=true KVS_DOCKER_STATE_DIR="$update_stopped_busy_port_dir" PATH="$update_stopped_busy_port_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$update_stopped_busy_port_dir/update.out" 2>"$update_stopped_busy_port_dir/update.err"; then
  echo "stopped update continued after required port preflight failed"
  exit 1
fi

grep -q "Pulling Docker image maximemichaud/kvs-conversion-server:$default_image_tag" "$update_stopped_busy_port_dir/update.out"
grep -q "Checking Docker port availability before replacing the existing container" "$update_stopped_busy_port_dir/update.out"
grep -q "Bind for 0.0.0.0:21 failed" "$update_stopped_busy_port_dir/update.err"
grep -q "Required Docker ports are not available. Existing container was left untouched." "$update_stopped_busy_port_dir/update.err"
grep -q "docker pull maximemichaud/kvs-conversion-server:$default_image_tag" "$update_stopped_busy_port_dir/docker.log"
grep -q -- "-p 21:21" "$update_stopped_busy_port_dir/docker.log"
if grep -q "docker rm conversion-server" "$update_stopped_busy_port_dir/docker.log"; then
  echo "stopped update removed the existing container after failed port preflight"
  exit 1
fi
if grep -q "Update completed. Start container to use new image." "$update_stopped_busy_port_dir/update.out"; then
  echo "stopped update reported completion after failed port preflight"
  exit 1
fi

update_stopped_preflight_failure_dir="$tmpdir/update-stopped-preflight-failure"
mkdir -p "$update_stopped_preflight_failure_dir/bin" "$update_stopped_preflight_failure_dir/install"
make_config "$update_stopped_preflight_failure_dir/install/.kvs-server.conf" updatefailuser updatefailpass
cat > "$update_stopped_preflight_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* && "$args" == *"-a"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
    esac
    ;;
  pull)
    echo "image pulled"
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      echo "docker: simulated stopped-update startup failure" >&2
      exit 125
    fi
    echo "final replacement run should not execute after failed update startup preflight" >&2
    exit 1
    ;;
  rm)
    touch "$state_dir/rm-called"
    echo "docker rm should not run after failed update startup preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_stopped_preflight_failure_dir/bin/docker"

if (
  cd "$update_stopped_preflight_failure_dir/install"
  KVS_DOCKER_STATE_DIR="$update_stopped_preflight_failure_dir" PATH="$update_stopped_preflight_failure_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$update_stopped_preflight_failure_dir/update.out" 2>"$update_stopped_preflight_failure_dir/update.err"; then
  echo "stopped update continued after replacement startup preflight failed"
  exit 1
fi

grep -q "Pulling Docker image maximemichaud/kvs-conversion-server:$default_image_tag" "$update_stopped_preflight_failure_dir/update.out"
grep -q "Checking replacement container startup before stopping the existing container" "$update_stopped_preflight_failure_dir/update.out"
grep -q "simulated stopped-update startup failure" "$update_stopped_preflight_failure_dir/update.err"
grep -q "Replacement container failed to start. Existing container was left running." "$update_stopped_preflight_failure_dir/update.err"
grep -q -- "--name conversion-server-start-check-" "$update_stopped_preflight_failure_dir/docker.log"
if grep -q "docker rm conversion-server" "$update_stopped_preflight_failure_dir/docker.log"; then
  echo "stopped update removed the existing container after failed startup preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$update_stopped_preflight_failure_dir/docker.log"; then
  echo "stopped update attempted final replacement after failed startup preflight"
  exit 1
fi
if grep -Fq -- "source=${update_stopped_preflight_failure_dir}/install/data" "$update_stopped_preflight_failure_dir/docker.log"; then
  echo "stopped update startup preflight mounted the live data directory"
  exit 1
fi
[[ ! -e "$update_stopped_preflight_failure_dir/rm-called" ]]

update_stopped_dir="$tmpdir/update-stopped-non-auto-remove"
mkdir -p "$update_stopped_dir/bin" "$update_stopped_dir/install"
make_config "$update_stopped_dir/install/.kvs-server.conf" stoppeduser stoppedpass
cat > "$update_stopped_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_DOCKER_STATE_DIR:?}

printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ -f "$state_dir/start-check-name" ]]; then
        cat "$state_dir/start-check-name"
      elif [[ -f "$state_dir/new-running" ]]; then
        echo "conversion-server"
      elif [[ -f "$state_dir/removed" ]]; then
        exit 0
      elif [[ "$args" == *"-a"* ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    case "$*" in
      *HostConfig.AutoRemove*)
        echo "false"
        ;;
      *State.Health.Status*)
        echo "healthy"
        ;;
      *NetworkSettings*)
        echo "172.17.0.2"
        ;;
      *StartedAt*)
        echo "2026-06-17T00:00:00Z"
        ;;
    esac
    ;;
  pull)
    echo "image pulled"
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  start)
    echo "docker start should not be used after stopped update recreation" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      previous=""
      for arg in "$@"; do
        if [[ "$previous" == "--name" ]]; then
          printf '%s\n' "$arg" > "$state_dir/start-check-name"
          break
        fi
        previous="$arg"
      done
      echo "start-check-container-id"
      exit 0
    fi
    touch "$state_dir/new-running"
    echo "new-container-id"
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" ]] && [[ "$2" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-name"
      echo "$2"
      exit 0
    fi
    exit 0
    ;;
  stats)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$update_stopped_dir/bin/docker"

(
  cd "$update_stopped_dir/install"
  KVS_DOCKER_STATE_DIR="$update_stopped_dir" PATH="$update_stopped_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" update
) >"$update_stopped_dir/update.out" 2>"$update_stopped_dir/update.err"

(
  cd "$update_stopped_dir/install"
  KVS_DOCKER_STATE_DIR="$update_stopped_dir" PATH="$update_stopped_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" start
) >"$update_stopped_dir/start.out" 2>"$update_stopped_dir/start.err"

grep -q "Removing existing container 'conversion-server' before recreating it" "$update_stopped_dir/update.out"
grep -q "Update completed. Start container to use new image." "$update_stopped_dir/update.out"
grep -q "Creating and starting container with saved configuration" "$update_stopped_dir/start.out"
grep -q "docker rm conversion-server" "$update_stopped_dir/docker.log"
grep -q "docker run --rm -d --name conversion-server --cpus" "$update_stopped_dir/docker.log"
if grep -q "docker start conversion-server" "$update_stopped_dir/docker.log"; then
  echo "start restarted the old stopped container after update"
  exit 1
fi
[[ ! -s "$update_stopped_dir/update.err" ]]
[[ ! -s "$update_stopped_dir/start.err" ]]

echo "config path management tests passed"
