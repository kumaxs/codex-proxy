#!/bin/zsh

set -o pipefail
set -o nounset
umask 077

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly BUILD_SCRIPT="${SCRIPT_DIR}/build-app.sh"
readonly SOURCE_BIN="${PROJECT_ROOT}/bin"
readonly SOURCE_LIB="${PROJECT_ROOT}/lib"
readonly SOURCE_CONFIG="${PROJECT_ROOT}/config"
readonly SOURCE_JS="${PROJECT_ROOT}/app/Codex-Proxy.js"
readonly SOURCE_RUNTIME_README="${PROJECT_ROOT}/docs/RUNTIME.md"
readonly SOURCE_PLIST_TEMPLATE="${PROJECT_ROOT}/templates/io.github.kumaxs.codex-proxy-relay.plist.in"
readonly MANIFEST_NAME=".codex-proxy-manifest"
readonly RELAY_LABEL="io.github.kumaxs.codex-proxy-relay"
readonly RELAY_PLIST_NAME="${RELAY_LABEL}.plist"
readonly EXPECTED_BUNDLE_ID="io.github.kumaxs.codex-proxy"
readonly CURRENT_UID="$(/usr/bin/id -u)"
readonly INSTALL_LOCK_DIR="/private/tmp/com.github.kumaxs.codex-proxy-install-${CURRENT_UID}.lock"
readonly INSTALL_LOCK_FILE="${INSTALL_LOCK_DIR}/owner-pid"
readonly DEFAULT_RUNTIME_HOME="${HOME}/Library/Application Support/Codex Proxy"
readonly DEFAULT_APP_PATH="${HOME}/Applications/Codex Proxy.app"
readonly DEFAULT_PLIST_PATH="${HOME}/Library/LaunchAgents/${RELAY_PLIST_NAME}"
readonly DEFAULT_LISTEN_HOST="127.0.0.1"
readonly DEFAULT_LISTEN_PORT="29759"
readonly DEFAULT_CHATGPT_APP="/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
readonly LAUNCH_LOCK_DIR="/private/tmp/com.github.kumaxs.codex-proxy-launch-${CURRENT_UID}.lock"

