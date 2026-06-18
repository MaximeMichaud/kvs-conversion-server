#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)

# shellcheck source=scripts/user-support.sh
source "$repo_root/scripts/user-support.sh"
# shellcheck source=scripts/php-support.sh
source "$repo_root/scripts/php-support.sh"

assert_rejects_password() {
  local password="$1"
  local expected_message="$2"
  local output
  local status

  set +e
  output=$(validate_ftp_password "$password" 2>&1)
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "validate_ftp_password accepted an invalid password"
    exit 1
  fi

  if [[ "$output" != "$expected_message" ]]; then
    echo "Unexpected validation message: $output"
    exit 1
  fi
}

validate_ftp_password "validpass123"
max_length_password=$(head -c "$MAX_FTP_PASSWORD_LENGTH" /dev/zero | tr '\0' A)
oversized_password=$(head -c "$((MAX_FTP_PASSWORD_LENGTH + 1))" /dev/zero | tr '\0' A)
validate_ftp_password "$max_length_password"
assert_rejects_password "" "FTP_PASS is required"
assert_rejects_password "$oversized_password" "FTP_PASS must be $MAX_FTP_PASSWORD_LENGTH characters or fewer"
assert_rejects_password $'validpass123\nroot:rootpass123' "FTP_PASS must not contain CR or LF characters"
assert_rejects_password $'validpass123\rroot:rootpass123' "FTP_PASS must not contain CR or LF characters"

assert_rejects_account_ids() {
  local user_id="$1"
  local group_id="$2"
  local expected_message="$3"
  local output
  local status

  set +e
  output=$(FTP_USER=testuser USER_ID="$user_id" GROUP_ID="$group_id" validate_account_ids 2>&1)
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "validate_account_ids accepted invalid account IDs"
    exit 1
  fi

  if [[ "$output" != "$expected_message" ]]; then
    echo "Unexpected account ID validation message: $output"
    exit 1
  fi
}

oversized_account_id=$((MAX_ACCOUNT_ID + 1))
very_large_account_id="${MAX_ACCOUNT_ID}0"

FTP_USER=testuser USER_ID="$MAX_ACCOUNT_ID" GROUP_ID="$MAX_ACCOUNT_ID" validate_account_ids
assert_rejects_account_ids 0 1000 "USER_ID must be a positive integer greater than 0"
assert_rejects_account_ids 1000 0 "GROUP_ID must be a positive integer greater than 0"
assert_rejects_account_ids "$oversized_account_id" 1000 "USER_ID must be between 1 and $MAX_ACCOUNT_ID"
assert_rejects_account_ids 1000 "$oversized_account_id" "GROUP_ID must be between 1 and $MAX_ACCOUNT_ID"
assert_rejects_account_ids "$very_large_account_id" 1000 "USER_ID must be between 1 and $MAX_ACCOUNT_ID"
assert_rejects_account_ids 1000 "$very_large_account_id" "GROUP_ID must be between 1 and $MAX_ACCOUNT_ID"

assert_rejects_ftp_directory() {
  local path="$1"
  local description="$2"
  local expected_message="$3"
  local output
  local status

  set +e
  output=$(ensure_ftp_directory "$path" "$description" 2>&1)
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "ensure_ftp_directory accepted an unsafe path"
    exit 1
  fi

  if [[ "$output" != "$expected_message" ]]; then
    echo "Unexpected FTP directory validation message: $output"
    exit 1
  fi
}

ftp_directory_dir=$(mktemp -d)
cron_overlap_dir=""
cron_lock_collision_dir=""
cron_injection_dir=""
trap 'rm -rf "$ftp_directory_dir" "$cron_overlap_dir" "$cron_lock_collision_dir" "$cron_injection_dir"' EXIT
ensure_ftp_directory "$ftp_directory_dir/new-home" "FTP user home"
[[ -d "$ftp_directory_dir/new-home" ]]
ln -s /tmp "$ftp_directory_dir/symlink-home"
printf 'not a directory\n' > "$ftp_directory_dir/plain-file"
assert_rejects_ftp_directory "$ftp_directory_dir/symlink-home" "FTP user home" "FTP user home must not be a symbolic link: $ftp_directory_dir/symlink-home"
assert_rejects_ftp_directory "$ftp_directory_dir/plain-file" "FTP user home" "FTP user home exists and is not a directory: $ftp_directory_dir/plain-file"

assert_rejects_num_folders() {
  local value="$1"
  local expected_message="$2"
  local output
  local status

  set +e
  output=$(validate_num_folders "$value" 2>&1)
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "validate_num_folders accepted an invalid folder count"
    exit 1
  fi

  if [[ "$output" != "$expected_message" ]]; then
    echo "Unexpected folder count validation message: $output"
    exit 1
  fi
}

validate_num_folders "$DEFAULT_NUM_FOLDERS"
validate_num_folders "$MAX_NUM_FOLDERS"
assert_rejects_num_folders 0 "NUM_FOLDERS must be a positive integer"
assert_rejects_num_folders abc "NUM_FOLDERS must be a positive integer"
assert_rejects_num_folders "$((MAX_NUM_FOLDERS + 1))" "NUM_FOLDERS must be between 1 and $MAX_NUM_FOLDERS"
assert_rejects_num_folders 999999999999999999999999 "NUM_FOLDERS must be between 1 and $MAX_NUM_FOLDERS"

