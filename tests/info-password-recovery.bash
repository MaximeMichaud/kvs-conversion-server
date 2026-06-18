#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/testlib.bash
source "$script_dir/testlib.bash"
repo_root=$(kvs_repo_root)
default_image_tag=$(require_script_default DEFAULT_IMAGE_TAG)
default_php_version=$(require_script_default DEFAULT_PHP_VERSION)
default_num_folders=$(require_script_default DEFAULT_NUM_FOLDERS)
max_ftp_password_length=$(require_script_default MAX_FTP_PASSWORD_LENGTH)
max_num_folders=$(require_script_default MAX_NUM_FOLDERS)
custom_num_folders=2
if [[ "$custom_num_folders" == "$default_num_folders" ]]; then
  custom_num_folders=3
fi
host_cpu_count=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
too_high_cpu_limit=$((host_cpu_count + 1))
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=$(cd "$(dirname "$0")/.." && pwd)
state_key=${PWD//[^A-Za-z0-9_.-]/_}
container_state="$state_dir/container-running-$state_key"

case "$1" in
  ps)
    if [[ -f "$container_state" && "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  run)
    if [[ "$*" == *"--name conversion-server"* ]]; then
      touch "$container_state"
      echo "fake-container-id"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$tmpdir/bin/docker"

write_kvs_config "$tmpdir/.kvs-server.conf" \
  --ftp-user testuser \
  --ftp-pass secret-password-123 \
  --ipv4-address 203.0.113.10 \
  --num-folders "$default_num_folders" \
  --cpu-limit 2

run_script() {
  (cd "$tmpdir" && PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" "$@")
}

replace_config_line() {
  local config_path="$1"
  local key="$2"
  local replacement="$3"
  local tmp_config

  tmp_config="${config_path}.tmp"
  awk -v key="$key" -v replacement="$replacement" '
    index($0, key "=") == 1 {
      print replacement
      next
    }
    { print }
  ' "$config_path" > "$tmp_config"
  mv "$tmp_config" "$config_path"
}

assert_manual_quoted_ftp_pass_config() {
  local scenario="$1"
  local ftp_pass_line="$2"
  local expected_password="$3"
  local quoted_config_dir="$tmpdir/manual-$scenario-config"

  mkdir -p "$quoted_config_dir/bin" "$quoted_config_dir/install"
  write_kvs_config "$quoted_config_dir/install/.kvs-server.conf" \
    --ftp-user quoteduser \
    --ftp-pass placeholderpass123 \
    --ipv4-address 127.0.0.1 \
    --num-folders 1 \
    --cpu-limit 1
  replace_config_line "$quoted_config_dir/install/.kvs-server.conf" FTP_PASS "$ftp_pass_line"

  cat > "$quoted_config_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ -f "$KVS_DOCKER_STATE/running" && "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    exit 0
    ;;
  run)
    touch "$KVS_DOCKER_STATE/running"
    echo "fake-container-id"
    exit 0
    ;;
  inspect)
    if [[ "$*" == *"State.Health.Status"* ]]; then
      echo "healthy"
    fi
    exit 0
    ;;
  stats)
    echo "conversion-server 0.00% 10MiB / 1GiB 0B / 0B"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
  chmod +x "$quoted_config_dir/bin/docker"

  (
    cd "$quoted_config_dir/install"
    KVS_DOCKER_LOG="$quoted_config_dir/docker.log" KVS_DOCKER_STATE="$quoted_config_dir" \
      PATH="$quoted_config_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" start
  ) >"$quoted_config_dir/start.out" 2>"$quoted_config_dir/start.err"

  grep -q "Container created and started successfully" "$quoted_config_dir/start.out"
  grep -Fq -- "-e FTP_PASS=$expected_password" "$quoted_config_dir/docker.log"

  quoted_config_info_output=$(
    cd "$quoted_config_dir/install"
    KVS_DOCKER_LOG="$quoted_config_dir/info-docker.log" KVS_DOCKER_STATE="$quoted_config_dir" \
      PATH="$quoted_config_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info --show-password
  )
  [[ "$quoted_config_info_output" == *"FTP Password: $expected_password"* ]]
  if [[ "$quoted_config_info_output" == *"FTP Password: '$expected_password'"* \
    || "$quoted_config_info_output" == *"FTP Password: \"$expected_password\""* ]]; then
    echo "info displayed literal quote characters from a manually quoted FTP_PASS"
    exit 1
  fi
}

default_output=$(run_script info)
[[ "$default_output" == *"FTP Password: ********"* ]]
[[ "$default_output" == *"use info --show-password to reveal"* ]]
[[ "$default_output" != *"secret-password-123"* ]]

revealed_output=$(run_script info --show-password)
[[ "$revealed_output" == *"FTP Password: secret-password-123"* ]]
[[ "$revealed_output" != *"FTP Password: ********"* ]]

