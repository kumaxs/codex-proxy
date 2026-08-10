#!/bin/zsh

set -u
set -o pipefail
umask 077

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly MANIFEST_NAME=".codex-proxy-manifest"
readonly RELAY_LABEL="io.github.kumaxs.codex-proxy-relay"
readonly RELAY_PLIST_NAME="${RELAY_LABEL}.plist"
readonly EXPECTED_BUNDLE_ID="io.github.kumaxs.codex-proxy"
readonly EXPECTED_README_NAME="RUNTIME.md"
readonly DEFAULT_RUNTIME_HOME="${HOME}/Library/Application Support/Codex Proxy"
readonly DEFAULT_APP_PATH="${HOME}/Applications/Codex Proxy.app"
readonly DEFAULT_PLIST_PATH="${HOME}/Library/LaunchAgents/${RELAY_PLIST_NAME}"
readonly CURRENT_UID="$(/usr/bin/id -u)"
readonly INSTALL_LOCK_DIR="/private/tmp/com.github.kumaxs.codex-proxy-install-${CURRENT_UID}.lock"
readonly INSTALL_LOCK_FILE="${INSTALL_LOCK_DIR}/owner-pid"
readonly LAUNCH_LOCK_DIR="/private/tmp/com.github.kumaxs.codex-proxy-launch-${CURRENT_UID}.lock"

