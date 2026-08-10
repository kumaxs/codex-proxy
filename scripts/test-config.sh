#!/bin/zsh

set -u
set -o pipefail

LIB_DIR="${0:A:h}/../lib"
SCRIPT_DIR="${0:A:h}"
export SCRIPT_DIR
source "$LIB_DIR/config.sh"

# Keep every fixture registered globally so assertion failures (which exit the
# shell immediately) cannot bypass cleanup.  Each entry is an exact mktemp
# path created by this test; no broad parent directory is ever removed.
typeset -ga CODEX_PROXY_TEST_TEMP_ROOTS=()
typeset -ga CODEX_PROXY_TEST_TEMP_LOCKS=()

assert_pass() {
  print "[PASS] $1"
}

assert_fail() {
  print -u2 "[FAIL] $1"
  exit 1
}

mk_runtime_root() {
  local base
  # Keep fixtures under /private/tmp so the path-chain tests exercise the
  # explicit macOS /tmp -> /private/tmp sticky-directory exception instead of
  # traversing /var (itself a platform symlink).
  base="$(mktemp -d /private/tmp/codex-proxy-config-test.XXXXXX)"
  print -r -- "$base"
}

prepare_fake_install() {
  local root="$1"

  mkdir -p "$root/usr/bin" \
    "$root/Applications/ChatGPT.app/Contents/MacOS" \
    "$root/Applications/ChatGPT.app/Contents/Resources"

  touch "$root/usr/bin/mitmdump"
  chmod +x "$root/usr/bin/mitmdump"

  touch "$root/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
  chmod +x "$root/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
  touch "$root/Applications/ChatGPT.app/Contents/Resources/codex"
  chmod +x "$root/Applications/ChatGPT.app/Contents/Resources/codex"
}

write_config() {
  local file="$1" root="$2" upstream="$3" listen_host="$4" passthrough="$5"
  local mitmdump_path="${6:-${root}/usr/bin/mitmdump}"
  local chatgpt_path="${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

  cat > "$file" <<EOF_CONFIG
UPSTREAM_PROXY_URL=${upstream}
LISTEN_HOST=${listen_host}
LISTEN_PORT=29759
MITMDUMP_PATH=${mitmdump_path}
CHATGPT_APP_PATH=${chatgpt_path}
PASSTHROUGH_REGEX=${passthrough}
EOF_CONFIG
}

run_expect_success() {
  local label="$1" cfg="$2" home="$3"
  CODEX_PROXY_HOME="$home"
  codex_proxy_load_config "$cfg" || return 1
  assert_pass "$label"
}

run_expect_fail() {
  local label="$1" cfg="$2"
  CODEX_PROXY_HOME="${cfg:h}"
  if codex_proxy_load_config "$cfg" >/dev/null 2>&1; then
    return 1
  fi
  assert_pass "$label"
  return 0
}

run_command_expect_fail() {
  local label="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    assert_fail "$label"
    return 1
  fi
  assert_pass "$label"
  return 0
}

run_command_expect_success() {
  local label="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    assert_pass "$label"
    return 0
  fi
  assert_fail "$label"
  return 1
}

run_snippet() {
  local label="$1"
  local snippet="$2"

  if /bin/zsh -c "$snippet"; then
    assert_pass "$label"
    return 0
  fi
  assert_fail "$label"
  return 1
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [[ "$actual" != "$expected" ]]; then
    assert_fail "$label"
    return 1
  fi
  assert_pass "$label"
  return 0
}