saved_high_cpu_dir="$tmpdir/saved-high-cpu-info"
mkdir -p "$saved_high_cpu_dir/bin" "$saved_high_cpu_dir/install"
write_kvs_config "$saved_high_cpu_dir/install/.kvs-server.conf" \
  --ftp-user savedcpuuser \
  --ftp-pass savedcpupass123 \
  --cpu-limit 8
cat > "$saved_high_cpu_dir/bin/nproc" <<'NPROC'
#!/usr/bin/env bash
echo 2
NPROC
cat > "$saved_high_cpu_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  ps)
    exit 0
    ;;
  inspect)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$saved_high_cpu_dir/bin/nproc" "$saved_high_cpu_dir/bin/docker"

saved_high_cpu_output=$(
  cd "$saved_high_cpu_dir/install"
  PATH="$saved_high_cpu_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info --show-password
)
[[ "$saved_high_cpu_output" == *"FTP User: savedcpuuser"* ]]
[[ "$saved_high_cpu_output" == *"FTP Password: savedcpupass123"* ]]
[[ "$saved_high_cpu_output" == *"CPU Limit: 8 cores"* ]]

offline_info_dir="$tmpdir/offline-info"
mkdir -p "$offline_info_dir/bin" "$offline_info_dir/install"
write_kvs_config "$offline_info_dir/install/.kvs-server.conf" \
  --ftp-user offlineuser \
  --ftp-pass offline-secret-123
cat > "$offline_info_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
echo "docker daemon unavailable" >&2
exit 1
DOCKER
chmod +x "$offline_info_dir/bin/docker"

(
  cd "$offline_info_dir/install"
  PATH="$offline_info_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info --show-password
) >"$offline_info_dir/info.out" 2>"$offline_info_dir/info.err"

grep -q "docker daemon unavailable" "$offline_info_dir/info.err"
grep -q "Unable to query Docker containers; showing saved configuration only" "$offline_info_dir/info.err"
grep -q "Status: Unknown (Docker unavailable)" "$offline_info_dir/info.out"
grep -q "FTP User: offlineuser" "$offline_info_dir/info.out"
grep -q "FTP Password: offline-secret-123" "$offline_info_dir/info.out"

env_tag_output=$(KVS_IMAGE_TAG=latest run_script info)
[[ "$env_tag_output" == *"Docker Image: maximemichaud/kvs-conversion-server:$default_image_tag"* ]]
[[ "$env_tag_output" != *"Docker Image: maximemichaud/kvs-conversion-server:latest"* ]]

invalid_env_tag_output=$(KVS_IMAGE_TAG='bad/tag' run_script info)
[[ "$invalid_env_tag_output" == *"Docker Image: maximemichaud/kvs-conversion-server:$default_image_tag"* ]]

invalid_config_tag_dir="$tmpdir/info-invalid-image-tag"
mkdir -p "$invalid_config_tag_dir/bin" "$invalid_config_tag_dir/install"
cp "$tmpdir/bin/docker" "$invalid_config_tag_dir/bin/docker"
write_kvs_config "$invalid_config_tag_dir/install/.kvs-server.conf" \
  --ftp-user testuser \
  --ftp-pass secret-password-123 \
  --image-tag "bad/tag"

invalid_tag_info_output=$(
  cd "$invalid_config_tag_dir/install"
  PATH="$invalid_config_tag_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info
)
[[ "$invalid_tag_info_output" == *"Docker Image: maximemichaud/kvs-conversion-server:bad/tag"* ]]

if run_script info --bad-option >"$tmpdir/bad.out" 2>"$tmpdir/bad.err"; then
  echo "info accepted an unknown option"
  exit 1
fi
grep -q "Unknown option for info: --bad-option" "$tmpdir/bad.err"

if run_script info --show-password --bad-option >"$tmpdir/bad-reveal.out" 2>"$tmpdir/bad-reveal.err"; then
  echo "info accepted an unknown option after --show-password"
  exit 1
fi
grep -q "Unknown option for info: --bad-option" "$tmpdir/bad-reveal.err"
if grep -q "secret-password-123" "$tmpdir/bad-reveal.out"; then
  echo "info revealed the FTP password before rejecting an unknown option"
  exit 1
fi

install_dir="$tmpdir/install"
mkdir -p "$install_dir"
(
  cd "$install_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders "$custom_num_folders"
) >"$tmpdir/install.out" 2>&1

grep -q "Keep .kvs-server.conf private. It contains the FTP password required by KVS." "$tmpdir/install.out"
grep -q "read FTP_PASS from .kvs-server.conf or run the script with 'info --show-password'" "$tmpdir/install.out"
grep -q "  . Maximum tasks: $custom_num_folders" "$tmpdir/install.out"
if grep -q "  . Maximum tasks: $default_num_folders" "$tmpdir/install.out"; then
  echo "install output reported the default task count instead of --num-folders"
  exit 1