# Lifecycle hooks are accepted only for isolated copies under /private/tmp;
# production invocations always query the real launchd/lsof state.
LIFECYCLE_TEST_MODE=0
TEST_LISTENER_PIDS=""
TEST_LAUNCHD_STATE="absent"
TEST_LAUNCHD_PID=""
TEST_LAUNCHD_PATH=""
TEST_BOOTOUT_RESULT="success"
TEST_APP_PIDS=""
TEST_CHATGPT_PIDS=""
if [[ "${CODEX_PROXY_LIFECYCLE_TEST_MODE:-0}" == "1" && "$SCRIPT_DIR" == /private/tmp/* ]]; then
  LIFECYCLE_TEST_MODE=1
  TEST_LISTENER_PIDS="${CODEX_PROXY_TEST_LISTENER_PIDS:-}"
  TEST_LAUNCHD_STATE="${CODEX_PROXY_TEST_LAUNCHD_STATE:-absent}"
  TEST_LAUNCHD_PID="${CODEX_PROXY_TEST_LAUNCHD_PID:-}"
  TEST_LAUNCHD_PATH="${CODEX_PROXY_TEST_LAUNCHD_PATH:-}"
  TEST_BOOTOUT_RESULT="${CODEX_PROXY_TEST_BOOTOUT_RESULT:-success}"
  TEST_APP_PIDS="${CODEX_PROXY_TEST_APP_PIDS:-}"
  TEST_CHATGPT_PIDS="${CODEX_PROXY_TEST_CHATGPT_PIDS:-}"
fi

readonly ALLOWED_MANIFEST_KEYS=(
  ManifestFormat
  ManifestVersion
  RuntimeHome
  AppPath
  PlistPath
  RelayLabel
  BundleId
  InstalledBinPath
  InstalledLibPath
  InstalledManifestPath
  KeepConfigPath
  KeepMitmPath
  KeepLauncherLogPath
  KeepRelayLogPath
  KeepRuntimeReadmePath
)
readonly REQUIRED_MANIFEST_KEYS=(
  ManifestFormat
  ManifestVersion
  RuntimeHome
  AppPath
  PlistPath
  RelayLabel
  BundleId
  InstalledBinPath
  InstalledLibPath
  InstalledManifestPath
  KeepConfigPath
  KeepMitmPath
  KeepLauncherLogPath
  KeepRelayLogPath
  KeepRuntimeReadmePath
)

source "${PROJECT_ROOT}/lib/config.sh"

RUNTIME_HOME="${DEFAULT_RUNTIME_HOME}"
APP_PATH="${DEFAULT_APP_PATH}"
PLIST_PATH="${DEFAULT_PLIST_PATH}"
PURGE_RUNTIME=0
ASSUME_YES=0
DRY_RUN=0

TMP_ROOT=""
INSTALL_LOCK_CREATED=0
INSTALL_LOCK_PATH=""
CURRENT_APP_PATH=""
CURRENT_PLIST_PATH=""

MANIFEST_FORMAT=""
MANIFEST_VERSION=""
MANIFEST_RUNTIME_HOME=""
MANIFEST_APP_PATH=""
MANIFEST_PLIST_PATH=""
MANIFEST_LABEL=""
MANIFEST_BUNDLE_ID=""
MANIFEST_KEEP_CONFIG=""
MANIFEST_KEEP_MITM=""
MANIFEST_KEEP_LAUNCHER_LOG=""
MANIFEST_KEEP_RELAY_LOG=""
MANIFEST_KEEP_RUNTIME_README=""
MANIFEST_MANIFEST=""
MANIFEST_INSTALLED_BIN=""
MANIFEST_INSTALLED_LIB=""
LISTEN_HOST=""
LISTEN_PORT=""
LAUNCHD_JOB_LOADED=0
LAUNCHD_JOB_PID=""
LAUNCHD_JOB_PATH=""

usage() {
  cat <<'EOF_USAGE'
Usage: uninstall.sh [--home DIR] [--purge-runtime] [--yes] [--dry-run]
  --home            runtime home (absolute path)
  --purge-runtime   remove runtime home too
  --yes             required with --purge-runtime
  --dry-run         dry-run only
EOF_USAGE
}

log_info() {
  print -r -- "[INFO] $*"
}

log_error() {
  print -u2 -r -- "[ERROR] $*"
}

is_mode_owner_allowed() {
  local owner="$1"
  local mode="$2"
  local target="$3"
  local mode_decimal="$((8#$mode))"

  if [[ "$owner" == "$CURRENT_UID" ]]; then
    if (( (mode_decimal & 18) != 0 )); then
      return 1
    fi
    return 0
  fi

  if (( owner == 0 )); then
    if (( (mode_decimal & 512) != 0 )) && [[ "$target" == "/private/tmp" || "$target" == "/tmp" ]]; then
      return 0
    fi
    if (( (mode_decimal & 18) != 0 )); then
      return 1
    fi
    return 0
  fi

  return 1
}

owner_ok_for_target() {
  local target="$1"
  local allow_root="$2"
  local owner
  local mode

  if [[ ! -e "$target" ]]; then
    return 0
  fi
  if [[ -L "$target" ]]; then
    return 1
  fi
  owner="$(/usr/bin/stat -f '%u' "$target" 2>/dev/null)" || return 1
  mode="$(/usr/bin/stat -f '%A' "$target" 2>/dev/null)" || return 1
  if ! is_mode_owner_allowed "$owner" "$mode" "$target"; then
    return 1
  fi
  if [[ "$owner" != "$CURRENT_UID" ]]; then
    if ! (( allow_root == 1 && owner == 0 )); then
      return 1
    fi
  fi
  return 0
}

check_path_chain() {
  local target="$1"
  local allow_root="$2"
  local cursor="$target"
  local tmp_link

  while true; do
    if [[ "$cursor" == "/" ]]; then
      return 0
    fi
    if [[ "$cursor" == "/tmp" && -L "$cursor" ]]; then
      tmp_link="$(/bin/readlink "$cursor" 2>/dev/null || true)"
      if [[ "$tmp_link" == "/private/tmp" ]]; then
        cursor="/private/tmp"
      fi
    fi
    if [[ -L "$cursor" ]]; then
      log_error "unsafe symlink component: $cursor"
      return 1
    fi
    if [[ -e "$cursor" ]] && ! owner_ok_for_target "$cursor" "$allow_root"; then
      log_error "unsafe ownership/mode component: $cursor"
      return 1
    fi
    if [[ "${cursor:h}" == "$cursor" ]]; then
      return 0
    fi
    cursor="${cursor:h}"
  done
}

canonicalize_abs_path() {
  local target="$1"
  if [[ -z "$target" ]]; then
    return 1
  fi
  if [[ "$target" != /* ]]; then
    log_error "path must be absolute: $target"
    return 1
  fi
  print -r -- "${target:a}"
}

read_lock_file() {
  local uid pid raw
  local lock_file="$1"
  if ! raw="$(/bin/cat "$lock_file" 2>/dev/null)"; then
    return 1
  fi
  if [[ "$raw" != <->\ <-> ]]; then
    return 1
  fi
  uid="${raw%% *}"
  pid="${raw#* }"
  if [[ "$uid" != <-> || "$pid" != <-> ]]; then
    return 1
  fi
  print -r -- "$uid $pid"
  return 0
}

check_existing_install_lock() {
  local payload
  local lock_uid
  local lock_pid

  if [[ ! -e "$INSTALL_LOCK_DIR" && ! -L "$INSTALL_LOCK_DIR" ]]; then
    return 0
  fi
  if [[ -L "$INSTALL_LOCK_DIR" || ! -d "$INSTALL_LOCK_DIR" ]]; then
    log_error "install lock path is unsafe; refusing to continue: $INSTALL_LOCK_DIR"
    return 1
  fi
  if ! check_path_chain "$INSTALL_LOCK_DIR" 1; then
    return 1
  fi
  if [[ -L "$INSTALL_LOCK_FILE" ]]; then
    log_error "install lock owner is a symlink; refusing to continue: $INSTALL_LOCK_FILE"
    return 1
  fi
  if [[ -e "$INSTALL_LOCK_FILE" ]] && ! owner_ok_for_target "$INSTALL_LOCK_FILE" 1; then
    log_error "install lock owner has unsafe ownership/mode: $INSTALL_LOCK_FILE"
    return 1
  fi
  payload="$(read_lock_file "$INSTALL_LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$payload" ]]; then
    lock_uid="$(/usr/bin/printf '%s\n' "$payload" | /usr/bin/awk '{print $1}')"
    lock_pid="$(/usr/bin/printf '%s\n' "$payload" | /usr/bin/awk '{print $2}')"
    if /bin/ps -p "$lock_pid" >/dev/null 2>&1; then
      local active_uid
      active_uid="$(/bin/ps -p "$lock_pid" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
      if [[ "$active_uid" == "$lock_uid" ]]; then
        log_error "another install/uninstall transaction is active (uid=$lock_uid, pid=$lock_pid)"
        return 1
      fi
    fi
    log_error "install lock exists (stale or unverifiable); refusing to remove it: $INSTALL_LOCK_DIR"
  else
    log_error "install lock is missing a valid owner; refusing to remove it: $INSTALL_LOCK_DIR"
  fi
  return 1
}

check_existing_launch_lock() {
  local owner
  local owner_uid

  if [[ ! -e "$LAUNCH_LOCK_DIR" && ! -L "$LAUNCH_LOCK_DIR" ]]; then
    return 0
  fi
  if [[ -L "$LAUNCH_LOCK_DIR" || ! -d "$LAUNCH_LOCK_DIR" ]]; then
    log_error "launcher lock path is unsafe; refusing to continue: $LAUNCH_LOCK_DIR"
    return 1
  fi
  if ! check_path_chain "$LAUNCH_LOCK_DIR" 1; then
    return 1
  fi
  if [[ -L "$LAUNCH_LOCK_DIR/owner-pid" ]]; then
    log_error "launcher lock owner is a symlink; refusing to continue: $LAUNCH_LOCK_DIR/owner-pid"
    return 1
  fi
  if [[ -e "$LAUNCH_LOCK_DIR/owner-pid" ]] && ! owner_ok_for_target "$LAUNCH_LOCK_DIR/owner-pid" 1; then
    log_error "launcher lock owner has unsafe ownership/mode: $LAUNCH_LOCK_DIR/owner-pid"
    return 1
  fi
  owner="$(/bin/cat "$LAUNCH_LOCK_DIR/owner-pid" 2>/dev/null || true)"
  if [[ "$owner" != <-> ]]; then
    log_error "launcher lock has no valid owner; refusing to continue: $LAUNCH_LOCK_DIR"
    return 1
  fi
  owner_uid="$(/bin/ps -p "$owner" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
  if [[ -z "$owner_uid" || "$owner_uid" != "$CURRENT_UID" ]]; then
    log_error "launcher lock owner cannot be verified; refusing to continue: $LAUNCH_LOCK_DIR"
    return 1
  fi
  log_error "launcher process is active (uid=$owner_uid, pid=$owner); refusing transaction."
  return 1
}

acquire_install_lock() {
  local tmp_file

  if ! check_existing_install_lock; then
    return 1
  fi

  if ! /bin/mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    log_error "cannot create install lock directory (another transaction may be racing)."
    return 1
  fi

  if ! /bin/chmod 700 "$INSTALL_LOCK_DIR"; then
    /bin/rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
    return 1
  fi

  if ! tmp_file="$(/usr/bin/mktemp "${INSTALL_LOCK_DIR}/owner-pid.XXXXXX")"; then
    /bin/rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  if ! /usr/bin/printf '%s %s\n' "$CURRENT_UID" "$$" > "$tmp_file"; then
    /bin/rm -f -- "$tmp_file"
    /bin/rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  if ! /bin/chmod 600 "$tmp_file"; then
    /bin/rm -f -- "$tmp_file"
    /bin/rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  if ! /bin/mv -f "$tmp_file" "$INSTALL_LOCK_FILE"; then
    /bin/rm -f -- "$tmp_file"
    /bin/rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  if ! /bin/cat "$INSTALL_LOCK_FILE" >/dev/null 2>&1; then
    /bin/rm -f -- "$INSTALL_LOCK_FILE"
    /bin/rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
    return 1
  fi

  INSTALL_LOCK_CREATED=1
  INSTALL_LOCK_PATH="$INSTALL_LOCK_DIR"
  return 0
}

release_install_lock() {
  if (( INSTALL_LOCK_CREATED == 1 )); then
    /bin/rm -f -- "${INSTALL_LOCK_PATH}/owner-pid"
    /bin/rmdir -- "$INSTALL_LOCK_PATH" 2>/dev/null || true
    INSTALL_LOCK_CREATED=0
    INSTALL_LOCK_PATH=""
  fi
}

extract_manifest_keys() {
  local manifest_file="$1"
  local -a lines
  local line
  local key
  local -A found
  lines=("${(@f)$(
    /usr/bin/plutil -convert xml1 -o - "$manifest_file" 2>/dev/null || true
  )}")
  if (( ${#lines[@]} == 0 )); then
    return 1
  fi

  found=()
  for line in "${lines[@]}"; do
    if [[ "$line" != *'<key>'* ]]; then
      continue
    fi
    key="${line#*<key>}"
    key="${key%%</key>*}"
    if [[ -z "$key" ]]; then
      continue
    fi
    if [[ -n "${found[$key]+x}" ]]; then
      log_error "manifest duplicate key: $key"
      return 1
    fi
    found[$key]=1
  done

  for key in "${(@k)found}"; do
    local found_key=0
    for allowed in "${ALLOWED_MANIFEST_KEYS[@]}"; do
      if [[ "$key" == "$allowed" ]]; then
        found_key=1
        break
      fi
    done
    if (( found_key == 0 )); then
      log_error "manifest unknown key: $key"
      return 1
    fi
  done
  for key in "${REQUIRED_MANIFEST_KEYS[@]}"; do
    if [[ -z "${found[$key]+x}" ]]; then
      log_error "manifest required key missing: $key"
      return 1
    fi
  done
  return 0
}

manifest_get() {
  local manifest_file="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw "$manifest_file" 2>/dev/null
}

validate_manifest() {
  local manifest_file="${RUNTIME_HOME}/${MANIFEST_NAME}"
  if [[ -L "$manifest_file" || ! -f "$manifest_file" ]]; then
    log_error "manifest must be a regular file: $manifest_file"
    return 1
  fi
  if ! extract_manifest_keys "$manifest_file"; then
    return 1
  fi
  MANIFEST_FORMAT="$(manifest_get "$manifest_file" ManifestFormat)" || return 1
  MANIFEST_VERSION="$(manifest_get "$manifest_file" ManifestVersion)" || return 1
  MANIFEST_RUNTIME_HOME="$(manifest_get "$manifest_file" RuntimeHome)" || return 1
  MANIFEST_APP_PATH="$(manifest_get "$manifest_file" AppPath)" || return 1
  MANIFEST_PLIST_PATH="$(manifest_get "$manifest_file" PlistPath)" || return 1
  MANIFEST_LABEL="$(manifest_get "$manifest_file" RelayLabel)" || return 1
  MANIFEST_BUNDLE_ID="$(manifest_get "$manifest_file" BundleId)" || return 1
  MANIFEST_INSTALLED_BIN="$(manifest_get "$manifest_file" InstalledBinPath)" || return 1
  MANIFEST_INSTALLED_LIB="$(manifest_get "$manifest_file" InstalledLibPath)" || return 1
  MANIFEST_KEEP_CONFIG="$(manifest_get "$manifest_file" KeepConfigPath)" || return 1
  MANIFEST_KEEP_MITM="$(manifest_get "$manifest_file" KeepMitmPath)" || return 1
  MANIFEST_KEEP_LAUNCHER_LOG="$(manifest_get "$manifest_file" KeepLauncherLogPath)" || return 1
  MANIFEST_KEEP_RELAY_LOG="$(manifest_get "$manifest_file" KeepRelayLogPath)" || return 1
  MANIFEST_KEEP_RUNTIME_README="$(manifest_get "$manifest_file" KeepRuntimeReadmePath)" || return 1
  MANIFEST_MANIFEST="$(manifest_get "$manifest_file" InstalledManifestPath)" || return 1

  if [[ "$MANIFEST_FORMAT" != "codex-proxy-install" ]]; then
    log_error "manifest format mismatch: $MANIFEST_FORMAT"
    return 1
  fi
  if [[ "$MANIFEST_VERSION" != "1" ]]; then
    log_error "manifest version mismatch: $MANIFEST_VERSION"
    return 1
  fi
  if [[ "$MANIFEST_RUNTIME_HOME" != "$RUNTIME_HOME" ]]; then
    log_error "manifest runtime mismatch: $MANIFEST_RUNTIME_HOME"
    return 1
  fi
  if [[ "$MANIFEST_LABEL" != "$RELAY_LABEL" ]]; then
    log_error "manifest label mismatch: $MANIFEST_LABEL"
    return 1
  fi
  if [[ "$MANIFEST_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    log_error "manifest bundle mismatch: $MANIFEST_BUNDLE_ID"
    return 1
  fi
  if [[ "$MANIFEST_APP_PATH" != "$DEFAULT_APP_PATH" || "$MANIFEST_PLIST_PATH" != "$DEFAULT_PLIST_PATH" ]]; then
    log_error "manifest target identity mismatch."
    return 1
  fi
  if [[ "$MANIFEST_INSTALLED_BIN" != "$RUNTIME_HOME/bin" || "$MANIFEST_INSTALLED_LIB" != "$RUNTIME_HOME/lib" ]]; then
    log_error "manifest runtime payload identity mismatch."
    return 1
  fi
  if [[ "$MANIFEST_MANIFEST" != "$manifest_file" ]]; then
    log_error "manifest self-identity mismatch."
    return 1
  fi
  if [[ "$MANIFEST_KEEP_CONFIG" != "$RUNTIME_HOME/config" || "$MANIFEST_KEEP_MITM" != "$RUNTIME_HOME/mitmproxy" \
      || "$MANIFEST_KEEP_LAUNCHER_LOG" != "$RUNTIME_HOME/launcher.log" || "$MANIFEST_KEEP_RELAY_LOG" != "$RUNTIME_HOME/relay.log" \
      || "$MANIFEST_KEEP_RUNTIME_README" != "$RUNTIME_HOME/$EXPECTED_README_NAME" ]]; then
    log_error "manifest keep-path identity mismatch."
    return 1
  fi
  APP_PATH="$DEFAULT_APP_PATH"
  PLIST_PATH="$DEFAULT_PLIST_PATH"
  return 0
}

safe_remove() {
  local target="$1"

  if [[ ! -e "$target" ]]; then
    if [[ ! -L "$target" ]]; then
      return 0
    fi
  fi
  if [[ -L "$target" ]]; then
    log_error "refusing to remove symlink (including dangling): $target"
    return 1
  fi
  if [[ "$target" == "/" ]]; then
    log_error "refusing to remove root: $target"
    return 1
  fi
  if ! check_path_chain "$target" 1; then
    return 1
  fi
  if [[ -d "$target" ]]; then
    /bin/rm -rf -- "$target"
  else
    /bin/rm -f -- "$target"
  fi
  return 0
}

verify_app_bundle() {
  local bundle="$1"
  local bundle_id
  if [[ -L "$bundle" ]]; then
    log_error "app is symlink: $bundle"
    return 1
  fi
  if [[ ! -e "$bundle" ]]; then
    return 0
  fi
  if [[ ! -d "$bundle" ]]; then
    log_error "app bundle is missing: $bundle"
    return 1
  fi
  if [[ -L "$bundle/Contents" || -L "$bundle/Contents/Info.plist" || ! -f "$bundle/Contents/Info.plist" ]]; then
    log_error "app bundle metadata is unsafe or missing: $bundle"
    return 1
  fi
  bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "${bundle}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    log_error "app bundle-id mismatch: $bundle_id"
    return 1
  fi
  return 0
}

verify_plist_label() {
  local plist="$1"
  local label
  local relay_script
  local config_flag
  local config_path
  if [[ -L "$plist" ]]; then
    log_error "plist is symlink: $plist"
    return 1
  fi
  if [[ ! -e "$plist" ]]; then
    return 0
  fi
  if [[ ! -f "$plist" ]]; then
    log_error "launchd plist is not a regular file: $plist"
    return 1
  fi
  label="$(/usr/bin/plutil -extract Label raw "$plist" 2>/dev/null || true)"
  if [[ "$label" != "$RELAY_LABEL" ]]; then
    log_error "plist label mismatch: $label"
    return 1
  fi
  relay_script="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$plist" 2>/dev/null || true)"
  config_flag="$(/usr/bin/plutil -extract ProgramArguments.1 raw "$plist" 2>/dev/null || true)"
  config_path="$(/usr/bin/plutil -extract ProgramArguments.2 raw "$plist" 2>/dev/null || true)"
  if [[ "$relay_script" != "$RUNTIME_HOME/bin/relay.sh" || "$config_flag" != "--config" \
      || "$config_path" != "$RUNTIME_HOME/config/codex-proxy.conf" ]]; then
    log_error "plist program identity mismatch: $plist"
    return 1
  fi
  return 0
}

app_bundle_process_pids() {
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    /usr/bin/printf '%s\n' "$TEST_APP_PIDS" \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' \
      | /usr/bin/sort -un
    return 0
  fi
  if [[ ! -x /bin/ps ]]; then
    log_error "ps is unavailable; refusing to remove the app bundle."
    return 1
  fi
  /bin/ps -axo pid=,command= 2>/dev/null \
    | /usr/bin/awk -v prefix="$CURRENT_APP_PATH" '
      $1 ~ /^[0-9]+$/ {
        pid=$1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        if (index($0, prefix) == 1) print pid
      }
    ' \
    | /usr/bin/sort -un
}

check_app_bundle_not_running() {
  local process_output
  local -a process_pids

  if ! process_output="$(app_bundle_process_pids)"; then
    return 1
  fi
  if [[ -n "$process_output" ]]; then
    process_pids=("${(@f)process_output}")
  else
    process_pids=()
  fi
  if (( ${#process_pids[@]} > 0 )); then
    log_error "Codex Proxy.app is running (pid(s): ${(j:, :)process_pids}); refusing bundle removal."
    return 1
  fi
  return 0
}

chatgpt_bundle_process_pids() {
  local bundle_prefix="${CODEX_PROXY_CHATGPT_APP_PATH:h:h}/"
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    /usr/bin/printf '%s\n' "$TEST_CHATGPT_PIDS" \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' \
      | /usr/bin/sort -un
    return 0
  fi
  if [[ ! -x /bin/ps ]]; then
    log_error "ps is unavailable; refusing to remove an active proxy runtime."
    return 1
  fi
  /bin/ps -axo pid=,command= 2>/dev/null \
    | /usr/bin/awk -v prefix="$bundle_prefix" '
      $1 ~ /^[0-9]+$/ {
        pid=$1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        if (index($0, prefix) == 1) print pid
      }
    ' \
    | /usr/bin/sort -un
}

check_chatgpt_bundle_not_running() {
  local process_output
  local -a process_pids

  if ! process_output="$(chatgpt_bundle_process_pids)"; then
    return 1
  fi
  if [[ -n "$process_output" ]]; then
    process_pids=("${(@f)process_output}")
  else
    process_pids=()
  fi
  if (( ${#process_pids[@]} > 0 )); then
    log_error "ChatGPT/Codex is running (pid(s): ${(j:, :)process_pids}); quit it before uninstalling the proxy runtime."
    return 1
  fi
  return 0
}

load_runtime_listen_config() {
  local config_file="${RUNTIME_HOME}/config/codex-proxy.conf"

  if [[ -L "$config_file" || ! -f "$config_file" || ! -r "$config_file" ]]; then
    log_error "runtime config must be a readable regular file: $config_file"
    return 1
  fi
  if ! check_path_chain "$config_file" 1; then
    log_error "runtime config path is unsafe: $config_file"
    return 1
  fi
  CODEX_PROXY_HOME="$RUNTIME_HOME"
  if ! codex_proxy_load_config "$config_file"; then
    log_error "runtime config validation failed: $config_file"
    return 1
  fi
  LISTEN_HOST="$CODEX_PROXY_LISTEN_HOST"
  LISTEN_PORT="$CODEX_PROXY_LISTEN_PORT"
  if ! codex_proxy_validate_port "$LISTEN_PORT"; then
    return 1
  fi
  return 0
}

listener_pids_for_port() {
  local raw_lsof
  local lsof_rc

  if (( LIFECYCLE_TEST_MODE == 1 )); then
    /usr/bin/printf '%s\n' "$TEST_LISTENER_PIDS" \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' \
      | /usr/bin/sort -un
    return 0
  fi
  if [[ ! -x /usr/sbin/lsof ]]; then
    log_error "lsof is unavailable; refusing to infer listener ownership."
    return 1
  fi
  raw_lsof="$(/usr/sbin/lsof -nP -a -iTCP:"$LISTEN_PORT" -sTCP:LISTEN -Fp 2>/dev/null)"
  lsof_rc=$?
  # lsof returns 1 when no file descriptors match; that is a valid empty
  # listener set. Any other failure is unverifiable state and fails closed.
  if (( lsof_rc != 0 && lsof_rc != 1 )); then
    log_error "lsof failed while checking TCP listener ownership."
    return 1
  fi
  /usr/bin/printf '%s\n' "$raw_lsof" \
    | /usr/bin/awk '/^p[0-9]+$/ { sub(/^p/, ""); print }' \
    | /usr/bin/sort -un
}

query_launchd_job() {
  local launchd_output
  local launchd_result
  local launchd_rc

  LAUNCHD_JOB_LOADED=0
  LAUNCHD_JOB_PID=""
  LAUNCHD_JOB_PATH=""
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    case "$TEST_LAUNCHD_STATE" in
      absent)
        return 0
        ;;
      loaded)
        LAUNCHD_JOB_LOADED=1
        LAUNCHD_JOB_PID="$TEST_LAUNCHD_PID"
        LAUNCHD_JOB_PATH="${TEST_LAUNCHD_PATH:-$PLIST_PATH}"
        if [[ "$LAUNCHD_JOB_PATH" != "$PLIST_PATH" ]]; then
          log_error "managed launchd label points to an unexpected plist: $LAUNCHD_JOB_PATH"
          return 1
        fi
        return 0
        ;;
      loaded-no-pid)
        LAUNCHD_JOB_LOADED=1
        LAUNCHD_JOB_PATH="${TEST_LAUNCHD_PATH:-$PLIST_PATH}"
        if [[ "$LAUNCHD_JOB_PATH" != "$PLIST_PATH" ]]; then
          log_error "managed launchd label points to an unexpected plist: $LAUNCHD_JOB_PATH"
          return 1
        fi
        return 0
        ;;
      print-error|error)
        log_error "launchd query failed in lifecycle test hook."
        return 1
        ;;
      *)
        log_error "invalid lifecycle test launchd state: $TEST_LAUNCHD_STATE"
        return 1
        ;;
    esac
  fi
  if [[ ! -x /bin/launchctl ]]; then
    log_error "launchctl is unavailable; refusing to infer relay state."
    return 1
  fi
  launchd_result="$(/bin/launchctl print "gui/${CURRENT_UID}/${RELAY_LABEL}" 2>&1)"
  launchd_rc=$?
  if (( launchd_rc != 0 )); then
    if (( launchd_rc == 113 )) && [[ "$launchd_result" == *"Could not find service"* \
        && "$launchd_result" == *"in domain"* ]]; then
      return 0
    fi
    log_error "launchctl print failed while checking relay state: ${launchd_result:-<no diagnostic>}"
    return 1
  fi
  launchd_output="$launchd_result"
  LAUNCHD_JOB_LOADED=1
  LAUNCHD_JOB_PID="$(/usr/bin/printf '%s\n' "$launchd_output" \
    | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+[[:space:]]*$/ { print $3; exit }')"
  LAUNCHD_JOB_PATH="$(/usr/bin/printf '%s\n' "$launchd_output" \
    | /usr/bin/awk 'match($0, /^[[:space:]]*path = /) { print substr($0, RSTART + RLENGTH); exit }')"
  if [[ -z "$LAUNCHD_JOB_PATH" || "$LAUNCHD_JOB_PATH" != "$PLIST_PATH" ]]; then
    log_error "managed launchd label points to an unexpected plist: ${LAUNCHD_JOB_PATH:-<missing>}"
    return 1
  fi
  return 0
}

validate_listener_state() {
  local listener_output
  local -a listener_pids

  if ! query_launchd_job; then
    return 1
  fi
  if ! listener_output="$(listener_pids_for_port)"; then
    return 1
  fi
  if [[ -n "$listener_output" ]]; then
    listener_pids=("${(@f)listener_output}")
  else
    listener_pids=()
  fi
  if (( ${#listener_pids[@]} == 0 )); then
    return 0
  fi
  if (( LAUNCHD_JOB_LOADED == 0 )); then
    log_error "TCP listener(s) on ${LISTEN_HOST}:${LISTEN_PORT} exist without the managed launchd job: ${(j:, :)listener_pids}"
    return 1
  fi
  if [[ -z "$LAUNCHD_JOB_PID" || ${#listener_pids[@]} -ne 1 || "${listener_pids[1]}" != "$LAUNCHD_JOB_PID" ]]; then
    log_error "TCP listener ownership mismatch on ${LISTEN_HOST}:${LISTEN_PORT}; refusing lifecycle change."
    return 1
  fi
  return 0
}

wait_for_listener_clear() {
  local listener_output
  local attempt

  for attempt in {1..80}; do
    if ! listener_output="$(listener_pids_for_port)"; then
      return 1
    fi
    if [[ -z "$listener_output" ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done
  log_error "relay listener on ${LISTEN_HOST}:${LISTEN_PORT} did not disappear after bootout."
  return 1
}

bootout_job() {
  if ! query_launchd_job; then
    return 1
  fi
  if (( LAUNCHD_JOB_LOADED == 0 )); then
    return 0
  fi
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    case "$TEST_BOOTOUT_RESULT" in
      success)
        TEST_LAUNCHD_STATE="absent"
        TEST_LAUNCHD_PID=""
        TEST_LISTENER_PIDS=""
        return 0
        ;;
      partial-fail|fail)
        return 1
        ;;
      *)
        log_error "invalid lifecycle test bootout result: $TEST_BOOTOUT_RESULT"
        return 1
        ;;
    esac
  fi
  if ! /bin/launchctl bootout "gui/${CURRENT_UID}/${RELAY_LABEL}" >/dev/null 2>&1; then
    return 1
  fi
  if ! query_launchd_job; then
    return 1
  fi
  (( LAUNCHD_JOB_LOADED == 0 ))
}

cleanup_on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    release_install_lock
    if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
      /bin/rm -rf "$TMP_ROOT"
    fi
  fi
}
trap cleanup_on_exit EXIT

while (( $# > 0 )); do
  case "$1" in
    --home)
      require_value "$1" "${2:-}"
      RUNTIME_HOME="$2"
      shift 2
      ;;
    --purge-runtime)
      PURGE_RUNTIME=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "unsupported argument: $1"
      usage
      exit 64
      ;;
  esac
done

if (( PURGE_RUNTIME == 1 && ASSUME_YES != 1 )); then
  log_error "--purge-runtime requires --yes."
  exit 64
fi

RUNTIME_HOME="$(canonicalize_abs_path "$RUNTIME_HOME")" || exit 1
if ! check_existing_install_lock || ! check_existing_launch_lock; then
  exit 1
fi

TMP_ROOT="$(/usr/bin/mktemp -d /private/tmp/codex-proxy-uninstall.XXXXXX)" || {
  log_error "cannot create temporary workspace."
  exit 1
}

if [[ "$RUNTIME_HOME" == "/" ]]; then
  log_error "refusing root runtime."
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_path_chain "$RUNTIME_HOME" 1; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if [[ ! -d "$RUNTIME_HOME" ]]; then
  log_error "runtime home not found: $RUNTIME_HOME"
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if [[ -L "$RUNTIME_HOME" ]]; then
  log_error "runtime home cannot be symlink: $RUNTIME_HOME"
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

if [[ -L "${RUNTIME_HOME}/${MANIFEST_NAME}" || ! -f "${RUNTIME_HOME}/${MANIFEST_NAME}" ]]; then
  log_error "runtime manifest is required and must be a regular file."
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! validate_manifest; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
CURRENT_APP_PATH="$APP_PATH"
CURRENT_PLIST_PATH="$PLIST_PATH"
if [[ -L "$CURRENT_APP_PATH" || -L "$CURRENT_PLIST_PATH" ]]; then
  log_error "symlink target found in manifest data."
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_path_chain "$CURRENT_APP_PATH" 1; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_path_chain "$CURRENT_PLIST_PATH" 1; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if [[ "$CURRENT_APP_PATH" != "$DEFAULT_APP_PATH" ]]; then
  log_error "unexpected app path: $CURRENT_APP_PATH"
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if [[ "$CURRENT_PLIST_PATH" != "$DEFAULT_PLIST_PATH" ]]; then
  log_error "unexpected plist path: $CURRENT_PLIST_PATH"
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

if [[ -n "$MANIFEST_RUNTIME_HOME" && "$MANIFEST_RUNTIME_HOME" != "$RUNTIME_HOME" ]]; then
  log_error "manifest runtime mismatch: $MANIFEST_RUNTIME_HOME"
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

if ! verify_app_bundle "$CURRENT_APP_PATH" || ! verify_plist_label "$CURRENT_PLIST_PATH"; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_app_bundle_not_running; then
  log_error "app bundle process validation failed."
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! load_runtime_listen_config; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_chatgpt_bundle_not_running; then
  log_error "ChatGPT/Codex process validation failed."
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! validate_listener_state; then
  log_error "listener ownership validation failed."
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

if (( DRY_RUN == 1 )); then
  log_info "DRY-RUN: runtime=$RUNTIME_HOME"
  log_info "DRY-RUN: app=$CURRENT_APP_PATH"
  log_info "DRY-RUN: plist=$CURRENT_PLIST_PATH"
  if (( PURGE_RUNTIME == 1 )); then
    log_info "DRY-RUN: remove runtime home: $RUNTIME_HOME"
    log_info "DRY-RUN: remove app"
    log_info "DRY-RUN: remove plist"
  else
    log_info "DRY-RUN: remove ${RUNTIME_HOME}/bin"
    log_info "DRY-RUN: remove ${RUNTIME_HOME}/lib"
    log_info "DRY-RUN: remove ${RUNTIME_HOME}/${MANIFEST_NAME}"
    log_info "DRY-RUN: remove app"
    log_info "DRY-RUN: remove plist"
    log_info "DRY-RUN: keep ${RUNTIME_HOME}/config"
    log_info "DRY-RUN: keep ${RUNTIME_HOME}/mitmproxy"
    log_info "DRY-RUN: keep ${RUNTIME_HOME}/launcher.log"
    log_info "DRY-RUN: keep ${RUNTIME_HOME}/relay.log"
    log_info "DRY-RUN: keep ${RUNTIME_HOME}/${EXPECTED_README_NAME}"
  fi
  /bin/rm -rf "$TMP_ROOT"
  exit 0
fi

if ! acquire_install_lock; then
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

# The launcher refuses to proceed while this install lock exists.  Re-check
# its reciprocal lock after acquiring ours to close the check/mkdir race.
if ! check_existing_launch_lock; then
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! verify_app_bundle "$CURRENT_APP_PATH" || ! verify_plist_label "$CURRENT_PLIST_PATH"; then
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_app_bundle_not_running; then
  log_error "app bundle process validation failed after acquiring install lock."
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! check_chatgpt_bundle_not_running; then
  log_error "ChatGPT/Codex process validation failed after acquiring install lock."
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! validate_listener_state; then
  log_error "listener ownership validation failed after acquiring install lock."
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

if ! bootout_job; then
  log_error "failed to bootout launchd job."
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi
if ! wait_for_listener_clear; then
  log_error "listener remained active after launchd bootout; refusing to remove files."
  release_install_lock
  /bin/rm -rf "$TMP_ROOT"
  exit 1
fi

if (( PURGE_RUNTIME == 1 )); then
  if ! safe_remove "$CURRENT_PLIST_PATH"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
  if ! safe_remove "$CURRENT_APP_PATH"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
  if ! safe_remove "$RUNTIME_HOME"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
else
  if ! safe_remove "$RUNTIME_HOME/bin"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
  if ! safe_remove "$RUNTIME_HOME/lib"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
  if ! safe_remove "$CURRENT_APP_PATH"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
  if ! safe_remove "$CURRENT_PLIST_PATH"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
  # Keep the manifest until every other identity-checked target has been
  # removed, so a partial failure remains safely retryable.
  if ! safe_remove "${RUNTIME_HOME}/${MANIFEST_NAME}"; then
    release_install_lock
    /bin/rm -rf "$TMP_ROOT"
    exit 1
  fi
fi

release_install_lock
/bin/rm -rf "$TMP_ROOT"
if (( PURGE_RUNTIME == 1 )); then
  log_info "uninstall completed; runtime removed: $RUNTIME_HOME"
else
  log_info "uninstall completed; runtime scripts removed, config/ca/log kept."
fi
exit 0
