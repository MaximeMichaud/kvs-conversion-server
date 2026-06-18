#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/testlib.bash
source "$script_dir/testlib.bash"

repo_root=$(kvs_repo_root)
readme_path="$repo_root/README.md"
ci_workflow_path="$repo_root/.github/workflows/ci-build-and-push.yml"
image_repository=$(require_script_default IMAGE_REPOSITORY)
default_image_tag=$(require_script_default DEFAULT_IMAGE_TAG)
supported_php_versions=$(require_script_default SUPPORTED_PHP_VERSIONS)
default_php_version=$(require_script_default DEFAULT_PHP_VERSION)
default_php_assignment=$(read_script_assignment DEFAULT_PHP_VERSION)
expected_default_php_assignment="\${SUPPORTED_PHP_VERSIONS##* }"
supported_ftp_modes=$(require_script_default SUPPORTED_FTP_MODES)
default_num_folders=$(require_script_default DEFAULT_NUM_FOLDERS)
max_ftp_password_length=$(require_script_default MAX_FTP_PASSWORD_LENGTH)
max_crontab_lines=$(require_script_default MAX_CRONTAB_LINES)
max_num_folders=$(require_script_default MAX_NUM_FOLDERS)
default_cron_log_bytes=$(require_script_default DEFAULT_CRON_LOG_BYTES)
max_cron_log_bytes=$(require_script_default MAX_CRON_LOG_BYTES)
dockerfile_version=$(require_dockerfile_arg VERSION)
runtime_max_ftp_password_length=$(require_shell_assignment scripts/user-support.sh MAX_FTP_PASSWORD_LENGTH)
runtime_php_versions=$(read_dockerfile_php_cli_versions)
runtime_default_php_version=$(require_runtime_default DEFAULT_PHP_VERSION)
runtime_supported_php_versions=$(require_runtime_default SUPPORTED_PHP_VERSIONS)
runtime_supported_ftp_modes=$(require_runtime_default SUPPORTED_FTP_MODES)
runtime_default_num_folders=$(require_runtime_default DEFAULT_NUM_FOLDERS)
runtime_max_num_folders=$(require_runtime_default MAX_NUM_FOLDERS)
runtime_default_cron_log_bytes=$(require_runtime_default DEFAULT_CRON_LOG_BYTES)
runtime_max_cron_log_bytes=$(require_runtime_default MAX_CRON_LOG_BYTES)
entrypoint_num_folders=$(require_env_default scripts/entrypoint.sh NUM_FOLDERS)
folders_num_folders=$(require_env_default scripts/create_folders.sh NUM_FOLDERS)
folders_cron_log_max_bytes=$(require_env_default scripts/create_folders.sh CRON_LOG_MAX_BYTES)
cron_task_cron_log_max_bytes=$(require_env_default scripts/run-cron-task.sh CRON_LOG_MAX_BYTES)
vsftpd_log_file=$(awk -F= '$1 == "vsftpd_log_file" { print $2; exit }' "$repo_root/config/vsftpd-base.conf")
dockerfile_base_image=$(awk '$1 == "FROM" { print $2; exit }' "$repo_root/Dockerfile")
dockerfile_exposed_ports=$(awk '$1 == "EXPOSE" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }' "$repo_root/Dockerfile")
expected_num_folders_default="\$DEFAULT_NUM_FOLDERS"
expected_cron_log_bytes_default="\$DEFAULT_CRON_LOG_BYTES"
metadata_sensitive_files=()
world_execute_matches=""

while IFS= read -r -d '' file; do
  metadata_sensitive_files+=("$file")
done < <(
  find "$repo_root/.github/workflows" "$repo_root/tests" -type f \
    \( -name '*.bash' -o -name '*.yml' -o -name '*.yaml' \) \
    -print0
)

IFS=' ' read -r -a supported_php_version_list <<< "$supported_php_versions"
IFS=' ' read -r -a supported_ftp_mode_list <<< "$supported_ftp_modes"
IFS=' ' read -r -a runtime_php_version_list <<< "$runtime_php_versions"
last_supported_php_version="${supported_php_version_list[$((${#supported_php_version_list[@]} - 1))]}"

