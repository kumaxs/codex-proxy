#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/../lib/config.sh"

proxy_url=""
ca_mode="file"
ca_file=""
run_codex_doctor=0
cfg_path=""
ca_option_provided=0
cfg_path_provided=0
readonly -a AMBIENT_PROXY_UNSET_ARGS=(
  -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy
  -u ALL_PROXY -u all_proxy -u NO_PROXY -u no_proxy
  -u FTP_PROXY -u ftp_proxy -u SOCKS_PROXY -u socks_proxy
  -u WS_PROXY -u ws_proxy -u WSS_PROXY -u wss_proxy
  -u GIT_PROXY_COMMAND -u GIT_HTTP_PROXY -u GIT_HTTPS_PROXY
  -u npm_config_proxy -u npm_config_https_proxy
)

tmp_dir="$(/usr/bin/mktemp -d -t openai-network-audit.XXXXXX)"
request_counter=0

trap '[[ -d "$tmp_dir" ]] && /bin/rm -rf "$tmp_dir"' EXIT INT TERM HUP

usage() {
  cat <<'EOF_USAGE'
Usage: openai-network-audit.sh [--config PATH] [--proxy-url URL] [--ca-file PATH | --system-ca] [--codex-doctor]

  --config PATH      Use config file fields for defaults
  --proxy-url URL    HTTP proxy URL (default from config; required when no config is available)
  --ca-file PATH     Use this CA certificate for HTTPS validation
  --system-ca        Use system trust store (no custom CA)
  --codex-doctor     Also run `codex doctor --json --no-color` after probes
EOF_USAGE
}

CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"

