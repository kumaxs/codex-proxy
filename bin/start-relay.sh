#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../lib/config.sh"

CONFIG_PATH=""

usage() {
  cat <<'EOF_USAGE'
用法: start-relay.sh [--config PATH]
EOF_USAGE
}

if (( $# > 0 )); then
  while (( $# > 0 )); do
    case "$1" in
      --config)
        if [[ -z "${2:-}" ]]; then
          print -u2 "[ERROR] --config requires a path."
          usage
          exit 64
        fi
        CONFIG_PATH="$2"
        if [[ "$CONFIG_PATH" != /* ]]; then
          print -u2 "[ERROR] --config requires an absolute path."
          usage
          exit 64
        fi
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        if (( $# > 0 )); then
          print -u2 "[ERROR] unsupported argument: $1"
          usage
          exit 64
        fi
        break
        ;;
      --*)
        print -u2 "[ERROR] unsupported argument: $1"
        usage
        exit 64
        ;;
      *)
        print -u2 "[ERROR] unsupported argument: $1"
        usage
        exit 64
        ;;
    esac
  done
fi

readonly CURRENT_UID="$(/usr/bin/id -u)"
readonly INSTALL_TRANSACTION_LOCK="/private/tmp/com.github.kumaxs.codex-proxy-install-${CURRENT_UID}.lock"

# The installer uses this uid-scoped directory as its transaction fence.  A
# stale, malformed, or foreign lock is deliberately treated as active: this
# command must never race a runtime swap or an uninstall.
ensure_no_install_transaction() {
  if [[ -L "$INSTALL_TRANSACTION_LOCK" || -e "$INSTALL_TRANSACTION_LOCK" ]]; then
    print -u2 "[ERROR] A Codex Proxy install transaction is active or incomplete; refusing relay start."
    return 1
  fi
  return 0
}

if ! ensure_no_install_transaction; then
  exit 1
fi

if [[ -z "${CONFIG_PATH:-}" ]]; then
  CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"
  codex_proxy_init_runtime_paths
  CONFIG_PATH="$CODEX_PROXY_CONFIG_PATH"
fi

if ! codex_proxy_load_config "$CONFIG_PATH"; then
  exit 1
fi

readonly RELAY_LABEL="io.github.kumaxs.codex-proxy-relay"
readonly RELAY_AGENT="$HOME/Library/LaunchAgents/${RELAY_LABEL}.plist"
readonly RELAY_SCRIPT="$CODEX_PROXY_BIN_DIR/relay.sh"
readonly HEALTH_SCRIPT="$CODEX_PROXY_BIN_DIR/proxy-health.sh"
readonly RELAY_LOG_PATH="$CODEX_PROXY_RUNTIME_HOME/relay.log"
readonly PROXY_LISTEN_HOST="$CODEX_PROXY_LISTEN_HOST_FOR_BIND"
readonly PROXY_LISTEN_PORT="$CODEX_PROXY_LISTEN_PORT"
readonly UPSTREAM_HOST="$CODEX_PROXY_UPSTREAM_HOST"
readonly UPSTREAM_PORT="$CODEX_PROXY_UPSTREAM_PORT"
readonly CHATGPT_BUNDLE_PREFIX="${CODEX_PROXY_CHATGPT_APP_PATH%/Contents/MacOS/ChatGPT}"
readonly LAUNCH_DOMAIN="gui/${CURRENT_UID}"
readonly SERVICE_TARGET="${LAUNCH_DOMAIN}/${RELAY_LABEL}"

is_port_listening() {
  /usr/bin/nc -z "$PROXY_LISTEN_HOST" "$PROXY_LISTEN_PORT" >/dev/null 2>&1
}

get_launchctl_pid() {
  local service_state
  service_state="$(/bin/launchctl print "$SERVICE_TARGET" 2>/dev/null || true)"
  print -r -- "$service_state" | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+[[:space:]]*$/ { print $3; exit }'
}

get_launchctl_path() {
  local service_state
  service_state="$(/bin/launchctl print "$SERVICE_TARGET" 2>/dev/null || true)"
  # The first (top-level) path field is the plist launchd loaded for this
  # label.  Nested dictionaries may also contain path fields; only the first
  # one is relevant to the job identity.
  print -r -- "$service_state" | /usr/bin/awk '
    /^[[:space:]]*path[[:space:]]*=/ {
      value=$0
      sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", value)
      print value
      exit
    }
  '
}

launchctl_job_status() {
  local service_state
  local launchctl_rc

  service_state="$(/bin/launchctl print "$SERVICE_TARGET" 2>&1)"
  launchctl_rc=$?
  if (( launchctl_rc == 0 )); then
    return 0
  fi

  # macOS launchctl uses EX_NOPERM-like status 113 for a missing service and
  # emits this explicit diagnostic.  Only that unambiguous combination means
  # "not loaded"; permission, malformed-domain, and transient failures must
  # not fall through to bootstrap.
  if (( launchctl_rc == 113 )) &&
      [[ "$service_state" == *"Could not find service"* && "$service_state" == *"in domain"* ]]; then
    return 1
  fi

  print -u2 "[ERROR] launchctl print failed for $SERVICE_TARGET (rc=${launchctl_rc}): ${service_state:-no diagnostic}."
  return 2
}

get_listener_pids() {
  local lsof_output
  local lsof_rc

  # lsof is intentionally restricted to TCP LISTEN sockets on this port.  We
  # never kill or otherwise act on a PID that is not owned by the exact
  # launchd label below.
  lsof_output="$(/usr/sbin/lsof -nP -iTCP:"$PROXY_LISTEN_PORT" -sTCP:LISTEN -t 2>&1)"
  lsof_rc=$?
  if (( lsof_rc == 1 && -z "$lsof_output" )); then
    # lsof's documented no-match result is rc=1 with no diagnostic.
    return 0
  fi
  if (( lsof_rc != 0 )); then
    print -u2 "[ERROR] lsof listener query failed (rc=${lsof_rc}): ${lsof_output:-no diagnostic}."
    return 2
  fi
  if [[ -z "$lsof_output" ]]; then
    return 0
  fi
  print -r -- "$lsof_output" | /usr/bin/awk '/^[0-9]+$/ && !seen[$0]++ { print $0 }'
}

ensure_chatgpt_bundle_clear() {
  local ps_output
  local ps_rc
  local line
  local pid
  local command
  typeset -a chatgpt_pids=()

  # This is a read-only snapshot.  We deliberately do not terminate residual
  # ChatGPT/Codex processes here; the caller must exit and retry after the user
  # closes them.  A ps failure is equally unsafe and therefore fail-closed.
  ps_output="$(/bin/ps -axo pid=,command= 2>&1)"
  ps_rc=$?
  if (( ps_rc != 0 )); then
    print -u2 "[ERROR] Could not enumerate ChatGPT bundle processes (ps rc=${ps_rc}): ${ps_output:-no diagnostic}."
    return 2
  fi

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || continue
    pid="${line%%[[:space:]]*}"
    if [[ "$pid" != <-> ]]; then
      print -u2 "[ERROR] Process enumeration returned an unverifiable record; refusing relay action."
      return 2
    fi
    command="${line#"$pid"}"
    command="${command#"${command%%[![:space:]]*}"}"
    if [[ "$command" == "$CHATGPT_BUNDLE_PREFIX"* ]]; then
      chatgpt_pids+=("$pid")
    fi
  done <<< "$ps_output"

  if (( ${#chatgpt_pids[@]} > 0 )); then
    print -u2 "[ERROR] ChatGPT bundle processes are still running (PIDs ${(j:, :)chatgpt_pids}); close them before starting relay."
    return 1
  fi
  return 0
}

ensure_relay_log_safe() {
  local owner
  local mode
  local mode_decimal

  if ! codex_proxy_validate_path_chain "$CODEX_PROXY_RUNTIME_HOME"; then
    print -u2 "[ERROR] Relay runtime path has unsafe ownership, mode, or symlink component: $CODEX_PROXY_RUNTIME_HOME"
    return 1
  fi

  if [[ -L "$RELAY_LOG_PATH" ]]; then
    print -u2 "[ERROR] Relay log is a symlink: $RELAY_LOG_PATH"
    return 1
  fi
  if [[ ! -e "$RELAY_LOG_PATH" ]]; then
    # O_EXCL/noclobber prevents a concurrent symlink from being followed while
    # creating the first log file.  The parent runtime has already passed the
    # lexical path-chain and ownership checks above.
    if ! ( umask 077; set -C; : > "$RELAY_LOG_PATH" ) 2>/dev/null; then
      print -u2 "[ERROR] Relay log could not be created safely: $RELAY_LOG_PATH"
      return 1
    fi
    if ! /bin/chmod 600 "$RELAY_LOG_PATH"; then
      print -u2 "[ERROR] Relay log permissions could not be restricted: $RELAY_LOG_PATH"
      return 1
    fi
  fi

  if [[ -L "$RELAY_LOG_PATH" || ! -f "$RELAY_LOG_PATH" ]]; then
    print -u2 "[ERROR] Relay log is not a regular file: $RELAY_LOG_PATH"
    return 1
  fi
  if ! codex_proxy_validate_path_chain "$RELAY_LOG_PATH"; then
    print -u2 "[ERROR] Relay log path has unsafe ownership, mode, or symlink component: $RELAY_LOG_PATH"
    return 1
  fi

  owner="$(/usr/bin/stat -f '%u' "$RELAY_LOG_PATH" 2>/dev/null || true)"
  mode="$(/usr/bin/stat -f '%A' "$RELAY_LOG_PATH" 2>/dev/null || true)"
  if [[ "$owner" != "$CURRENT_UID" || "$mode" != <-> ]]; then
    print -u2 "[ERROR] Relay log must be owned by uid ${CURRENT_UID} with a numeric private mode: $RELAY_LOG_PATH"
    return 1
  fi
  mode_decimal=$((8#$mode))
  if (( (mode_decimal & 0777) != 0600 )); then
    print -u2 "[ERROR] Relay log must have mode 600: $RELAY_LOG_PATH"
    return 1
  fi
  return 0
}

verify_plist_identity() {
  local label
  local relay_script
  local config_flag
  local config_path
  local stdout_path
  local stderr_path

  if ! codex_proxy_validate_path_chain "$RELAY_AGENT"; then
    print -u2 "[ERROR] LaunchAgent plist path has unsafe ownership, mode, or symlink component: $RELAY_AGENT"
    return 1
  fi
  if [[ -L "$RELAY_AGENT" || ! -f "$RELAY_AGENT" ]]; then
    print -u2 "[ERROR] LaunchAgent plist is missing, non-regular, or a symlink: $RELAY_AGENT"
    return 1
  fi
  if ! /usr/bin/plutil -lint "$RELAY_AGENT" >/dev/null 2>&1; then
    print -u2 "[ERROR] LaunchAgent plist is not valid: $RELAY_AGENT"
    return 1
  fi

  label="$(/usr/bin/plutil -extract Label raw "$RELAY_AGENT" 2>/dev/null || true)"
  relay_script="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$RELAY_AGENT" 2>/dev/null || true)"
  config_flag="$(/usr/bin/plutil -extract ProgramArguments.1 raw "$RELAY_AGENT" 2>/dev/null || true)"
  config_path="$(/usr/bin/plutil -extract ProgramArguments.2 raw "$RELAY_AGENT" 2>/dev/null || true)"
  stdout_path="$(/usr/bin/plutil -extract StandardOutPath raw "$RELAY_AGENT" 2>/dev/null || true)"
  stderr_path="$(/usr/bin/plutil -extract StandardErrorPath raw "$RELAY_AGENT" 2>/dev/null || true)"

  if [[ "$label" != "$RELAY_LABEL" ]]; then
    print -u2 "[ERROR] LaunchAgent label mismatch: $RELAY_AGENT"
    return 1
  fi
  if [[ "$relay_script" != "$RELAY_SCRIPT" || "$config_flag" != "--config" \
      || "$config_path" != "$CONFIG_PATH" ]]; then
    print -u2 "[ERROR] LaunchAgent ProgramArguments do not identify this runtime/config: $RELAY_AGENT"
    return 1
  fi
  if [[ "$stdout_path" != "$RELAY_LOG_PATH" || "$stderr_path" != "$RELAY_LOG_PATH" ]]; then
    print -u2 "[ERROR] LaunchAgent log paths do not identify the expected relay log: $RELAY_AGENT"
    return 1
  fi
  # The relay job is intentionally a three-argument command.  Extra
  # arguments could change its upstream, interception policy, or executable;
  # reject rather than guessing what launchd would execute.
  if /usr/bin/plutil -extract ProgramArguments.3 raw "$RELAY_AGENT" >/dev/null 2>&1; then
    print -u2 "[ERROR] LaunchAgent ProgramArguments contain unexpected extra arguments: $RELAY_AGENT"
    return 1
  fi
  if ! ensure_relay_log_safe; then
    return 1
  fi
  return 0
}

verify_loaded_job_path() {
  local loaded_path
  loaded_path="$(get_launchctl_path)"
  if [[ "$loaded_path" != "$RELAY_AGENT" ]]; then
    print -u2 "[ERROR] Loaded relay job path mismatch: expected $RELAY_AGENT, got ${loaded_path:-unknown}."
    return 1
  fi
  return 0
}

collect_listener_pids() {
  typeset -ga listener_pids=()
  local listener_pid
  local listener_output

  if ! listener_output="$(get_listener_pids)"; then
    return 2
  fi
  while IFS= read -r listener_pid; do
    [[ -n "$listener_pid" ]] || continue
    listener_pids+=("$listener_pid")
  done <<< "$listener_output"
  return 0
}

print_listener_error() {
  local reason="$1"
  if (( ${#listener_pids[@]} == 0 )); then
    print -u2 "[ERROR] ${reason}; no listener PID was discovered."
  elif (( ${#listener_pids[@]} > 1 )); then
    print -u2 "[ERROR] ${reason}; found ${#listener_pids[@]} listener PIDs (${(j:, :)listener_pids})."
  else
    print -u2 "[ERROR] ${reason}; listener PID=${listener_pids[1]}."
  fi
}

verify_active_relay() {
  local launchctl_pid
  local launchctl_status

  if ! verify_plist_identity; then
    return 1
  fi
  launchctl_job_status
  launchctl_status=$?
  case "$launchctl_status" in
    0)
      ;;
    1)
      print -u2 "[ERROR] Relay launchd job is not loaded: $SERVICE_TARGET"
      return 1
      ;;
    *)
      return 1
      ;;
  esac
  if ! verify_loaded_job_path; then
    return 1
  fi

  if ! collect_listener_pids; then
    print -u2 "[ERROR] Relay listener PID enumeration failed."
    return 1
  fi
  if (( ${#listener_pids[@]} != 1 )); then
    print_listener_error "Relay listener is not unique"
    return 1
  fi

  launchctl_pid="$(get_launchctl_pid)"
  if [[ "$launchctl_pid" != <-> ]]; then
    print -u2 "[ERROR] Relay listener PID is not reported by launchd for $SERVICE_TARGET."
    return 1
  fi
  if [[ "$launchctl_pid" != "${listener_pids[1]}" ]]; then
    print -u2 "[ERROR] Relay ownership mismatch: launchd PID=${launchctl_pid} listener PID=${listener_pids[1]}."
    return 1
  fi

  if ! /bin/zsh "$HEALTH_SCRIPT" --config "$CONFIG_PATH" --http-only >/dev/null 2>&1; then
    print -u2 "[ERROR] Relay HTTP health check failed; see ${CODEX_PROXY_RUNTIME_HOME}/relay.log"
    return 1
  fi
  return 0
}

wait_for_relay_after_action() {
  local previous_pid="$1"
  local current_pid
  local launchctl_pid
  local attempt

  for attempt in {1..80}; do
    if ! collect_listener_pids; then
      return 1
    fi
    if (( ${#listener_pids[@]} == 1 )); then
      current_pid="${listener_pids[1]}"
      launchctl_pid="$(get_launchctl_pid)"
      if [[ "$launchctl_pid" == <-> && "$launchctl_pid" == "$current_pid" \
          && ( -z "$previous_pid" || "$current_pid" != "$previous_pid" ) ]]; then
        return 0
      fi
    fi
    /bin/sleep 0.1
  done

  return 1
}

if ! verify_plist_identity; then
  exit 1
fi

typeset -i job_loaded=0
launchctl_job_status
launchctl_status=$?
case "$launchctl_status" in
  0)
    job_loaded=1
    if ! verify_loaded_job_path; then
      exit 1
    fi
    ;;
  1)
    job_loaded=0
    ;;
  *)
    exit 1
    ;;
esac

typeset -a listener_pids=()
if ! collect_listener_pids; then
  print -u2 "[ERROR] Relay listener PID enumeration failed; refusing to start or restart."
  exit 1
fi
typeset -i port_listening=0
if is_port_listening; then
  port_listening=1
fi

# A listener without this exact launchd label is never ours to restart.  This
# check also treats a lsof/nc disagreement as unsafe instead of guessing.
if (( job_loaded == 0 )); then
  if (( port_listening == 1 || ${#listener_pids[@]} > 0 )); then
    print_listener_error "Port ${PROXY_LISTEN_PORT} is occupied by an unknown or non-label listener"
    exit 1
  fi
else
  if (( ${#listener_pids[@]} > 1 )); then
    print_listener_error "Loaded relay job has multiple listeners"
    exit 1
  fi
  if (( port_listening == 1 && ${#listener_pids[@]} == 0 )); then
    print_listener_error "Port ${PROXY_LISTEN_PORT} is listening but its PID cannot be attributed"
    exit 1
  fi
  if (( port_listening == 0 && ${#listener_pids[@]} == 1 )); then
    print_listener_error "lsof found a listener that nc could not verify"
    exit 1
  fi
fi

if ! /usr/bin/nc -z "$UPSTREAM_HOST" "$UPSTREAM_PORT" >/dev/null 2>&1; then
  print -u2 "[ERROR] Upstream proxy is not listening on ${UPSTREAM_HOST}:${UPSTREAM_PORT}."
  exit 1
fi

if ! ensure_no_install_transaction; then
  exit 1
fi

if ! ensure_chatgpt_bundle_clear; then
  exit 1
fi

previous_listener_pid=""
if (( job_loaded == 1 )); then
  if (( ${#listener_pids[@]} == 1 )); then
    launchctl_pid="$(get_launchctl_pid)"
    if [[ "$launchctl_pid" != <-> || "$launchctl_pid" != "${listener_pids[1]}" ]]; then
      print -u2 "[ERROR] Relay ownership mismatch before kickstart: launchd PID=${launchctl_pid:-unknown} listener PID=${listener_pids[1]}."
      exit 1
    fi
    previous_listener_pid="${listener_pids[1]}"
  fi

  # This is the only controlled restart path.  It targets the exact label
  # after the on-disk identity check above, so a config edit takes effect while
  # an unrelated listener is never killed.
  if ! /bin/launchctl kickstart -k "$SERVICE_TARGET" >/dev/null 2>&1; then
    print -u2 "[ERROR] Failed to kickstart relay launchd job: $SERVICE_TARGET"
    exit 1
  fi
else
  if ! /bin/launchctl bootstrap "$LAUNCH_DOMAIN" "$RELAY_AGENT" >/dev/null 2>&1; then
    print -u2 "[ERROR] Failed to bootstrap relay LaunchAgent: $RELAY_AGENT"
    exit 1
  fi
fi

if ! ensure_no_install_transaction; then
  exit 1
fi

if ! wait_for_relay_after_action "$previous_listener_pid"; then
  print -u2 "[ERROR] Relay did not produce one new listener owned by $SERVICE_TARGET; see ${CODEX_PROXY_RUNTIME_HOME}/relay.log"
  exit 1
fi

if ! verify_active_relay; then
  exit 1
fi

print "[INFO] Relay is healthy at ${PROXY_LISTEN_HOST}:${PROXY_LISTEN_PORT}."
exit 0
