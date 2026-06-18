#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/testlib.bash
source "$script_dir/testlib.bash"

repo_root=$(kvs_repo_root)
default_php_version=$(require_script_default DEFAULT_PHP_VERSION)
supported_php_versions=$(require_script_default SUPPORTED_PHP_VERSIONS)
supported_ftp_modes=$(require_script_default SUPPORTED_FTP_MODES)

tmpdir=$(mktemp -d)
comma_tmpdir_alias_link=""
trap 'rm -rf "$tmpdir"; [[ -z "${comma_tmpdir_alias_link:-}" ]] || rm -f "$comma_tmpdir_alias_link"' EXIT

ftp_mode_choice_for() {
  local target="$1"
  local index=1
  local mode

  for mode in $supported_ftp_modes; do
    if [[ "$mode" == "$target" ]]; then
      printf '%s' "$index"
      return 0
    fi
    ((index++))
  done

  echo "Supported FTP mode not found: $target" >&2
  return 1
}

php_version_choice_for() {
  local target="$1"
  local index=1
  local version

  for version in $supported_php_versions; do
    if [[ "$version" == "$target" ]]; then
      printf '%s' "$index"
      return 0
    fi
    ((index++))
  done

  echo "Supported PHP version not found: $target" >&2
  return 1
}

php_version_label() {
  local version="$1"
  printf 'PHP %s' "${version#php}"
}

write_fake_docker() {
  local docker_path="$1"

  cat > "$docker_path" <<'DOCKER'
#!/usr/bin/env bash
state_dir=$(cd "$(dirname "$0")/.." && pwd)
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
  pull)
    exit 0
    ;;
  run)
    for arg in "$@"; do
      case "$arg" in
        type=bind,source=*,*,target=*)
          echo "unsafe comma in Docker mount source: $arg" >&2
          exit 44
          ;;
      esac
    done
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
  chmod +x "$docker_path"
}

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"
write_fake_docker "$fake_bin/docker"
cat > "$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""
while (($#)); do
  case "$1" in
    -o)
      out="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$out" ]]; then
  cat "${KVS_FAKE_CURL_SCRIPT_SOURCE:?}"
else
  cat "${KVS_FAKE_CURL_SCRIPT_SOURCE:?}" > "$out"
fi
CURL
chmod +x "$fake_bin/curl"

config_symlink_dir="$tmpdir/config-symlink"
mkdir -p "$config_symlink_dir/install"
printf 'DO NOT CLOBBER\n' > "$config_symlink_dir/victim.txt"
ln -s "$config_symlink_dir/victim.txt" "$config_symlink_dir/install/.kvs-server.conf"

