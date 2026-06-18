#!/bin/bash

is_reserved_ftp_username() {
  case "$1" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|_apt|nobody|systemd-network|ftp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

MAX_FTP_PASSWORD_LENGTH=511

validate_ftp_username() {
  local value="$1"

  if ((${#value} > 32)); then
    echo "FTP_USER must be 32 characters or fewer"
    exit 1
  fi

  if [[ "$value" == "." || "$value" == ".." ]]; then
    echo "FTP_USER cannot be '.' or '..'"
    exit 1
  fi

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "FTP_USER cannot be purely numeric"
    exit 1
  fi

  if [[ ! "$value" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]]; then
    echo "FTP_USER may only contain letters, digits, underscores, dots, and dashes, and must not start with a dash"
    exit 1
  fi

  if is_reserved_ftp_username "$value"; then
    echo "FTP_USER '$value' is reserved by the container image"
    exit 1
  fi
}

validate_ftp_password() {
  local value="$1"

  if [[ -z "$value" ]]; then
    echo "FTP_PASS is required"
    exit 1
  fi

  if ((${#value} > MAX_FTP_PASSWORD_LENGTH)); then
    echo "FTP_PASS must be $MAX_FTP_PASSWORD_LENGTH characters or fewer"
    exit 1
  fi

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "FTP_PASS must not contain CR or LF characters"
    exit 1
  fi
}

# Keep runtime account IDs inside signed 32-bit range to avoid UID/GID wrapping
# in tools that expose account metadata through signed integer fields.
MAX_ACCOUNT_ID=2147483647

account_id_exceeds_max() {
  local value="$1"

  if ((${#value} > ${#MAX_ACCOUNT_ID})); then
    return 0
  fi

  if ((${#value} < ${#MAX_ACCOUNT_ID})); then
    return 1
  fi

  ((value > MAX_ACCOUNT_ID))
}

validate_account_id_value() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer greater than 0"
    exit 1
  fi

  if account_id_exceeds_max "$value"; then
    echo "$name must be between 1 and $MAX_ACCOUNT_ID"
    exit 1
  fi
}

validate_account_ids() {
  local existing_user
  local existing_user_name
  local ftp_user_record
  local ftp_uid
  local ftp_gid
  local existing_group
  local existing_group_name
  local ftp_group_record
  local ftp_group_gid

  validate_account_id_value "USER_ID" "$USER_ID"
  validate_account_id_value "GROUP_ID" "$GROUP_ID"

  if existing_user=$(getent passwd "$USER_ID"); then
    IFS=: read -r existing_user_name _ <<< "$existing_user"
    if [[ "$existing_user_name" != "$FTP_USER" ]]; then
      echo "USER_ID '$USER_ID' is already in use by the container image"
      exit 1
    fi
  fi

  if ftp_user_record=$(getent passwd "$FTP_USER"); then
    IFS=: read -r _ _ ftp_uid ftp_gid _ <<< "$ftp_user_record"
    if [[ "$ftp_uid" != "$USER_ID" ]]; then
      echo "FTP_USER '$FTP_USER' exists with UID '$ftp_uid', expected '$USER_ID'"
      exit 1
    fi
    if [[ "$ftp_gid" != "$GROUP_ID" ]]; then
      echo "FTP_USER '$FTP_USER' exists with primary GID '$ftp_gid', expected '$GROUP_ID'"
      exit 1
    fi
  fi

  if existing_group=$(getent group "$GROUP_ID"); then
    IFS=: read -r existing_group_name _ <<< "$existing_group"
    if [[ "$existing_group_name" != "$FTP_USER" ]]; then
      echo "GROUP_ID '$GROUP_ID' is already in use by the container image"
      exit 1
    fi
  fi

  if ftp_group_record=$(getent group "$FTP_USER"); then
    IFS=: read -r _ _ ftp_group_gid _ <<< "$ftp_group_record"
    if [[ "$ftp_group_gid" != "$GROUP_ID" ]]; then
      echo "FTP_USER '$FTP_USER' conflicts with an existing container group"
      exit 1
    fi
  fi
}

ensure_ftp_directory() {
  local path="$1"
  local description="$2"

  if [[ -L "$path" ]]; then
    echo "$description must not be a symbolic link: $path"
    exit 1
  fi

  if [[ -e "$path" ]]; then
    if [[ ! -d "$path" ]]; then
      echo "$description exists and is not a directory: $path"
      exit 1
    fi
    return 0
  fi

  mkdir "$path"
}

ftp_user_can_traverse_directory() {
  local path="$1"
  local quoted_path

  printf -v quoted_path '%q' "$path"
  su -s /bin/bash "$FTP_USER" -c "test -x $quoted_path" >/dev/null 2>&1
}

ensure_ftp_base_traverse_access() {
  local path="$1"
  local description="$2"

  if ! id "$FTP_USER" >/dev/null 2>&1; then
    echo "FTP_USER '$FTP_USER' must exist before securing $description"
    exit 1
  fi

  if ftp_user_can_traverse_directory "$path"; then
    return 0
  fi

  if ! command -v setfacl >/dev/null 2>&1; then
    echo "Cannot grant FTP_USER '$FTP_USER' execute access to $description because setfacl is not installed: $path"
    exit 1
  fi

  if ! setfacl -m "u:$FTP_USER:--x" "$path"; then
    echo "Cannot grant FTP_USER '$FTP_USER' execute access to $description with ACL: $path"
    exit 1
  fi

  if ! ftp_user_can_traverse_directory "$path"; then
    echo "FTP_USER '$FTP_USER' still cannot traverse $description after ACL update: $path"
    exit 1
  fi
}

ensure_ftp_account() {
  if getent group "$FTP_USER" >/dev/null 2>&1; then
    echo "Group $FTP_USER already exists."
  else
    echo "Creating group $FTP_USER."
    groupadd -g "$GROUP_ID" "$FTP_USER"
  fi

  if id "$FTP_USER" >/dev/null 2>&1; then
    echo "User $FTP_USER already exists."
  else
    echo "Creating user $FTP_USER."
    useradd -u "$USER_ID" -g "$FTP_USER" -d "/home/vsftpd/$FTP_USER" "$FTP_USER"
  fi

  echo "$FTP_USER:$FTP_PASS" | chpasswd
}