if (( $# > 0 )); then
  while (( $# > 0 )); do
    case "$1" in
      --config)
        if (( $# < 2 )); then
          usage
          exit 64
        fi
        cfg_path="$2"
        cfg_path_provided=1
        shift 2
        ;;
      --proxy-url)
        if (( $# < 2 )); then
          usage
          exit 64
        fi
        proxy_url="$2"
        shift 2
        ;;
      --ca-file)
        if (( $# < 2 )); then
          usage
          exit 64
        fi
        ca_mode="file"
        ca_file="$2"
        ca_option_provided=1
        shift 2
        ;;
      --system-ca)
        ca_mode="system"
        ca_option_provided=1
        shift
        ;;
      --codex-doctor)
        run_codex_doctor=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        print -u2 "Unknown argument: $1"
        usage
        exit 64
        ;;
    esac
  done
fi

if [[ -z "$cfg_path" ]]; then
  codex_proxy_init_runtime_paths
  cfg_path="$CODEX_PROXY_CONFIG_PATH"
fi

if [[ "$cfg_path" != "" && "$cfg_path" != /* ]]; then
  print -u2 "Invalid config path: $cfg_path"
  exit 64
fi

cfg_loaded=0
if [[ -f "$cfg_path" ]]; then
  if ! codex_proxy_load_config "$cfg_path"; then
    exit 1
  fi
  proxy_url="${proxy_url:-$CODEX_PROXY_RELAY_URL}"
  cfg_loaded=1
  if (( ca_option_provided == 0 )); then
    ca_file="${ca_file:-$CODEX_PROXY_CA_CERT}"
  fi
elif (( cfg_path_provided == 1 )); then
  print -u2 "Config file not found: $cfg_path"
  exit 64
fi

if (( cfg_loaded == 0 )); then
  if [[ -z "$proxy_url" ]]; then
    print -u2 "Missing --proxy-url: no config is available."
    exit 64
  fi
  if (( ca_option_provided == 0 )); then
    print -u2 "Missing CA mode: pass --ca-file <path> or --system-ca when no config is available."
    exit 64
  fi
  ca_file="${ca_file:-}"
fi

if (( run_codex_doctor == 1 && cfg_loaded != 1 )); then
  print -u2 "--codex-doctor requires successfully loaded config."
  exit 64
fi

if [[ -z "$proxy_url" || "$proxy_url" != *"://"* ]]; then
  print -u2 "Invalid proxy URL: $proxy_url"
  exit 64
fi

if [[ "$ca_mode" == "file" && -z "$ca_file" ]]; then
  print -u2 "Missing --ca-file path"
  exit 64
fi

validate_http_proxy_url() {
  local value="$1"
  local authority host port
  local no_scheme

  if [[ "$value" != http://* && "$value" != https://* ]]; then
    print -u2 "Invalid proxy URL scheme: $value"
    return 1
  fi

  no_scheme="${value#*://}"
  if [[ "$no_scheme" == *"/"* || "$no_scheme" == *"?"* || "$no_scheme" == *"#"* ]]; then
    print -u2 "Invalid proxy URL: must not contain path, query, or fragment."
    return 1
  fi

  authority="${value#*://}"
  if [[ "$authority" == *"@"* ]]; then
    print -u2 "Invalid proxy URL: userinfo is not allowed in '$value'."
    return 1
  fi

  if [[ "$authority" == \[* ]]; then
    host="${authority#\[}"
    host="${host%%\]*}"
    port="${authority##*]}"
    if [[ -n "$port" ]]; then
      if [[ "$port" != :* ]]; then
        print -u2 "Invalid proxy URL: malformed IPv6 authority in '$value'."
        return 1
      fi
      port="${port#:}"
    fi
  else
    if [[ "$authority" == *:*:* ]]; then
      print -u2 "Invalid proxy URL: malformed IPv6 authority in '$value'."
      return 1
    fi
    host="${authority%%:*}"
    if [[ "$host" != "$authority" ]]; then
      port="${authority##*:}"
    fi
  fi

  if [[ -z "$host" ]]; then
    print -u2 "Invalid proxy URL: missing host in '$value'."
    return 1
  fi

  if [[ -n "$port" ]]; then
    if [[ "$port" != <-> ]] || (( port < 1 || port > 65535 )); then
      print -u2 "Invalid proxy URL port in '$value'."
      return 1
    fi
  fi

  return 0
}

validate_absolute_path() {
  local value="$1"
  local label="$2"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if [[ "$value" != /* ]]; then
    print -u2 "Invalid ${label}: $value"
    return 1
  fi
  return 0
}

if ! validate_http_proxy_url "$proxy_url"; then
  exit 64
fi

if ! validate_absolute_path "$cfg_path" "config path"; then
  exit 64
fi

if [[ "$ca_mode" == "file" ]]; then
  if ! validate_absolute_path "$ca_file" "CA file"; then
    exit 64
  fi
  if [[ ! -r "$ca_file" ]]; then
    print -u2 "Cannot read CA file: $ca_file"
    exit 64
  fi
fi

host_of() {
  local url="$1"
  local no_scheme="${url#*://}"
  print -r -- "${no_scheme%%/*}"
}

next_tmp_file() {
  request_counter=$(( request_counter + 1 ))
  print -r -- "${tmp_dir}/request-${request_counter}.$1"
}

run_request() {
  local severity="$1"      # critical|advisory
  local check_type="$2"    # service|transport
  local mode="$3"          # https|ws
  local url="$4"
  local label="$5"

  local -a curl_args=(
    /usr/bin/curl
    --silent
    --show-error
    --connect-timeout 8
    --max-time 20
    --output /dev/null
    --proxy "$proxy_url"
    --noproxy ""
    --write-out "%{http_code}|%{content_type}|%{time_total}\n"
  )

  if [[ "$ca_mode" == "file" ]]; then
    curl_args+=(--cacert "$ca_file")
  fi

  if [[ "$mode" == "ws" ]]; then
    curl_args+=(--http1.1 --max-time 8)
    curl_args+=(
      -H "Upgrade: websocket"
      -H "Connection: Upgrade"
      -H "Sec-WebSocket-Version: 13"
      -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
      -H "Origin: https://chatgpt.com"
    )
  else
    curl_args+=(--head)
  fi

  local tmp_out tmp_err
  local curl_exit
  local content_type elapsed_secs elapsed_ms
  local decision="OK"

  tmp_out="$(next_tmp_file out)"
  tmp_err="$(next_tmp_file err)"
  : > "$tmp_out"
  : > "$tmp_err"

  set +e
  if [[ "$ca_mode" == "file" ]]; then
    /usr/bin/env \
      "${AMBIENT_PROXY_UNSET_ARGS[@]}" \
      -u CURL_CA_BUNDLE -u REQUESTS_CA_BUNDLE -u SSL_CERT_DIR -u AWS_CA_BUNDLE \
      -u NODE_OPTIONS \
      HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" \
      http_proxy="$proxy_url" https_proxy="$proxy_url" \
      CODEX_CA_CERTIFICATE="$ca_file" SSL_CERT_FILE="$ca_file" NODE_EXTRA_CA_CERTS="$ca_file" \
      "${curl_args[@]}" "$url" >"$tmp_out" 2>"$tmp_err"
  else
    /usr/bin/env \
      -u CODEX_CA_CERTIFICATE -u SSL_CERT_FILE -u NODE_EXTRA_CA_CERTS \
      "${AMBIENT_PROXY_UNSET_ARGS[@]}" \
      -u CURL_CA_BUNDLE -u REQUESTS_CA_BUNDLE -u SSL_CERT_DIR -u AWS_CA_BUNDLE \
      -u NODE_OPTIONS \
      HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" \
      http_proxy="$proxy_url" https_proxy="$proxy_url" \
      "${curl_args[@]}" "$url" >"$tmp_out" 2>"$tmp_err"
  fi
  curl_exit=$?
  set -e

  local host
  local http_code="N/A"
  local content_type="N/A"
  local elapsed_ms="N/A"

  if [[ -s "$tmp_out" ]]; then
    IFS="|" read -r http_code content_type elapsed_secs < "$tmp_out"
    http_code="${http_code:-N/A}"
    content_type="${content_type:-N/A}"
    elapsed_secs="${elapsed_secs:-N/A}"
    if [[ "$elapsed_secs" != "N/A" ]]; then
      elapsed_ms="$(/usr/bin/awk -v t="$elapsed_secs" 'BEGIN { printf "%.3f", t * 1000 }')"
    fi
  fi

  host="$(host_of "$url")"
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$host" "$curl_exit" "$http_code" "$content_type" "$elapsed_ms"

  if [[ "$mode" == "ws" && "$http_code" == "101" ]]; then
    return
  fi

  if (( curl_exit != 0 )) || [[ "$http_code" == "N/A" || "$http_code" == "000" ]]; then
    if [[ "$severity" == "critical" ]]; then
      print -u2 "[$severity][$label] transport/CURL failure (exit=$curl_exit)"
      return 1
    fi
    print -u2 "[$severity][$label] transport/CURL warning (exit=$curl_exit)"
    return 0
  fi

  if [[ "$mode" == "ws" ]]; then
    if [[ "$http_code" == "400" || "$http_code" == "401" || "$http_code" == "403" || "$http_code" == "404" ]]; then
      return
    fi
    print -u2 "[$severity][$label] websocket warning: HTTP $http_code"
    return 1
  fi

  if [[ "$severity" == "critical" && "$check_type" == "service" ]]; then
    if [[ "$http_code" == 5* || "$http_code" == "407" ]]; then
      print -u2 "[$severity][$label] service hard fail: HTTP $http_code"
      return 1
    fi
  fi
  return 0
}

run_codex_doctor_check() {
  local codex_binary
  codex_binary="$(codex_proxy_resolve_bundled_codex "$CODEX_PROXY_CHATGPT_APP_PATH")" || return 1

  local output_file error_file
  local doctor_exit
  output_file="$(next_tmp_file codex-doctor-output)"
  error_file="$(next_tmp_file codex-doctor-error)"
  : > "$output_file"
  : > "$error_file"

  set +e
  if [[ "$ca_mode" == "file" ]]; then
    /usr/bin/env \
      "${AMBIENT_PROXY_UNSET_ARGS[@]}" \
      -u CURL_CA_BUNDLE -u REQUESTS_CA_BUNDLE -u SSL_CERT_DIR -u AWS_CA_BUNDLE \
      -u NODE_OPTIONS \
      HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" \
      http_proxy="$proxy_url" https_proxy="$proxy_url" \
      NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1" \
      CODEX_CA_CERTIFICATE="$ca_file" SSL_CERT_FILE="$ca_file" NODE_EXTRA_CA_CERTS="$ca_file" \
      "$codex_binary" doctor --json --no-color >"$output_file" 2>"$error_file"
  else
    /usr/bin/env \
      -u CODEX_CA_CERTIFICATE -u SSL_CERT_FILE -u NODE_EXTRA_CA_CERTS \
      "${AMBIENT_PROXY_UNSET_ARGS[@]}" \
      -u CURL_CA_BUNDLE -u REQUESTS_CA_BUNDLE -u SSL_CERT_DIR -u AWS_CA_BUNDLE \
      -u NODE_OPTIONS \
      HTTP_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" \
      http_proxy="$proxy_url" https_proxy="$proxy_url" \
      NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1" \
      "$codex_binary" doctor --json --no-color >"$output_file" 2>"$error_file"
  fi
  doctor_exit=$?
  set -e

  if /usr/bin/grep -Fq '"handshake result": "HTTP 101 Switching Protocols"' "$output_file"; then
    if (( doctor_exit != 0 )); then
      print -u2 "codex doctor reached HTTP 101 but another check failed (exit $doctor_exit)"
      return 1
    fi
    print "codex doctor: websocket handshake observed as HTTP 101"
    return 0
  fi

  if (( doctor_exit != 0 )); then
    print -u2 "codex doctor exited with $doctor_exit before confirming HTTP 101"
    return 1
  fi

  if [[ "$ca_mode" == "system" ]]; then
    print -u2 "codex doctor did not report HTTP 101 while in --system-ca mode"
    return 1
  fi

  print "codex doctor: no HTTP 101 in output (advisory in --ca-file mode)"
  return 0
}

CRITICAL_SERVICE_CHECKS=(
  "chatgpt_backend|https://chatgpt.com/backend-api/"
  "developers|https://developers.openai.com/"
  "auth_setup|https://setup.auth.openai.com/"
)

CRITICAL_TRANSPORT_CHECKS=(
  "ws_chatgpt|https://ws.chatgpt.com/"
  "wham_remote|https://chatgpt.com/backend-api/wham/remote/control/server"
)

ADVISORY_CHECKS=(
  "chatgpt_root|https://chatgpt.com/"
  "openai_root|https://openai.com/"
  "openai_auth|https://auth.openai.com/"
  "auth0_openai|https://auth0.openai.com/"
  "chat_openai|https://chat.openai.com/"
)

hard_fail=0
warn_fail=0
ok_count=0

for check in "${CRITICAL_SERVICE_CHECKS[@]}"; do
  check_fields=("${(s:|:)check}")
  if ! run_request critical service https "${check_fields[2]}" "${check_fields[1]}"; then
    hard_fail=$(( hard_fail + 1 ))
  else
    ok_count=$(( ok_count + 1 ))
  fi
done

for check in "${CRITICAL_TRANSPORT_CHECKS[@]}"; do
  check_fields=("${(s:|:)check}")
  if ! run_request critical transport ws "${check_fields[2]}" "${check_fields[1]}"; then
    warn_fail=$(( warn_fail + 1 ))
  else
    ok_count=$(( ok_count + 1 ))
  fi
done

for check in "${ADVISORY_CHECKS[@]}"; do
  check_fields=("${(s:|:)check}")
  if ! run_request advisory transport https "${check_fields[2]}" "${check_fields[1]}"; then
    warn_fail=$(( warn_fail + 1 ))
  else
    ok_count=$(( ok_count + 1 ))
  fi
done

if (( run_codex_doctor == 1 )); then
  run_codex_doctor_check || hard_fail=$(( hard_fail + 1 ))
fi

print
print "Summary: ok=$ok_count hard_fail=$hard_fail warn=$warn_fail"
if (( hard_fail > 0 )); then
  exit 1
fi
if (( warn_fail > 0 )); then
  exit 2
fi
exit 0
