#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

  mkdir -p "$(dirname "$config_path")"
  cat > "$config_path" <<CONFIG
PHP_VERSION=php8.1
FTP_MODE=ftp
FTP_USER=$ftp_user
FTP_PASS=$ftp_pass
IPV4_ADDRESS=127.0.0.1
NETWORK_INTERFACE=eth0
NUM_FOLDERS=2
CPU_LIMIT=1
IMAGE_TAG=1.3.0
CONTAINER_NAME=conversion-server
CONFIG
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

if KVS_CONFIG="$tmpdir/missing.conf" run_from "$tmpdir/install/sub" info >"$tmpdir/missing.out" 2>&1; then
  echo "missing KVS_CONFIG unexpectedly fell back to a parent config"
  exit 1
fi
grep -q "Configuration file not found" "$tmpdir/missing.out"

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

echo "config path management tests passed"
