#!/bin/zsh

# Launch the installed Antigravity Electron app through the existing Codex Proxy.
# Browser/Chromium traffic uses the configured upstream directly; background
# HTTP(S) clients use the existing loopback relay. This does not modify the app
# bundle, macOS system proxy, or system trust store.

set -u
set -o pipefail
umask 077

readonly SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/../lib/config.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: launch-antigravity-proxied.sh [--config PATH] [--status]
  Default action launches Antigravity with browser and background traffic proxied.
  --config PATH  Use the existing Codex Proxy config file.
  --status       Check configured proxy listeners and Antigravity process state.
EOF_USAGE
}

log_info() { print -r -- "[INFO] $*"; }
log_error() { print -u2 -r -- "[ERROR] $*"; }

CONFIG_PATH=""
ACTION="launch"

while (( $# > 0 )); do
  case "$1" in
    --config)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { log_error "--config requires a path."; exit 64; }
      CONFIG_PATH="$2"
      shift 2
      ;;
    --status)
      [[ "$ACTION" == "launch" ]] || { log_error "Only one action may be selected."; exit 64; }
      ACTION="status"
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$CONFIG_PATH" ]]; then
  codex_proxy_init_runtime_paths
  CONFIG_PATH="$CODEX_PROXY_CONFIG_PATH"
fi
codex_proxy_load_config "$CONFIG_PATH" || exit 1

readonly APP_PATH="/Applications/Antigravity.app"
readonly APP_EXECUTABLE="${APP_PATH}/Contents/MacOS/Antigravity"
readonly UPSTREAM_URL="$CODEX_PROXY_UPSTREAM_PROXY_URL"
readonly RELAY_URL="$CODEX_PROXY_RELAY_URL"
readonly UPSTREAM_HOST="$CODEX_PROXY_UPSTREAM_HOST"
readonly UPSTREAM_PORT="$CODEX_PROXY_UPSTREAM_PORT"
readonly RELAY_HOST="$CODEX_PROXY_LISTEN_HOST_FOR_BIND"
readonly RELAY_PORT="$CODEX_PROXY_LISTEN_PORT"
readonly NO_PROXY_VALUE="localhost,127.0.0.1,::1"
RELAY_CA=""

is_running() {
  /usr/bin/pgrep -f '^/Applications/Antigravity.app/Contents/MacOS/Antigravity([[:space:]]|$)' >/dev/null 2>&1
}

check_listeners() {
  if ! /usr/bin/nc -z "$UPSTREAM_HOST" "$UPSTREAM_PORT" >/dev/null 2>&1; then
    log_error "Upstream proxy ${UPSTREAM_HOST}:${UPSTREAM_PORT} is not listening. Start the existing upstream proxy first."
    return 1
  fi
  if ! /usr/bin/nc -z "$RELAY_HOST" "$RELAY_PORT" >/dev/null 2>&1; then
    log_error "Codex Proxy relay ${RELAY_HOST}:${RELAY_PORT} is not listening. Start it with the existing start-relay.sh first."
    return 1
  fi
  return 0
}

case "$ACTION" in
  status)
    check_listeners || exit 1
    log_info "Upstream ${UPSTREAM_HOST}:${UPSTREAM_PORT} is listening."
    log_info "Codex Proxy relay ${RELAY_HOST}:${RELAY_PORT} is listening."
    if is_running; then
      MAIN_PID="$(/usr/bin/pgrep -f '^/Applications/Antigravity.app/Contents/MacOS/Antigravity([[:space:]]|$)' | /usr/bin/head -n 1)"
      MAIN_COMMAND="$(/bin/ps -p "$MAIN_PID" -o command= 2>/dev/null)"
      MAIN_ENV="$(/bin/ps eww -p "$MAIN_PID" -o command= 2>/dev/null)"
      if [[ "$MAIN_COMMAND" == *"--proxy-server=${UPSTREAM_URL}"* &&
            "$MAIN_ENV" == *"HTTP_PROXY=${RELAY_URL}"* &&
            "$MAIN_ENV" == *"HTTPS_PROXY=${RELAY_URL}"* &&
            "$MAIN_ENV" == *"NODE_USE_ENV_PROXY=1"* ]]; then
        log_info "Antigravity PID $MAIN_PID has the expected browser and Node proxy settings."
      else
        log_error "Antigravity is running, but its proxy settings could not be verified. Quit it and relaunch with this script."
        exit 1
      fi
    else
      log_info "Antigravity is not running."
    fi
    exit 0
    ;;
  launch) ;;