fi
grep -q '^FTP_PASS=testpass123$' "$install_dir/.kvs-server.conf"

ftps_tls_install_dir="$tmpdir/ftps-tls-install"
mkdir -p "$ftps_tls_install_dir"
(
  cd "$ftps_tls_install_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftps_tls \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user tlsuser \
    --ftp-pass tlspass123 \
    --num-folders 1
) >"$ftps_tls_install_dir/install.out" 2>&1

grep -q "Using FTP mode: ftps_tls" "$ftps_tls_install_dir/install.out"
grep -q "  . Force SSL Connection: True" "$ftps_tls_install_dir/install.out"
grep -q "  . FTP Port: 21" "$ftps_tls_install_dir/install.out"
grep -Fq -- "-e FTP_MODE='ftps_tls'" "$ftps_tls_install_dir/install.out"
grep -q '^FTP_MODE=ftps_tls$' "$ftps_tls_install_dir/.kvs-server.conf"

quoted_pass_dir="$tmpdir/quoted-pass"
mkdir -p "$quoted_pass_dir"
(
  cd "$quoted_pass_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user quoteuser \
    --ftp-pass "pa'ss123" \
    --num-folders 1
) >"$quoted_pass_dir/install.out" 2>&1

awk '/^  docker run --rm -d \\/{capture=1} capture{print} capture && /^$/{exit}' \
  "$quoted_pass_dir/install.out" > "$quoted_pass_dir/advanced-command.sh"
bash -n "$quoted_pass_dir/advanced-command.sh"
grep -Fq -- "-e FTP_PASS='pa'\\''ss123'" "$quoted_pass_dir/install.out"
if grep -Fq -- "-e FTP_PASS='pa'ss123'" "$quoted_pass_dir/install.out"; then
  echo "advanced Docker command printed an unescaped single quote in FTP_PASS"
  exit 1
fi
quoted_revealed_output=$(
  cd "$quoted_pass_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info --show-password
)
[[ "$quoted_revealed_output" == *"FTP Password: pa'ss123"* ]]
grep -Fq "FTP_PASS=pa\\'ss123" "$quoted_pass_dir/.kvs-server.conf"

dash_prefixed_pass_dir="$tmpdir/dash-prefixed-pass"
mkdir -p "$dash_prefixed_pass_dir"
(
  cd "$dash_prefixed_pass_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user dashpassuser \
    --ftp-pass=--secret123 \
    --num-folders 1
) >"$dash_prefixed_pass_dir/install.out" 2>&1

grep -Fq -- "-e FTP_PASS='--secret123'" "$dash_prefixed_pass_dir/install.out"
grep -Fq "FTP_PASS=--secret123" "$dash_prefixed_pass_dir/.kvs-server.conf"

ansi_pass_dir="$tmpdir/ansi-pass"
ansi_pass=$'pa\t'\''ss123'
mkdir -p "$ansi_pass_dir"
(
  cd "$ansi_pass_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user ansiuser \
    --ftp-pass "$ansi_pass" \
    --num-folders 1
) >"$ansi_pass_dir/install.out" 2>&1

grep -Fq "FTP_PASS=$'pa\\t\\'ss123'" "$ansi_pass_dir/.kvs-server.conf"
ansi_revealed_output=$(
  cd "$ansi_pass_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" info --show-password
)
[[ "$ansi_revealed_output" == *"FTP Password: $ansi_pass"* ]]
bad_ansi_pass=$'pa\t\\\047ss123'
if [[ "$ansi_revealed_output" == *"FTP Password: $bad_ansi_pass"* ]]; then
  echo "ANSI-C quoted FTP_PASS gained an extra backslash after config reload"
  exit 1
fi

assert_manual_quoted_ftp_pass_config single "FTP_PASS='manualsingle123'" "manualsingle123"
assert_manual_quoted_ftp_pass_config double 'FTP_PASS="manualdouble123"' "manualdouble123"

bad_pass_dir="$tmpdir/bad-pass"
bad_pass_bin="$bad_pass_dir/bin"
mkdir -p "$bad_pass_bin" "$bad_pass_dir/install"
cat > "$bad_pass_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$bad_pass_bin/docker"

if (
  cd "$bad_pass_dir/install"
  KVS_DOCKER_LOG="$bad_pass_dir/docker.log" PATH="$bad_pass_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass $'testpass123\nroot:rootpass123' \
    --num-folders 1
) >"$bad_pass_dir/install.out" 2>"$bad_pass_dir/install.err"; then
  echo "install accepted an FTP password rejected by the container"
  exit 1
fi
grep -q "FTP password must not contain CR or LF characters" "$bad_pass_dir/install.err"
[[ ! -e "$bad_pass_dir/install/.kvs-server.conf" ]]
[[ ! -e "$bad_pass_dir/install/data" ]]
[[ ! -e "$bad_pass_dir/docker.log" ]]