assert_no_metadata_hardcode_matches() {
  local description="$1"
  local pattern
  local file
  local match
  local found=0
  shift

  for pattern in "$@"; do
    for file in "${metadata_sensitive_files[@]}"; do
      while IFS= read -r match; do
        if ((found == 0)); then
          echo "$description must be derived from project defaults in tests and workflows, not hardcoded:"
        fi
        printf '  %s\n' "${match#"$repo_root/"}"
        found=1
      done < <(grep -EnH -- "$pattern" "$file" || true)
    done
  done

  if ((found)); then
    exit 1
  fi
}

assert_no_metadata_literal_matches() {
  local description="$1"
  local literal="$2"
  local file
  local match
  local found=0

  if [[ -z "$literal" ]]; then
    return 0
  fi

  for file in "${metadata_sensitive_files[@]}"; do
    while IFS= read -r match; do
      if ((found == 0)); then
        echo "$description must be derived from project defaults in tests and workflows, not hardcoded:"
      fi
      printf '  %s\n' "${match#"$repo_root/"}"
      found=1
    done < <(grep -FnH -- "$literal" "$file" || true)
  done

  if ((found)); then
    exit 1
  fi
}

require_readme_contains() {
  local description="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$readme_path"; then
    echo "$description is out of sync with project defaults:"
    echo "  expected README.md to contain: $expected"
    exit 1
  fi
}

require_readme_not_contains() {
  local description="$1"
  local unexpected="$2"

  if grep -Fq -- "$unexpected" "$readme_path"; then
    echo "$description duplicates generated project metadata in README.md:"
    echo "  unexpected README.md content: $unexpected"
    exit 1
  fi
}

require_readme_line_contains() {
  local description="$1"
  local selector="$2"
  local expected="$3"
  local line

  line=$(grep -F -- "$selector" "$readme_path" | head -n 1 || true)
  if [[ -z "$line" ]]; then
    echo "$description is missing from README.md:"
    echo "  expected a line containing: $selector"
    exit 1
  fi

  if [[ "$line" != *"$expected"* ]]; then
    echo "$description is out of sync with project defaults:"
    echo "  expected line to contain: $expected"
    echo "  actual line: $line"
    exit 1
  fi
}

require_readme_line_not_match() {
  local description="$1"
  local selector="$2"
  local unexpected_pattern="$3"
  local line

  line=$(grep -F -- "$selector" "$readme_path" | head -n 1 || true)
  if [[ -z "$line" ]]; then
    echo "$description is missing from README.md:"
    echo "  expected a line containing: $selector"
    exit 1
  fi

  if [[ "$line" =~ $unexpected_pattern ]]; then
    echo "$description duplicates generated project metadata in README.md:"
    echo "  unexpected pattern: $unexpected_pattern"
    echo "  actual line: $line"
    exit 1
  fi
}