cleanup() {
  local path
  for path in "${CODEX_PROXY_TEST_TEMP_ROOTS[@]}"; do
    if [[ -n "$path" && ( -e "$path" || -L "$path" ) ]]; then
      /bin/rm -rf -- "$path"
    fi
  done
  for path in "${CODEX_PROXY_TEST_TEMP_LOCKS[@]}"; do
    if [[ -n "$path" && ( -e "$path" || -L "$path" ) ]]; then
      # An unsafe-lock fixture may deliberately remove directory execute
      # permission.  Restore just this test-owned lock's private modes before
      # recursive cleanup so EXIT/INT/TERM/HUP traps cannot strand it.
      if [[ -d "$path" && ! -L "$path" ]]; then
        /bin/chmod 700 "$path" 2>/dev/null || true
        if [[ -f "$path/owner-pid" && ! -L "$path/owner-pid" ]]; then
          /bin/chmod 600 "$path/owner-pid" 2>/dev/null || true
        fi
      fi
      /bin/rm -rf -- "$path"
    fi
  done
  CODEX_PROXY_TEST_TEMP_ROOTS=()
  CODEX_PROXY_TEST_TEMP_LOCKS=()
}

trap cleanup EXIT INT TERM HUP

main() {
  local root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  local cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""
  run_expect_success "accept legal default ChatGPT path" "$cfg" "$root" || assert_fail "default ChatGPT path was rejected"
  run_snippet "allow root-owned group-write system parent when available" \
    'source "$SCRIPT_DIR/../lib/config.sh"; owner="$(/usr/bin/stat -f "%u" /Applications 2>/dev/null || true)"; mode="$(/usr/bin/stat -f "%A" /Applications 2>/dev/null || true)"; if [[ "$owner" == 0 && "$mode" == <-> ]] && (( (8#$mode & 16) != 0 && (8#$mode & 2) == 0 )); then codex_proxy_validate_path_component /Applications 0; else true; fi'

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  local symlink_target="${root}/real-codex-proxy.conf"
  write_config "$symlink_target" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""
  /bin/ln -s "$symlink_target" "$cfg"
  run_expect_fail "reject config file symlink" "$cfg" || assert_fail "config file symlink was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""
  /bin/chmod 664 "$cfg"
  run_expect_fail "reject group-write config file" "$cfg" || assert_fail "group-write config file was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  local unsafe_parent="${root}/unsafe-parent"
  cfg="${unsafe_parent}/codex-proxy.conf"
  /bin/mkdir -p "$unsafe_parent"
  prepare_fake_install "$unsafe_parent"
  write_config "$cfg" "$unsafe_parent" "http://127.0.0.1:29758" "127.0.0.1" ""
  /bin/chmod 775 "$unsafe_parent"
  run_expect_fail "reject group-write config parent" "$cfg" || assert_fail "group-write config parent was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  local executable_link="${root}/usr/bin/mitmdump-link"
  /bin/ln -s "${root}/usr/bin/mitmdump" "$executable_link"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" "" "$executable_link"
  run_expect_fail "reject mitmdump executable symlink" "$cfg" || assert_fail "mitmdump executable symlink was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  /bin/chmod 666 "${root}/usr/bin/mitmdump"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""
  run_expect_fail "reject unsafe mitmdump executable mode" "$cfg" || assert_fail "unsafe mitmdump executable mode was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  /bin/rm -f "${root}/Applications/ChatGPT.app/Contents/Resources/codex"
  /bin/ln -s "${root}/usr/bin/mitmdump" "${root}/Applications/ChatGPT.app/Contents/Resources/codex"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""
  run_expect_fail "reject ChatGPT Codex helper symlink" "$cfg" || assert_fail "ChatGPT Codex helper symlink was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  /bin/chmod 600 "${root}/Applications/ChatGPT.app/Contents/Resources/codex"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""
  run_expect_fail "reject non-executable ChatGPT Codex helper" "$cfg" || assert_fail "non-executable ChatGPT Codex helper was accepted"

  local root_install="${root}/install"
  local root_spaced="${root}/Config Home With Space"
  local cfg_spaced="${root_spaced}/codex-proxy.conf"
  mkdir -p "$root_install" "$root_spaced"
  prepare_fake_install "$root_install"
  prepare_fake_install "$root_spaced"
  write_config "$cfg_spaced" "$root_install" "http://127.0.0.1:29758" "127.0.0.1" ""
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root_install" "$root_spaced")
  run_expect_success "valid config with spaced runtime home" "$cfg_spaced" "$root_spaced" || assert_fail "spaced runtime home config unexpectedly failed"

  local root_spaced_value="${root}/Config Home With Space/With Real Space"
  local cfg_spaced_value="${root_spaced_value}/codex-proxy.conf"
  local mitm_path="${root_spaced_value}/usr/bin/mitmdump"
  local app_path="${root_spaced_value}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
  mkdir -p "${root_spaced_value}/usr/bin" "${root_spaced_value}/Applications/ChatGPT.app/Contents/MacOS" "${root_spaced_value}/Applications/ChatGPT.app/Contents/Resources"
  touch "$mitm_path" "$app_path" "${root_spaced_value}/Applications/ChatGPT.app/Contents/Resources/codex"
  chmod +x "$mitm_path" "$app_path" "${root_spaced_value}/Applications/ChatGPT.app/Contents/Resources/codex"
  write_config "$cfg_spaced_value" "$root_spaced_value" "http://127.0.0.1:29758" "127.0.0.1" ""
  run_expect_success "accept config values containing path spaces" "$cfg_spaced_value" "$root_spaced_value" || assert_fail "path spaces were rejected"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root_spaced_value")

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  write_config "$cfg" "$root" "https://user:pass@127.0.0.1:29758" "127.0.0.1" ""
  run_expect_fail "reject userinfo in upstream proxy URL" "$cfg" || assert_fail "userinfo URL was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "0.0.0.0" ""
  run_expect_fail "reject non-loopback listen host" "$cfg" || assert_fail "non-loopback host was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  cat > "$cfg" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
FOO=bar
EOF_CONFIG
  run_expect_fail "reject unknown key" "$cfg" || assert_fail "unknown key was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  cat > "$cfg" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=[
EOF_CONFIG
  run_expect_fail "reject malformed passthrough regex" "$cfg" || assert_fail "invalid regex was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/codex-proxy.conf"
  prepare_fake_install "$root"
  cat > "$cfg" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
LISTEN_HOST=127.0.0.1
EOF_CONFIG
  run_expect_fail "reject duplicate key" "$cfg" || assert_fail "duplicate key was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/ipv6-relay.conf"
  prepare_fake_install "$root"
  cat > "$cfg" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758
LISTEN_HOST=::1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  CODEX_PROXY_HOME="$root"
  if ! codex_proxy_load_config "$cfg"; then
    assert_fail "ipv6 relay config should load"
  else
    assert_eq "render relay URL with bracketed ::1" "$CODEX_PROXY_RELAY_URL" "http://[::1]:29759"
    assert_eq "normalize LISTEN_HOST=[::1] for bind socket" "$CODEX_PROXY_LISTEN_HOST_FOR_BIND" "::1"
  fi

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/ipv6-bracket-relay.conf"
  prepare_fake_install "$root"
  cat > "$cfg" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758
LISTEN_HOST=[::1]
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  CODEX_PROXY_HOME="$root"
  if ! codex_proxy_load_config "$cfg"; then
    assert_fail "[::1] relay config should load"
  else
    assert_eq "render relay URL with bracketed host token [::1]" "$CODEX_PROXY_RELAY_URL" "http://[::1]:29759"
    assert_eq "normalize bracketed LISTEN_HOST for bind socket" "$CODEX_PROXY_LISTEN_HOST_FOR_BIND" "::1"
  fi

  local cfg_url_path="${root}/bad-url-path.conf"
  cat > "$cfg_url_path" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758/path
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  run_expect_fail "reject upstream URL path" "$cfg_url_path" || assert_fail "upstream URL path was accepted"

  local cfg_url_query="${root}/bad-url-query.conf"
  cat > "$cfg_url_query" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758?x=1
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  run_expect_fail "reject upstream URL query" "$cfg_url_query" || assert_fail "upstream URL query was accepted"

  local cfg_url_fragment="${root}/bad-url-fragment.conf"
  cat > "$cfg_url_fragment" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758#x
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  run_expect_fail "reject upstream URL fragment" "$cfg_url_fragment" || assert_fail "upstream URL fragment was accepted"

  local cfg_url_ipv6="${root}/bad-url-ipv6.conf"
  cat > "$cfg_url_ipv6" <<EOF_CONFIG
UPSTREAM_PROXY_URL=http://::1:29758
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  run_expect_fail "reject malformed unbracketed IPv6 upstream URL" "$cfg_url_ipv6" || assert_fail "unbracketed IPv6 URL was accepted"

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/bad-proxy.conf"
cat > "$cfg" <<EOF_CONFIG
UPSTREAM_PROXY_URL=ftp://127.0.0.1:29758
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${root}/usr/bin/mitmdump
CHATGPT_APP_PATH=${root}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT
PASSTHROUGH_REGEX=
EOF_CONFIG
  run_expect_fail "reject non-http/https upstream URL" "$cfg" || assert_fail "non-http/https upstream URL was accepted"

  local health_cfg="${root}/health-duplicate.conf"
  local health_root="${root}/health-root"
  mkdir -p "$health_root"
  prepare_fake_install "$health_root"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$health_root")
  write_config "$health_cfg" "$health_root" "http://127.0.0.1:29758" "127.0.0.1" ""

  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  cfg="${root}/bad-openai-audit.conf"
  prepare_fake_install "$root"
  write_config "$cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" ""

  run_command_expect_fail "openai-network-audit rejects relative config path" \
    /bin/zsh "$SCRIPT_DIR/../bin/openai-network-audit.sh" --config "relative-path"

  local audit_home
  audit_home="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$audit_home")
  run_command_expect_fail "openai-network-audit requires explicit proxy+CA when config missing" \
    /bin/zsh -c "CODEX_PROXY_HOME='$audit_home' /bin/zsh '$SCRIPT_DIR/../bin/openai-network-audit.sh'"
  run_command_expect_fail "openai-network-audit requires CA mode when config missing" \
    /bin/zsh -c "CODEX_PROXY_HOME='$audit_home' /bin/zsh '$SCRIPT_DIR/../bin/openai-network-audit.sh' --proxy-url 'http://127.0.0.1:29759'"
  run_command_expect_fail "openai-network-audit --codex-doctor requires loaded config" \
    /bin/zsh -c "CODEX_PROXY_HOME='$audit_home' /bin/zsh '$SCRIPT_DIR/../bin/openai-network-audit.sh' --proxy-url 'http://127.0.0.1:29759' --system-ca --codex-doctor"
  run_command_expect_fail "openai-network-audit rejects explicit malformed proxy URL path" \
    /bin/zsh -c "CODEX_PROXY_HOME='$audit_home' /bin/zsh '$SCRIPT_DIR/../bin/openai-network-audit.sh' --proxy-url 'http://127.0.0.1:29759/path' --system-ca"
  run_command_expect_fail "openai-network-audit rejects explicit malformed IPv6 upstream URL" \
    /bin/zsh -c "CODEX_PROXY_HOME='$audit_home' /bin/zsh '$SCRIPT_DIR/../bin/openai-network-audit.sh' --proxy-url 'http://::1:29759' --system-ca"
  run_command_expect_fail "openai-network-audit rejects explicit userinfo URL" \
    /bin/zsh -c "CODEX_PROXY_HOME='$audit_home' /bin/zsh '$SCRIPT_DIR/../bin/openai-network-audit.sh' --proxy-url 'https://user:pass@127.0.0.1:29759' --system-ca"

  run_command_expect_fail "openai-network-audit rejects invalid proxy URL scheme" \
    /bin/zsh "$SCRIPT_DIR/../bin/openai-network-audit.sh" --proxy-url "ftp://127.0.0.1:29759"

  run_command_expect_fail "openai-network-audit rejects proxy URL with userinfo" \
    /bin/zsh "$SCRIPT_DIR/../bin/openai-network-audit.sh" --proxy-url "https://user:pass@127.0.0.1:29759"

  run_command_expect_fail "start-relay rejects relative config path" \
    /bin/zsh "$SCRIPT_DIR/../bin/start-relay.sh" --config "relative-path"

  run_command_expect_fail "proxy-health rejects relative config path" \
    /bin/zsh "$SCRIPT_DIR/../bin/proxy-health.sh" --config "relative-path"

  run_command_expect_fail "proxy-health rejects duplicate mode" \
    /bin/zsh "$SCRIPT_DIR/../bin/proxy-health.sh" --config "$health_cfg" --full --http-only
  run_command_expect_fail "proxy-health rejects duplicate full mode" \
    /bin/zsh "$SCRIPT_DIR/../bin/proxy-health.sh" --config "$health_cfg" --full --full

  run_snippet "proxy-health parses curl probe tuple as (rc code)" \
    'probe="9 202"; fields=("${(z)probe}"); rc="${fields[1]:-999}"; code="${fields[2]:-000}"; [[ "$rc" == 9 && "$code" == 202 ]]'

  run_command_expect_fail "launch-codex rejects unknown trailing argument after action" \
    /bin/zsh "$SCRIPT_DIR/../bin/launch-codex-proxied.sh" --config "/tmp/not-a-config" --status foo

  run_command_expect_fail "launch-codex rejects non-integer --wait-clear timeout" \
    /bin/zsh "$SCRIPT_DIR/../bin/launch-codex-proxied.sh" --config "/tmp/not-a-config" --wait-clear abc

  run_snippet "launch-codex process_has_required_env matches raw spaced value" \
    'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; REQUIRED_ENVS=( "CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem" ); line="/usr/bin/env CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem PATH=/usr/bin"; process_has_required_env "$line"'

  run_command_expect_fail "launch-codex process_has_required_env rejects missing required spaced value" \
    /bin/zsh -c 'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; REQUIRED_ENVS=( "CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem" ); line="/usr/bin/env CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/wrong bundle.pem PATH=/usr/bin"; process_has_required_env "$line"'

  run_command_expect_fail "launch-codex process_has_required_env rejects key-prefix deception" \
    /bin/zsh -c 'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; REQUIRED_ENVS=( "CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem" ); line="/usr/bin/env CODEX_CA_CERTIFICATE_ORIG=/tmp/Application Support/codex/ca bundle.pem CODEX_CA_CERTIFICATE2=/tmp/Application Support/codex/ca bundle.pem PATH=/usr/bin"; process_has_required_env "$line"'

  run_command_expect_fail "launch-codex process_has_required_env rejects ALL_PROXY assignment" \
    /bin/zsh -c 'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; REQUIRED_ENVS=( "CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem" ); line="/usr/bin/env ALL_PROXY=http://127.0.0.1:8080 CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem"; process_has_required_env "$line"'

  run_snippet "launch-codex process_has_required_env ignores PRE_ALL_PROXY prefix deception" \
    'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; REQUIRED_ENVS=( "CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem" ); line="/usr/bin/env PRE_ALL_PROXY=http://127.0.0.1:8080 CODEX_CA_CERTIFICATE=/tmp/Application Support/codex/ca bundle.pem"; process_has_required_env "$line"'

  run_snippet "launch-codex lock path includes uid" \
    'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; uid="$(/usr/bin/id -u)"; [[ "$LAUNCH_LOCK_DIR" == *"-${uid}.lock" ]]'
  run_snippet "launch-codex install lock path includes uid" \
    'source "$SCRIPT_DIR/../bin/launch-codex-proxied.sh"; uid="$(/usr/bin/id -u)"; [[ "$INSTALL_TRANSACTION_LOCK" == "/private/tmp/com.github.kumaxs.codex-proxy-install-${uid}.lock" ]]'
  run_command_expect_fail "launch-codex acquire_launch_lock fails when install lock exists" \
    /bin/zsh -c 'script_dir="${SCRIPT_DIR:-$PWD}"; source "$script_dir/../bin/launch-codex-proxied.sh"; lock="/private/tmp/com.github.kumaxs.codex-proxy-install-$(/usr/bin/id -u).lock"; : > "$lock"; if acquire_launch_lock; then rm -f "$lock"; exit 1; fi; rm -f "$lock"; exit 1'
  run_command_expect_fail "launch-codex preflight fails when install lock exists" \
    /bin/zsh -c "lock=\"/private/tmp/com.github.kumaxs.codex-proxy-install-\$(/usr/bin/id -u).lock\"; : > \"\$lock\"; /bin/zsh '$SCRIPT_DIR/../bin/launch-codex-proxied.sh' --config '$health_cfg' --preflight; rc=\$?; /bin/rm -f \"\$lock\"; exit \"\$rc\""
  root="$(mk_runtime_root)"
  CODEX_PROXY_TEST_TEMP_ROOTS+=("$root")
  local relay_home="${root}/runtime"
  local relay_cfg="${root}/relay.conf"
  local fake_mitmdump="${root}/usr/bin/fake-mitmdump"
  local env_report="${root}/relay-env-report"
  /bin/mkdir -p "$relay_home"
  /bin/chmod 700 "$relay_home"
  prepare_fake_install "$root"
  cat > "$fake_mitmdump" <<'EOF_FAKE_MITMDUMP'