oversized_pass_dir="$tmpdir/oversized-pass"
oversized_pass_bin="$oversized_pass_dir/bin"
mkdir -p "$oversized_pass_bin" "$oversized_pass_dir/install"
cp "$bad_pass_bin/docker" "$oversized_pass_bin/docker"
chmod +x "$oversized_pass_bin/docker"
oversized_ftp_pass=$(head -c "$((max_ftp_password_length + 1))" /dev/zero | tr '\0' A)

if (
  cd "$oversized_pass_dir/install"
  KVS_DOCKER_LOG="$oversized_pass_dir/docker.log" PATH="$oversized_pass_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass "$oversized_ftp_pass" \
    --num-folders 1
) >"$oversized_pass_dir/install.out" 2>"$oversized_pass_dir/install.err"; then
  echo "install accepted an FTP password longer than MAX_FTP_PASSWORD_LENGTH"
  exit 1
fi
grep -q "FTP password must be $max_ftp_password_length characters or fewer" "$oversized_pass_dir/install.err"
[[ ! -e "$oversized_pass_dir/install/.kvs-server.conf" ]]
[[ ! -e "$oversized_pass_dir/install/data" ]]
[[ ! -e "$oversized_pass_dir/docker.log" ]]

config_path_dir="$tmpdir/config-path-directory"
config_path_bin="$config_path_dir/bin"
mkdir -p "$config_path_bin" "$config_path_dir/install/.kvs-server.conf"
cat > "$config_path_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$config_path_bin/docker"

if (
  cd "$config_path_dir/install"
  KVS_DOCKER_LOG="$config_path_dir/docker.log" PATH="$config_path_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders "$default_num_folders"
) >"$config_path_dir/install.out" 2>"$config_path_dir/install.err"; then
  echo "install accepted a configuration path that is a directory"
  exit 1
fi
grep -q "Configuration path exists and is not a regular file: .kvs-server.conf" "$config_path_dir/install.err"
[[ ! -e "$config_path_dir/docker.log" ]]
[[ ! -e "$config_path_dir/install/data" ]]

unspecified_ipv4_dir="$tmpdir/unspecified-ipv4"
unspecified_ipv4_bin="$unspecified_ipv4_dir/bin"
mkdir -p "$unspecified_ipv4_bin" "$unspecified_ipv4_dir/install"
cat > "$unspecified_ipv4_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$unspecified_ipv4_bin/docker"

