#!/bin/zsh

set -u
set -o pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../lib/config.sh"

usage() {
  print -u2 "Usage: $0 [--config PATH] [--http-only|--full]"
}

CHECK_MODE="--full"
typeset -gi mode_seen=0
if (( $# > 0 )); then
  while (( $# > 0 )); do
    case "$1" in
      --config)
        if [[ -z "${2:-}" ]]; then
          print -u2 "[ERROR] --config requires a path."
          exit 64
        fi
        CONFIG_PATH="$2"
        if [[ "$CONFIG_PATH" != /* ]]; then
          print -u2 "[ERROR] --config requires an absolute path."
          exit 64
        fi
        shift 2
        ;;
      --http-only|--full)
        if (( mode_seen == 1 )); then
          print -u2 "[ERROR] health mode provided more than once."
          exit 64
        fi
        CHECK_MODE="$1"
        mode_seen=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        if (( $# > 0 )); then
          usage
          exit 64
        fi
        break
        ;;
      --*)
        usage
        exit 64
        ;;
      *)
        usage
        exit 64
        ;;
    esac
  done
fi

if [[ -z "${CONFIG_PATH:-}" ]]; then
  CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"
  codex_proxy_init_runtime_paths
  CONFIG_PATH="$CODEX_PROXY_CONFIG_PATH"
fi

if ! codex_proxy_load_config "$CONFIG_PATH"; then
  exit 1
fi

readonly RELAY_URL="$CODEX_PROXY_RELAY_URL"
readonly RELAY_HOST="${CODEX_PROXY_LISTEN_HOST}"
readonly RELAY_PORT="${CODEX_PROXY_LISTEN_PORT}"
readonly UPSTREAM_HOST="$CODEX_PROXY_UPSTREAM_HOST"
readonly UPSTREAM_PORT="$CODEX_PROXY_UPSTREAM_PORT"
readonly RELAY_CA="$CODEX_PROXY_CA_CERT"
CODEX_BINARY="$(codex_proxy_resolve_bundled_codex "$CODEX_PROXY_CHATGPT_APP_PATH")" || exit 1
readonly CODEX_BINARY
readonly NO_PROXY_VALUE="localhost,127.0.0.1,::1"
readonly -a AMBIENT_PROXY_UNSET_ARGS=(
  -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy
  -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy
  -u FTP_PROXY -u ftp_proxy -u SOCKS_PROXY -u socks_proxy
  -u WS_PROXY -u ws_proxy -u WSS_PROXY -u wss_proxy
  -u GIT_PROXY_COMMAND -u GIT_HTTP_PROXY -u GIT_HTTPS_PROXY
  -u npm_config_proxy -u npm_config_https_proxy
)

probe_http_code() {
  local target_url="$1"
  local code
  local rc

  set +e
  code="$(/usr/bin/env "${AMBIENT_PROXY_UNSET_ARGS[@]}" /usr/bin/curl \
    --proxy "$RELAY_URL" \
    --noproxy "" \
    --cacert "$RELAY_CA" \
    --connect-timeout 8 \
    --max-time 20 \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out "%{http_code}" \
    "$target_url")"
  rc=$?
  set -e

  print "$rc $code"
}

classify_status() {
  local target="$1"
  local code="$2"
  local rc="$3"

  if [[ "$code" == "000" ]]; then
    print -u2 "Layer \"$target\" is unreachable through relay (curl_http_code=$code)."
    return 1
  fi

  if (( rc != 0 )); then
    print -u2 "Layer \"$target\" failed due to curl transport error (exit=$rc, curl_http_code=$code)."
    return 1
  fi

  case "$code" in
    2[0-9][0-9]|3[0-9][0-9]|4[0-9][0-9])
      print "Layer \"$target\" reachable (HTTP $code)."
      return 0
      ;;
    5[0-9][0-9])
      print -u2 "Layer \"$target\" returned server error HTTP $code."
      return 1
      ;;
    *)
      print -u2 "Layer \"$target\" returned unexpected HTTP $code."
      return 1
      ;;
  esac
}

probe_websocket_upgrade() {
  local target="$1"
  local target_url="$2"
  local code
  local rc

  set +e
  code="$(/usr/bin/env "${AMBIENT_PROXY_UNSET_ARGS[@]}" /usr/bin/curl \
    --request GET \
    --proxy "$RELAY_URL" \
    --noproxy "" \
    --cacert "$RELAY_CA" \
    --connect-timeout 8 \
    --max-time 20 \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out "%{http_code}" \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    --http1.1 \
    "$target_url")"
  rc=$?
  set -e

  if [[ "$code" == "101" ]]; then
    print "Layer \"$target\" accepted WebSocket Upgrade (HTTP 101)."
    return 0
  fi

  if (( rc != 0 )) || [[ "$code" == "000" ]]; then
    print -u2 "Layer \"$target\" failed due to curl transport error (exit=$rc, curl_http_code=$code)."
    return 1
  fi

  case "$code" in
    400|401|403|404)
      print "Layer \"$target\" reached the unauthenticated WebSocket surface (HTTP $code)."
      return 0
      ;;
    *)
      print -u2 "Layer \"$target\" returned unexpected WebSocket probe status HTTP $code."
      return 1
      ;;
  esac
}

if ! /usr/bin/nc -z "$UPSTREAM_HOST" "$UPSTREAM_PORT" >/dev/null 2>&1; then
  print -u2 "Upstream HTTP proxy is not listening on ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
  exit 1
fi

if ! /usr/bin/nc -z "$RELAY_HOST" "$RELAY_PORT" >/dev/null 2>&1; then
  print -u2 "Codex relay is not listening on ${RELAY_HOST}:${RELAY_PORT}"
  exit 1
fi

if [[ ! -r "$RELAY_CA" ]]; then
  print -u2 "Codex relay CA is not readable: $RELAY_CA"
  exit 1
fi

set +e
http_probe="$(probe_http_code "https://chatgpt.com/backend-api/")"
http_probe_fields=("${(z)http_probe}")
http_rc="${http_probe_fields[1]:-999}"
http_code="${http_probe_fields[2]:-000}"
set -e

if ! classify_status "https://chatgpt.com/backend-api/" "$http_code" "$http_rc"; then
  exit 1
fi

print "HTTPS relay check passed (HTTP $http_code)."

if [[ "$CHECK_MODE" == "--http-only" ]]; then
  exit 0
fi

if [[ ! -x "$CODEX_BINARY" ]]; then
  print -u2 "Bundled Codex binary is missing: $CODEX_BINARY"
  exit 2
fi

tmp_json=""
tmp_stderr=""
cleanup_health_temp() {
  [[ -n "$tmp_json" ]] && /bin/rm -f -- "$tmp_json"
  [[ -n "$tmp_stderr" ]] && /bin/rm -f -- "$tmp_stderr"
}
trap cleanup_health_temp EXIT INT TERM HUP
tmp_json="$(/usr/bin/mktemp -t codex-proxy-doctor.json)"
tmp_stderr="$(/usr/bin/mktemp -t codex-proxy-doctor.stderr)"

set +e
/usr/bin/env \
  "${AMBIENT_PROXY_UNSET_ARGS[@]}" \
  HTTP_PROXY="$RELAY_URL" \
  HTTPS_PROXY="$RELAY_URL" \
  http_proxy="$RELAY_URL" \
  https_proxy="$RELAY_URL" \
  NO_PROXY="$NO_PROXY_VALUE" \
  no_proxy="$NO_PROXY_VALUE" \
  CODEX_CA_CERTIFICATE="$RELAY_CA" \
  SSL_CERT_FILE="$RELAY_CA" \
  NODE_EXTRA_CA_CERTS="$RELAY_CA" \
  TERM=xterm-256color \
  "$CODEX_BINARY" doctor --json --no-color >"$tmp_json" 2>"$tmp_stderr"
doctor_rc=$?
set -e

if /usr/bin/grep -Fq '"handshake result": "HTTP 101 Switching Protocols"' "$tmp_json" && (( doctor_rc == 0 )); then
  print "Codex WebSocket handshake passed (HTTP 101)."
elif /usr/bin/grep -Fq '"handshake result": "HTTP 101 Switching Protocols"' "$tmp_json"; then
  print -u2 "Codex doctor reached WebSocket HTTP 101 but reported another failed check (exit $doctor_rc)."
else
  print -u2 "Codex doctor did not confirm a WebSocket HTTP 101 handshake (exit $doctor_rc). HTTPS fallback remains available."
fi

if ! /usr/bin/grep -Fq '"handshake result": "HTTP 101 Switching Protocols"' "$tmp_json" || (( doctor_rc != 0 )); then
doctor_ok=1
else
doctor_ok=0
fi

websocket_checks_ok=0
if ! probe_websocket_upgrade "ws.chatgpt.com" "https://ws.chatgpt.com/" ; then websocket_checks_ok=1; fi
if ! probe_websocket_upgrade "chatgpt.com root" "https://chatgpt.com/" ; then websocket_checks_ok=1; fi
if ! probe_websocket_upgrade "remote-control" "https://chatgpt.com/backend-api/wham/remote/control/server" ; then websocket_checks_ok=1; fi

if (( doctor_ok != 0 || websocket_checks_ok != 0 )); then
  exit 2
fi

print "WebSocket reachability checks passed (http/https paths and remote-control tunnel endpoints)."
exit 0