# Lifecycle hooks are accepted only for isolated copies under /private/tmp;
# production invocations always query the real launchd/lsof state.
LIFECYCLE_TEST_MODE=0
TEST_LISTENER_PIDS=""
TEST_LAUNCHD_STATE="absent"
TEST_LAUNCHD_PID=""
TEST_LAUNCHD_PATH=""
TEST_BOOTOUT_RESULT="success"
TEST_BOOTSTRAP_RESULT="success"
TEST_APP_PIDS=""
TEST_CHATGPT_PIDS=""
TEST_HEALTH_RESULT="success"
if [[ "${CODEX_PROXY_LIFECYCLE_TEST_MODE:-0}" == "1" && "$SCRIPT_DIR" == /private/tmp/* ]]; then
  LIFECYCLE_TEST_MODE=1
  TEST_LISTENER_PIDS="${CODEX_PROXY_TEST_LISTENER_PIDS:-}"
  TEST_LAUNCHD_STATE="${CODEX_PROXY_TEST_LAUNCHD_STATE:-absent}"
  TEST_LAUNCHD_PID="${CODEX_PROXY_TEST_LAUNCHD_PID:-}"
  TEST_LAUNCHD_PATH="${CODEX_PROXY_TEST_LAUNCHD_PATH:-}"
  TEST_BOOTOUT_RESULT="${CODEX_PROXY_TEST_BOOTOUT_RESULT:-success}"
  TEST_BOOTSTRAP_RESULT="${CODEX_PROXY_TEST_BOOTSTRAP_RESULT:-success}"
  TEST_APP_PIDS="${CODEX_PROXY_TEST_APP_PIDS:-}"
  TEST_CHATGPT_PIDS="${CODEX_PROXY_TEST_CHATGPT_PIDS:-}"
  TEST_HEALTH_RESULT="${CODEX_PROXY_TEST_HEALTH_RESULT:-success}"
fi

source "${PROJECT_ROOT}/lib/config.sh"

UPSTREAM_URL=""
UPSTREAM_URL_SET=0
LISTEN_HOST="${DEFAULT_LISTEN_HOST}"
LISTEN_PORT="${DEFAULT_LISTEN_PORT}"
MITMDUMP_PATH=""
CHATGPT_APP_PATH="${DEFAULT_CHATGPT_APP}"
PASSTHROUGH='^(localhost|127\.0\.0\.1|::1)$'
RUNTIME_HOME="${DEFAULT_RUNTIME_HOME}"
APP_PATH="${DEFAULT_APP_PATH}"
PLIST_PATH="${DEFAULT_PLIST_PATH}"
START=0
DRY_RUN=0

TMP_ROOT=""
RUNTIME_BACKUP=""
APP_BACKUP=""
PLIST_BACKUP=""
BUNDLE_ID_USED=""
BUILD_STDOUT=""
BUILD_STDERR=""

RUNTIME_WAS_MOVED=0
APP_WAS_MOVED=0
PLIST_WAS_MOVED=0
OLD_PLIST_BACKUP=""
OLD_JOB_ACTIVE=0
OLD_JOB_BOOTED_OUT=0
OLD_JOB_PID=""
NEW_JOB_BOOTSTRAPPED=0
START_ATTEMPTED=0
INSTALL_LOCK_CREATED=0
INSTALL_LOCK_PATH=""
ABORTING=0
ROLLBACK_DONE=0
ROLLBACK_FAILED=0
RECOVERY_NOTICE_SHOWN=0
LAUNCHD_JOB_LOADED=0
LAUNCHD_JOB_PID=""
LAUNCHD_JOB_PATH=""

usage() {
  cat <<'EOF_USAGE'
Usage: install.sh --upstream-url URL --mitmdump PATH [--listen-host HOST] [--listen-port PORT] [--chatgpt-app-path PATH] [--passthrough REGEX] [--home DIR] [--start] [--no-start] [--dry-run]
  --upstream-url    required, must be http/https URL without userinfo
  --mitmdump        required, absolute executable path (symlinks are rejected)
  --listen-host     loopback host (default 127.0.0.1)
  --listen-port     relay port (default 29759)
  --chatgpt-app-path optional, default /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
  --passthrough     optional passthrough regex
  --home            reserved; must equal the HOME-derived default runtime root
  --start           bootstrap launchd job after install (opt-in)
  --no-start        keep launchd untouched (default)
  --dry-run         dry-run only
EOF_USAGE
}

log_info() {
  print -r -- "[INFO] $*"
}

log_error() {
  print -u2 -r -- "[ERROR] $*"
}

require_value() {
  local option="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == --* ]]; then
    log_error "${option} requires a value."
    exit 64
  fi
}

require_readable_file() {
  local target="$1"
  if [[ ! -r "$target" ]]; then
    log_error "missing readable file: $target"
    return 1
  fi
}

require_directory() {
  local target="$1"
  if [[ ! -d "$target" ]]; then
    log_error "missing directory: $target"
    return 1
  fi
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
      break
    fi
    cursor="${cursor:h}"
  done
  return 0
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
  local active_uid

  if [[ -L "$INSTALL_LOCK_DIR" || -e "$INSTALL_LOCK_DIR" ]]; then
    if [[ -L "$INSTALL_LOCK_DIR" ]]; then
      log_error "install lock path is a symlink; refusing to continue: $INSTALL_LOCK_DIR"
      return 1
    fi
    if [[ ! -d "$INSTALL_LOCK_DIR" ]] || ! check_path_chain "$INSTALL_LOCK_DIR" 1; then
      log_error "install lock path is unsafe; refusing to continue: $INSTALL_LOCK_DIR"
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
      lock_uid="${payload%% *}"
      lock_pid="${payload#* }"
      if /bin/ps -p "$lock_pid" >/dev/null 2>&1; then
        active_uid="$(/bin/ps -p "$lock_pid" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
        if [[ "$active_uid" == "$lock_uid" ]]; then
          log_error "install transaction is active (uid=${lock_uid}, pid=${lock_pid})"
          return 1
        fi
      fi
      log_error "install lock exists (stale or unverifiable); refusing to remove it: $INSTALL_LOCK_DIR"
    else
      log_error "install lock is missing a valid owner; refusing to remove it: $INSTALL_LOCK_DIR"
    fi
    return 1
  fi
  return 0
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
  log_error "launcher process is active (uid=${owner_uid}, pid=${owner}); refusing transaction."
  return 1
}

acquire_install_lock() {
  local tmp_file
  if ! check_existing_install_lock; then
    return 1
  fi

  if ! /bin/mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    log_error "failed to create install lock directory (another transaction may be racing)."
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

cleanup_tmp_root() {
  if [[ -z "$TMP_ROOT" || ! -d "$TMP_ROOT" ]]; then
    return 0
  fi
  if (( ROLLBACK_FAILED == 1 )); then
    write_recovery_notice
    if (( RECOVERY_NOTICE_SHOWN == 0 )); then
      log_error "rollback was incomplete; recovery data was retained at: $TMP_ROOT"
      RECOVERY_NOTICE_SHOWN=1
    fi
    return 0
  fi
  if ! /bin/rm -rf -- "${TMP_ROOT}"; then
    ROLLBACK_FAILED=1
    write_recovery_notice
    log_error "temporary workspace cleanup failed; inspect the retained path: $TMP_ROOT"
    return 1
  fi
  return 0
}

write_recovery_notice() {
  local notice_path
  [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || return 0
  notice_path="${TMP_ROOT}/RECOVERY-README.txt"
  if [[ -L "$notice_path" ]]; then
    log_error "cannot write recovery notice through a symlink: $notice_path"
    return 1
  fi
  /usr/bin/printf '%s\n' \
    'Codex Proxy installation recovery workspace' \
    '' \
    'This directory was intentionally retained because rollback or cleanup did not complete.' \
    'Do not execute files from it. Preserve it while comparing runtime-old, app-old, and plist-old' \
    'with the managed installation paths reported by the installer. Remove only after recovery is verified.' \
    > "$notice_path" || return 1
  /bin/chmod 600 "$notice_path" || return 1
  return 0
}

resolve_exec_path() {
  local input="$1"
  local candidate="$input"
  local hops=0
  local resolved
  local link

  if [[ "$input" != /* ]]; then
    log_error "mitmdump path must be absolute: $input"
    return 1
  fi
  if ! check_path_chain "${input:h}" 1; then
    log_error "insecure mitmdump parent path: ${input:h}"
    return 1
  fi

  while [[ -L "$candidate" ]]; do
    if (( ++hops > 16 )); then
      log_error "mitmdump symlink chain too long: $input"
      return 1
    fi
    if ! check_path_chain "$candidate" 1; then
      log_error "insecure mitmdump symlink path: $candidate"
      return 1
    fi
    link="$(/bin/readlink "$candidate" 2>/dev/null)" || {
      log_error "failed to resolve mitmdump symlink: $candidate"
      return 1
    }
    if [[ "$link" == /* ]]; then
      resolved="$link"
    else
      resolved="${candidate:h}/${link}"
    fi
    candidate="${resolved:A}"
  done

  if [[ ! -f "$candidate" ]]; then
    log_error "mitmdump not found: $candidate"
    return 1
  fi
  if [[ ! -x "$candidate" ]]; then
    log_error "mitmdump is not executable: $candidate"
    return 1
  fi
  if ! check_path_chain "$candidate" 1; then
    log_error "insecure mitmdump executable: $candidate"
    return 1
  fi
  print -r -- "$candidate"
}

json_escape() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//$'\n'/\\n}"
  raw="${raw//$'\r'/\\r}"
  raw="${raw//$'\t'/\\t}"
  print -r -- "$raw"
}

check_target_paths() {
  if [[ "$RUNTIME_HOME" == "/" || "$APP_PATH" == "/" || "$PLIST_PATH" == "/" ]]; then
    log_error "refusing root path."
    return 1
  fi
  if [[ "$RUNTIME_HOME" != /* || "$APP_PATH" != /* || "$PLIST_PATH" != /* ]]; then
    log_error "paths must be absolute."
    return 1
  fi
  if [[ -L "$RUNTIME_HOME" || -L "$APP_PATH" || -L "$PLIST_PATH" ]]; then
    log_error "paths may not be symlinks."
    return 1
  fi
  if ! check_path_chain "$RUNTIME_HOME" 1; then
    return 1
  fi
  if ! check_path_chain "${APP_PATH:h}" 1; then
    return 1
  fi
  if ! check_path_chain "${PLIST_PATH:h}" 1; then
    return 1
  fi
  return 0
}

validate_inputs() {
  local test_home="$1"
  local cfg_file="$2"

  if (( UPSTREAM_URL_SET != 1 )); then
    log_error "--upstream-url is required."
    return 1
  fi
  if ! codex_proxy_validate_http_url "$UPSTREAM_URL"; then
    return 1
  fi
  if ! codex_proxy_validate_listen_host "$LISTEN_HOST"; then
    return 1
  fi
  if ! codex_proxy_validate_port "$LISTEN_PORT"; then
    return 1
  fi
  if ! codex_proxy_validate_passthrough "$PASSTHROUGH"; then
    return 1
  fi
  if ! codex_proxy_validate_chatgpt_path "$CHATGPT_APP_PATH"; then
    return 1
  fi

  MITMDUMP_PATH="$(resolve_exec_path "$MITMDUMP_PATH")" || return 1

  if ! /bin/mkdir -p "${cfg_file:h}" ; then
    return 1
  fi
  if [[ -L "$cfg_file" ]]; then
    log_error "config path is symlink: $cfg_file"
    return 1
  fi
  if ! /usr/bin/printf 'UPSTREAM_PROXY_URL=%s\n' "$UPSTREAM_URL" > "$cfg_file"; then
    return 1
  fi
  if ! /usr/bin/printf 'LISTEN_HOST=%s\n' "$LISTEN_HOST" >> "$cfg_file"; then
    return 1
  fi
  if ! /usr/bin/printf 'LISTEN_PORT=%s\n' "$LISTEN_PORT" >> "$cfg_file"; then
    return 1
  fi
  if ! /usr/bin/printf 'MITMDUMP_PATH=%s\n' "$MITMDUMP_PATH" >> "$cfg_file"; then
    return 1
  fi
  if ! /usr/bin/printf 'CHATGPT_APP_PATH=%s\n' "$CHATGPT_APP_PATH" >> "$cfg_file"; then
    return 1
  fi
  if ! /usr/bin/printf 'PASSTHROUGH_REGEX=%s\n' "$PASSTHROUGH" >> "$cfg_file"; then
    return 1
  fi
  if ! /bin/cat "$cfg_file" >/dev/null 2>&1; then
    return 1
  fi

  CODEX_PROXY_HOME="$test_home"
  if ! codex_proxy_load_config "$cfg_file"; then
    return 1
  fi
  return 0
}

render_launchd_plist() {
  local output_file="$1"
  local runtime_home="$2"
  local cfg_file="$3"
  local relay_script="${runtime_home}/bin/relay.sh"
  local log_file="${runtime_home}/relay.log"
  local relay_script_escaped
  local cfg_file_escaped

  if ! /bin/cp -p "$SOURCE_PLIST_TEMPLATE" "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -lint "$output_file" >/dev/null 2>&1; then
    return 1
  fi
  if ! /usr/bin/plutil -replace Label -string "$RELAY_LABEL" "$output_file"; then
    return 1
  fi
  relay_script_escaped="$(json_escape "$relay_script")"
  cfg_file_escaped="$(json_escape "$cfg_file")"
  if ! /usr/bin/plutil -replace ProgramArguments -json "[\"${relay_script_escaped}\",\"--config\",\"${cfg_file_escaped}\"]" "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace RunAtLoad -bool true "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace KeepAlive -bool true "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace ProcessType -string Background "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace Umask -integer 63 "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace ThrottleInterval -integer 5 "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace StandardOutPath -string "$log_file" "$output_file"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace StandardErrorPath -string "$log_file" "$output_file"; then
    return 1
  fi
  return 0
}

write_manifest() {
  local target="$1"
  local runtime_home="$2"

  if ! /usr/bin/plutil -create xml1 "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace ManifestFormat -string codex-proxy-install "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace ManifestVersion -integer 1 "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace RuntimeHome -string "$runtime_home" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace AppPath -string "$APP_PATH" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace PlistPath -string "$PLIST_PATH" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace RelayLabel -string "$RELAY_LABEL" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace BundleId -string "$EXPECTED_BUNDLE_ID" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace InstalledBinPath -string "${runtime_home}/bin" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace InstalledLibPath -string "${runtime_home}/lib" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace InstalledManifestPath -string "${runtime_home}/${MANIFEST_NAME}" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace KeepConfigPath -string "${runtime_home}/config" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace KeepMitmPath -string "${runtime_home}/mitmproxy" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace KeepLauncherLogPath -string "${runtime_home}/launcher.log" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace KeepRelayLogPath -string "${runtime_home}/relay.log" "$target"; then
    return 1
  fi
  if ! /usr/bin/plutil -replace KeepRuntimeReadmePath -string "${runtime_home}/RUNTIME.md" "$target"; then
    return 1
  fi
  return 0
}

set_runtime_permissions() {
  local runtime_home="$1"
  local item
  if ! /bin/chmod 700 "$runtime_home" "$runtime_home/bin" "$runtime_home/lib" "$runtime_home/config"; then
    return 1
  fi
  if [[ -d "$runtime_home/mitmproxy" ]] && ! /bin/chmod 700 "$runtime_home/mitmproxy"; then
    return 1
  fi
  if ! /bin/chmod 600 "$runtime_home/$MANIFEST_NAME" "$runtime_home/config/codex-proxy.conf" "$runtime_home/RUNTIME.md"; then
    return 1
  fi
  if [[ -f "$runtime_home/launcher.log" ]] && ! /bin/chmod 600 "$runtime_home/launcher.log"; then
    return 1
  fi
  if [[ -f "$runtime_home/relay.log" ]] && ! /bin/chmod 600 "$runtime_home/relay.log"; then
    return 1
  fi
  for item in "$runtime_home/launcher.log.1" "$runtime_home/launcher.log.2" \
      "$runtime_home/launcher.log.3" "$runtime_home/launcher.log.4" "$runtime_home/launcher.log.5"; do
    if [[ -f "$item" ]] && ! /bin/chmod 600 "$item"; then
      return 1
    fi
  done
  return 0
}

preserve_runtime_state() {
  local old_runtime="$1"
  local staged_runtime="$2"
  local item
  local nested_link
  local persistent_dir
  local -a persistent_logs

  [[ -d "$old_runtime" ]] || return 0

  persistent_logs=(
    "$old_runtime/launcher.log"
    "$old_runtime/launcher.log.1"
    "$old_runtime/launcher.log.2"
    "$old_runtime/launcher.log.3"
    "$old_runtime/launcher.log.4"
    "$old_runtime/launcher.log.5"
    "$old_runtime/relay.log"
  )

  for persistent_dir in "$old_runtime/config" "$old_runtime/mitmproxy"; do
    if [[ -L "$persistent_dir" ]]; then
      log_error "existing runtime persistent directory is a symlink: $persistent_dir"
      return 1
    fi
    if [[ -e "$persistent_dir" && ! -d "$persistent_dir" ]]; then
      log_error "existing runtime persistent path is not a directory: $persistent_dir"
      return 1
    fi
    if [[ -d "$persistent_dir" ]]; then
      nested_link="$(/usr/bin/find -P "$persistent_dir" -type l -print -quit 2>/dev/null)" || {
        log_error "unable to inspect persistent directory: $persistent_dir"
        return 1
      }
      if [[ -n "$nested_link" ]]; then
        log_error "existing runtime persistent state contains a symlink: $nested_link"
        return 1
      fi
    fi
  done

  for item in "${persistent_logs[@]}"; do
    if [[ -L "$item" ]]; then
      log_error "existing runtime persistent log is a symlink: $item"
      return 1
    fi
    if [[ -e "$item" && ! -f "$item" ]]; then
      log_error "existing runtime persistent log is not a regular file: $item"
      return 1
    fi
  done

  if [[ -d "$old_runtime/config" ]]; then
    if ! /bin/cp -pR "$old_runtime/config/." "$staged_runtime/config/"; then
      return 1
    fi
  fi
  if [[ -d "$old_runtime/mitmproxy" ]]; then
    if ! /bin/cp -pR "$old_runtime/mitmproxy" "$staged_runtime/"; then
      return 1
    fi
  fi
  for item in "${persistent_logs[@]}"; do
    if [[ -f "$item" ]] && ! /bin/cp -p "$item" "$staged_runtime/${item:t}"; then
      return 1
    fi
  done
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

app_bundle_process_pids() {
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    /usr/bin/printf '%s\n' "$TEST_APP_PIDS" \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' \
      | /usr/bin/sort -un
    return 0
  fi
  if [[ ! -x /bin/ps ]]; then
    log_error "ps is unavailable; refusing to replace the app bundle."
    return 1
  fi
  /bin/ps -axo pid=,command= 2>/dev/null \
    | /usr/bin/awk -v prefix="$APP_PATH" '
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
    log_error "Codex Proxy.app is running (pid(s): ${(j:, :)process_pids}); refusing bundle replacement."
    return 1
  fi
  return 0
}

chatgpt_bundle_process_pids() {
  local bundle_prefix="${CHATGPT_APP_PATH:h:h}/"
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    /usr/bin/printf '%s\n' "$TEST_CHATGPT_PIDS" \
      | /usr/bin/tr ',' '\n' \
      | /usr/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i }' \
      | /usr/bin/sort -un
    return 0
  fi
  if [[ ! -x /bin/ps ]]; then
    log_error "ps is unavailable; refusing to change proxy lifecycle state."
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
    log_error "ChatGPT/Codex is running (pid(s): ${(j:, :)process_pids}); quit it before changing proxy lifecycle state."
    return 1
  fi
  return 0
}

run_http_health_check() {
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    [[ "$TEST_HEALTH_RESULT" == "success" ]]
    return $?
  fi
  if [[ ! -x "${RUNTIME_HOME}/bin/proxy-health.sh" ]]; then
    log_error "runtime HTTP health checker is missing or not executable."
    return 1
  fi
  /bin/zsh "${RUNTIME_HOME}/bin/proxy-health.sh" \
    --config "${RUNTIME_HOME}/config/codex-proxy.conf" --http-only >/dev/null 2>&1
}

wait_for_started_relay() {
  local listener_output
  local -a listener_pids
  local attempt

  for attempt in {1..80}; do
    if ! listener_output="$(listener_pids_for_port)"; then
      return 1
    fi
    if [[ -n "$listener_output" ]]; then
      listener_pids=("${(@f)listener_output}")
    else
      listener_pids=()
    fi
    if (( ${#listener_pids[@]} == 1 )) && validate_listener_state; then
      if run_http_health_check; then
        return 0
      fi
      return 1
    fi
    /bin/sleep 0.1
  done
  log_error "managed relay did not expose a uniquely owned listener in time."
  return 1
}

old_job_active() {
  query_launchd_job || return 1
  (( LAUNCHD_JOB_LOADED == 1 ))
}

bootout_job() {
  local job_loaded

  if ! query_launchd_job; then
    return 1
  fi
  job_loaded="$LAUNCHD_JOB_LOADED"
  if (( job_loaded == 0 )); then
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
      partial-fail)
        return 1
        ;;
      fail)
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

bootstrap_job() {
  if (( LIFECYCLE_TEST_MODE == 1 )); then
    case "$TEST_BOOTSTRAP_RESULT" in
      success)
        TEST_LAUNCHD_STATE="loaded"
        TEST_LAUNCHD_PID="${CODEX_PROXY_TEST_NEW_JOB_PID:-99999}"
        TEST_LISTENER_PIDS="$TEST_LAUNCHD_PID"
        return 0
        ;;
      partial-fail)
        TEST_LAUNCHD_STATE="loaded"
        TEST_LAUNCHD_PID="${CODEX_PROXY_TEST_NEW_JOB_PID:-99999}"
        TEST_LISTENER_PIDS="$TEST_LAUNCHD_PID"
        return 1
        ;;
      fail)
        return 1
        ;;
      *)
        log_error "invalid lifecycle test bootstrap result: $TEST_BOOTSTRAP_RESULT"
        return 1
        ;;
    esac
  fi
  if ! /bin/launchctl bootstrap "gui/${CURRENT_UID}" "$PLIST_PATH" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

backup_target() {
  local target="$1"
  local backup="$2"
  if [[ ! -e "$target" ]]; then
    return 0
  fi
  if [[ -L "$target" ]]; then
    log_error "refusing to back up symlink: $target"
    return 1
  fi
  if ! check_path_chain "$target" 1; then
    log_error "refusing to back up unsafe path: $target"
    return 1
  fi
  if ! /bin/mv "$target" "$backup"; then
    return 1
  fi
  return 0
}

rollback_install() {
  local rollback_rc=0
  local target

  if (( ROLLBACK_DONE == 1 )); then
    return 0
  fi
  ROLLBACK_DONE=1
  # Rollback status is deliberately independent from the business failure
  # status supplied by the caller. Files are restored before launchd state.
  # Mark the transaction aborting so the EXIT trap cannot invoke rollback a
  # second time after an explicit failure-path rollback.
  ABORTING=1
  if (( NEW_JOB_BOOTSTRAPPED == 1 )); then
    if ! bootout_job >/dev/null 2>&1; then
      log_error "failed to remove newly bootstrapped launchd job."
      rollback_rc=1
    fi
    NEW_JOB_BOOTSTRAPPED=0
  fi

  for target in "$APP_PATH" "$PLIST_PATH" "$RUNTIME_HOME"; do
    case "$target" in
      "$APP_PATH") (( APP_WAS_MOVED == 1 )) || continue ;;
      "$PLIST_PATH") (( PLIST_WAS_MOVED == 1 )) || continue ;;
      "$RUNTIME_HOME") (( RUNTIME_WAS_MOVED == 1 )) || continue ;;
    esac
    if [[ -L "$target" ]]; then
      if ! /bin/rm -f -- "$target"; then rollback_rc=1; fi
    elif [[ -d "$target" ]]; then
      if ! /bin/rm -rf -- "$target"; then rollback_rc=1; fi
    elif [[ -e "$target" ]]; then
      if ! /bin/rm -f -- "$target"; then rollback_rc=1; fi
    fi
  done

  if [[ -n "$RUNTIME_BACKUP" && -d "$RUNTIME_BACKUP" ]]; then
    if ! /bin/mv -f "$RUNTIME_BACKUP" "$RUNTIME_HOME"; then
      rollback_rc=1
    else
      RUNTIME_BACKUP=""
    fi
  fi
  if [[ -n "$APP_BACKUP" && -d "$APP_BACKUP" ]]; then
    if ! /bin/mv -f "$APP_BACKUP" "$APP_PATH"; then
      rollback_rc=1
    else
      APP_BACKUP=""
    fi
  fi
  if [[ -n "$PLIST_BACKUP" && -f "$PLIST_BACKUP" ]]; then
    if ! /bin/mv -f "$PLIST_BACKUP" "$PLIST_PATH"; then
      rollback_rc=1
    else
      PLIST_BACKUP=""
    fi
  fi

  if (( OLD_JOB_BOOTED_OUT == 1 )); then
    if ! query_launchd_job; then
      log_error "unable to query launchd while restoring old job."
      rollback_rc=1
    elif (( LAUNCHD_JOB_LOADED == 1 )); then
      log_error "old relay label remains loaded; refusing duplicate bootstrap during rollback."
      rollback_rc=1
    elif [[ ! -f "$PLIST_PATH" ]] || ! bootstrap_job; then
      log_error "failed to restore old launchd job state."
      rollback_rc=1
    elif ! query_launchd_job || (( LAUNCHD_JOB_LOADED == 0 )); then
      log_error "old relay job did not become loaded during rollback."
      rollback_rc=1
    else
      OLD_JOB_BOOTED_OUT=0
    fi
  fi

  if (( rollback_rc != 0 )); then
    ROLLBACK_FAILED=1
  fi

  return "$rollback_rc"
}

handle_signal() {
  local rc="$1"
  ABORTING=1
  if ! rollback_install "$rc"; then
    log_error "rollback failed after signal."
    rc=1
  fi
  release_install_lock
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    cleanup_tmp_root
  fi
  exit "$rc"
}

cleanup_on_exit() {
  local rc=$?
  if (( ABORTING == 1 )); then
    return
  fi
  if (( rc != 0 )); then
    if ! rollback_install "$rc"; then
      log_error "rollback failed."
      rc=1
    fi
  fi
  release_install_lock
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    cleanup_tmp_root
  fi
  return "$rc"
}

trap 'handle_signal 130' INT
trap 'handle_signal 129' HUP
trap 'handle_signal 143' TERM
trap cleanup_on_exit EXIT

while (( $# > 0 )); do
  case "$1" in
    --upstream-url)
      require_value "$1" "${2:-}"
      UPSTREAM_URL="$2"
      UPSTREAM_URL_SET=1
      shift 2
      ;;
    --mitmdump)
      require_value "$1" "${2:-}"
      MITMDUMP_PATH="$2"
      shift 2
      ;;
    --listen-host)
      require_value "$1" "${2:-}"
      LISTEN_HOST="$2"
      shift 2
      ;;
    --listen-port)
      require_value "$1" "${2:-}"
      LISTEN_PORT="$2"
      shift 2
      ;;
    --chatgpt-app-path)
      require_value "$1" "${2:-}"
      CHATGPT_APP_PATH="$2"
      shift 2
      ;;
    --passthrough)
      require_value "$1" "${2:-}"
      PASSTHROUGH="$2"
      shift 2
      ;;
    --home)
      require_value "$1" "${2:-}"
      RUNTIME_HOME="$2"
      shift 2
      ;;
    --start)
      START=1
      shift
      ;;
    --no-start)
      START=0
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

if (( UPSTREAM_URL_SET != 1 )); then
  log_error "--upstream-url is required."
  usage
  exit 64
fi

if [[ -z "$MITMDUMP_PATH" ]]; then
  log_error "--mitmdump is required."
  usage
  exit 64
fi

RUNTIME_HOME="$(canonicalize_abs_path "$RUNTIME_HOME")" || exit 1
APP_PATH="$(canonicalize_abs_path "$APP_PATH")" || exit 1
PLIST_PATH="$(canonicalize_abs_path "$PLIST_PATH")" || exit 1

if [[ "$RUNTIME_HOME" != "$DEFAULT_RUNTIME_HOME" ]]; then
  log_error "custom runtime homes are unsupported by the dynamic launcher; use the HOME-derived default."
  exit 64
fi

if ! require_readable_file "$BUILD_SCRIPT" \
  || ! require_readable_file "$SOURCE_JS" \
  || ! require_readable_file "$SOURCE_RUNTIME_README" \
  || ! require_readable_file "$SOURCE_PLIST_TEMPLATE" \
  || ! require_directory "$SOURCE_BIN" \
  || ! require_directory "$SOURCE_LIB" \
  || ! require_directory "$SOURCE_CONFIG"; then
  exit 1
fi

if ! check_target_paths; then
  exit 1
fi

# Refuse to replace a bundle that is currently executing.  This check is
# intentionally performed before any transaction workspace or lock is
# created; a ps failure is not evidence of safety and therefore fails closed.
if ! check_app_bundle_not_running; then
  log_error "app bundle process validation failed."
  exit 1
fi
if ! check_chatgpt_bundle_not_running; then
  log_error "ChatGPT/Codex process validation failed."
  exit 1
fi

# A dry-run is read-only, but it must still fail closed when another lifecycle
# transaction or launcher is active.  Do not create or remove either lock here.
if ! check_existing_install_lock || ! check_existing_launch_lock; then
  exit 1
fi

TMP_ROOT="$(/usr/bin/mktemp -d /private/tmp/codex-proxy-install.XXXXXX)" || {
  log_error "cannot create temporary workspace."
  exit 1
}
BUILD_STDOUT="${TMP_ROOT}/build.stdout"
BUILD_STDERR="${TMP_ROOT}/build.stderr"

if ! /bin/mkdir -p "${TMP_ROOT}/validate/config"; then
  log_error "cannot create validation temp directory."
  cleanup_tmp_root
  exit 1
fi

TMP_VALIDATE_HOME="${TMP_ROOT}/validate/home"
TMP_VALIDATE_CFG="${TMP_ROOT}/validate/config/codex-proxy.conf"
if ! /bin/mkdir -p "$TMP_VALIDATE_HOME"; then
  log_error "cannot create validation runtime directory."
  cleanup_tmp_root
  exit 1
fi

if ! validate_inputs "$TMP_VALIDATE_HOME" "$TMP_VALIDATE_CFG"; then
  log_error "configuration validation failed."
  cleanup_tmp_root
  exit 1
fi
if ! validate_listener_state; then
  log_error "listener ownership validation failed."
  cleanup_tmp_root
  exit 1
fi

if (( DRY_RUN == 1 )); then
  log_info "DRY-RUN: runtime-home=$RUNTIME_HOME"
  log_info "DRY-RUN: app=$APP_PATH"
  log_info "DRY-RUN: plist=$PLIST_PATH"
  log_info "DRY-RUN: start=$START"
  log_info "DRY-RUN: mitmdump=$MITMDUMP_PATH"
  cleanup_tmp_root
  exit 0
fi

if ! acquire_install_lock; then
  log_error "cannot acquire install lock."
  cleanup_tmp_root
  exit 1
fi

# The launcher refuses to start while this install lock exists.  Re-check the
# reciprocal launcher lock after acquiring ours to close the check/mkdir race.
if ! check_existing_launch_lock; then
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! validate_listener_state; then
  log_error "listener ownership validation failed after acquiring install lock."
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! check_app_bundle_not_running; then
  log_error "app bundle process validation failed after acquiring install lock."
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! check_chatgpt_bundle_not_running; then
  log_error "ChatGPT/Codex process validation failed after acquiring install lock."
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if ! /bin/mkdir -p "${RUNTIME_HOME:h}" "${APP_PATH:h}" "${PLIST_PATH:h}"; then
  log_error "failed to create parent directories."
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

RUNTIME_BACKUP="${TMP_ROOT}/runtime-old"
APP_BACKUP="${TMP_ROOT}/app-old"
PLIST_BACKUP="${TMP_ROOT}/plist-old"

# Replacing a plist while its relay is loaded would leave the old process
# running against an untracked file. Require --start so the transaction can
# bootout/bootstrap atomically; the default no-start mode is fail-closed.
if old_job_active; then
  OLD_JOB_ACTIVE=1
  OLD_JOB_PID="$LAUNCHD_JOB_PID"
  if (( START == 0 )); then
    log_error "relay launchd job is already loaded; rerun with --start to replace it safely."
    release_install_lock
    cleanup_tmp_root
    exit 1
  fi
fi

if ! backup_target "$RUNTIME_HOME" "$RUNTIME_BACKUP"; then
  log_error "unable to back up existing runtime."
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! backup_target "$APP_PATH" "$APP_BACKUP"; then
  log_error "unable to back up existing app."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! backup_target "$PLIST_PATH" "$PLIST_BACKUP"; then
  log_error "unable to back up existing launchd plist."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if [[ -f "$PLIST_BACKUP" || -d "$PLIST_BACKUP" ]]; then
  OLD_PLIST_BACKUP="$PLIST_BACKUP"
fi
if (( OLD_JOB_ACTIVE == 1 )); then
  if [[ -z "$OLD_PLIST_BACKUP" || ! -f "$OLD_PLIST_BACKUP" ]]; then
    log_error "active launchd job has no restorable plist; refusing --start transaction."
    rollback_install 1
    release_install_lock
    cleanup_tmp_root
    exit 1
  fi
fi

STAGE_RUNTIME="${TMP_ROOT}/runtime"
STAGE_APP="${TMP_ROOT}/Codex Proxy.app"
STAGE_PLIST="${TMP_ROOT}/${RELAY_PLIST_NAME}"
STAGE_CFG="${STAGE_RUNTIME}/config/codex-proxy.conf"
STAGE_MANIFEST="${STAGE_RUNTIME}/${MANIFEST_NAME}"
STAGE_RUNTIME_README="${STAGE_RUNTIME}/RUNTIME.md"

if ! /bin/mkdir -p "${STAGE_RUNTIME}/bin" "${STAGE_RUNTIME}/lib" "${STAGE_RUNTIME}/config"; then
  log_error "unable to create stage directories."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if ! /bin/cp -pR "$SOURCE_BIN/." "$STAGE_RUNTIME/bin/"; then
  log_error "copying bin failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/cp -pR "$SOURCE_LIB/." "$STAGE_RUNTIME/lib/"; then
  log_error "copying lib failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/cp -pR "$SOURCE_CONFIG/." "$STAGE_RUNTIME/config/"; then
  log_error "copying config failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! preserve_runtime_state "$RUNTIME_BACKUP" "$STAGE_RUNTIME"; then
  log_error "preserving runtime persistent state failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/cp -p "$SOURCE_RUNTIME_README" "$STAGE_RUNTIME_README"; then
  log_error "copying runtime README failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if ! /bin/mkdir -p "${STAGE_CFG:h}"; then
  log_error "cannot create staged config directory."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/printf 'UPSTREAM_PROXY_URL=%s\n' "$UPSTREAM_URL" > "$STAGE_CFG"; then
  log_error "failed to write staged config."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/printf 'LISTEN_HOST=%s\n' "$LISTEN_HOST" >> "$STAGE_CFG"; then
  log_error "failed to write staged config."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/printf 'LISTEN_PORT=%s\n' "$LISTEN_PORT" >> "$STAGE_CFG"; then
  log_error "failed to write staged config."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/printf 'MITMDUMP_PATH=%s\n' "$MITMDUMP_PATH" >> "$STAGE_CFG"; then
  log_error "failed to write staged config."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/printf 'CHATGPT_APP_PATH=%s\n' "$CHATGPT_APP_PATH" >> "$STAGE_CFG"; then
  log_error "failed to write staged config."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/printf 'PASSTHROUGH_REGEX=%s\n' "$PASSTHROUGH" >> "$STAGE_CFG"; then
  log_error "failed to write staged config."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if ! render_launchd_plist "$STAGE_PLIST" "$RUNTIME_HOME" "${RUNTIME_HOME}/config/codex-proxy.conf"; then
  log_error "rendering launchd plist failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/chmod 600 "$STAGE_PLIST"; then
  log_error "plis permission setup failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if ! /bin/zsh "$BUILD_SCRIPT" --script "$SOURCE_JS" --output-dir "$TMP_ROOT" --name "Codex Proxy" --bundle-id "$EXPECTED_BUNDLE_ID" > "$BUILD_STDOUT" 2> "$BUILD_STDERR"; then
  if [[ -s "$BUILD_STDERR" ]]; then
    /bin/cat "$BUILD_STDERR" >&2
  fi
  log_error "build-app failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /usr/bin/awk '/^Bundle-id: /{print $2}' "$BUILD_STDOUT" | /usr/bin/tail -n 1 > "${TMP_ROOT}/build.bundle"; then
  log_error "failed to parse build output."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
BUNDLE_ID_USED="$(/bin/cat "${TMP_ROOT}/build.bundle" 2>/dev/null)" || true
if [[ -z "$BUNDLE_ID_USED" ]]; then
  log_error "missing bundle id from build."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if [[ "$BUNDLE_ID_USED" != "$EXPECTED_BUNDLE_ID" ]]; then
  log_error "bundle id mismatch: $BUNDLE_ID_USED"
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! write_manifest "$STAGE_MANIFEST" "$RUNTIME_HOME"; then
  log_error "writing manifest failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/chmod 700 "$STAGE_RUNTIME/bin" "$STAGE_RUNTIME/lib" "$STAGE_RUNTIME/config"; then
  log_error "staged runtime permission setup failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/chmod 600 "$STAGE_MANIFEST" "$STAGE_CFG" "$STAGE_RUNTIME_README"; then
  log_error "staged manifest/config permission setup failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if ! /bin/mv "$STAGE_RUNTIME" "$RUNTIME_HOME"; then
  log_error "moving runtime failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
RUNTIME_WAS_MOVED=1

if ! /bin/mv "$TMP_ROOT/Codex Proxy.app" "$APP_PATH"; then
  log_error "moving app bundle failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
APP_WAS_MOVED=1

if ! /bin/mv "$STAGE_PLIST" "$PLIST_PATH"; then
  log_error "moving launchd plist failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
PLIST_WAS_MOVED=1

if ! set_runtime_permissions "$RUNTIME_HOME"; then
  log_error "setting runtime permissions failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi
if ! /bin/chmod 600 "$PLIST_PATH"; then
  log_error "launchd plist permission setup failed."
  rollback_install 1
  release_install_lock
  cleanup_tmp_root
  exit 1
fi

if (( START == 1 )); then
  START_ATTEMPTED=1
  if (( OLD_JOB_ACTIVE == 1 )); then
    # Mark restoration required before invoking launchctl: a failed bootout
    # may have partially changed state and rollback must inspect it safely.
    OLD_JOB_BOOTED_OUT=1
    if ! bootout_job; then
      log_error "failed to stop old launchd job."
      rollback_install 1
      release_install_lock
      cleanup_tmp_root
      exit 1
    fi
  fi
  # Mark before bootstrap: launchctl can partially load a job and still
  # return failure. Rollback must best-effort bootout that label as well.
  NEW_JOB_BOOTSTRAPPED=1
  if ! bootstrap_job; then
    log_error "launchctl bootstrap failed."
    rollback_install 1
    release_install_lock
    cleanup_tmp_root
    exit 1
  fi
  if ! wait_for_started_relay; then
    log_error "started relay listener/HTTP health verification failed."
    rollback_install 1
    release_install_lock
    cleanup_tmp_root
    exit 1
  fi
fi

/bin/rm -rf "$RUNTIME_BACKUP" "$APP_BACKUP" "$PLIST_BACKUP"
RUNTIME_BACKUP=""
APP_BACKUP=""
PLIST_BACKUP=""

if (( OLD_JOB_ACTIVE == 1 )) && [[ -n "$OLD_PLIST_BACKUP" && -f "$OLD_PLIST_BACKUP" ]]; then
  /bin/rm -f -- "$OLD_PLIST_BACKUP"
  OLD_PLIST_BACKUP=""
fi

# Commit point: no subsequent EXIT/signal cleanup may roll back the installed
# files or a successfully bootstrapped job.
NEW_JOB_BOOTSTRAPPED=0
OLD_JOB_BOOTED_OUT=0
ROLLBACK_DONE=1
release_install_lock
if (( START == 0 )); then
  log_info "install completed (runtime, app, plist installed; launchd untouched)."
else
  log_info "install completed (launchd started)."
fi
log_info "runtime-home: $RUNTIME_HOME"
log_info "app-path: $APP_PATH"
log_info "plist-path: $PLIST_PATH"
log_info "bundle-id: $BUNDLE_ID_USED"
exit 0