if (
  cd "$unspecified_ipv4_dir/install"
  KVS_DOCKER_LOG="$unspecified_ipv4_dir/docker.log" PATH="$unspecified_ipv4_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 0.0.0.0 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$unspecified_ipv4_dir/install.out" 2>"$unspecified_ipv4_dir/install.err"; then
  echo "install accepted 0.0.0.0 as the passive FTP address"
  exit 1
fi
grep -q "IPv4 address must not be 0.0.0.0 because FTP passive mode advertises it to clients" "$unspecified_ipv4_dir/install.err"
[[ ! -e "$unspecified_ipv4_dir/install/.kvs-server.conf" ]]
[[ ! -e "$unspecified_ipv4_dir/install/data" ]]
[[ ! -e "$unspecified_ipv4_dir/docker.log" ]]

zero_padded_unspecified_ipv4_dir="$tmpdir/zero-padded-unspecified-ipv4"
zero_padded_unspecified_ipv4_bin="$zero_padded_unspecified_ipv4_dir/bin"
mkdir -p "$zero_padded_unspecified_ipv4_bin" "$zero_padded_unspecified_ipv4_dir/install"
cat > "$zero_padded_unspecified_ipv4_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$zero_padded_unspecified_ipv4_bin/docker"

if (
  cd "$zero_padded_unspecified_ipv4_dir/install"
  KVS_DOCKER_LOG="$zero_padded_unspecified_ipv4_dir/docker.log" PATH="$zero_padded_unspecified_ipv4_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 00.00.00.00 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$zero_padded_unspecified_ipv4_dir/install.out" 2>"$zero_padded_unspecified_ipv4_dir/install.err"; then
  echo "install accepted zero-padded 0.0.0.0 as the passive FTP address"
  exit 1
fi
grep -q "IPv4 address must not be 0.0.0.0 because FTP passive mode advertises it to clients" "$zero_padded_unspecified_ipv4_dir/install.err"
[[ ! -e "$zero_padded_unspecified_ipv4_dir/install/.kvs-server.conf" ]]
[[ ! -e "$zero_padded_unspecified_ipv4_dir/install/data" ]]
[[ ! -e "$zero_padded_unspecified_ipv4_dir/docker.log" ]]

high_cpu_dir="$tmpdir/high-cpu"
high_cpu_bin="$high_cpu_dir/bin"
mkdir -p "$high_cpu_bin" "$high_cpu_dir/install"
cat > "$high_cpu_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$high_cpu_bin/docker"

if (
  cd "$high_cpu_dir/install"
  KVS_DOCKER_LOG="$high_cpu_dir/docker.log" PATH="$high_cpu_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit "$too_high_cpu_limit" \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$high_cpu_dir/install.out" 2>"$high_cpu_dir/install.err"; then
  echo "install accepted a CPU limit above the host CPU count"
  exit 1
fi
grep -q "CPU limit must be between 0.01 and $host_cpu_count" "$high_cpu_dir/install.err"
[[ ! -e "$high_cpu_dir/install/.kvs-server.conf" ]]
[[ ! -e "$high_cpu_dir/install/data" ]]
[[ ! -e "$high_cpu_dir/docker.log" ]]

too_many_folders_dir="$tmpdir/too-many-folders"
too_many_folders_bin="$too_many_folders_dir/bin"
mkdir -p "$too_many_folders_bin" "$too_many_folders_dir/install"
cat > "$too_many_folders_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker' >> "$KVS_DOCKER_LOG"
exit 0
DOCKER
chmod +x "$too_many_folders_bin/docker"
too_many_folders=$((max_num_folders + 1))

if (
  cd "$too_many_folders_dir/install"
  KVS_DOCKER_LOG="$too_many_folders_dir/docker.log" PATH="$too_many_folders_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders "$too_many_folders"
) >"$too_many_folders_dir/install.out" 2>"$too_many_folders_dir/install.err"; then
  echo "install accepted too many FTP folders"
  exit 1
fi
grep -q "Number of folders must be between 1 and $max_num_folders" "$too_many_folders_dir/install.err"
[[ ! -e "$too_many_folders_dir/install/.kvs-server.conf" ]]
[[ ! -e "$too_many_folders_dir/install/data" ]]
[[ ! -e "$too_many_folders_dir/docker.log" ]]

colon_mount_dir="$tmpdir/colon:path"
colon_mount_bin="$tmpdir/colon-path-bin"
mkdir -p "$colon_mount_bin" "$colon_mount_dir/install"
cat > "$colon_mount_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=$(dirname "${KVS_DOCKER_LOG:?}")
printf 'docker' >> "$KVS_DOCKER_LOG"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$KVS_DOCKER_LOG"
done
printf '\n' >> "$KVS_DOCKER_LOG"

case "$1" in
  ps)
    if [[ -f "$state_dir/container-running" && "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  run)
    if [[ "$*" == *"--name conversion-server"* ]]; then
      touch "$state_dir/container-running"
      echo "fake-container-id"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$colon_mount_bin/docker"

(
  cd "$colon_mount_dir/install"
  KVS_DOCKER_LOG="$colon_mount_dir/docker.log" PATH="$colon_mount_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$colon_mount_dir/install.out" 2>&1

grep -Fq -- "--mount type=bind\\,source=${colon_mount_dir}/install/data\\,target=/home/vsftpd" "$colon_mount_dir/docker.log"
if grep -q -- " -v " "$colon_mount_dir/docker.log"; then
  echo "install used -v for a data path that may contain colons"
  exit 1
fi
grep -Fq -- "--mount 'type=bind,source=${colon_mount_dir}/install/data,target=/home/vsftpd'" "$colon_mount_dir/install.out"

comma_mount_dir="$tmpdir/comma,path"
mkdir -p "$comma_mount_dir/install"
(
  cd "$comma_mount_dir/install"
  KVS_DOCKER_LOG="$comma_mount_dir/docker.log" TMPDIR="$tmpdir" PATH="$colon_mount_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$comma_mount_dir/install.out" 2>&1

comma_alias_root="$tmpdir/kvs-conversion-server-mounts-$(id -u)"
comma_alias_link=$(find "$comma_alias_root" -maxdepth 1 -type l | head -n 1)
[[ -n "$comma_alias_link" ]]
[[ "$(readlink "$comma_alias_link")" == "$comma_mount_dir/install/data" ]]
grep -Fq -- "--mount type=bind\\,source=${comma_alias_link}\\,target=/home/vsftpd" "$comma_mount_dir/docker.log"
if grep -Fq -- "source=${comma_mount_dir}/install/data" "$comma_mount_dir/docker.log"; then
  echo "install passed an unescaped comma path directly to Docker --mount"
  exit 1
fi
grep -Fq -- "--mount 'type=bind,source=${comma_alias_link},target=/home/vsftpd'" "$comma_mount_dir/install.out"

bad_user_dir="$tmpdir/bad-user"
mkdir -p "$bad_user_dir"
if (
  cd "$bad_user_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user 'bad/user' \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$tmpdir/bad-user.out" 2>"$tmpdir/bad-user.err"; then
  echo "install accepted an FTP username rejected by the container"
  exit 1
fi
grep -q "FTP username may only contain" "$tmpdir/bad-user.err"
[[ ! -e "$bad_user_dir/.kvs-server.conf" ]]
[[ ! -e "$bad_user_dir/data" ]]

long_user_dir="$tmpdir/long-user"
mkdir -p "$long_user_dir"
if (
  cd "$long_user_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user 'abcdefghijklmnopqrstuvwxyzabcdefg' \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$tmpdir/long-user.out" 2>"$tmpdir/long-user.err"; then
  echo "install accepted an FTP username longer than the container supports"
  exit 1
fi
grep -q "FTP username must be 32 characters or fewer" "$tmpdir/long-user.err"
[[ ! -e "$long_user_dir/.kvs-server.conf" ]]
[[ ! -e "$long_user_dir/data" ]]

dot_user_dir="$tmpdir/dot-user"
mkdir -p "$dot_user_dir"
if (
  cd "$dot_user_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user '.' \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$tmpdir/dot-user.out" 2>"$tmpdir/dot-user.err"; then
  echo "install accepted a dot-only FTP username rejected by the container"
  exit 1
fi
grep -q "FTP username cannot be '.' or '..'" "$tmpdir/dot-user.err"
[[ ! -e "$dot_user_dir/.kvs-server.conf" ]]
[[ ! -e "$dot_user_dir/data" ]]

reserved_user_dir="$tmpdir/reserved-user"
mkdir -p "$reserved_user_dir"
if (
  cd "$reserved_user_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user root \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$tmpdir/reserved-user.out" 2>"$tmpdir/reserved-user.err"; then
  echo "install accepted an FTP username reserved by the container"
  exit 1
fi
grep -q "FTP username 'root' is reserved by the container image" "$tmpdir/reserved-user.err"
[[ ! -e "$reserved_user_dir/.kvs-server.conf" ]]
[[ ! -e "$reserved_user_dir/data" ]]

numeric_user_dir="$tmpdir/numeric-user"
mkdir -p "$numeric_user_dir"
if (
  cd "$numeric_user_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user 12345 \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$tmpdir/numeric-user.out" 2>"$tmpdir/numeric-user.err"; then
  echo "install accepted a purely numeric FTP username rejected by the container"
  exit 1
fi
grep -q "FTP username cannot be purely numeric" "$tmpdir/numeric-user.err"
[[ ! -e "$numeric_user_dir/.kvs-server.conf" ]]
[[ ! -e "$numeric_user_dir/data" ]]

headless_no_auto_stop_dir="$tmpdir/headless-no-auto-stop"
mkdir -p "$headless_no_auto_stop_dir/bin" "$headless_no_auto_stop_dir/install"
cat > "$headless_no_auto_stop_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}
printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.ID}} {{.Names}}"* ]]; then
      echo "abc123 conversion-server"
    elif [[ "$args" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "true"
    elif [[ "$*" == *"NetworkSettings.Ports"* ]]; then
      echo "21"
      seq 21100 21110
    fi
    ;;
  pull)
    exit 0
    ;;
  stop|rm)
    echo "docker $1 should not run without --auto-stop-container" >&2
    exit 1
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    echo "replacement docker run should not execute without --auto-stop-container" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$headless_no_auto_stop_dir/bin/docker"

if (
  cd "$headless_no_auto_stop_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$headless_no_auto_stop_dir" PATH="$headless_no_auto_stop_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" \
      --headless \
      --php-version "$default_php_version" \
      --ftp-mode ftp \
      --ipv4 127.0.0.1 \
      --cpu-limit 1 \
      --ftp-user testuser \
      --ftp-pass testpass123 \
      --num-folders 1
) >"$headless_no_auto_stop_dir/install.out" 2>"$headless_no_auto_stop_dir/install.err"; then
  echo "headless install replaced an existing container without --auto-stop-container"
  exit 1
fi

grep -q "already exists with ID abc123" "$headless_no_auto_stop_dir/install.out"
grep -q "Re-run with --auto-stop-container" "$headless_no_auto_stop_dir/install.err"
grep -q "docker pull maximemichaud/kvs-conversion-server:$default_image_tag" "$headless_no_auto_stop_dir/docker.log"
if grep -Eq "docker (stop|rm) conversion-server" "$headless_no_auto_stop_dir/docker.log"; then
  echo "headless install stopped or removed the existing container without --auto-stop-container"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$headless_no_auto_stop_dir/docker.log"; then
  echo "headless install attempted replacement without --auto-stop-container"
  exit 1
fi
if grep -q -- "--name conversion-server-start-check-" "$headless_no_auto_stop_dir/docker.log"; then
  echo "headless install attempted replacement startup preflight without --auto-stop-container"
  exit 1
fi
[[ ! -e "$headless_no_auto_stop_dir/install/.kvs-server.conf" ]]
[[ ! -e "$headless_no_auto_stop_dir/install/data" ]]

auto_stop_dir="$tmpdir/auto-stop-existing"
mkdir -p "$auto_stop_dir/bin" "$auto_stop_dir/install"
cat > "$auto_stop_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}

case "$1" in
  ps)
    args="$*"
    if [[ -f "$state_dir/start-check-running" && "$args" == *"{{.Names}}"* ]]; then
      cat "$state_dir/start-check-name"
    fi
    if [[ -f "$state_dir/new-container" && "$args" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    elif [[ "$args" == *"-aq"* ]]; then
      [[ -f "$state_dir/stopped" ]] || echo "abc123"
    elif [[ "$args" == *"{{.ID}} {{.Names}}"* ]]; then
      [[ -f "$state_dir/stopped" ]] || echo "abc123 conversion-server"
    elif [[ "$args" == *"{{.Names}}"* ]]; then
      [[ -f "$state_dir/stopped" ]] || echo "conversion-server"
    fi
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" && "${2:-}" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-running" "$state_dir/start-check-name"
      echo "${2:-}"
    else
      touch "$state_dir/stopped"
      echo "conversion-server"
    fi
    ;;
  pull)
    exit 0
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" =~ --name[[:space:]](conversion-server-start-check-[^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" > "$state_dir/start-check-name"
      touch "$state_dir/start-check-running"
      echo "fake-start-check-id"
      exit 0
    fi
    if [[ ! -f "$state_dir/stopped" ]]; then
      echo 'docker: Error response from daemon: Conflict. The container name "/conversion-server" is already in use.' >&2
      exit 125
    fi
    touch "$state_dir/new-container"
    echo "fake-container-id"
    echo "docker run $*" >> "$state_dir/docker.log"
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$auto_stop_dir/bin/docker"

(
  cd "$auto_stop_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$auto_stop_dir" PATH="$auto_stop_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" \
      --headless \
      --php-version "$default_php_version" \
      --ftp-mode ftp \
      --ipv4 127.0.0.1 \
      --cpu-limit 1 \
      --ftp-user testuser \
      --ftp-pass testpass123 \
      --num-folders 1 \
      --auto-stop-container
) >"$auto_stop_dir/install.out" 2>"$auto_stop_dir/install.err"

grep -q "Auto-stopping the existing container" "$auto_stop_dir/install.out"
grep -q "Running the Docker image in detached mode" "$auto_stop_dir/install.out"
grep -q "docker run run --rm -d --name conversion-server" "$auto_stop_dir/docker.log"

auto_stop_nonrm_dir="$tmpdir/auto-stop-non-auto-remove"
mkdir -p "$auto_stop_nonrm_dir/bin" "$auto_stop_nonrm_dir/install"
cat > "$auto_stop_nonrm_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}

case "$1" in
  ps)
    args="$*"
    if [[ -f "$state_dir/start-check-running" && "$args" == *"{{.Names}}"* ]]; then
      cat "$state_dir/start-check-name"
    fi
    if [[ -f "$state_dir/new-container" || -f "$state_dir/removed" ]]; then
      if [[ "$args" == *"{{.Names}}"* ]]; then
        [[ -f "$state_dir/new-container" ]] && echo "conversion-server"
      fi
    elif [[ "$args" == *"{{.ID}} {{.Names}}"* ]]; then
      echo "abc123 conversion-server"
    elif [[ "$args" == *"{{.Names}}"* ]]; then
      if [[ "$args" == *" -a "* || "$args" == *"ps -a"* ]]; then
        echo "conversion-server"
      elif [[ ! -f "$state_dir/stopped" ]]; then
        echo "conversion-server"
      fi
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    fi
    ;;
  stop)
    if [[ -f "$state_dir/start-check-name" && "${2:-}" == "$(cat "$state_dir/start-check-name")" ]]; then
      rm -f "$state_dir/start-check-running" "$state_dir/start-check-name"
      echo "${2:-}"
    else
      touch "$state_dir/stopped"
      echo "conversion-server"
    fi
    ;;
  rm)
    touch "$state_dir/removed"
    echo "conversion-server"
    ;;
  pull)
    exit 0
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" =~ --name[[:space:]](conversion-server-start-check-[^[:space:]]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" > "$state_dir/start-check-name"
      touch "$state_dir/start-check-running"
      echo "fake-start-check-id"
      exit 0
    fi
    if [[ ! -f "$state_dir/removed" ]]; then
      echo 'docker: Error response from daemon: Conflict. The container name "/conversion-server" is already in use.' >&2
      exit 125
    fi
    touch "$state_dir/new-container"
    echo "docker run $*" >> "$state_dir/docker.log"
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$auto_stop_nonrm_dir/bin/docker"

(
  cd "$auto_stop_nonrm_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$auto_stop_nonrm_dir" PATH="$auto_stop_nonrm_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" \
      --headless \
      --php-version "$default_php_version" \
      --ftp-mode ftp \
      --ipv4 127.0.0.1 \
      --cpu-limit 1 \
      --ftp-user testuser \
      --ftp-pass testpass123 \
      --num-folders 1 \
      --auto-stop-container
) >"$auto_stop_nonrm_dir/install.out" 2>"$auto_stop_nonrm_dir/install.err"

grep -q "Auto-stopping the existing container" "$auto_stop_nonrm_dir/install.out"
grep -q "Removing existing container 'conversion-server' before recreating it" "$auto_stop_nonrm_dir/install.out"
grep -q "Running the Docker image in detached mode" "$auto_stop_nonrm_dir/install.out"
grep -q "docker run run --rm -d --name conversion-server" "$auto_stop_nonrm_dir/docker.log"

missing_tag_dir="$tmpdir/missing-tag-preflight"
mkdir -p "$missing_tag_dir/bin" "$missing_tag_dir/install"
cat > "$missing_tag_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}
printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  pull)
    echo 'manifest not found' >&2
    exit 1
    ;;
  ps)
    if [[ "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  stop|rm|run)
    echo "docker $1 should not run after a failed pull" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$missing_tag_dir/bin/docker"

if (
  cd "$missing_tag_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$missing_tag_dir" PATH="$missing_tag_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" \
      --headless \
      --php-version "$default_php_version" \
      --ftp-mode ftp \
      --ipv4 127.0.0.1 \
      --cpu-limit 1 \
      --ftp-user testuser \
      --ftp-pass testpass123 \
      --num-folders 1 \
      --image-tag missing-test-tag
) >"$missing_tag_dir/install.out" 2>"$missing_tag_dir/install.err"; then
  echo "install continued after docker pull failed"
  exit 1
fi

grep -q "manifest not found" "$missing_tag_dir/install.err"
grep -q "docker pull maximemichaud/kvs-conversion-server:missing-test-tag" "$missing_tag_dir/docker.log"
if grep -Eq "docker (stop|rm|run)" "$missing_tag_dir/docker.log"; then
  echo "install touched the existing container after docker pull failed"
  exit 1
fi
[[ ! -e "$missing_tag_dir/install/.kvs-server.conf" ]]
[[ ! -e "$missing_tag_dir/install/data" ]]

busy_port_dir="$tmpdir/busy-port-preflight"
mkdir -p "$busy_port_dir/bin" "$busy_port_dir/install"
cat > "$busy_port_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}
printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    args="$*"
    if [[ "$args" == *"{{.ID}} {{.Names}}"* ]]; then
      echo "abc123 conversion-server"
    elif [[ "$args" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  inspect)
    if [[ "$*" == *"HostConfig.AutoRemove"* ]]; then
      echo "false"
    elif [[ "$*" == *"NetworkSettings.Ports"* ]]; then
      echo "21"
      seq 21100 21110
    fi
    ;;
  pull)
    exit 0
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      echo "docker: Error response from daemon: Bind for 0.0.0.0:990 failed: port is already allocated" >&2
      exit 125
    fi
    echo "replacement docker run should not execute after failed port preflight" >&2
    exit 1
    ;;
  stop|rm)
    echo "docker $1 should not run after a failed port preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$busy_port_dir/bin/docker"

if (
  cd "$busy_port_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$busy_port_dir" PATH="$busy_port_dir/bin:$PATH" NO_COLOR=1 \
    "$repo_root/kvs-conversion-server.sh" \
      --headless \
      --php-version "$default_php_version" \
      --ftp-mode ftps_implicit \
      --ipv4 127.0.0.1 \
      --cpu-limit 1 \
      --ftp-user testuser \
      --ftp-pass testpass123 \
      --num-folders 1 \
      --auto-stop-container
) >"$busy_port_dir/install.out" 2>"$busy_port_dir/install.err"; then
  echo "install continued after required port preflight failed"
  exit 1
fi

grep -q "Checking Docker port availability before replacing the existing container" "$busy_port_dir/install.out"
grep -q "Bind for 0.0.0.0:990 failed" "$busy_port_dir/install.err"
grep -q "Required Docker ports are not available. Existing container was left untouched." "$busy_port_dir/install.err"
grep -q "docker pull maximemichaud/kvs-conversion-server:$default_image_tag" "$busy_port_dir/docker.log"
grep -q -- "-p 990:990" "$busy_port_dir/docker.log"
if grep -q "docker stop conversion-server" "$busy_port_dir/docker.log"; then
  echo "install stopped the existing container after failed port preflight"
  exit 1
fi
if grep -q "docker rm conversion-server" "$busy_port_dir/docker.log"; then
  echo "install removed the existing container after failed port preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$busy_port_dir/docker.log"; then
  echo "install attempted replacement after failed port preflight"
  exit 1
fi
[[ ! -e "$busy_port_dir/install/.kvs-server.conf" ]]
[[ ! -e "$busy_port_dir/install/data" ]]

echo "info password recovery tests passed"