esac

[[ -x "$APP_EXECUTABLE" ]] || { log_error "Antigravity executable not found at ${APP_EXECUTABLE}."; exit 1; }
if is_running; then
  log_error "Antigravity is already running. Quit it completely, then relaunch using this script; reusing an existing Electron process cannot reliably apply proxy settings."
  exit 1
fi
check_listeners || exit 1
RELAY_CA="$(codex_proxy_effective_ca)" || { log_error "Could not resolve the appropriate TLS trust bundle."; exit 1; }
[[ -r "$RELAY_CA" ]] || { log_error "TLS trust bundle is not readable: ${RELAY_CA}"; exit 1; }

# No proxy fallback: if the required existing local services are unavailable,
# refuse to launch rather than silently starting an unproxied application.
log_info "Launching Antigravity ${APP_PATH} with Chromium upstream ${UPSTREAM_URL} and background relay ${RELAY_URL}."
/usr/bin/nohup /usr/bin/env \
  -u ALL_PROXY -u all_proxy \
  -u FTP_PROXY -u ftp_proxy \
  -u SOCKS_PROXY -u socks_proxy \
  -u WS_PROXY -u ws_proxy -u WSS_PROXY -u wss_proxy \
  -u NODE_OPTIONS -u NODE_USE_ENV_PROXY -u CODEX_NODE_HTTPS_PROXY \
  -u GIT_PROXY_COMMAND -u GIT_HTTP_PROXY -u GIT_HTTPS_PROXY \
  -u npm_config_proxy -u npm_config_https_proxy \
  HTTP_PROXY="$RELAY_URL" \
  HTTPS_PROXY="$RELAY_URL" \
  http_proxy="$RELAY_URL" \
  https_proxy="$RELAY_URL" \
  NODE_USE_ENV_PROXY=1 \
  NODE_EXTRA_CA_CERTS="$RELAY_CA" \
  SSL_CERT_FILE="$RELAY_CA" \
  CODEX_CA_CERTIFICATE="$RELAY_CA" \
  NO_PROXY="$NO_PROXY_VALUE" \
  no_proxy="$NO_PROXY_VALUE" \
  "$APP_EXECUTABLE" "--proxy-server=$UPSTREAM_URL" >> "${CODEX_PROXY_RUNTIME_HOME}/antigravity-launcher.log" 2>&1 </dev/null &

sleep 2
if ! is_running; then
  log_error "Antigravity did not remain running after launch. Check ${CODEX_PROXY_RUNTIME_HOME}/antigravity-launcher.log."
  exit 1
fi

MAIN_PID="$(/usr/bin/pgrep -f '^/Applications/Antigravity.app/Contents/MacOS/Antigravity([[:space:]]|$)' | /usr/bin/head -n 1)"
MAIN_COMMAND="$(/bin/ps -p "$MAIN_PID" -o command= 2>/dev/null)"
if [[ "$MAIN_COMMAND" != *"--proxy-server=${UPSTREAM_URL}"* ]]; then
  log_error "Antigravity main process is running without the expected Chromium proxy argument. Proxy status is unverified."
  exit 1
fi
MAIN_ENV="$(/bin/ps eww -p "$MAIN_PID" -o command= 2>/dev/null)"
if [[ "$MAIN_ENV" != *"HTTP_PROXY=${RELAY_URL}"* ||
      "$MAIN_ENV" != *"HTTPS_PROXY=${RELAY_URL}"* ||
      "$MAIN_ENV" != *"NODE_USE_ENV_PROXY=1"* ]]; then
  log_error "Antigravity main process does not expose the expected Node proxy environment. Proxy status is unverified."
  exit 1
fi
log_info "Antigravity main process PID $MAIN_PID has the configured Chromium proxy argument and Node proxy environment."
log_info "Background proxy sockets must be confirmed during real Agent requests; status does not guarantee every component honors the proxy."
exit 0