format_markdown_code_list() {
  local -a values=("$@")
  local count=${#values[@]}
  local index
  local item
  local output=""

  for index in "${!values[@]}"; do
    item="\`${values[$index]}\`"
    if ((index == 0)); then
      output="$item"
    elif ((index == count - 1 && count > 2)); then
      output="$output, or $item"
    elif ((index == count - 1)); then
      output="$output or $item"
    else
      output="$output, $item"
    fi
  done

  printf '%s' "$output"
}

value_exceeds_max() {
  local value="$1"
  local max="$2"

  if ((${#value} > ${#max})); then
    return 0
  fi

  if ((${#value} < ${#max})); then
    return 1
  fi

  ((value > max))
}

image_tag_hardcode_patterns=(
  "(^|[^[:alnum:]_])(KVS_)?IMAGE_TAG[[:space:]]*[:=][[:space:]]*[\"']*[0-9]+\\.[0-9]+\\.[0-9]+([^0-9.]|$)"
  '--image-tag[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+([^0-9.]|$)'
  "--image-tag[[:space:]]+[\"']+[0-9]+\\.[0-9]+\\.[0-9]+([^0-9.]|$)"
  'kvs-conversion-server:[0-9]+\.[0-9]+\.[0-9]+([^0-9.]|$)'
)

php_version_hardcode_patterns=(
  "(^|[^[:alnum:]_])(KVS_)?PHP_VERSION[[:space:]]*[:=][[:space:]]*[\"']*php[0-9]+\\.[0-9]+([^0-9.]|$)"
  '--php-version[[:space:]]+php[0-9]+\.[0-9]+([^0-9.]|$)'
  "--php-version[[:space:]]+[\"']+php[0-9]+\\.[0-9]+([^0-9.]|$)"
)

if [[ "$dockerfile_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Dockerfile VERSION default ($dockerfile_version) must not hardcode a release version; release builds must pass DEFAULT_IMAGE_TAG ($default_image_tag) explicitly"
  exit 1
fi

if ! [[ "$default_image_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "DEFAULT_IMAGE_TAG ($default_image_tag) must use MAJOR.MINOR.PATCH"
  exit 1
fi

supported_ftp_modes_markdown=$(format_markdown_code_list "${supported_ftp_mode_list[@]}")
workflow_test_image=$(awk -F: '
  $1 ~ /^[[:space:]]*KVS_TEST_IMAGE$/ {
    value = $0
    sub(/^[^:]+:[[:space:]]*/, "", value)
    print value
    exit
  }
' "$ci_workflow_path" | tr -d "'\"")

if [[ -z "$workflow_test_image" ]]; then
  echo "CI workflow must define KVS_TEST_IMAGE once for local Docker integration tests"
  exit 1
fi

workflow_test_image_literal_count=$(grep -RohF -- "$workflow_test_image" "$repo_root/.github/workflows" | wc -l | tr -d ' ')
if ((workflow_test_image_literal_count != 1)); then
  echo "CI workflow test image tag ($workflow_test_image) must only be defined once through KVS_TEST_IMAGE"
  exit 1
fi

if ! grep -Fq "\$KVS_TEST_IMAGE" "$ci_workflow_path"; then
  echo "CI workflow must use KVS_TEST_IMAGE instead of repeating the local Docker test image tag"
  exit 1
fi

require_readme_not_contains "README current release line" "Current release:"
require_readme_not_contains "README image tag environment example" "\`KVS_IMAGE_TAG=$default_image_tag\`"
require_readme_not_contains "README image tag option example" "\`--image-tag $default_image_tag\`"
require_readme_not_contains "README Docker patch tag example" "\`$image_repository:$default_image_tag\`"
require_readme_line_contains "README default Docker image tag" "installer uses the pinned Docker image tag" "\`kvs-conversion-server.sh\`"
require_readme_line_contains "README image tag option default" "\`--image-tag TAG\`" "Installer default"
require_readme_line_not_match "README image tag option default" "\`--image-tag TAG\`" "\`[0-9]+\\.[0-9]+\\.[0-9]+\`"
require_readme_line_contains "README image tag environment syntax" "\`KVS_IMAGE_TAG=TAG\`" "\`--image-tag TAG\`"
require_readme_line_contains "README semver release format" "Git release tags use" "\`vMAJOR.MINOR.PATCH\`"
require_readme_line_contains "README Docker release format" "Docker image tags omit the \`v\` prefix" "A release tag publishes"
require_readme_contains "README Docker patch tag placeholder" "- \`$image_repository:MAJOR.MINOR.PATCH\`"
require_readme_contains "README Docker minor tag placeholder" "- \`$image_repository:MAJOR.MINOR\`"
require_readme_line_contains "README installer default tag" "installer defaults to" "\`DEFAULT_IMAGE_TAG\`"
require_readme_line_contains "README PHP version option default" "\`--php-version VERSION\`" "Supported PHP CLI version"
require_readme_line_contains "README PHP version option default" "\`--php-version VERSION\`" "Installer default"
require_readme_line_not_match "README PHP version option default" "\`--php-version VERSION\`" "\`php[0-9]+\\.[0-9]+\`"
require_readme_line_contains "README PHP version environment syntax" "\`KVS_PHP_VERSION=VERSION\`" "\`--php-version VERSION\`"
require_readme_line_contains "README FTP mode option default" "\`--ftp-mode MODE\`" "$supported_ftp_modes_markdown"
require_readme_line_contains "README folder count option default" "\`--num-folders NUMBER\`" "Installer default"
require_readme_line_not_match "README folder count option default" "\`--num-folders NUMBER\`" "\`[0-9]+\`"
require_readme_line_contains "README current defaults help" "current defaults and supported values" "\`--help\`"

for php_version in "${supported_php_version_list[@]}"; do
  require_readme_not_contains "README PHP version environment example $php_version" "\`KVS_PHP_VERSION=$php_version\`"
  require_readme_not_contains "README PHP version option example $php_version" "\`--php-version $php_version\`"
done

for ftp_mode in "${supported_ftp_mode_list[@]}"; do
  if [[ ! -f "$repo_root/config/vsftpd-$ftp_mode.conf" ]]; then
    echo "Supported FTP mode ($ftp_mode) must have config/vsftpd-$ftp_mode.conf"
    exit 1
  fi

  require_readme_contains "README FTP mode $ftp_mode port row" "| \`$ftp_mode\` |"

done

if [[ "$dockerfile_base_image" != "debian:trixie-slim" ]]; then
  echo "Dockerfile base image ($dockerfile_base_image) must pin Debian 13 instead of using a floating stable tag"
  exit 1
fi

if grep -Fq "debian:stable-slim" "$repo_root/Dockerfile"; then
  echo "Dockerfile must not use the floating Debian stable-slim tag"
  exit 1
fi

if grep -Eq '^[[:space:]]*ARG[[:space:]]+PHP_PACKAGE_VERSIONS([[:space:]=]|$)' "$repo_root/Dockerfile"; then
  echo "Dockerfile must derive PHP package versions from scripts/php-support.sh, not a separate PHP_PACKAGE_VERSIONS ARG"
  exit 1
fi

if ! grep -Fq "kvs-conversion-server.sh /usr/local/lib/kvs/kvs-conversion-server.sh" "$repo_root/Dockerfile"; then
  echo "Dockerfile must copy kvs-conversion-server.sh before installing PHP packages"
  exit 1
fi

if grep -Eq '^[[:space:]]*(DEFAULT_PHP_VERSION|SUPPORTED_PHP_VERSIONS)="?php[0-9]' "$repo_root/scripts/php-support.sh" \
  || grep -Eq '^[[:space:]]*SUPPORTED_FTP_MODES="?ftp' "$repo_root/scripts/php-support.sh" \
  || grep -Eq '^[[:space:]]*(DEFAULT_NUM_FOLDERS|MAX_NUM_FOLDERS)=[0-9]' "$repo_root/scripts/php-support.sh"; then
  echo "Runtime PHP support must derive project defaults from kvs-conversion-server.sh, not duplicate assignments"
  exit 1
fi

if ! grep -Fq "SUPPORTED_FTP_MODES=\$(read_project_default SUPPORTED_FTP_MODES)" "$repo_root/scripts/php-support.sh"; then
  echo "Runtime PHP support must derive SUPPORTED_FTP_MODES from kvs-conversion-server.sh"
  exit 1
fi

if grep -Eq '\^\(ftp\|ftps\|ftps_implicit\|ftps_tls\)\$|FTP_MODE must be ftp, ftps, ftps_implicit or ftps_tls' \
  "$repo_root/scripts/entrypoint.sh" "$repo_root/scripts/run-vsftpd.sh"; then
  echo "Runtime FTP mode validation must derive supported modes instead of hardcoding the list"
  exit 1
fi

world_execute_matches=$(grep -R -n -- 'chmod a+x' "$repo_root/scripts" || true)
if [[ -n "$world_execute_matches" ]]; then
  echo "Runtime scripts must not grant world execute access to FTP bind mounts:"
  printf '%s\n' "${world_execute_matches//$repo_root\//}"
  exit 1
fi

if ! grep -Fq "ensure_ftp_base_traverse_access" "$repo_root/scripts/create_folders.sh" \
  || ! grep -Fq "ensure_ftp_base_traverse_access" "$repo_root/scripts/run-vsftpd.sh"; then
  echo "Runtime scripts must grant FTP base traversal with the shared ACL helper"
  exit 1
fi

if ! grep -Eq '^[[:space:]]*acl[[:space:]\\]*$' "$repo_root/Dockerfile"; then
  echo "Dockerfile must install acl so bind-mounted FTP roots can grant user-specific traversal"
  exit 1
fi

if ! grep -Fq "is_supported_ftp_mode" "$repo_root/scripts/entrypoint.sh" \
  || ! grep -Fq "format_supported_ftp_modes" "$repo_root/scripts/entrypoint.sh" \
  || ! grep -Fq "is_supported_ftp_mode" "$repo_root/scripts/run-vsftpd.sh" \
  || ! grep -Fq "format_supported_ftp_modes" "$repo_root/scripts/run-vsftpd.sh"; then
  echo "Runtime FTP mode validation must use project default helpers"
  exit 1
fi

if [[ " $dockerfile_exposed_ports " != *" 20 "* ]] \
  || [[ " $dockerfile_exposed_ports " != *" 21 "* ]] \
  || [[ " $dockerfile_exposed_ports " != *" 990 "* ]] \
  || [[ " $dockerfile_exposed_ports " != *" 21100-21110 "* ]]; then
  echo "Dockerfile must expose FTP, FTPS, and passive FTP ports"
  exit 1
fi

if [[ " $dockerfile_exposed_ports " == *" 20-22 "* ]] || [[ " $dockerfile_exposed_ports " == *" 22 "* ]]; then
  echo "Dockerfile must not expose SSH port 22"
  exit 1
fi

if ! grep -Fq "scripts/run-cron-task.sh /usr/local/bin/run-cron-task.sh" "$repo_root/Dockerfile"; then
  echo "Dockerfile must copy scripts/run-cron-task.sh for bounded cron task logs"
  exit 1
fi

if ! grep -Fq "/usr/local/bin/run-cron-task.sh" "$repo_root/scripts/create_folders.sh"; then
  echo "create_folders.sh must use run-cron-task.sh for bounded cron task logs"
  exit 1
fi

assert_no_metadata_hardcode_matches "Docker image tags" "${image_tag_hardcode_patterns[@]}"
assert_no_metadata_literal_matches "Docker image tag literal '$default_image_tag'" "$default_image_tag"
assert_no_metadata_literal_matches "maximum FTP password length" "$max_ftp_password_length"
assert_no_metadata_literal_matches "default cron log byte limit" "$default_cron_log_bytes"
assert_no_metadata_literal_matches "maximum cron log byte limit" "$max_cron_log_bytes"

if [[ "$default_php_version" != "$last_supported_php_version" ]]; then
  echo "DEFAULT_PHP_VERSION ($default_php_version) must be the newest supported PHP version ($last_supported_php_version)"
  exit 1
fi

if [[ "$default_php_assignment" != "$expected_default_php_assignment" ]]; then
  echo "DEFAULT_PHP_VERSION must derive from the newest SUPPORTED_PHP_VERSIONS entry instead of hardcoding a PHP release"
  exit 1
fi

if [[ "$runtime_default_php_version" != "$default_php_version" ]]; then
  echo "Runtime DEFAULT_PHP_VERSION ($runtime_default_php_version) must match installer DEFAULT_PHP_VERSION ($default_php_version)"
  exit 1
fi

if [[ "$runtime_supported_php_versions" != "$supported_php_versions" ]]; then
  echo "Runtime SUPPORTED_PHP_VERSIONS ($runtime_supported_php_versions) must match installer SUPPORTED_PHP_VERSIONS ($supported_php_versions)"
  exit 1
fi

if [[ "$runtime_supported_ftp_modes" != "$supported_ftp_modes" ]]; then
  echo "Runtime SUPPORTED_FTP_MODES ($runtime_supported_ftp_modes) must match installer SUPPORTED_FTP_MODES ($supported_ftp_modes)"
  exit 1
fi

if ! [[ "$max_ftp_password_length" =~ ^[1-9][0-9]*$ ]]; then
  echo "MAX_FTP_PASSWORD_LENGTH ($max_ftp_password_length) must be a positive integer"
  exit 1
fi

if [[ "$runtime_max_ftp_password_length" != "$max_ftp_password_length" ]]; then
  echo "Runtime MAX_FTP_PASSWORD_LENGTH ($runtime_max_ftp_password_length) must match installer MAX_FTP_PASSWORD_LENGTH ($max_ftp_password_length)"
  exit 1
fi

for php_version in "${supported_php_version_list[@]}"; do
  if [[ " $runtime_php_versions " != *" $php_version "* ]]; then
    echo "Supported PHP version ($php_version) must be installed by the Dockerfile"
    exit 1
  fi
done

for php_version in "${runtime_php_version_list[@]}"; do
  if [[ " $supported_php_versions " != *" $php_version "* ]]; then
    echo "Dockerfile PHP version ($php_version) must be listed in SUPPORTED_PHP_VERSIONS ($supported_php_versions)"
    exit 1
  fi
done

assert_no_metadata_hardcode_matches "PHP versions" "${php_version_hardcode_patterns[@]}"
for php_version in "${supported_php_version_list[@]}"; do
  assert_no_metadata_literal_matches "PHP version literal '$php_version'" "$php_version"
done

if ! grep -Fq "supported_php_versions=" "$repo_root/Dockerfile" || ! grep -Fq "SUPPORTED_PHP_VERSIONS" "$repo_root/Dockerfile"; then
  echo "Dockerfile must read SUPPORTED_PHP_VERSIONS from kvs-conversion-server.sh"
  exit 1
fi

if ! grep -Fq "for supported_php_version in \$supported_php_versions" "$repo_root/Dockerfile"; then
  echo "Dockerfile must iterate over supported PHP versions from scripts/php-support.sh when installing PHP packages"
  exit 1
fi

for package_suffix in cli curl gd ftp mbstring opcache; do
  if ! grep -Fq "\"php\${php_version}-${package_suffix}\"" "$repo_root/Dockerfile"; then
    echo "Dockerfile must derive php-${package_suffix} packages from SUPPORTED_PHP_VERSIONS"
    exit 1
  fi
done

if ! grep -Fq "php\"\$php_version\" -i" "$repo_root/Dockerfile"; then
  echo "Dockerfile must discover PHP extension directories from SUPPORTED_PHP_VERSIONS"
  exit 1
fi

if ! grep -Fq "ioncube_loader_lin_\${php_version}.so" "$repo_root/Dockerfile"; then
  echo "Dockerfile must derive IonCube loader names from SUPPORTED_PHP_VERSIONS"
  exit 1
fi

if ! grep -Fq "/etc/php/\${php_version}/cli/php.ini" "$repo_root/Dockerfile"; then
  echo "Dockerfile must derive PHP CLI ini paths from SUPPORTED_PHP_VERSIONS"
  exit 1
fi

if [[ "$runtime_default_num_folders" != "$default_num_folders" ]]; then
  echo "Runtime DEFAULT_NUM_FOLDERS ($runtime_default_num_folders) must match installer DEFAULT_NUM_FOLDERS ($default_num_folders)"
  exit 1
fi

if [[ "$runtime_max_num_folders" != "$max_num_folders" ]]; then
  echo "Runtime MAX_NUM_FOLDERS ($runtime_max_num_folders) must match installer MAX_NUM_FOLDERS ($max_num_folders)"
  exit 1
fi

if value_exceeds_max "$((max_num_folders + 2))" "$max_crontab_lines"; then
  echo "MAX_NUM_FOLDERS ($max_num_folders) must leave room for cron markers within MAX_CRONTAB_LINES ($max_crontab_lines)"
  exit 1
fi

if value_exceeds_max "$default_num_folders" "$max_num_folders"; then
  echo "DEFAULT_NUM_FOLDERS ($default_num_folders) must not exceed MAX_NUM_FOLDERS ($max_num_folders)"
  exit 1
fi

if [[ "$entrypoint_num_folders" != "$expected_num_folders_default" ]]; then
  echo "entrypoint NUM_FOLDERS default ($entrypoint_num_folders) must use runtime DEFAULT_NUM_FOLDERS"
  exit 1
fi

if [[ "$folders_num_folders" != "$expected_num_folders_default" ]]; then
  echo "create_folders NUM_FOLDERS default ($folders_num_folders) must use runtime DEFAULT_NUM_FOLDERS"
  exit 1
fi

if [[ "$runtime_default_cron_log_bytes" != "$default_cron_log_bytes" ]]; then
  echo "Runtime DEFAULT_CRON_LOG_BYTES ($runtime_default_cron_log_bytes) must match installer DEFAULT_CRON_LOG_BYTES ($default_cron_log_bytes)"
  exit 1
fi

if [[ "$runtime_max_cron_log_bytes" != "$max_cron_log_bytes" ]]; then
  echo "Runtime MAX_CRON_LOG_BYTES ($runtime_max_cron_log_bytes) must match installer MAX_CRON_LOG_BYTES ($max_cron_log_bytes)"
  exit 1
fi

if [[ "$folders_cron_log_max_bytes" != "$expected_cron_log_bytes_default" ]]; then
  echo "create_folders CRON_LOG_MAX_BYTES default ($folders_cron_log_max_bytes) must use runtime DEFAULT_CRON_LOG_BYTES"
  exit 1
fi

if [[ "$cron_task_cron_log_max_bytes" != "$expected_cron_log_bytes_default" ]]; then
  echo "run-cron-task CRON_LOG_MAX_BYTES default ($cron_task_cron_log_max_bytes) must use runtime DEFAULT_CRON_LOG_BYTES"
  exit 1
fi

if [[ -z "$vsftpd_log_file" ]]; then
  echo "vsftpd_log_file is missing from config/vsftpd-base.conf"
  exit 1
fi

if ! grep -Fq "docker exec conversion-server tail -f $vsftpd_log_file" "$repo_root/kvs-conversion-server.sh"; then
  echo "Displayed vsftpd log command must match vsftpd_log_file ($vsftpd_log_file)"
  exit 1
fi
