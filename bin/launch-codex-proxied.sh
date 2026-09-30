#!/bin/zsh

set -u
set -o pipefail
setopt nullglob
umask 077

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../lib/config.sh"

# Test mode is intentionally only accepted for copies under /private/tmp.
readonly SELF_PATH="${0:A}"
if [[ "${CODEX_PROXY_LAUNCHER_TEST_MODE:-0}" == "1" ]]; then
  if [[ "$SELF_PATH" != /private/tmp/* ]]; then
    print -u2 "[ERROR] test mode is refused outside /private/tmp"
    exit 64
  fi
  readonly TEST_MODE=1
  readonly TEST_PROCESS_TABLE="${CODEX_PROXY_TEST_PROCESS_TABLE:-}"
  readonly TEST_SOCKET_TABLE="${CODEX_PROXY_TEST_SOCKET_TABLE:-}"
  readonly TEST_DRY_RUN="${CODEX_PROXY_TEST_DRY_RUN:-0}"
  readonly TEST_TERM_LOG="${CODEX_PROXY_TEST_TERM_LOG:-/private/tmp/codex-proxy-test-term.log}"
  readonly TEST_LOCK_OWNER_STATE="${CODEX_PROXY_TEST_LOCK_OWNER_STATE:-auto}"
  readonly LAUNCH_LOCK_DIR="${CODEX_PROXY_TEST_LOCK_DIR:-/private/tmp/com.github.kumaxs.codex-proxy-launch-test-$(/usr/bin/id -u).lock}"
else
  readonly TEST_MODE=0
  readonly TEST_PROCESS_TABLE=""
  readonly TEST_SOCKET_TABLE=""
  readonly TEST_DRY_RUN=0
  readonly TEST_TERM_LOG=""
  readonly TEST_LOCK_OWNER_STATE="live"
  readonly LAUNCH_LOCK_DIR="/private/tmp/com.github.kumaxs.codex-proxy-launch-$(/usr/bin/id -u).lock"
fi
readonly INSTALL_TRANSACTION_LOCK="/private/tmp/com.github.kumaxs.codex-proxy-install-$(/usr/bin/id -u).lock"

readonly SOCKET_SAMPLE_ROUNDS=8
readonly SOCKET_SAMPLE_SLEEP_SECONDS="0.5"
readonly NO_PROXY_VALUE="localhost,127.0.0.1,::1"
typeset -a REQUIRED_ENVS=()
readonly -a FORBIDDEN_PROXY_ENVS=(
  ALL_PROXY all_proxy
  FTP_PROXY ftp_proxy
  SOCKS_PROXY socks_proxy
  WS_PROXY ws_proxy
  WSS_PROXY wss_proxy
  GIT_PROXY_COMMAND GIT_HTTP_PROXY GIT_HTTPS_PROXY
  npm_config_proxy npm_config_https_proxy
)
readonly -a CLEAR_PROXY_ENV_ARGS=(
  -u ALL_PROXY -u all_proxy
  -u FTP_PROXY -u ftp_proxy
  -u SOCKS_PROXY -u socks_proxy
  -u WS_PROXY -u ws_proxy
  -u WSS_PROXY -u wss_proxy
  -u GIT_PROXY_COMMAND -u GIT_HTTP_PROXY -u GIT_HTTPS_PROXY
  -u npm_config_proxy -u npm_config_https_proxy
)

TUNNEL_ACTION=""
WAIT_SECONDS="20"
CONFIG_PATH=""
typeset -gi LAUNCH_LOCK_HELD=0

usage() {
  cat <<'EOF_USAGE'
用法（仅用于本机 Codex Proxy 启动器）:
  launch-codex-proxied.sh [--config PATH] --preflight
  launch-codex-proxied.sh [--config PATH] --status
  launch-codex-proxied.sh [--config PATH] --list-processes
  launch-codex-proxied.sh [--config PATH] --process-state
  launch-codex-proxied.sh [--config PATH] --wait-clear [seconds]
  launch-codex-proxied.sh [--config PATH] --terminate-residuals --confirmed-by-user
  launch-codex-proxied.sh [--config PATH] --launch-and-verify
  launch-codex-proxied.sh [--config PATH] --verify-current
EOF_USAGE
}

log_info() { print -r -- "[INFO] $*"; }
log_warn() { print -u2 -r -- "[WARN] $*"; }
log_error() { print -u2 -r -- "[ERROR] $*"; }

parse_pid() {
  print -r -- "${1%%$'\t'*}"
}

parse_command() {
  print -r -- "${1#*$'\t'}"
}

is_bundle_command() {
  [[ "$1" == "${CHATGPT_BUNDLE_PREFIX}"* ]]
}

is_main_command() {
  [[ "$1" == "$CHATGPT_EXECUTABLE" || "$1" == "${CHATGPT_EXECUTABLE} "* ]]
}

is_app_server_command() {
  local command_line="$1"
  is_bundle_command "$command_line" && [[ " $command_line " == *" app-server "* ]]
}

all_target_processes() {
  local source_table
  if (( TEST_MODE == 1 )); then
    source_table="$TEST_PROCESS_TABLE"
    if [[ -z "$source_table" || ! -r "$source_table" ]]; then
      log_error "Test process snapshot is unavailable."
      return 2
    fi
    /usr/bin/awk -v prefix="$CHATGPT_BUNDLE_PREFIX" '
      $1 ~ /^[0-9]+$/ {
        pid=$1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        if (index($0, prefix) == 1) print pid "\t" $0
      }
    ' "$source_table"
  else
    /bin/ps -axo pid=,command= | /usr/bin/awk -v prefix="$CHATGPT_BUNDLE_PREFIX" '
      $1 ~ /^[0-9]+$/ {
        pid=$1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        if (index($0, prefix) == 1) print pid "\t" $0
      }
    '
  fi
}

base_command_for_pid() {
  local pid="$1"
  if (( TEST_MODE == 1 )); then
    /usr/bin/awk -v wanted="$pid" '
      $1 == wanted {
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        print
        exit
      }
    ' "$TEST_PROCESS_TABLE"
  else
    /bin/ps -p "$pid" -o command= 2>/dev/null
  fi
}

environment_command_for_pid() {
  local pid="$1"
  if (( TEST_MODE == 1 )); then
    base_command_for_pid "$pid"
  else
    /bin/ps eww -p "$pid" -o command= 2>/dev/null
  fi
}

process_identity_for_pid() {
  local pid="$1"
  local uid start_time executable_path

  if (( TEST_MODE == 1 )); then
    executable_path="$(base_command_for_pid "$pid")"
    executable_path="${executable_path%%[[:space:]]*}"
    [[ -n "$executable_path" ]] || return 1
    print -r -- "$(/usr/bin/id -u)\tstart-${pid}\t${executable_path}"
    return 0
  fi

  uid="$(/bin/ps -p "$pid" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]')" || return 1
  start_time="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  executable_path="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/awk '/^n/ { sub(/^n/, ""); print; exit }')" || return 1
  executable_path="${executable_path:A}"
  [[ "$uid" == "$(/usr/bin/id -u)" ]] || return 1
  [[ "$executable_path" == "${CHATGPT_BUNDLE_PREFIX}"* ]] || return 1
  [[ -n "$start_time" && -n "$executable_path" ]] || return 1
  print -r -- "${uid}\t${start_time}\t${executable_path}"
}

command_has_exact_env() {
  local command_line="$1"
  local key="$2"
  local expected="$3"
  local needle="${key}=${expected}"

  /usr/bin/awk -v line="$command_line" -v needle="$needle" '
    function is_space(ch) {
      return (ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "\f")
    }

    BEGIN {
      local_len = length(line)
      needle_len = length(needle)
      start = 1
      while (start <= local_len) {
        segment = substr(line, start)
        match_pos = index(segment, needle)
        if (match_pos == 0) {
          exit 1
        }
        abs_pos = start + match_pos - 1
        before_pos = abs_pos - 1
        after_pos = abs_pos + needle_len
        before = (before_pos < 1) ? " " : substr(line, before_pos, 1)
        after = (after_pos > local_len) ? " " : substr(line, after_pos, 1)
        if ((abs_pos == 1 || is_space(before)) && (after_pos > local_len || is_space(after))) {
          exit 0
        }
        start = abs_pos + needle_len
      }
      exit 1
    }
  ' >/dev/null 2>&1
}

command_has_env_key() {
  local command_line="$1"
  local key="$2"
  local needle="${key}="

  /usr/bin/awk -v line="$command_line" -v needle="$needle" '
    function is_space(ch) {
      return (ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "\f")
    }

    BEGIN {
      local_len = length(line)
      needle_len = length(needle)
      start = 1
      while (start <= local_len) {
        segment = substr(line, start)
        match_pos = index(segment, needle)
        if (match_pos == 0) {
          exit 1
        }
        abs_pos = start + match_pos - 1
        before_pos = abs_pos - 1
        before = (before_pos < 1) ? " " : substr(line, before_pos, 1)
        if (abs_pos == 1 || is_space(before)) {
          exit 0
        }
        start = abs_pos + needle_len
      }
      exit 1
    }
  ' >/dev/null 2>&1
}

process_has_required_env() {
  local command_line="$1"
  local item key expected actual forbidden_key

  for item in "${REQUIRED_ENVS[@]}"; do
    key="${item%%=*}"
    expected="${item#*=}"
    command_has_exact_env "$command_line" "$key" "$expected" || return 1
  done
  for forbidden_key in "${FORBIDDEN_PROXY_ENVS[@]}"; do
    command_has_env_key "$command_line" "$forbidden_key" && return 1
  done
  return 0
}

has_processes() {
  local snapshot
  if ! snapshot="$(all_target_processes)"; then
    log_error "Unable to enumerate ChatGPT bundle processes; refusing to assume an empty process set."
    return 2
  fi
  [[ -n "$snapshot" ]]
}

process_state() {
  has_processes
  local rc=$?
  case "$rc" in
    0) print -r -- "present"; return 0 ;;
    1) print -r -- "absent"; return 0 ;;
    *) return "$rc" ;;
  esac
}

core_process_shape_ready() {
  local snapshot record base_command
  local main_count=0
  local app_server_count=0

  if ! snapshot="$(all_target_processes)"; then
    log_error "Unable to enumerate ChatGPT bundle processes."
    return 2
  fi

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    base_command="$(parse_command "$record")"
    if is_main_command "$base_command"; then
      (( main_count += 1 ))
    elif is_app_server_command "$base_command"; then
      (( app_server_count += 1 ))
    fi
  done <<< "$snapshot"

  (( main_count == 1 && app_server_count == 1 ))
}

list_processes() {
  local snapshot record pid base_command env_command role env_state count=0

  if ! snapshot="$(all_target_processes)"; then
    log_error "Unable to enumerate ChatGPT bundle processes."
    return 2
  fi

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    pid="$(parse_pid "$record")"
    base_command="$(parse_command "$record")"
    env_command="$(environment_command_for_pid "$pid")"

    if is_main_command "$base_command"; then
      role="main"
    elif is_app_server_command "$base_command"; then
      role="app-server"
    else
      role="helper"
    fi

    if [[ "$role" == "helper" ]]; then
      env_state="not-checked"
    elif process_has_required_env "$env_command"; then
      env_state="env-ok"
    else
      env_state="env-bad"
    fi

    /usr/bin/printf '%s\t%s\t%s\n' "$pid" "$role" "$env_state"
    (( count += 1 ))
  done <<< "$snapshot"

  if (( count == 0 )); then
    log_info "No ChatGPT bundle process is running."
  else
    log_info "Target process count: ${count}"
  fi
}

socket_snapshot_for_pid() {
  local pid="$1"
  if (( TEST_MODE == 1 )); then
    [[ -r "$TEST_SOCKET_TABLE" ]] || return 0
    /usr/bin/awk -F $'\t' -v wanted="$pid" '$1 == wanted { print $2 }' "$TEST_SOCKET_TABLE"
  else
    /usr/sbin/lsof -a -nP -iTCP -sTCP:ESTABLISHED -p "$pid" 2>/dev/null
  fi
}

verify_process_sockets() {
  local pid="$1"
  local role="$2"
  local require_relay="$3"
  local allow_upstream="$4"
  local round line remote
  local found_relay=0
  local found_established=0
  local forbidden_upstream=0
  local forbidden_external_443=0

  for (( round = 1; round <= SOCKET_SAMPLE_ROUNDS; round++ )); do
    while IFS= read -r line; do
      [[ "$line" == *"->"* ]] || continue
      remote="${line##*->}"
      remote="${remote#${remote%%[![:space:]]*}}"
      remote="${remote%%[[:space:]]*}"
      (( found_established = 1 ))

      case "$remote" in
        127.0.0.1:${RELAY_PORT}|localhost:${RELAY_PORT}|\[::1\]:${RELAY_PORT}|::1:${RELAY_PORT})
          (( found_relay = 1 ))
          ;;
        *:${UPSTREAM_PORT})
          (( forbidden_upstream = 1 ))
          ;;
        *:443)
          case "$remote" in
            127.0.0.1:443|localhost:443|\[::1\]:443|::1:443) ;;
            *) (( forbidden_external_443 = 1 )) ;;
          esac
          ;;
      esac
    done < <(socket_snapshot_for_pid "$pid")

    if (( TEST_MODE == 0 && round < SOCKET_SAMPLE_ROUNDS )); then
      /bin/sleep "$SOCKET_SAMPLE_SLEEP_SECONDS"
    fi
  done

  if (( forbidden_upstream == 1 && allow_upstream == 0 )); then
    log_error "${role} PID ${pid}: direct connection to upstream port ${UPSTREAM_PORT} is forbidden."
    return 1
  fi
  if (( forbidden_external_443 == 1 )); then
    log_error "${role} PID ${pid}: direct external port 443 connection is forbidden."
    return 1
  fi
  if (( require_relay == 1 )); then
    if (( found_established == 0 )); then
      log_error "${role} PID ${pid}: no ESTABLISHED TCP connection was observed."
      return 1
    fi
    if (( found_relay == 0 )); then
      log_error "${role} PID ${pid}: no ESTABLISHED connection to relay port ${RELAY_PORT} was observed."
      return 1
    fi
  fi
  return 0
}

verify_current() {
  local snapshot record pid base_command env_command main_identity app_server_identity
  local -a main_pids=()
  local -a app_server_pids=()

  if ! snapshot="$(all_target_processes)"; then
    log_error "Unable to enumerate ChatGPT bundle processes."
    return 2
  fi

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    pid="$(parse_pid "$record")"
    base_command="$(parse_command "$record")"
    if is_main_command "$base_command"; then
      main_pids+=("$pid")
    elif is_app_server_command "$base_command"; then
      app_server_pids+=("$pid")
    fi
  done <<< "$snapshot"

  if (( ${#main_pids[@]} != 1 )); then
    log_error "Expected exactly one ChatGPT main process; found ${#main_pids[@]}."
    return 1
  fi
  if (( ${#app_server_pids[@]} != 1 )); then
    log_error "Expected exactly one Codex app-server process; found ${#app_server_pids[@]}."
    return 1
  fi

  main_identity="$(process_identity_for_pid "${main_pids[1]}")" || {
    log_error "ChatGPT main process identity could not be verified from its loaded executable."
    return 1
  }
  app_server_identity="$(process_identity_for_pid "${app_server_pids[1]}")" || {
    log_error "Codex app-server process identity could not be verified from its loaded executable."
    return 1
  }

  base_command="$(base_command_for_pid "${main_pids[1]}")"
  if [[ " $base_command " != *" --proxy-server=${BROWSER_PROXY_URL} "* ]]; then
    log_error "ChatGPT main process is missing the required Chromium proxy argument."
    return 1
  fi

  env_command="$(environment_command_for_pid "${main_pids[1]}")"
  if ! process_has_required_env "$env_command"; then
    log_error "ChatGPT main process environment does not exactly match the scoped proxy policy."
    return 1
  fi

  env_command="$(environment_command_for_pid "${app_server_pids[1]}")"
  if ! process_has_required_env "$env_command"; then
    log_error "Codex app-server environment does not exactly match the scoped proxy policy."
    return 1
  fi

  verify_process_sockets "${main_pids[1]}" "ChatGPT main" 0 1 || return 1
  verify_process_sockets "${app_server_pids[1]}" "Codex app-server" 1 0 || return 1

  [[ "$(process_identity_for_pid "${main_pids[1]}" 2>/dev/null)" == "$main_identity" ]] || {
    log_error "ChatGPT main process identity changed during verification."
    return 1
  }
  [[ "$(process_identity_for_pid "${app_server_pids[1]}" 2>/dev/null)" == "$app_server_identity" ]] || {
    log_error "Codex app-server identity changed during verification."
    return 1
  }

  log_info "Current ChatGPT main process and Codex app-server passed env/socket verification."
  return 0
}

wait_clear() {
  local timeout_seconds="${1:-20}"
  [[ "$timeout_seconds" == <-> ]] || { log_error "wait timeout must be a non-negative integer."; return 64; }

  local ticks=$(( timeout_seconds * 4 ))
  local tick process_rc

  for (( tick = 0; tick <= ticks; tick++ )); do
    has_processes
    process_rc=$?
    case "$process_rc" in
      0) ;;
      1)
        log_info "All ChatGPT bundle processes have exited."
        return 0
        ;;
      *)
        return "$process_rc"
        ;;
    esac
    (( tick < ticks )) && /bin/sleep 0.25
  done

  log_error "Timed out while waiting for ChatGPT bundle processes to exit."
  list_processes >&2
  return 1
}

terminate_residuals() {
  if [[ "${1:-}" != "--confirmed-by-user" ]]; then
    log_error "TERM requires the explicit --confirmed-by-user acknowledgement."
    return 64
  fi

  local record pid current_identity
  local -a snapshot_records=()
  local -A snapshot_identities=()
  local snapshot_text

  if ! snapshot_text="$(all_target_processes)"; then
    log_error "Unable to enumerate ChatGPT bundle processes; TERM was not sent."
    return 2
  fi

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    pid="$(parse_pid "$record")"
    current_identity="$(process_identity_for_pid "$pid")" || {
      log_error "PID ${pid} identity could not be verified; TERM was not sent."
      return 1
    }
    snapshot_records+=("$record")
    snapshot_identities[$pid]="$current_identity"
  done <<< "$snapshot_text"

  if (( ${#snapshot_records[@]} == 0 )); then
    log_info "No ChatGPT bundle process requires TERM."
    return 0
  fi

  log_warn "Explicitly confirmed TERM will target ${#snapshot_records[@]} ChatGPT bundle process(es)."

  for record in "${snapshot_records[@]}"; do
    pid="$(parse_pid "$record")"
    [[ "$pid" == <-> ]] || { log_warn "Skipped a non-numeric PID."; continue }

    current_identity="$(process_identity_for_pid "$pid" 2>/dev/null)"
    if [[ -z "$current_identity" || "$current_identity" != "${snapshot_identities[$pid]}" ]]; then
      log_warn "Skipped PID ${pid}; its UID/start time/loaded executable changed after snapshot."
      continue
    fi

    if (( TEST_MODE == 1 && TEST_DRY_RUN == 1 )); then
      print -r -- "kill -TERM ${pid}" >> "$TEST_TERM_LOG"
    else
      /bin/kill -TERM "$pid"
    fi
  done

  if (( TEST_MODE == 1 && TEST_DRY_RUN == 1 )); then
    return 0
  fi
  wait_clear 20
}

release_launch_lock() {
  (( LAUNCH_LOCK_HELD == 1 )) || return 0

  local owner=""
  [[ -r "$LAUNCH_LOCK_DIR/owner-pid" ]] && owner="$(<"$LAUNCH_LOCK_DIR/owner-pid")"
  if [[ -d "$LAUNCH_LOCK_DIR" && ! -L "$LAUNCH_LOCK_DIR" && "$owner" == "$$" ]]; then
    /bin/rm -f -- "$LAUNCH_LOCK_DIR/owner-pid"
    /bin/rmdir -- "$LAUNCH_LOCK_DIR" 2>/dev/null || true
  fi
  LAUNCH_LOCK_HELD=0
}

acquire_launch_lock() {
  local owner="" lock_uid="" owner_uid="" ps_rc

  if [[ -e "$INSTALL_TRANSACTION_LOCK" || -L "$INSTALL_TRANSACTION_LOCK" ]]; then
    log_error "A Codex Proxy install transaction is active or incomplete; refusing launch."
    return 1
  fi

  if ! /bin/mkdir "$LAUNCH_LOCK_DIR" 2>/dev/null; then
    if [[ ! -d "$LAUNCH_LOCK_DIR" || -L "$LAUNCH_LOCK_DIR" ]]; then
      log_error "Launch lock path is not a real directory; refusing concurrent launch."
      return 1
    fi

    lock_uid="$(/usr/bin/stat -f '%u' "$LAUNCH_LOCK_DIR" 2>/dev/null)" || return 1
    if [[ "$lock_uid" != "$(/usr/bin/id -u)" ]]; then
      log_error "Launch lock is not owned by the current user."
      return 1
    fi
    if [[ ! -r "$LAUNCH_LOCK_DIR/owner-pid" ]]; then
      log_error "Launch lock exists without a readable owner; refusing concurrent launch."
      return 1
    fi
    owner="$(<"$LAUNCH_LOCK_DIR/owner-pid")"
    if [[ "$owner" != <-> ]]; then
      log_error "Launch lock has an invalid owner; refusing concurrent launch."
      return 1
    fi

    if (( TEST_MODE == 1 )); then
      case "$TEST_LOCK_OWNER_STATE" in
        active)
          owner_uid="$(/usr/bin/id -u)"
          ps_rc=0
          ;;
        stale)
          owner_uid=""
          ps_rc=1
          ;;
        foreign)
          owner_uid="0"
          ps_rc=0
          ;;
        error)
          owner_uid=""
          ps_rc=2
          ;;
        *)
          owner_uid="$(/bin/ps -p "$owner" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
          ps_rc=$?
          ;;
      esac
    else
      owner_uid="$(/bin/ps -p "$owner" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]')"
      ps_rc=$?
    fi

    case "$ps_rc" in
      0)
        if [[ -z "$owner_uid" ]]; then
          log_error "Launch lock owner lookup returned no UID; refusing concurrent launch."
        elif [[ "$owner_uid" != "$(/usr/bin/id -u)" ]]; then
          log_error "Launch lock refers to another user process; refusing concurrent launch."
        else
          log_error "Another Codex Proxy launch is already active (PID ${owner})."
        fi
        return 1
        ;;
      1)
        ;;
      *)
        log_error "Launch lock owner lookup failed (ps rc=${ps_rc}); refusing concurrent launch."
        return 1
        ;;
    esac

    /bin/rm -f -- "$LAUNCH_LOCK_DIR/owner-pid"
    /bin/rmdir -- "$LAUNCH_LOCK_DIR" 2>/dev/null || {
      log_error "Stale launch lock could not be removed safely."
      return 1
    }
    /bin/mkdir "$LAUNCH_LOCK_DIR" 2>/dev/null || {
      log_error "Launch lock could not be re-created after stale-lock cleanup."
      return 1
    }
  fi

  /bin/chmod 700 "$LAUNCH_LOCK_DIR" || {
    /bin/rmdir -- "$LAUNCH_LOCK_DIR" 2>/dev/null || true
    log_error "Launch lock permissions could not be secured."
    return 1
  }

  if ! /usr/bin/printf '%s\n' "$$" > "$LAUNCH_LOCK_DIR/owner-pid"; then
    /bin/rm -f -- "$LAUNCH_LOCK_DIR/owner-pid"
    /bin/rmdir -- "$LAUNCH_LOCK_DIR" 2>/dev/null || true
    log_error "Launch lock owner could not be recorded."
    return 1
  fi

  LAUNCH_LOCK_HELD=1
  trap 'release_launch_lock' EXIT
  trap 'release_launch_lock; exit 129' HUP
  trap 'release_launch_lock; exit 130' INT
  trap 'release_launch_lock; exit 143' TERM
}

launch_chatgpt() {
  /usr/bin/nohup /usr/bin/env \
    "${CLEAR_PROXY_ENV_ARGS[@]}" \
    HTTP_PROXY="$RELAY_URL" \
    HTTPS_PROXY="$RELAY_URL" \
    http_proxy="$RELAY_URL" \
    https_proxy="$RELAY_URL" \
    CODEX_CA_CERTIFICATE="$RELAY_CA" \
    SSL_CERT_FILE="$RELAY_CA" \
    NODE_EXTRA_CA_CERTS="$RELAY_CA" \
    NO_PROXY="$NO_PROXY_VALUE" \
    no_proxy="$NO_PROXY_VALUE" \
    "$CHATGPT_EXECUTABLE" "--proxy-server=$BROWSER_PROXY_URL" >> "$LAUNCHER_LOG" 2>&1 </dev/null &
}

preflight() {
  local failed=0
  log_info "Running strict proxy preflight."

  if [[ -e "$INSTALL_TRANSACTION_LOCK" || -L "$INSTALL_TRANSACTION_LOCK" ]]; then
    log_error "A Codex Proxy install transaction is active or incomplete; refusing preflight."
    return 1
  fi

  [[ -x "$CHATGPT_EXECUTABLE" ]] || { log_error "ChatGPT executable is missing."; failed=1; }
  [[ -x "$START_RELAY" ]] || { log_error "start-relay.sh is missing or not executable."; failed=1; }
  [[ -x "$PROXY_HEALTH" ]] || { log_error "proxy-health.sh is missing or not executable."; failed=1; }
  [[ -x /usr/bin/nc ]] || { log_error "nc is unavailable."; failed=1; }
  [[ -x /usr/sbin/lsof ]] || { log_error "lsof is unavailable."; failed=1; }

  if (( failed != 0 )); then
    return 1
  fi

  if ! /usr/bin/nc -z "$UPSTREAM_HOST" "$UPSTREAM_PORT" >/dev/null 2>&1; then
    log_error "Upstream HTTP proxy is not listening on ${UPSTREAM_HOST}:${UPSTREAM_PORT}."
    return 1
  fi

  /usr/bin/env "${CLEAR_PROXY_ENV_ARGS[@]}" /bin/zsh "$START_RELAY" --config "$CONFIG_PATH" >/dev/null || {
    log_error "Relay ownership/health validation failed; it was not replaced automatically."
    return 1
  }

  [[ -r "$RELAY_CA" ]] || { log_error "Relay CA is missing or unreadable."; failed=1; }
  if (( failed != 0 )); then
    return 1
  fi

  /bin/zsh "$PROXY_HEALTH" --config "$CONFIG_PATH" --full >/dev/null || {
    log_error "Full HTTPS/WebSocket proxy health check failed."
    return 1
  }

  log_info "Strict proxy preflight passed."
  return 0
}

status() {
  local rc=0
  local process_rc

  if /usr/bin/nc -z "$UPSTREAM_HOST" "$UPSTREAM_PORT" >/dev/null 2>&1; then
    log_info "Upstream ${UPSTREAM_HOST}:${UPSTREAM_PORT} is listening."
  else
    log_error "Upstream ${UPSTREAM_HOST}:${UPSTREAM_PORT} is unavailable."
    rc=1
  fi

  if /usr/bin/nc -z "$RELAY_BIND_HOST" "$RELAY_PORT" >/dev/null 2>&1; then
    log_info "Relay ${RELAY_BIND_HOST}:${RELAY_PORT} is listening."
  else
    log_error "Relay ${RELAY_BIND_HOST}:${RELAY_PORT} is unavailable."
    rc=1
  fi

  list_processes
  process_rc=$?
  (( process_rc == 0 )) || return "$process_rc"

  has_processes
  process_rc=$?
  case "$process_rc" in
    0) verify_current || rc=1 ;;
    1) ;;
    *) return "$process_rc" ;;
  esac

  return "$rc"
}

init_runtime() {
  CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"
  if [[ -z "$CONFIG_PATH" ]]; then
    codex_proxy_init_runtime_paths
    CONFIG_PATH="$CODEX_PROXY_CONFIG_PATH"
  fi
  if ! codex_proxy_load_config "$CONFIG_PATH"; then
    return 1
  fi

  CHATGPT_EXECUTABLE="$CODEX_PROXY_CHATGPT_APP_PATH"
  CHATGPT_BUNDLE_PREFIX="${CODEX_PROXY_CHATGPT_APP_PATH:h:h}/"
  RELAY_URL="$CODEX_PROXY_RELAY_URL"
  RELAY_CA="$CODEX_PROXY_CA_CERT"
  RELAY_PORT="${CODEX_PROXY_LISTEN_PORT}"
  RELAY_BIND_HOST="${CODEX_PROXY_LISTEN_HOST_FOR_BIND}"
  UPSTREAM_HOST="$CODEX_PROXY_UPSTREAM_HOST"
  UPSTREAM_PORT="$CODEX_PROXY_UPSTREAM_PORT"
  BROWSER_PROXY_URL="$CODEX_PROXY_UPSTREAM_PROXY_URL"
  START_RELAY="$CODEX_PROXY_BIN_DIR/start-relay.sh"
  PROXY_HEALTH="$CODEX_PROXY_BIN_DIR/proxy-health.sh"
  ROTATE_LOG="$CODEX_PROXY_BIN_DIR/rotate-launcher-log.sh"
  LAUNCHER_LOG="$CODEX_PROXY_RUNTIME_HOME/launcher.log"

  REQUIRED_ENVS=(
    "HTTP_PROXY=${RELAY_URL}"
    "HTTPS_PROXY=${RELAY_URL}"
    "http_proxy=${RELAY_URL}"
    "https_proxy=${RELAY_URL}"
    "CODEX_CA_CERTIFICATE=${RELAY_CA}"
    "SSL_CERT_FILE=${RELAY_CA}"
    "NODE_EXTRA_CA_CERTS=${RELAY_CA}"
    "NO_PROXY=${NO_PROXY_VALUE}"
    "no_proxy=${NO_PROXY_VALUE}"
  )
  return 0
}

launch_and_verify() {
  local process_rc

  acquire_launch_lock || return 1
  has_processes
  process_rc=$?
  case "$process_rc" in
    0)
      log_error "Refusing to launch while any ChatGPT bundle process remains."
      list_processes >&2
      return 1
      ;;
    1) ;;
    *)
      return "$process_rc"
      ;;
  esac

  preflight || return 1

  has_processes
  process_rc=$?
  case "$process_rc" in
    0)
      log_error "A ChatGPT bundle process appeared during preflight; refusing a raced second launch."
      list_processes >&2
      return 1
      ;;
    1) ;;
    *)
      return "$process_rc"
      ;;
  esac

  if [[ ! -x "$ROTATE_LOG" ]]; then
    log_error "Launcher log rotation helper is missing or not executable."
    return 1
  fi
  if ! /bin/zsh "$ROTATE_LOG"; then
    log_error "Launcher log path is unsafe or rotation failed; launch was refused."
    return 1
  fi

  launch_chatgpt || { log_error "The proxied ChatGPT process could not be started."; return 1; }

  local tick
  for (( tick = 0; tick < 120; tick++ )); do
    if core_process_shape_ready; then
      break
    fi
    /bin/sleep 0.25
  done

  if ! core_process_shape_ready; then
    log_error "A unique ChatGPT main process and Codex app-server did not appear within 30 seconds."
    log_error "The launched app may still be running in an unverified state; close it manually before retrying. No automatic TERM was sent."
    return 1
  fi

  if verify_current; then
    return 0
  fi

  /bin/sleep 3
  verify_current || {
    log_error "Proxied launch did not pass postflight verification. No direct-launch fallback was used."
    log_error "The launched app remains user-controlled and may still be running in an unverified state; close it manually before retrying. No automatic TERM was sent."
    return 1
  }
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --config)
        if (( $# < 2 )); then
          usage
          return 64
        fi
        CONFIG_PATH="$2"
        if [[ "$CONFIG_PATH" != /* ]]; then
          log_error "--config requires an absolute path."
          return 64
        fi
        shift 2
        ;;
      --preflight)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="preflight"
        shift
        ;;
      --status)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="status"
        shift
        ;;
      --list-processes)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="list-processes"
        shift
        ;;
      --process-state)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="process-state"
        shift
        ;;
      --wait-clear)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="wait-clear"
        if (( $# >= 2 )) && [[ "$2" == <-> ]]; then
          WAIT_SECONDS="$2"
          shift 2
        elif (( $# >= 2 )) && [[ "$2" != --* ]]; then
          log_error "Invalid --wait-clear timeout: $2"
          usage
          return 64
        else
          WAIT_SECONDS="20"
          shift
        fi
        ;;
      --terminate-residuals)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="terminate-residuals"
        if [[ "${2:-}" != "--confirmed-by-user" ]]; then
          log_error "The --terminate-residuals action requires --confirmed-by-user."
          usage
          return 64
        fi
        shift 2
        ;;
      --launch-and-verify)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="launch-and-verify"
        shift
        ;;
      --verify-current)
        [[ -z "$TUNNEL_ACTION" ]] || { log_error "Only one action can be used at once."; usage; return 64; }
        TUNNEL_ACTION="verify-current"
        shift
        ;;
      --confirmed-by-user)
        [[ "$TUNNEL_ACTION" == "terminate-residuals" ]] || {
          log_error "Unexpected --confirmed-by-user without --terminate-residuals."
          return 64
        }
        shift
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      --*)
        log_error "Unknown option: $1"
        usage
        return 64
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        return 64
        ;;
    esac
  done

  if (( $# > 0 )); then
    log_error "Unexpected trailing argument: $1"
    usage
    return 64
  fi

  if [[ -z "$TUNNEL_ACTION" ]]; then
    usage
    return 64
  fi

  return 0
}

main() {
  parse_args "$@" || return $?

  if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH=""
  fi
  if ! init_runtime; then
    return 1
  fi

  case "$TUNNEL_ACTION" in
    preflight) preflight ;;
    status) status ;;
    list-processes) list_processes ;;
    process-state) process_state ;;
    wait-clear) wait_clear "$WAIT_SECONDS" ;;
    terminate-residuals) terminate_residuals --confirmed-by-user ;;
    launch-and-verify) launch_and_verify ;;
    verify-current) verify_current ;;
    *)
      usage
      return 64
      ;;
  esac
}

main "$@"