if (
  cd "$config_symlink_dir/install"
  KVS_DOCKER_LOG="$config_symlink_dir/docker.log" PATH="$fake_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$config_symlink_dir/install.out" 2>"$config_symlink_dir/install.err"; then
  echo "install accepted a symlinked .kvs-server.conf"
  exit 1
fi

grep -q "Configuration path must not be a symbolic link: .kvs-server.conf" "$config_symlink_dir/install.err"
grep -qx "DO NOT CLOBBER" "$config_symlink_dir/victim.txt"
[[ -L "$config_symlink_dir/install/.kvs-server.conf" ]]
[[ ! -e "$config_symlink_dir/docker.log" ]]
[[ ! -e "$config_symlink_dir/install/data" ]]

process_substitution_dir="$tmpdir/process-substitution-install"
mkdir -p "$process_substitution_dir/install"
(
  cd "$process_substitution_dir/install"
  KVS_DOCKER_LOG="$process_substitution_dir/docker.log" \
    KVS_FAKE_CURL_SCRIPT_SOURCE="$repo_root/kvs-conversion-server.sh" \
    PATH="$fake_bin:$PATH" \
    NO_COLOR=1 \
    bash <(cat "$repo_root/kvs-conversion-server.sh") \
      --headless \
      --php-version "$default_php_version" \
      --ftp-mode ftp \
      --ipv4 127.0.0.1 \
      --cpu-limit 1 \
      --ftp-user testuser \
      --ftp-pass testpass123 \
      --num-folders 1
) >"$process_substitution_dir/install.out" 2>"$process_substitution_dir/install.err"

[[ -f "$process_substitution_dir/install/.kvs-server.conf" ]]
[[ -d "$process_substitution_dir/install/data" ]]
[[ -x "$process_substitution_dir/install/kvs-conversion-server.sh" ]]
cmp -s "$repo_root/kvs-conversion-server.sh" "$process_substitution_dir/install/kvs-conversion-server.sh"
grep -q "To manage the container, use the script commands" "$process_substitution_dir/install.out"
grep -q "  ./kvs-conversion-server.sh status" "$process_substitution_dir/install.out"
(
  cd "$process_substitution_dir/install"
  NO_COLOR=1 ./kvs-conversion-server.sh --help
) >"$process_substitution_dir/help.out" 2>"$process_substitution_dir/help.err"
grep -q "MANAGEMENT COMMANDS:" "$process_substitution_dir/help.out"
[[ ! -s "$process_substitution_dir/help.err" ]]
rm -f "$tmpdir/container-running"

docker_installer_dir="$tmpdir/docker-installer-symlink"
docker_installer_bin="$docker_installer_dir/bin"
mkdir -p "$docker_installer_bin" "$docker_installer_dir/install"
for cmd in bash awk dirname uname nproc grep sed date stat id mkdir chmod ln readlink mktemp basename; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -s "$(command -v "$cmd")" "$docker_installer_bin/$cmd"
  fi
done
cat > "$docker_installer_bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "-o" ]]; then
    out="$arg"
    break
  fi
  previous="$arg"
done

printf 'curl_out=%s\n' "$out" >> "${KVS_FAKE_INSTALL_STATE_DIR:?}/install-docker.log"
printf 'fake docker installer payload\n' > "$out"
CURL
cat > "$docker_installer_bin/sh" <<'SH'
#!/usr/bin/env bash
printf 'sh_arg=%s\n' "${1:-}" >> "${KVS_FAKE_INSTALL_STATE_DIR:?}/install-docker.log"
exit 0
SH
cat > "$docker_installer_bin/rm" <<'RM'
#!/usr/bin/env bash
printf 'rm_args=%s\n' "$*" >> "${KVS_FAKE_INSTALL_STATE_DIR:?}/install-docker.log"
command -p rm "$@"
RM
chmod +x "$docker_installer_bin/curl" "$docker_installer_bin/sh" "$docker_installer_bin/rm"
printf 'DO NOT CLOBBER\n' > "$docker_installer_dir/victim.txt"
ln -s "$docker_installer_dir/victim.txt" "$docker_installer_dir/install/install-docker.sh"

if (
  cd "$docker_installer_dir/install"
  KVS_FAKE_INSTALL_STATE_DIR="$docker_installer_dir" PATH="$docker_installer_bin" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$docker_installer_dir/install.out" 2>"$docker_installer_dir/install.err"; then
  echo "install unexpectedly succeeded without docker after fake installer"
  exit 1
fi

grep -q "Docker is not installed" "$docker_installer_dir/install.out"
grep -q "Docker has been installed" "$docker_installer_dir/install.out"
grep -qx "DO NOT CLOBBER" "$docker_installer_dir/victim.txt"
[[ -L "$docker_installer_dir/install/install-docker.sh" ]]
if grep -qx "curl_out=install-docker.sh" "$docker_installer_dir/install-docker.log"; then
  echo "install downloaded the Docker installer through a predictable symlink path"
  exit 1
fi
grep -Eq '^curl_out=/.*kvs-install-docker\.' "$docker_installer_dir/install-docker.log"

comma_mount_dir="$tmpdir/install,withcomma"
comma_tmpdir="$tmpdir/tmp,withcomma"
mkdir -p "$comma_mount_dir" "$comma_tmpdir"
(
  cd "$comma_mount_dir"
  KVS_DOCKER_LOG="$tmpdir/comma-tmpdir-docker.log" TMPDIR="$comma_tmpdir" PATH="$fake_bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$tmpdir/comma-tmpdir-install.out" 2>"$tmpdir/comma-tmpdir-install.err"

comma_tmpdir_alias_root="/tmp/kvs-conversion-server-mounts-$(id -u)"
comma_tmpdir_alias_link=$(find "$comma_tmpdir_alias_root" -maxdepth 1 -type l -lname "$comma_mount_dir/data" | head -n 1)
[[ -n "$comma_tmpdir_alias_link" ]]
[[ "$comma_tmpdir_alias_link" != *","* ]]
grep -Fq -- "--mount type=bind\\,source=${comma_tmpdir_alias_link}\\,target=/home/vsftpd" "$tmpdir/comma-tmpdir-docker.log"
grep -q '^FTP_MODE=ftp$' "$comma_mount_dir/.kvs-server.conf"
rm -f "$tmpdir/container-running"

ftps_tls_choice=$(ftp_mode_choice_for ftps_tls)
interactive_dir="$tmpdir/interactive-ftps-tls"
mkdir -p "$interactive_dir"
(
  cd "$interactive_dir"
  printf '%s\n\n' "$ftps_tls_choice" | KVS_DOCKER_LOG="$tmpdir/interactive-docker.log" PATH="$fake_bin:$PATH" NO_COLOR=1 \
    KVS_PHP_VERSION="$default_php_version" \
    KVS_IPV4_ADDRESS=127.0.0.1 \
    KVS_CPU_LIMIT=1 \
    KVS_FTP_USER=tlsuser \
    KVS_FTP_PASS=tlspass123 \
    KVS_NUM_FOLDERS=1 \
    "$repo_root/kvs-conversion-server.sh"
) >"$tmpdir/interactive-install.out" 2>"$tmpdir/interactive-install.err"

grep -Fq "${ftps_tls_choice}. FTPS TLS - Alias for explicit FTPS via AUTH TLS on port 21" "$tmpdir/interactive-install.out"
grep -Fq "You have selected FTPS TLS mode (AUTH TLS on port 21)." "$tmpdir/interactive-install.out"
grep -Fq -- "-e FTP_MODE='ftps_tls'" "$tmpdir/interactive-install.out"
grep -q '^FTP_MODE=ftps_tls$' "$interactive_dir/.kvs-server.conf"

rm -f "$tmpdir/container-running"
default_php_label=$(php_version_label "$default_php_version")
interactive_php_dir="$tmpdir/interactive-default-php"
mkdir -p "$interactive_php_dir"
set +e
(
  cd "$interactive_php_dir"
  printf '\n' | KVS_DOCKER_LOG="$tmpdir/interactive-php-docker.log" PATH="$fake_bin:$PATH" NO_COLOR=1 \
    KVS_FTP_MODE=ftp \
    KVS_IPV4_ADDRESS=127.0.0.1 \
    KVS_CPU_LIMIT=1 \
    KVS_FTP_USER=phpuser \
    KVS_FTP_PASS=phppass123 \
    KVS_NUM_FOLDERS=1 \
    "$repo_root/kvs-conversion-server.sh"
) >"$tmpdir/interactive-php-install.out" 2>"$tmpdir/interactive-php-install.err"
interactive_php_status=$?
set -e

if ((interactive_php_status != 0)) && [[ ! -f "$interactive_php_dir/.kvs-server.conf" ]]; then
  cat "$tmpdir/interactive-php-install.out"
  cat "$tmpdir/interactive-php-install.err" >&2
  echo "interactive PHP prompt test failed before writing configuration"
  exit 1
fi

grep -Fq "Choose the PHP version to use:" "$tmpdir/interactive-php-install.out"
php_menu_index=1
for php_version in $supported_php_versions; do
  php_menu_label=$(php_version_label "$php_version")
  if [[ "$php_version" == "$default_php_version" ]]; then
    php_menu_label="$php_menu_label - Recommended if your KVS version is 6.2 or higher."
  elif ((php_menu_index == 1)); then
    php_menu_label="$php_menu_label - Recommended if your KVS version is below 6.2."
  fi
  grep -Fq "$php_menu_index. $php_menu_label" "$tmpdir/interactive-php-install.out"
  ((php_menu_index++))
done
grep -Fq "$default_php_label is the default selection, suitable for KVS 6.2 or higher." "$tmpdir/interactive-php-install.out"
grep -q "^PHP_VERSION=$default_php_version$" "$interactive_php_dir/.kvs-server.conf"

dead_container_dir="$tmpdir/dead-container-install"
mkdir -p "$dead_container_dir/bin" "$dead_container_dir/install"
cat > "$dead_container_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}
printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    exit 0
    ;;
  pull)
    exit 0
    ;;
  run)
    if [[ "$*" == *"--name conversion-server"* ]]; then
      echo "deadbeefdead"
    fi
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
chmod +x "$dead_container_dir/bin/docker"

if (
  cd "$dead_container_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$dead_container_dir" PATH="$dead_container_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$dead_container_dir/install.out" 2>"$dead_container_dir/install.err"; then
  echo "install succeeded after the started container disappeared"
  exit 1
fi

grep -q "deadbeefdead" "$dead_container_dir/install.out"
grep -q "Docker reported that container 'conversion-server' started, but it is not running" "$dead_container_dir/install.err"
if grep -q "The Docker container is running" "$dead_container_dir/install.out"; then
  echo "install printed running instructions for a disappeared container"
  exit 1
fi
[[ ! -e "$dead_container_dir/install/.kvs-server.conf" ]]

auto_stop_preflight_failure_dir="$tmpdir/auto-stop-preflight-failure"
mkdir -p "$auto_stop_preflight_failure_dir/bin" "$auto_stop_preflight_failure_dir/install"
cat > "$auto_stop_preflight_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}
printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ "$*" == *"{{.ID}} {{.Names}}"* ]]; then
      echo "abc123 conversion-server"
    elif [[ "$*" == *"{{.Names}}"* ]]; then
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
    esac
    ;;
  pull)
    exit 0
    ;;
  run)
    if [[ "$*" == *"--name conversion-server-port-check-"* ]]; then
      exit 0
    fi
    if [[ "$*" == *"--name conversion-server-start-check-"* ]]; then
      echo "docker: simulated install replacement startup failure" >&2
      exit 125
    fi
    echo "final replacement run should not execute after failed install startup preflight" >&2
    exit 1
    ;;
  stop|rm)
    touch "$state_dir/$1-called"
    echo "docker $1 should not run after failed install startup preflight" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$auto_stop_preflight_failure_dir/bin/docker"

