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

cat > "$tmpdir/.kvs-server.conf" <<'CONFIG'
PHP_VERSION=php8.1
FTP_MODE=ftp
FTP_USER=testuser
FTP_PASS=secret-password-123
IPV4_ADDRESS=203.0.113.10
NETWORK_INTERFACE=eth0
NUM_FOLDERS=5
CPU_LIMIT=2
IMAGE_TAG=1.3.0
CONTAINER_NAME=conversion-server
CONFIG

run_script() {
  (cd "$tmpdir" && PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" "$@")
}

default_output=$(run_script info)
[[ "$default_output" == *"FTP Password: ********"* ]]
[[ "$default_output" == *"use info --show-password to reveal"* ]]
[[ "$default_output" != *"secret-password-123"* ]]

revealed_output=$(run_script info --show-password)
[[ "$revealed_output" == *"FTP Password: secret-password-123"* ]]
[[ "$revealed_output" != *"FTP Password: ********"* ]]

if run_script info --bad-option >"$tmpdir/bad.out" 2>"$tmpdir/bad.err"; then
  echo "info accepted an unknown option"
  exit 1
fi
grep -q "Unknown option for info: --bad-option" "$tmpdir/bad.err"

install_dir="$tmpdir/install"
mkdir -p "$install_dir"
(
  cd "$install_dir"
  PATH="$tmpdir/bin:$PATH" NO_COLOR=1 "$repo_root/kvs-conversion-server.sh" \
    --headless \
    --php-version php8.1 \
    --ftp-mode ftp \
    --ipv4 127.0.0.1 \
    --cpu-limit 1 \
    --ftp-user testuser \
    --ftp-pass testpass123 \
    --num-folders 2
) >"$tmpdir/install.out" 2>&1

grep -q "Keep .kvs-server.conf private. It contains the FTP password required by KVS." "$tmpdir/install.out"
grep -q "read FTP_PASS from .kvs-server.conf or run the script with 'info --show-password'" "$tmpdir/install.out"
grep -q '^FTP_PASS=testpass123$' "$install_dir/.kvs-server.conf"

echo "info password recovery tests passed"
