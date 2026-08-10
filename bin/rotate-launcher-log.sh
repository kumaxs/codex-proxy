#!/bin/zsh

set -u
set -o pipefail
umask 077

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../lib/config.sh"
readonly CURRENT_UID="$(/usr/bin/id -u)"

MAX_LAUNCHER_LOG_FILES=5

is_mode_owner_allowed() {
  local owner="$1"
  local mode="$2"
  local target="$3"
  local mode_decimal="$((8#$mode))"
  if (( owner == 0 )); then
    if [[ "$target" == "/private/tmp" || "$target" == "/tmp" ]] \
        && (( (mode_decimal & 512) != 0 )); then
      return 0
    fi
    if (( (mode_decimal & 18) != 0 )); then
      return 1
    fi
    return 0
  fi
  if (( owner == CURRENT_UID )); then
    if (( (mode_decimal & 18) != 0 )); then
      return 1
    fi
    return 0
  fi
  return 1
}

check_target_is_safe() {
  local target="$1"
  local owner
  local mode
  local cursor
  if [[ -L "$target" ]]; then
    return 1
  fi
  if [[ ! -e "$target" ]]; then
    return 0
  fi
  owner="$(/usr/bin/stat -f '%u' "$target" 2>/dev/null)" || return 1
  mode="$(/usr/bin/stat -f '%A' "$target" 2>/dev/null)" || return 1
  if ! is_mode_owner_allowed "$owner" "$mode" "$target"; then
    return 1
  fi
  cursor="${target:h}"
  while true; do
    if [[ "$cursor" == "/" ]]; then
      return 0
    fi
    if [[ -L "$cursor" ]]; then
      return 1
    fi
    if [[ -e "$cursor" ]]; then
      owner="$(/usr/bin/stat -f '%u' "$cursor" 2>/dev/null)" || return 1
      mode="$(/usr/bin/stat -f '%A' "$cursor" 2>/dev/null)" || return 1
      if ! is_mode_owner_allowed "$owner" "$mode" "$cursor"; then
        return 1
      fi
    fi
    cursor="${cursor:h}"
  done
}

if [[ "$MAX_LAUNCHER_LOG_FILES" != <-> ]]; then
  print -u2 "[ERROR] MAX_LAUNCHER_LOG_FILES must be numeric."
  exit 1
fi
if (( MAX_LAUNCHER_LOG_FILES < 1 || MAX_LAUNCHER_LOG_FILES > 5 )); then
  print -u2 "[ERROR] MAX_LAUNCHER_LOG_FILES must be between 1 and 5."
  exit 1
fi

CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"
codex_proxy_init_runtime_paths

runtime_root="${CODEX_PROXY_RUNTIME_HOME}"
log_file="${runtime_root}/launcher.log"

if [[ -L "$runtime_root" ]]; then
  print -u2 "[ERROR] unsafe symlink runtime root: $runtime_root"
  exit 1
fi
if ! check_target_is_safe "$runtime_root"; then
  print -u2 "[ERROR] unsafe runtime root: $runtime_root"
  exit 1
fi

if [[ ! -d "$runtime_root" ]]; then
  exit 0
fi
if ! check_target_is_safe "$log_file"; then
  print -u2 "[ERROR] unsafe launcher log path: $log_file"
  exit 1
fi

oldest_log="${log_file}.${MAX_LAUNCHER_LOG_FILES}"
if [[ -e "$oldest_log" || -L "$oldest_log" ]]; then
  if ! check_target_is_safe "$oldest_log"; then
    print -u2 "[ERROR] unsafe oldest launcher log: $oldest_log"
    exit 1
  fi
  if ! /bin/rm -f "$oldest_log"; then
    print -u2 "[ERROR] failed to prune oldest launcher log."
    exit 1
  fi
fi

for (( i = MAX_LAUNCHER_LOG_FILES - 1; i >= 1; i-- )); do
  src="${log_file}.${i}"
  dst="${log_file}.$(( i + 1 ))"
  if [[ -e "$src" || -L "$src" ]]; then
    if ! check_target_is_safe "$src"; then
      print -u2 "[ERROR] unsafe rotated launcher log source: $src"
      exit 1
    fi
    if ! check_target_is_safe "$dst"; then
      print -u2 "[ERROR] unsafe rotated launcher log destination: $dst"
      exit 1
    fi
    if ! /bin/mv -f "$src" "$dst"; then
      print -u2 "[ERROR] failed to rotate launcher log: $src -> $dst"
      exit 1
    fi
  fi
done

if [[ -e "$log_file" ]]; then
  if ! /bin/mv -f "$log_file" "${log_file}.1"; then
    print -u2 "[ERROR] failed to rotate launcher log."
    exit 1
  fi
fi

if ! /usr/bin/touch "$log_file"; then
  print -u2 "[ERROR] failed to recreate launcher.log."
  exit 1
fi

if ! /bin/chmod 600 "$log_file"; then
  print -u2 "[ERROR] failed to restrict launcher.log permissions."
  exit 1
fi
for (( i = 1; i <= MAX_LAUNCHER_LOG_FILES; i++ )); do
  rotated_log="${log_file}.${i}"
  if [[ -e "$rotated_log" || -L "$rotated_log" ]]; then
    if ! check_target_is_safe "$rotated_log" || ! /bin/chmod 600 "$rotated_log"; then
      print -u2 "[ERROR] failed to restrict rotated launcher log: $rotated_log"
      exit 1
    fi
  fi
done
exit 0
