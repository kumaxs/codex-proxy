#!/bin/zsh

set -u
set -o pipefail
setopt extendedglob

readonly CODEX_PROXY_DEFAULT_HOME="${HOME}/Library/Application Support/Codex Proxy"
readonly CODEX_PROXY_CONFIG_FILENAME="codex-proxy.conf"
readonly CODEX_PROXY_RELAY_LABEL="io.github.kumaxs.codex-proxy-relay"
readonly -a CODEX_PROXY_REQUIRED_KEYS=(
  UPSTREAM_PROXY_URL
  LISTEN_HOST
  LISTEN_PORT
  MITMDUMP_PATH
  CHATGPT_APP_PATH
  PASSTHROUGH_REGEX
)
readonly -a CODEX_PROXY_ALLOWED_KEYS=(UPSTREAM_PROXY_URL LISTEN_HOST LISTEN_PORT MITMDUMP_PATH CHATGPT_APP_PATH PASSTHROUGH_REGEX)

CODEX_PROXY_HOME="${CODEX_PROXY_HOME:-$CODEX_PROXY_DEFAULT_HOME}"
CODEX_PROXY_RUNTIME_HOME=""
CODEX_PROXY_CONFIG_PATH=""
CODEX_PROXY_BIN_DIR=""
CODEX_PROXY_LIB_DIR=""
CODEX_PROXY_MITM_DIR=""

typeset -gA CODEX_PROXY_CFG
typeset -g CODEX_PROXY_UPSTREAM_PROXY_URL=""
typeset -g CODEX_PROXY_LISTEN_HOST=""
typeset -g CODEX_PROXY_LISTEN_HOST_FOR_BIND=""
typeset -g CODEX_PROXY_LISTEN_PORT=""
typeset -g CODEX_PROXY_MITMDUMP_PATH=""
typeset -g CODEX_PROXY_CHATGPT_APP_PATH=""
typeset -g CODEX_PROXY_PASSTHROUGH_REGEX=""
typeset -g CODEX_PROXY_UPSTREAM_HOST=""
typeset -g CODEX_PROXY_UPSTREAM_PORT=""
typeset -g CODEX_PROXY_RELAY_URL=""
typeset -g CODEX_PROXY_CA_CERT=""
typeset -g CODEX_PROXY_LOADED=0

codex_proxy_runtime_home() {
  print -r -- "$CODEX_PROXY_RUNTIME_HOME"
}

codex_proxy_config_path() {
  print -r -- "$CODEX_PROXY_CONFIG_PATH"
}

codex_proxy_init_runtime_paths() {
  # Keep the lexical path here.  `${path:A}` resolves symlinks before the
  # loader can inspect them, which would make an unsafe runtime root
  # indistinguishable from its target.  The path-chain validator below is
  # deliberately responsible for rejecting symlink components.
  CODEX_PROXY_RUNTIME_HOME="${CODEX_PROXY_HOME:a}"
  CODEX_PROXY_CONFIG_PATH="${CODEX_PROXY_RUNTIME_HOME}/config/${CODEX_PROXY_CONFIG_FILENAME}"
  CODEX_PROXY_BIN_DIR="${CODEX_PROXY_RUNTIME_HOME}/bin"
  CODEX_PROXY_LIB_DIR="${CODEX_PROXY_RUNTIME_HOME}/lib"
  CODEX_PROXY_MITM_DIR="${CODEX_PROXY_RUNTIME_HOME}/mitmproxy"
}