if (
  cd "$auto_stop_preflight_failure_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$auto_stop_preflight_failure_dir" PATH="$auto_stop_preflight_failure_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1 \
    --auto-stop-container
) >"$auto_stop_preflight_failure_dir/install.out" 2>"$auto_stop_preflight_failure_dir/install.err"; then
  echo "install continued after replacement startup preflight failed"
  exit 1
fi

grep -q "Checking replacement container startup before stopping the existing container" "$auto_stop_preflight_failure_dir/install.out"
grep -q "simulated install replacement startup failure" "$auto_stop_preflight_failure_dir/install.err"
grep -q "Replacement container failed to start. Existing container was left running." "$auto_stop_preflight_failure_dir/install.err"
grep -q -- "--name conversion-server-start-check-" "$auto_stop_preflight_failure_dir/docker.log"
if grep -q "docker stop conversion-server" "$auto_stop_preflight_failure_dir/docker.log"; then
  echo "install stopped the existing container after failed startup preflight"
  exit 1
fi
if grep -q "docker rm conversion-server" "$auto_stop_preflight_failure_dir/docker.log"; then
  echo "install removed the existing container after failed startup preflight"
  exit 1
fi
if grep -q -- "--name conversion-server --cpus" "$auto_stop_preflight_failure_dir/docker.log"; then
  echo "install attempted final replacement after failed startup preflight"
  exit 1