assert_rejects_cron_log_max_bytes() {
  local value="$1"
  local expected_message="$2"
  local output
  local status

  set +e
  output=$(validate_cron_log_max_bytes "$value" 2>&1)
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "validate_cron_log_max_bytes accepted an invalid log limit"
    exit 1
  fi

  if [[ "$output" != "$expected_message" ]]; then
    echo "Unexpected cron log validation message: $output"
    exit 1
  fi
}

validate_cron_log_max_bytes "$DEFAULT_CRON_LOG_BYTES"
validate_cron_log_max_bytes "$MAX_CRON_LOG_BYTES"
assert_rejects_cron_log_max_bytes 0 "CRON_LOG_MAX_BYTES must be a positive integer"
assert_rejects_cron_log_max_bytes abc "CRON_LOG_MAX_BYTES must be a positive integer"
assert_rejects_cron_log_max_bytes "${MAX_CRON_LOG_BYTES}0" "CRON_LOG_MAX_BYTES must be between 1 and $MAX_CRON_LOG_BYTES"

validate_pasv_hostname_resolution localhost

set +e
pasv_unspecified_resolution_output=$(validate_pasv_hostname_resolution 0 2>&1)
pasv_unspecified_resolution_status=$?
set -e
if [[ "$pasv_unspecified_resolution_status" -eq 0 ]]; then
  echo "validate_pasv_hostname_resolution accepted a hostname resolving to 0.0.0.0"
  exit 1
fi
if [[ "$pasv_unspecified_resolution_output" != "PASV_ADDRESS hostname must not resolve to 0.0.0.0 when PASV_ADDR_RESOLVE is YES: 0" ]]; then
  echo "Unexpected unspecified passive hostname resolution message: $pasv_unspecified_resolution_output"
  exit 1
fi

set +e
pasv_resolution_output=$(validate_pasv_hostname_resolution not-a-real-kvs-host.invalid 2>&1)
pasv_resolution_status=$?
set -e
if [[ "$pasv_resolution_status" -eq 0 ]]; then
  echo "validate_pasv_hostname_resolution accepted an unresolved hostname"
  exit 1
fi
if [[ "$pasv_resolution_output" != "PASV_ADDRESS hostname must resolve to an IPv4 address when PASV_ADDR_RESOLVE is YES: not-a-real-kvs-host.invalid" ]]; then
  echo "Unexpected passive hostname resolution message: $pasv_resolution_output"
  exit 1
fi

cron_overlap_dir=$(mktemp -d)
mkdir -p "$cron_overlap_dir/bin" "$cron_overlap_dir/job"
printf '<?php // placeholder\n' > "$cron_overlap_dir/job/remote_cron.php"
cat > "$cron_overlap_dir/bin/su" <<'SH'
#!/bin/sh
if [ -n "${KVS_FAKE_SU_OUTPUT_BYTES:-}" ]; then
  head -c "$KVS_FAKE_SU_OUTPUT_BYTES" /dev/zero | tr '\0' A
  exit 0
fi
printf 'start\n'
sleep 5
printf 'end\n'
SH
chmod +x "$cron_overlap_dir/bin/su"

cron_log="$cron_overlap_dir/cron.log"
test_cron_log_bytes=100
: > "$cron_log"

set +e
cron_log_limit_output=$(env PATH="$cron_overlap_dir/bin:$PATH" CRON_LOG_MAX_BYTES="${MAX_CRON_LOG_BYTES}0" bash "$repo_root/scripts/run-cron-task.sh" "$cron_overlap_dir/job" "$DEFAULT_PHP_VERSION" testuser "$cron_log" 2>&1)
cron_log_limit_status=$?
set -e

if [[ "$cron_log_limit_status" -eq 0 ]]; then
  echo "run-cron-task accepted an oversized CRON_LOG_MAX_BYTES"
  exit 1
fi

if [[ "$cron_log_limit_output" != "CRON_LOG_MAX_BYTES must be between 1 and $MAX_CRON_LOG_BYTES" ]]; then
  echo "Unexpected run-cron-task log limit message: $cron_log_limit_output"
  exit 1
fi

# shellcheck disable=SC2094
env PATH="$cron_overlap_dir/bin:$PATH" KVS_FAKE_SU_OUTPUT_BYTES=200 CRON_LOG_MAX_BYTES="$test_cron_log_bytes" bash "$repo_root/scripts/run-cron-task.sh" "$cron_overlap_dir/job" "$DEFAULT_PHP_VERSION" testuser "$cron_log" >> "$cron_log" 2>&1
cron_log_size=$(wc -c < "$cron_log" | tr -d '[:space:]')
if ((cron_log_size > test_cron_log_bytes)); then
  echo "run-cron-task left $cron_log_size bytes after a $test_cron_log_bytes byte log limit"
  exit 1