# macOS path hardening helpers.  Every existing component must be owned by the
# invoking user or root.  Current-user components may never be writable by
# group/other.  Root-owned *parent directories* may retain the common macOS
# 0775-style group write bit (but never other write); actual target files and
# directories remain private.  The only shared-directory exception is the
# standard root-owned sticky /private/tmp (with /tmp -> /private/tmp accepted
# as macOS's conventional alias).
codex_proxy_validate_path_component() {
  local target="$1"
  local is_final="${2:-0}"
  local owner mode mode_decimal

  [[ -e "$target" && ! -L "$target" ]] || return 1
  owner="$(/usr/bin/stat -f '%u' "$target" 2>/dev/null)" || return 1
  mode="$(/usr/bin/stat -f '%A' "$target" 2>/dev/null)" || return 1
  [[ "$owner" == <-> && "$mode" == <-> ]] || return 1
  mode_decimal=$((8#$mode))

  if [[ "$target" == "/private/tmp" || "$target" == "/tmp" ]] &&
      [[ -d "$target" ]] &&
      [[ "$owner" == "0" ]] && (( (mode_decimal & 512) != 0 )); then
    return 0
  fi

  if [[ "$owner" != "$(/usr/bin/id -u)" && "$owner" != "0" ]]; then
    return 1
  fi
  # Other write is never acceptable.  Group write on a root-owned directory
  # is tolerated only for a non-final parent component; this covers standard
  # system paths such as /Applications without weakening target-file checks.
  (( (mode_decimal & 2) == 0 )) || return 1
  if [[ "$owner" == "0" && "$is_final" != "1" && -d "$target" ]]; then
    return 0
  fi
  (( (mode_decimal & 16) == 0 ))
}

# Validate a lexical absolute path without resolving symlinks.  A missing
# final component may be allowed for relay's first-run mitmproxy directory;
# missing intermediate components are always rejected.
codex_proxy_validate_path_chain() {
  local target="${1:-}"
  local allow_missing_final="${2:-0}"
  local current component tmp_target
  local -i component_index=0 component_total=0
  local -a components nonempty_components

  [[ "$target" == /* ]] || return 1
  [[ "$target" != *"/../"* && "$target" != */.. &&
     "$target" != *"/./"* && "$target" != */. ]] || return 1

  # Splitting the lexical path lets us inspect a symlink component before the
  # kernel follows it.  Empty components are harmless duplicate separators.
  components=( ${(s:/:)target} )
  nonempty_components=()
  for component in "${components[@]}"; do
    [[ -n "$component" ]] && nonempty_components+=("$component")
  done
  component_total=${#nonempty_components[@]}
  current=""
  for component in "${nonempty_components[@]}"; do
    (( component_index++ ))
    if [[ -z "$current" ]]; then
      current="/${component}"
    else
      current="${current}/${component}"
    fi

    if [[ "$current" == "/tmp" && -L "$current" ]]; then
      tmp_target="$(/usr/bin/readlink "$current" 2>/dev/null)" || return 1
      [[ "$tmp_target" == "/private/tmp" || "$tmp_target" == "private/tmp" ]] || return 1
      current="/private/tmp"
    fi

    if [[ ! -e "$current" && ! -L "$current" ]]; then
      if (( component_index == component_total )) && [[ "$allow_missing_final" == "1" ]]; then
        return 0
      fi
      return 1
    fi
    if (( component_index == component_total )); then
      codex_proxy_validate_path_component "$current" 1 || return 1
    else
      codex_proxy_validate_path_component "$current" 0 || return 1
    fi
  done
  return 0
}

codex_proxy_validate_mitm_state() {
  local mitm_dir="$1"
  local path
  local -a sensitive_paths

  [[ -d "$mitm_dir" && ! -L "$mitm_dir" ]] || return 1

  # mitmproxy's CA material is created lazily.  Validate only entries that
  # are present, while rejecting both symlinked and unsafe existing CA/key
  # files.  The glob also covers version-specific names such as
  # mitmproxy-ca-cert.p12 and mitmproxy-ca-key.pem.
  sensitive_paths=( "$mitm_dir"/mitmproxy-ca*(N) )
  for path in "${sensitive_paths[@]}"; do
    [[ -e "$path" || -L "$path" ]] || continue
    if [[ -L "$path" || ! -f "$path" ]] || ! codex_proxy_validate_path_chain "$path"; then
      return 1
    fi
  done
  return 0
}

codex_proxy_assert_key() {
  local key="$1"
  local value="$2"

  case "$key" in
    UPSTREAM_PROXY_URL|LISTEN_HOST|LISTEN_PORT|MITMDUMP_PATH|CHATGPT_APP_PATH|PASSTHROUGH_REGEX)
      ;;
    *)
      print -u2 "Config parser: unsupported key '$key'. Allowed keys: ${(j:, :)CODEX_PROXY_ALLOWED_KEYS}."
      return 1
      ;;
  esac

  if [[ "$key" != "PASSTHROUGH_REGEX" && -z "$value" ]]; then
    print -u2 "Config parser: key '$key' must not be empty."
    return 1
  fi
}

codex_proxy_validate_http_url() {
  local value="$1"
  local authority no_scheme host port

  if [[ "$value" != http://* && "$value" != https://* ]]; then
    print -u2 "Config parser: UPSTREAM_PROXY_URL must be http://... or https://..."
    return 1
  fi

  no_scheme="${value#*://}"
  if [[ "$no_scheme" == *"/"* || "$no_scheme" == *"?"* || "$no_scheme" == *"#"* ]]; then
    print -u2 "Config parser: UPSTREAM_PROXY_URL must not contain path, query, or fragment."
    return 1
  fi

  authority="${no_scheme}"
  authority="${authority%%/*}"
  if [[ "$authority" == *"@"* ]]; then
    print -u2 "Config parser: UPSTREAM_PROXY_URL must not contain userinfo."
    return 1
  fi

  case "$authority" in
    \[*)
    host="${authority#\[}"
    host="${host%%\]*}"
    port="${authority##*]}"
    if [[ -n "$port" ]]; then
      if [[ "$port" != :* ]]; then
        print -u2 "Config parser: invalid IPv6 authority in UPSTREAM_PROXY_URL: '$value'"
        return 1
      fi
      port="${port#:}"
    fi
      ;;
  *)
    if [[ "$authority" == *:*:* ]]; then
      print -u2 "Config parser: invalid IPv6 authority in UPSTREAM_PROXY_URL: '$value'"
      return 1
    fi
    host="${authority%%:*}"
    if [[ "$host" == "$authority" ]]; then
      port=""
    else
      port="${authority##*:}"
    fi
      ;;
  esac

  if [[ -z "$host" ]]; then
    print -u2 "Config parser: UPSTREAM_PROXY_URL is missing host."
    return 1
  fi

  if [[ -z "$port" ]]; then
    if [[ "$value" == http://* ]]; then
      port=80
    else
      port=443
    fi
  fi

  if [[ ! "$port" == <-> ]] || (( port < 1 || port > 65535 )); then
    print -u2 "Config parser: invalid upstream port '$port'."
    return 1
  fi

  CODEX_PROXY_UPSTREAM_HOST="$host"
  CODEX_PROXY_UPSTREAM_PORT="$port"
  return 0
}

codex_proxy_validate_listen_host() {
  local host="$1"
  case "$host" in
    127.0.0.1|localhost|::1|\[::1\])
      return 0
      ;;
    *)
      print -u2 "Config parser: LISTEN_HOST must be loopback only (127.0.0.1, ::1, or localhost)."
      return 1
      ;;
  esac
}

codex_proxy_validate_port() {
  local value="$1"
  if [[ ! "$value" == <-> ]] || (( value < 1 || value > 65535 )); then
    print -u2 "Config parser: invalid LISTEN_PORT '$value'."
    return 1
  fi
  return 0
}

codex_proxy_validate_file() {
  local value="$1"
  if [[ ! "$value" == /* ]]; then
    print -u2 "Config parser: path must be absolute: '$value'"
    return 1
  fi
  if ! codex_proxy_validate_path_chain "$value"; then
    print -u2 "Config parser: path contains an unsafe symlink, owner, or mode component: '$value'"
    return 1
  fi
  if [[ ! -f "$value" ]]; then
    print -u2 "Config parser: regular executable file not found: '$value'"
    return 1
  fi
  if [[ ! -x "$value" ]]; then
    print -u2 "Config parser: executable not found: '$value'"
    return 1
  fi
  return 0
}

codex_proxy_validate_chatgpt_path() {
  local value="$1"
  if [[ "${value:t}" != "ChatGPT" ]]; then
    print -u2 "Config parser: CHATGPT_APP_PATH must point to /Contents/MacOS/ChatGPT"
    return 1
  fi

  if [[ "${value:h:t}" != "MacOS" || "${value:h:h:t}" != "Contents" ]]; then
    print -u2 "Config parser: CHATGPT_APP_PATH must point to /Contents/MacOS/ChatGPT"
    return 1
  fi

  if ! codex_proxy_validate_file "$value"; then
    print -u2 "Config parser: ChatGPT executable path is unsafe: '$value'"
    return 1
  fi

  local codex_helper="${value%/MacOS/ChatGPT}/Resources/codex"
  if ! codex_proxy_validate_path_chain "$codex_helper" ||
      [[ ! -f "$codex_helper" || ! -x "$codex_helper" ]]; then
    print -u2 "Config parser: Codex helper path is unsafe, missing, or not executable: '$codex_helper'."
    return 1
  fi
  return 0
}

codex_proxy_validate_passthrough() {
  local value="$1"
  if [[ -z "$value" ]]; then
    return 0
  fi
  local validate_rc
  /usr/bin/printf '%s\n' '' | /usr/bin/grep -E -q -- "$value" 2>/dev/null
  validate_rc=$?
  case "$validate_rc" in
    0|1)
      return 0
      ;;
    2)
      print -u2 "Config parser: PASSTHROUGH_REGEX is not a valid extended regular expression."
      return 1
      ;;
    *)
      print -u2 "Config parser: PASSTHROUGH_REGEX validation error."
      return 1
      ;;
  esac
  return 0
}

codex_proxy_parse_config_line() {
  local line="$1"
  local key value

  if [[ "$line" == \#* || "$line" == '' ]]; then
    return 0
  fi
  if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *'${'* ]]; then
    print -u2 "Config parser: command/code execution syntax is forbidden."
    return 1
  fi
  if [[ "$line" != *=* ]]; then
    print -u2 "Config parser: invalid assignment line: '$line'"
    return 1
  fi

  key="${line%%=*}"
  value="${line#*=}"

  if [[ "$key" == *[[:space:]]* ]]; then
    print -u2 "Config parser: whitespace is not allowed in key."
    return 1
  fi
  if [[ ! "$key" == [A-Z_][A-Z0-9_]# ]]; then
    print -u2 "Config parser: invalid key: '$key'"
    return 1
  fi

  if ! codex_proxy_assert_key "$key" "$value"; then
    return 1
  fi
  if [[ -n "${CODEX_PROXY_CFG[$key]+x}" ]]; then
    print -u2 "Config parser: duplicate key '$key'."
    return 1
  fi

  CODEX_PROXY_CFG[$key]="$value"
}

codex_proxy_validate_and_export() {
  local key

  for key in $CODEX_PROXY_REQUIRED_KEYS; do
    if [[ -z "${CODEX_PROXY_CFG[$key]+x}" ]]; then
      print -u2 "Config parser: required key '$key' missing."
      return 1
    fi
  done

  CODEX_PROXY_UPSTREAM_PROXY_URL="${CODEX_PROXY_CFG[UPSTREAM_PROXY_URL]}"
  CODEX_PROXY_LISTEN_HOST="${CODEX_PROXY_CFG[LISTEN_HOST]}"
  CODEX_PROXY_LISTEN_HOST_FOR_BIND="${CODEX_PROXY_LISTEN_HOST}"
  CODEX_PROXY_LISTEN_PORT="${CODEX_PROXY_CFG[LISTEN_PORT]}"
  CODEX_PROXY_MITMDUMP_PATH="${CODEX_PROXY_CFG[MITMDUMP_PATH]}"
  CODEX_PROXY_CHATGPT_APP_PATH="${CODEX_PROXY_CFG[CHATGPT_APP_PATH]}"
  CODEX_PROXY_PASSTHROUGH_REGEX="${CODEX_PROXY_CFG[PASSTHROUGH_REGEX]}"

  codex_proxy_validate_http_url "$CODEX_PROXY_UPSTREAM_PROXY_URL" || return 1
  codex_proxy_validate_listen_host "$CODEX_PROXY_LISTEN_HOST" || return 1
  codex_proxy_validate_port "$CODEX_PROXY_LISTEN_PORT" || return 1
  codex_proxy_validate_file "$CODEX_PROXY_MITMDUMP_PATH" || return 1
  codex_proxy_validate_chatgpt_path "$CODEX_PROXY_CHATGPT_APP_PATH" || return 1
  codex_proxy_validate_passthrough "$CODEX_PROXY_PASSTHROUGH_REGEX" || return 1

  if [[ "$CODEX_PROXY_LISTEN_HOST" == "[::1]" ]]; then
    CODEX_PROXY_LISTEN_HOST_FOR_BIND="::1"
  fi

  if [[ "$CODEX_PROXY_LISTEN_HOST_FOR_BIND" == "::1" ]]; then
    CODEX_PROXY_RELAY_URL="http://[::1]:${CODEX_PROXY_LISTEN_PORT}"
  elif [[ "$CODEX_PROXY_LISTEN_HOST" == *":"* && "$CODEX_PROXY_LISTEN_HOST" != "[::1]" ]]; then
    CODEX_PROXY_RELAY_URL="http://[${CODEX_PROXY_LISTEN_HOST}]:${CODEX_PROXY_LISTEN_PORT}"
  else
    CODEX_PROXY_RELAY_URL="http://${CODEX_PROXY_LISTEN_HOST}:${CODEX_PROXY_LISTEN_PORT}"
  fi
  CODEX_PROXY_CA_CERT="${CODEX_PROXY_MITM_DIR}/mitmproxy-ca-cert.pem"
  CODEX_PROXY_LOADED=1
  return 0
}

codex_proxy_load_config() {
  local config_file="${1:-$CODEX_PROXY_CONFIG_PATH}"
  codex_proxy_init_runtime_paths
  CODEX_PROXY_CFG=()
  CODEX_PROXY_LOADED=0

  if [[ -z "${config_file}" || "$config_file" != /* ||
        ! -f "$config_file" || ! -r "$config_file" ]] ||
      ! codex_proxy_validate_path_chain "$config_file"; then
    print -u2 "Config loader: cannot read config file '$config_file'."
    return 1
  fi

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    local trimmed="${line%$'\r'}"
    trimmed="${trimmed##[[:space:]]##}"
    trimmed="${trimmed%%[[:space:]]##}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    if ! codex_proxy_parse_config_line "$trimmed"; then
      return 1
    fi
  done < "$config_file"

  if ! codex_proxy_validate_and_export; then
    return 1
  fi
  return 0
}

codex_proxy_config_is_loaded() {
  [[ "$CODEX_PROXY_LOADED" == 1 ]]
}