fi
if grep -Fq -- "source=${auto_stop_preflight_failure_dir}/install/data" "$auto_stop_preflight_failure_dir/docker.log"; then
  echo "install startup preflight mounted the live data directory"
  exit 1
fi
[[ ! -e "$auto_stop_preflight_failure_dir/stop-called" ]]
[[ ! -e "$auto_stop_preflight_failure_dir/rm-called" ]]
[[ ! -e "$auto_stop_preflight_failure_dir/install/.kvs-server.conf" ]]

config_save_failure_dir="$tmpdir/config-save-failure"
mkdir -p "$config_save_failure_dir/bin" "$config_save_failure_dir/install"
cat > "$config_save_failure_dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
state_dir=${KVS_FAKE_DOCKER_STATE_DIR:?}
printf 'docker' >> "$state_dir/docker.log"
for arg in "$@"; do
  printf ' %q' "$arg" >> "$state_dir/docker.log"
done
printf '\n' >> "$state_dir/docker.log"

case "$1" in
  ps)
    if [[ -f "$state_dir/container-running" && "$*" == *"{{.Names}}"* ]]; then
      echo "conversion-server"
    fi
    ;;
  pull)
    exit 0
    ;;
  run)
    if [[ "$*" == *"--name conversion-server"* ]]; then
      touch "$state_dir/container-running"
      echo "fake-container-id"
    fi
    exit 0
    ;;
  stop)
    touch "$state_dir/container-stopped"
    rm -f "$state_dir/container-running"
    echo "conversion-server"
    ;;
  rm)
    touch "$state_dir/container-removed"
    ;;
  *)
    exit 0
    ;;
esac
DOCKER
chmod +x "$config_save_failure_dir/bin/docker"
cat > "$config_save_failure_dir/bin/mv" <<'MV'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == ".kvs-server.conf" ]]; then
    echo "simulated config save failure" >&2
    exit 1
  fi
done
exec /usr/bin/mv "$@"
MV
chmod +x "$config_save_failure_dir/bin/mv"

if (
  cd "$config_save_failure_dir/install"
  KVS_FAKE_DOCKER_STATE_DIR="$config_save_failure_dir" PATH="$config_save_failure_dir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version "$default_php_version" \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 1
) >"$config_save_failure_dir/install.out" 2>"$config_save_failure_dir/install.err"; then
  echo "install succeeded after configuration save failed"
  exit 1
fi

[[ ! -e "$config_save_failure_dir/install/.kvs-server.conf" ]]
[[ ! -e "$config_save_failure_dir/container-running" ]]
[[ -e "$config_save_failure_dir/container-stopped" ]]
grep -q "Configuration could not be saved after the container started" "$config_save_failure_dir/install.err"
grep -q "docker stop conversion-server" "$config_save_failure_dir/docker.log"

echo "install behavior tests passed"