fi
: > "$cron_log"

# shellcheck disable=SC2094
env PATH="$cron_overlap_dir/bin:$PATH" CRON_LOG_MAX_BYTES="$test_cron_log_bytes" bash "$repo_root/scripts/run-cron-task.sh" "$cron_overlap_dir/job" "$DEFAULT_PHP_VERSION" testuser "$cron_log" >> "$cron_log" 2>&1 &
first_cron_pid=$!
deadline=$((SECONDS + 10))
until grep -q '^start$' "$cron_log"; do
  if ((SECONDS > deadline)); then
    cat "$cron_log"
    exit 1
  fi
  sleep 0.1
done

printf '%*s\n' "$((test_cron_log_bytes + 20))" x >> "$cron_log"
# shellcheck disable=SC2094
env PATH="$cron_overlap_dir/bin:$PATH" CRON_LOG_MAX_BYTES="$test_cron_log_bytes" bash "$repo_root/scripts/run-cron-task.sh" "$cron_overlap_dir/job" "$DEFAULT_PHP_VERSION" testuser "$cron_log" >> "$cron_log" 2>&1 || true
wait "$first_cron_pid"

grep -q '^end$' "$cron_log"
grep -q "Skipping $cron_overlap_dir/job because a previous cron task is still running" "$cron_log"

cron_lock_collision_dir=$(mktemp -d)
mkdir -p "$cron_lock_collision_dir/bin" "$cron_lock_collision_dir/a/b" "$cron_lock_collision_dir/a_b"
printf '<?php // placeholder\n' > "$cron_lock_collision_dir/a/b/remote_cron.php"
printf '<?php // placeholder\n' > "$cron_lock_collision_dir/a_b/remote_cron.php"
cat > "$cron_lock_collision_dir/bin/su" <<'SH'
#!/bin/sh
printf 'start\n'
sleep 2
printf 'end\n'
SH
chmod +x "$cron_lock_collision_dir/bin/su"

collision_log1="$cron_lock_collision_dir/log1"
collision_log2="$cron_lock_collision_dir/log2"
: > "$collision_log1"
: > "$collision_log2"

# shellcheck disable=SC2094
env PATH="$cron_lock_collision_dir/bin:$PATH" CRON_LOG_MAX_BYTES="$test_cron_log_bytes" bash "$repo_root/scripts/run-cron-task.sh" "$cron_lock_collision_dir/a/b" "$DEFAULT_PHP_VERSION" testuser "$collision_log1" > "$collision_log1" 2>&1 &
first_collision_pid=$!
deadline=$((SECONDS + 10))
until grep -q '^start$' "$collision_log1"; do
  if ((SECONDS > deadline)); then
    cat "$collision_log1"
    exit 1
  fi
  sleep 0.1
done

# shellcheck disable=SC2094
env PATH="$cron_lock_collision_dir/bin:$PATH" CRON_LOG_MAX_BYTES="$test_cron_log_bytes" bash "$repo_root/scripts/run-cron-task.sh" "$cron_lock_collision_dir/a_b" "$DEFAULT_PHP_VERSION" testuser "$collision_log2" > "$collision_log2" 2>&1
wait "$first_collision_pid"

grep -q '^start$' "$collision_log2"
grep -q '^end$' "$collision_log2"
if grep -q "Skipping $cron_lock_collision_dir/a_b because a previous cron task is still running" "$collision_log2"; then
  echo "run-cron-task reused the same lock for two distinct task directories"
  exit 1
fi

cron_injection_dir=$(mktemp -d)
mkdir -p "$cron_injection_dir/bin" "$cron_injection_dir/job"
printf '<?php // placeholder\n' > "$cron_injection_dir/job/remote_cron.php"
cat > "$cron_injection_dir/bin/su" <<'SH'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-c" ]; then
    shift
    /bin/sh -c "$1"
    exit $?
  fi
  shift
done
exit 0
SH
chmod +x "$cron_injection_dir/bin/su"

cron_injection_marker="$cron_injection_dir/marker"
cron_injection_php_version="${DEFAULT_PHP_VERSION}; printf injected > '$cron_injection_marker'; #"
set +e
cron_injection_output=$(env PATH="$cron_injection_dir/bin:$PATH" CRON_LOG_MAX_BYTES="$test_cron_log_bytes" bash "$repo_root/scripts/run-cron-task.sh" "$cron_injection_dir/job" "$cron_injection_php_version" testuser "$cron_injection_dir/cron.log" 2>&1)
cron_injection_status=$?
set -e

if [[ "$cron_injection_status" -eq 0 ]]; then
  echo "run-cron-task accepted an invalid PHP_VERSION"
  exit 1
fi

if [[ -e "$cron_injection_marker" ]]; then
  echo "run-cron-task executed shell content from PHP_VERSION"
  exit 1
fi

expected_php_message="PHP_VERSION must be $(format_supported_php_versions quoted)"
if [[ "$cron_injection_output" != "$expected_php_message" ]]; then
  echo "Unexpected run-cron-task PHP version message: $cron_injection_output"
  exit 1
fi

echo "runtime validation tests passed"
