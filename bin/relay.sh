#!/bin/zsh

set -u
set -o pipefail
umask 077

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../lib/config.sh"

readonly CURRENT_UID="$(/usr/bin/id -u)"
readonly INSTALL_TRANSACTION_LOCK="/private/tmp/com.github.kumaxs.codex-proxy-install-${CURRENT_UID}.lock"
readonly INSTALL_TRANSACTION_OWNER="${INSTALL_TRANSACTION_LOCK}/owner-pid"

codex_proxy_private_lock_mode() {
  local target="$1"
  local mode mode_decimal

  mode="$(/usr/bin/stat -f '%A' "$target" 2>/dev/null)" || return 1
  [[ "$mode" == <-> ]] || return 1
  mode_decimal=$((8#$mode))
  # Installer lock directories/files are private (700/600).  Reject every
  # group/other permission bit, including read/execute—not only write.
  (( (mode_decimal & 63) == 0 && (mode_decimal & 07000) == 0 ))
}

codex_proxy_assert_no_install_transaction() {
  local raw lock_uid lock_pid active_uid entry
  local -a lock_entries

  if [[ ! -e "$INSTALL_TRANSACTION_LOCK" && ! -L "$INSTALL_TRANSACTION_LOCK" ]]; then
    return 0
  fi

  if [[ -L "$INSTALL_TRANSACTION_LOCK" || ! -d "$INSTALL_TRANSACTION_LOCK" ]] ||
      ! codex_proxy_validate_path_chain "$INSTALL_TRANSACTION_LOCK" ||
      ! codex_proxy_private_lock_mode "$INSTALL_TRANSACTION_LOCK"; then
    print -u2 "[ERROR] Install transaction lock path is unsafe; refusing relay start."
    return 1
  fi

  if [[ -L "$INSTALL_TRANSACTION_OWNER" || ! -f "$INSTALL_TRANSACTION_OWNER" ||
        ! -r "$INSTALL_TRANSACTION_OWNER" ]] ||
      ! codex_proxy_validate_path_chain "$INSTALL_TRANSACTION_OWNER" ||
      ! codex_proxy_private_lock_mode "$INSTALL_TRANSACTION_OWNER"; then
    print -u2 "[ERROR] Install transaction lock owner is unsafe; refusing relay start."
    return 1
  fi

  lock_entries=( "$INSTALL_TRANSACTION_LOCK"/*(N) "$INSTALL_TRANSACTION_LOCK"/.[!.]*(N) )
  for entry in "${lock_entries[@]}"; do
    [[ "${entry:t}" == "owner-pid" ]] || {
      print -u2 "[ERROR] Install transaction lock contains unexpected state; refusing relay start."
      return 1
    }
  done

  raw="$(/bin/cat "$INSTALL_TRANSACTION_OWNER" 2>/dev/null)" || {
    print -u2 "[ERROR] Install transaction lock owner is unreadable; refusing relay start."
    return 1
  }
  if [[ "$raw" != <->\ <-> ]]; then
    print -u2 "[ERROR] Install transaction lock owner is malformed; refusing relay start."
    return 1
  fi
  lock_uid="${raw%% *}"
  lock_pid="${raw#* }"
  if [[ "$lock_uid" != "$CURRENT_UID" ]]; then
    print -u2 "[ERROR] Install transaction lock owner UID is unexpected; refusing relay start."
    return 1
  fi

  active_uid="$(/bin/ps -p "$lock_pid" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
  if [[ -n "$active_uid" ]]; then
    if [[ "$active_uid" != "$lock_uid" ]]; then
      print -u2 "[ERROR] Install transaction lock owner PID has an unexpected UID; refusing relay start."
    else
      print -u2 "[ERROR] A Codex Proxy install transaction is active; refusing relay start."
    fi
    return 1
  fi

  # A valid-looking but stale lock is still an incomplete transaction.  Relay
  # never removes it; the installer/uninstaller recovery path owns cleanup.
  print -u2 "[ERROR] Install transaction lock exists but cannot be verified; refusing relay start."
  return 1
}

CONFIG_PATH=""
typeset -a ARGS=()

while (( $# > 0 )); do
  case "$1" in
    --config)
      [[ "${2:-}" != "" ]] || { print -u2 "[ERROR] --config requires a path."; exit 64 }
      CONFIG_PATH="$2"
      if [[ "$CONFIG_PATH" != /* ]]; then
        print -u2 "[ERROR] --config requires an absolute path."
        exit 64
      fi
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if ! codex_proxy_assert_no_install_transaction; then
  exit 1
fi

if [[ -z "$CONFIG_PATH" ]]; then
  CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"
  codex_proxy_init_runtime_paths
  CONFIG_PATH="$CODEX_PROXY_CONFIG_PATH"
fi

if ! codex_proxy_load_config "$CONFIG_PATH"; then
  exit 1
fi

if ! codex_proxy_validate_path_chain "$CODEX_PROXY_MITMDUMP_PATH" ||
    [[ ! -f "$CODEX_PROXY_MITMDUMP_PATH" || ! -x "$CODEX_PROXY_MITMDUMP_PATH" ]]; then
  print -u2 "[ERROR] mitmdump path is unsafe or not executable: $CODEX_PROXY_MITMDUMP_PATH"
  exit 1
fi

if ! codex_proxy_validate_path_chain "$CODEX_PROXY_MITM_DIR" 1; then
  print -u2 "[ERROR] mitm proxy directory path has an unsafe symlink, owner, or mode component: $CODEX_PROXY_MITM_DIR"
  exit 1
fi
if [[ -L "$CODEX_PROXY_MITM_DIR" ||
      ( -e "$CODEX_PROXY_MITM_DIR" && ! -d "$CODEX_PROXY_MITM_DIR" ) ]]; then
  print -u2 "[ERROR] mitm proxy path exists but is not a directory: $CODEX_PROXY_MITM_DIR"
  exit 1
fi
if [[ ! -e "$CODEX_PROXY_MITM_DIR" ]]; then
  # The runtime home and its parent have already been checked.  Creating only
  # the final component avoids mkdir -p traversing a path that changed after
  # validation; the post-create validation below closes that race fail-closed.
  /bin/mkdir "$CODEX_PROXY_MITM_DIR" || exit 1
fi
if ! codex_proxy_validate_path_chain "$CODEX_PROXY_MITM_DIR" ||
    ! codex_proxy_validate_mitm_state "$CODEX_PROXY_MITM_DIR"; then
  print -u2 "[ERROR] mitm proxy directory or CA/key state is unsafe: $CODEX_PROXY_MITM_DIR"
  exit 1
fi

/bin/chmod 700 "$CODEX_PROXY_MITM_DIR" || exit 1
if ! codex_proxy_validate_mitm_state "$CODEX_PROXY_MITM_DIR"; then
  print -u2 "[ERROR] mitm proxy CA/key state is unsafe: $CODEX_PROXY_MITM_DIR"
  exit 1
fi

typeset -a mitmdump_args=(
  --quiet
  --mode
  "upstream:${CODEX_PROXY_UPSTREAM_PROXY_URL}"
  --listen-host
  "$CODEX_PROXY_LISTEN_HOST_FOR_BIND"
  --listen-port
  "$CODEX_PROXY_LISTEN_PORT"
  --set
  "confdir=${CODEX_PROXY_MITM_DIR}"
  --set
  "http2=true"
  --set
  "http3=false"
  --set
  "http2_ping_keepalive=10"
  --set
  "connection_strategy=lazy"
  --set
  "tcp_timeout=900"
  --set
  "termlog_verbosity=warn"
  --set
  "flow_detail=0"
)

if [[ -n "$CODEX_PROXY_PASSTHROUGH_REGEX" ]]; then
  mitmdump_args+=(--ignore-hosts "$CODEX_PROXY_PASSTHROUGH_REGEX")
fi

if ! codex_proxy_assert_no_install_transaction; then
  exit 1
fi

# The relay must never inherit a user's ambient proxy/bypass settings.  Keep
# the custom test hook (if present) intact while removing common HTTP,
# SOCKS/WebSocket, Git, npm, and bypass-variable variants.
exec /usr/bin/env \
  -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy \
  -u FTP_PROXY -u ftp_proxy -u SOCKS_PROXY -u socks_proxy \
  -u WS_PROXY -u ws_proxy -u WSS_PROXY -u wss_proxy \
  -u GIT_PROXY_COMMAND -u GIT_HTTP_PROXY -u GIT_HTTPS_PROXY \
  -u npm_config_proxy -u npm_config_https_proxy \
  "$CODEX_PROXY_MITMDUMP_PATH" "${mitmdump_args[@]}" "${ARGS[@]}"