#!/bin/zsh
set -u
report="${CODEX_PROXY_TEST_ENV_OUTPUT:?}"
: > "$report"
for key in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy \
  FTP_PROXY ftp_proxy SOCKS_PROXY socks_proxy WS_PROXY ws_proxy WSS_PROXY wss_proxy \
  GIT_PROXY_COMMAND GIT_HTTP_PROXY GIT_HTTPS_PROXY npm_config_proxy npm_config_https_proxy; do
  if /usr/bin/printenv "$key" >/dev/null 2>&1; then
    /usr/bin/printf '%s=1 ' "$key" >> "$report"
  else
    /usr/bin/printf '%s=0 ' "$key" >> "$report"
  fi
done
/usr/bin/printf '\n' >> "$report"
EOF_FAKE_MITMDUMP
  /bin/chmod 700 "$fake_mitmdump"
  write_config "$relay_cfg" "$root" "http://127.0.0.1:29758" "127.0.0.1" "" "$fake_mitmdump"
  run_command_expect_success "relay accepts an empty first-run mitm directory" \
    /usr/bin/env \
      CODEX_PROXY_HOME="$relay_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=https://127.0.0.1:2 \
      http_proxy=http://127.0.0.1:3 https_proxy=https://127.0.0.1:4 \
      ALL_PROXY=http://127.0.0.1:5 all_proxy=http://127.0.0.1:6 \
      NO_PROXY=localhost no_proxy=localhost \
      FTP_PROXY=http://127.0.0.1:7 ftp_proxy=http://127.0.0.1:8 \
      SOCKS_PROXY=socks5://127.0.0.1:9 socks_proxy=socks5://127.0.0.1:10 \
      WS_PROXY=http://127.0.0.1:11 ws_proxy=http://127.0.0.1:12 \
      WSS_PROXY=https://127.0.0.1:13 wss_proxy=https://127.0.0.1:14 \
      GIT_PROXY_COMMAND=git-proxy GIT_HTTP_PROXY=http://127.0.0.1:15 \
      GIT_HTTPS_PROXY=https://127.0.0.1:16 npm_config_proxy=http://127.0.0.1:17 \
      npm_config_https_proxy=https://127.0.0.1:18 \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"
  local env_line
  env_line="$(<"$env_report")"
  assert_eq "relay clears inherited proxy and bypass variables" "$env_line" \
    "HTTP_PROXY=0 HTTPS_PROXY=0 http_proxy=0 https_proxy=0 ALL_PROXY=0 all_proxy=0 NO_PROXY=0 no_proxy=0 FTP_PROXY=0 ftp_proxy=0 SOCKS_PROXY=0 socks_proxy=0 WS_PROXY=0 ws_proxy=0 WSS_PROXY=0 wss_proxy=0 GIT_PROXY_COMMAND=0 GIT_HTTP_PROXY=0 GIT_HTTPS_PROXY=0 npm_config_proxy=0 npm_config_https_proxy=0 "

  local relay_install_lock="/private/tmp/com.github.kumaxs.codex-proxy-install-$(/usr/bin/id -u).lock"
  if [[ -e "$relay_install_lock" || -L "$relay_install_lock" ]]; then
    assert_fail "relay installer lock fixture path unexpectedly exists"
  fi
  /bin/mkdir "$relay_install_lock"
  CODEX_PROXY_TEST_TEMP_LOCKS+=("$relay_install_lock")
  /bin/chmod 700 "$relay_install_lock"
  /usr/bin/printf '%s %s\n' "$(/usr/bin/id -u)" "$$" > "$relay_install_lock/owner-pid"
  /bin/chmod 600 "$relay_install_lock/owner-pid"
  /bin/rm -f "$env_report"
  run_command_expect_fail "relay rejects active installer transaction before fake mitmdump" \
    /usr/bin/env CODEX_PROXY_HOME="$relay_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"
  if [[ -e "$env_report" ]]; then
    assert_fail "fake mitmdump executed while installer transaction was active"
  else
    assert_pass "fake mitmdump stayed stopped for active installer transaction"
  fi
  /bin/rm -rf -- "$relay_install_lock"

  /bin/mkdir "$relay_install_lock"
  CODEX_PROXY_TEST_TEMP_LOCKS+=("$relay_install_lock")
  /usr/bin/printf '%s %s\n' "$(/usr/bin/id -u)" "$$" > "$relay_install_lock/owner-pid"
  /bin/chmod 600 "$relay_install_lock/owner-pid"
  /bin/chmod 666 "$relay_install_lock"
  /bin/rm -f "$env_report"
  run_command_expect_fail "relay rejects unsafe installer lock before fake mitmdump" \
    /usr/bin/env CODEX_PROXY_HOME="$relay_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"
  if [[ -e "$env_report" ]]; then
    assert_fail "fake mitmdump executed with unsafe installer lock"
  else
    assert_pass "fake mitmdump stayed stopped for unsafe installer lock"
  fi
  /bin/chmod 700 "$relay_install_lock" 2>/dev/null || true
  /bin/rm -rf -- "$relay_install_lock"

  /bin/mkdir "$relay_install_lock"
  CODEX_PROXY_TEST_TEMP_LOCKS+=("$relay_install_lock")
  /bin/chmod 700 "$relay_install_lock"
  /usr/bin/printf '%s\n' malformed-owner-pid > "$relay_install_lock/owner-pid"
  /bin/chmod 600 "$relay_install_lock/owner-pid"
  /bin/rm -f "$env_report"
  run_command_expect_fail "relay rejects malformed installer lock owner before fake mitmdump" \
    /usr/bin/env CODEX_PROXY_HOME="$relay_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"
  if [[ -e "$env_report" ]]; then
    assert_fail "fake mitmdump executed with malformed installer lock owner"
  else
    assert_pass "fake mitmdump stayed stopped for malformed installer lock owner"
  fi
  /bin/rm -rf -- "$relay_install_lock"

  /bin/ln -s "$fake_mitmdump" "$relay_home/mitmproxy/mitmproxy-ca.pem"
  run_command_expect_fail "relay rejects symlinked mitmproxy CA/key state" \
    /usr/bin/env CODEX_PROXY_HOME="$relay_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"
  /bin/rm -f "$relay_home/mitmproxy/mitmproxy-ca.pem"
  : > "$relay_home/mitmproxy/mitmproxy-ca.pem"
  /bin/chmod 666 "$relay_home/mitmproxy/mitmproxy-ca.pem"
  run_command_expect_fail "relay rejects group-write mitmproxy CA/key state" \
    /usr/bin/env CODEX_PROXY_HOME="$relay_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"

  local relay_link_home="${root}/runtime-link"
  /bin/ln -s "$relay_home" "$relay_link_home"
  run_command_expect_fail "relay rejects symlinked mitm runtime path chain" \
    /usr/bin/env CODEX_PROXY_HOME="$relay_link_home" CODEX_PROXY_TEST_ENV_OUTPUT="$env_report" \
      /bin/zsh "$SCRIPT_DIR/../bin/relay.sh" --config "$relay_cfg"

  print "config parser tests passed"
}

main "$@"
