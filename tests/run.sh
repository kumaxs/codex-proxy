#!/bin/zsh

set -u
set -o pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly TEST_TMP_PREFIX="/private/tmp/codex-proxy-tests"
readonly RELAY_BASE_BUNDLE_ID="io.github.kumaxs.codex-proxy"

typeset -i TOTAL_PASS=0
typeset -i TOTAL_FAIL=0
typeset -a TEMP_PATHS=()
typeset -a SCRIPT_FILES=()

resolve_script_files() {
  local file
  local -a repo_files=()

  SCRIPT_FILES=(
    "${PROJECT_ROOT}/scripts/"*.sh(N)
    "${PROJECT_ROOT}/bin/"*.sh(N)
    "${PROJECT_ROOT}/lib/"*.sh(N)
  )
  if (( ${#SCRIPT_FILES[@]} == 0 )); then
    repo_files=("${(@f)$(find "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/bin" "$PROJECT_ROOT/lib" -type f -name '*.sh' 2>/dev/null)}")
    SCRIPT_FILES=("${repo_files[@]}")
  fi
}

add_temp_path() {
  local target
  for target in "$@"; do
    [[ -n "$target" ]] && TEMP_PATHS+=("$target")
  done
}

cleanup() {
  local target
  for target in "${TEMP_PATHS[@]}"; do
    if [[ -e "$target" || -L "$target" ]]; then
      /bin/rm -rf "$target"
    fi
  done
}

trap cleanup EXIT INT TERM HUP

print_pass() {
  TOTAL_PASS=$((TOTAL_PASS + 1))
  print "[PASS] $1"
}

print_fail() {
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
  print "[FAIL] $1"
  [[ -n "${2:-}" ]] && print "[INFO] $2"
}

make_tmpfile() {
  print -r -- "$(/usr/bin/mktemp "$TEST_TMP_PREFIX.XXXXXXXX")"
}

make_tmpdir() {
  print -r -- "$(/usr/bin/mktemp -d "$TEST_TMP_PREFIX.XXXXXXXX")"
}

run_scripts_syntax_check() {
  resolve_script_files
  if (( ${#SCRIPT_FILES[@]} == 0 )); then
    print_fail "zsh syntax check" "No shell scripts detected under scripts/, bin/, lib/."
    return 1
  fi

  local file
  for file in "${SCRIPT_FILES[@]}"; do
    if [[ ! -r "$file" ]]; then
      print_fail "zsh syntax check" "Unreadable script: $file"
      return 1
    fi
    if ! /bin/zsh -n "$file"; then
      print_fail "zsh syntax check: $file"
      return 1
    fi
  done
  print_pass "zsh syntax check"
  return 0
}

collect_scannable_sources() {
  local file
  local -a repo_files=()
  local -a scan_candidates=()
  local candidate
  local relative_file
  local ext

  repo_files=("${(@f)$(find "$PROJECT_ROOT" -type f 2>/dev/null)}")

  for file in "${repo_files[@]}"; do
    ext="${file:e}"
    candidate="$file"
    if [[ "$file" == "$PROJECT_ROOT"/* ]]; then
      relative_file="${file#${PROJECT_ROOT}/}"
      candidate="$file"
    else
      relative_file="$file"
      candidate="${PROJECT_ROOT}/${file}"
    fi
    case "${ext:l}" in
      a|app|bmp|class|dylib|ear|eot|gif|gz|icns|jpg|jpeg|jar|otf|pdf|png|pyc|so|svg|ttf|woff|woff2|xz|zip|zst|wasm|webp|mp4|mov|mkv|mp3|wav|ogg|flac)
        continue
        ;;
      *)
        ;;
    esac

    case "$relative_file" in
      .git/*|.codex/*)
        continue
        ;;
      tests/run.sh)
        continue
        ;;
      *)
        scan_candidates+=("$candidate")
        ;;
    esac
  done

  print -r -l -- "${scan_candidates[@]}"
}

run_search() {
  local tool="$1"
  local pattern="$2"
  local -a candidates=("${@:3}")
  local -a raw_matches=()
  local -a filtered_matches=()
  local match file_name

  if (( ${#candidates[@]} == 0 )); then
    return 1
  fi

  if [[ "$tool" == "rg" ]]; then
    if ! raw_matches=("${(@f)$(rg --no-heading -n -e "$pattern" "${candidates[@]}" 2>/dev/null)}"); then
      raw_matches=()
    fi
  else
    if ! raw_matches=("${(@f)$(grep -Hn -E "$pattern" "${candidates[@]}" 2>/dev/null)}"); then
      raw_matches=()
    fi
  fi

  for match in "${raw_matches[@]}"; do
    file_name="${match%%:*}"
    if [[ "$file_name" == "${SCRIPT_DIR}/run.sh" || "$file_name" == "tests/run.sh" ]]; then
      continue
    fi
    filtered_matches+=("$match")
  done

  if (( ${#filtered_matches[@]} > 0 )); then
    print "${(@)filtered_matches}"
    return 0
  fi
  return 1
}

run_static_safety_scan() {
  local search_tool="$1"
  shift
  local -a scan_targets=("$@")
  local -a patterns=(
    "networksetup"
    "scutil"
    "launchctl[[:space:]]+submit"
    "systemsetup"
    "/""Users/[A-Za-z0-9._-]+/"
    "BEGIN[[:space:]]+OPENSSH[[:space:]]+PRIVATE[[:space:]]+KEY"
    "BEGIN[[:space:]]+RSA[[:space:]]+PRIVATE[[:space:]]+KEY"
    "BEGIN[[:space:]]+EC[[:space:]]+PRIVATE[[:space:]]+KEY"
    "BEGIN[[:space:]]+PRIVATE[[:space:]]+KEY"
    "[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"
    "[Ff][Oo][Xx][Mm][Aa][Ii][Ll]"
    "[Hh]er""mes"
    "global-state/.*/state_[0-9]+/auth\\.json"
    "/global-state/state_[0-9]+/auth\\.json"
  )
  local pattern matches

  if [[ -z "$search_tool" ]]; then
    print_fail "Static safety scan: no available search tool"
    return 1
  fi

  for pattern in "${patterns[@]}"; do
    matches="$(run_search "$search_tool" "$pattern" "${scan_targets[@]}")"
    if [[ -n "$matches" ]]; then
      print_fail "Static safety scan pattern '$pattern' found"
      print "$matches"
      return 1
    fi
  done

  print_pass "Static sensitive/command scan"
  return 0
}

run_static_scan() {
  local scan_tool="$1"
  shift
  if run_static_safety_scan "$scan_tool" "$@"; then
    return 0
  fi
  return 1
}

run_template_lint_and_restrictions() {
  local template_file="${PROJECT_ROOT}/templates/io.github.kumaxs.codex-proxy-relay.plist.in"
  local keepalive_count
  local template_path

  if [[ ! -f "$template_file" ]]; then
    print_fail "template plist lint" "Missing template: $template_file"
    return 1
  fi
  if ! /usr/bin/plutil -lint "$template_file" >/dev/null 2>&1; then
    print_fail "template plist lint" "$template_file failed plutil lint."
    return 1
  fi

  keepalive_count="$(/usr/bin/grep -c '<key>KeepAlive</key>' "$template_file" || true)"
  if [[ "$keepalive_count" != "1" ]]; then
    print_fail "template KeepAlive policy" "Template must contain exactly one KeepAlive entry; found $keepalive_count"
    return 1
  fi

  for template_path in "${PROJECT_ROOT}/templates/"*.plist.in; do
    [[ -f "$template_path" ]] || continue
    if [[ "$template_path" == "$template_file" ]]; then
      continue
    fi
    if /usr/bin/grep -q '<key>KeepAlive</key>' "$template_path"; then
      print_fail "template KeepAlive scope" "KeepAlive appears in multiple template files"
      return 1
    fi
  done

  print_pass "template plist lint and KeepAlive restriction"
  return 0
}

run_test_config_suite() {
  local out_file
  out_file="$(make_tmpfile)"
  add_temp_path "$out_file"

  if ! /bin/zsh "$PROJECT_ROOT/scripts/test-config.sh" > "$out_file" 2>&1; then
    print_fail "scripts/test-config.sh suite" "$(/usr/bin/tail -n 60 "$out_file")"
    return 1
  fi
  if ! /usr/bin/grep -q "config parser tests passed" "$out_file"; then
    print_fail "scripts/test-config.sh result" "Missing success marker in output"
    return 1
  fi
  print_pass "scripts/test-config.sh"
  return 0
}

run_build_suite() {
  local build_root build_stdout build_stderr app_bundle info_plist decompiled launcher_expected launcher_found
  local icon_file bundle_id
  local expected_tokens_file source_tokens_file symlink_output_target symlink_output_path
  build_root="$(make_tmpdir)"
  add_temp_path "$build_root"
  build_stdout="$(make_tmpfile)"
  build_stderr="$(make_tmpfile)"
  decompiled="$(make_tmpfile)"
  expected_tokens_file="$(make_tmpfile)"
  source_tokens_file="$(make_tmpfile)"
  launcher_expected="$(make_tmpfile)"
  launcher_found="$(make_tmpfile)"
  add_temp_path "$build_stdout" "$build_stderr" "$decompiled" "$expected_tokens_file" "$source_tokens_file" "$launcher_expected" "$launcher_found"

  symlink_output_target="$(make_tmpdir)"
  symlink_output_path="$(make_tmpfile)"
  /bin/rm -f "$symlink_output_path"
  /bin/ln -s "$symlink_output_target" "$symlink_output_path"
  add_temp_path "$symlink_output_target" "$symlink_output_path"
  if /bin/zsh "$PROJECT_ROOT/scripts/build-app.sh" \
    --script "$PROJECT_ROOT/app/Codex-Proxy.js" \
    --output-dir "$symlink_output_path" \
    --name "Codex Proxy" > /dev/null 2>&1; then
    print_fail "scripts/build-app rejects symlink output directory"
    return 1
  fi

  app_bundle="${build_root}/Codex Proxy.app"
  info_plist="${app_bundle}/Contents/Info.plist"

  if ! /bin/zsh "$PROJECT_ROOT/scripts/build-app.sh" \
    --script "$PROJECT_ROOT/app/Codex-Proxy.js" \
    --output-dir "$build_root" \
    --name "Codex Proxy" \
    > "$build_stdout" 2>"$build_stderr"; then
    print_fail "scripts/build-app execution" "$(/usr/bin/tail -n 80 "$build_stderr")"
    return 1
  fi

  if ! /usr/bin/grep -q '^Bundle-id:' "$build_stdout"; then
    print_fail "scripts/build-app output marker"
    return 1
  fi
  bundle_id="$(/usr/bin/awk '/^Bundle-id:/{print $2}' "$build_stdout" | /usr/bin/tail -n 1)"
  if [[ -z "$bundle_id" || "$bundle_id" != "${RELAY_BASE_BUNDLE_ID}" ]]; then
    print_fail "scripts/build-app bundle id"
    return 1
  fi

  if [[ ! -d "$app_bundle" ]]; then
    print_fail "scripts/build-app output path"
    return 1
  fi
  if ! /usr/bin/plutil -lint "$info_plist" >/dev/null 2>&1; then
    print_fail "scripts/build-app Info.plist lint"
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict --deep --verbose=2 "$app_bundle" >/dev/null 2>&1; then
    print_fail "scripts/build-app codesign verification"
    return 1
  fi
  if ! /usr/bin/osadecompile "$app_bundle/Contents/Resources/Scripts/main.scpt" > "$decompiled"; then
    print_fail "scripts/build-app osadecompile"
    return 1
  fi

  icon_file="$(/usr/bin/plutil -extract CFBundleIconFile raw "$info_plist" 2>/dev/null || true)"
  if [[ "$icon_file" != "CodexProxy.icns" ]]; then
    print_fail "scripts/build-app CFBundleIconFile" "Expected CodexProxy.icns, found ${icon_file:-<missing>}"
    return 1
  fi

  if /usr/bin/plutil -extract CFBundleIconName raw "$info_plist" >/dev/null 2>&1; then
    print_fail "scripts/build-app CFBundleIconName forbidden"
    return 1
  fi

  if [[ "$(/usr/bin/plutil -extract NSAppleEventsUsageDescription raw "$info_plist" 2>/dev/null || true)" \
      != "Codex Proxy uses Apple Events to request a graceful quit after explicit confirmation and to foreground ChatGPT after a successful launch." ]]; then
    print_fail "scripts/build-app Apple Events usage description"
    return 1
  fi
  local privacy_key
  for privacy_key in \
    NSAppleMusicUsageDescription NSCalendarsUsageDescription NSCameraUsageDescription \
    NSContactsUsageDescription NSHomeKitUsageDescription NSMicrophoneUsageDescription \
    NSPhotoLibraryUsageDescription NSRemindersUsageDescription NSSiriUsageDescription \
    NSSystemAdministrationUsageDescription; do
    if /usr/bin/plutil -extract "$privacy_key" raw "$info_plist" >/dev/null 2>&1; then
      print_fail "scripts/build-app removes unused privacy key ${privacy_key}"
      return 1
    fi
  done

  if [[ -e "${app_bundle}/Contents/Resources/applet.icns" || -e "${app_bundle}/Contents/Resources/applet.rsrc" \
      || -e "${app_bundle}/Contents/Resources/Assets.car" ]]; then
    print_fail "scripts/build-app resource cleanup"
    return 1
  fi
  if [[ ! -f "${app_bundle}/Contents/Resources/${icon_file}" ]]; then
    print_fail "scripts/build-app embedded icon"
    return 1
  fi
  if ! /usr/bin/cmp -s "$PROJECT_ROOT/assets/CodexProxy.icns" "${app_bundle}/Contents/Resources/${icon_file}"; then
    print_fail "scripts/build-app embedded icon byte parity"
    return 1
  fi

  /bin/cat > "$expected_tokens_file" <<EOF_TOKENS
launch-codex-proxied.sh
getProcessState
performLaunch
com.openai.codex
--process-state
--launch-and-verify
EOF_TOKENS

  /usr/bin/sort -u "$expected_tokens_file" > "$launcher_expected"
  /usr/bin/grep -Eo 'launch-codex-proxied\.sh|getProcessState|performLaunch|com\.openai\.codex|--process-state|--launch-and-verify' "$decompiled" \
    | /usr/bin/sort -u > "$launcher_found"
  if ! /usr/bin/diff -u -b "$launcher_expected" "$launcher_found" >/dev/null 2>&1; then
    print_fail "scripts/build-app decompile consistency check"
    return 1
  fi
  /usr/bin/grep -Eo 'launch-codex-proxied\.sh|getProcessState|performLaunch|com\.openai\.codex|--process-state|--launch-and-verify' "$PROJECT_ROOT/app/Codex-Proxy.js" \
    | /usr/bin/sort -u > "$source_tokens_file"
  if ! /usr/bin/diff -u -b "$source_tokens_file" "$launcher_found" >/dev/null 2>&1; then
    print_fail "scripts/build-app source/decompile token parity"
    return 1
  fi

  print_pass "scripts/build-app, plist/codesign/osadecompile + icon checks"
  return 0
}

run_log_rotation_suite() {
  local runtime_root log_file dangling_target output_file index
  local -a expected=(current one two three four)

  runtime_root="$(make_tmpdir)"
  output_file="$(make_tmpfile)"
  add_temp_path "$runtime_root" "$output_file"
  /bin/chmod 700 "$runtime_root"
  log_file="$runtime_root/launcher.log"

  /usr/bin/printf '%s\n' current > "$log_file"
  /usr/bin/printf '%s\n' one > "${log_file}.1"
  /usr/bin/printf '%s\n' two > "${log_file}.2"
  /usr/bin/printf '%s\n' three > "${log_file}.3"
  /usr/bin/printf '%s\n' four > "${log_file}.4"
  /usr/bin/printf '%s\n' five > "${log_file}.5"
  /bin/chmod 600 "$log_file" "${log_file}.1" "${log_file}.2" \
    "${log_file}.3" "${log_file}.4" "${log_file}.5"

  if ! CODEX_PROXY_HOME="$runtime_root" /bin/zsh "$PROJECT_ROOT/bin/rotate-launcher-log.sh" \
      > "$output_file" 2>&1; then
    print_fail "launcher log five-file rotation" "$(/usr/bin/tail -n 40 "$output_file")"
    return 1
  fi
  if [[ ! -f "$log_file" || -s "$log_file" ]]; then
    print_fail "launcher log rotation recreates an empty current log"
    return 1
  fi
  for index in {1..5}; do
    if [[ "$(/bin/cat "${log_file}.${index}")" != "${expected[$index]}" ]]; then
      print_fail "launcher log rotation preserves expected history order"
      return 1
    fi
  done

  /bin/rm -f "$log_file"
  dangling_target="$runtime_root/dangling-target"
  /bin/ln -s "$dangling_target" "$log_file"
  if CODEX_PROXY_HOME="$runtime_root" /bin/zsh "$PROJECT_ROOT/bin/rotate-launcher-log.sh" \
      > "$output_file" 2>&1; then
    print_fail "launcher log rotation rejects dangling symlink"
    return 1
  fi
  if [[ -e "$dangling_target" || ! -L "$log_file" ]]; then
    print_fail "launcher log symlink rejection does not touch target"
    return 1
  fi

  print_pass "launcher log rotation order + symlink safety"
  return 0
}

run_install_and_uninstall_suite() {
  local home_root runtime_home runtime_manifest cfg_file
  local fake_mitmdump chatgpt_root chatgpt_app app_server_path out_file
  local app_bundle plist_file manifest_mode
  local dry_run_file default_dry_run_file
  local manifest_format manifest_version manifest_bundle_id manifest_runtime_home manifest_app_path
  local failure_home failure_project failure_runtime failure_app failure_plist failure_output
  local lifecycle_project install_script uninstall_script
  local listener_home listener_chatgpt_root listener_chatgpt_app listener_mitmdump listener_runtime listener_output
  local partial_output partial_recovery

  lifecycle_project="$(/usr/bin/mktemp -d "${TEST_TMP_PREFIX}-lifecycle-project.XXXXXXXX")"
  if [[ -z "$lifecycle_project" || ! -d "$lifecycle_project" ]]; then
    print_fail "scripts/install lifecycle fixture project creation"
    return 1
  fi
  /bin/chmod 700 "$lifecycle_project"
  add_temp_path "$lifecycle_project"
  /bin/cp -pR "$PROJECT_ROOT/." "$lifecycle_project/"
  install_script="$lifecycle_project/scripts/install.sh"
  uninstall_script="$lifecycle_project/scripts/uninstall.sh"

  home_root="$(/usr/bin/mktemp -d "${TEST_TMP_PREFIX}-install.XXXXXXXX")"
  if [[ -z "$home_root" || ! -d "$home_root" ]]; then
    print_fail "scripts/install suite temp HOME creation"
    return 1
  fi
  /bin/chmod 700 "$home_root"
  add_temp_path "$home_root"

  /bin/chmod 770 "$home_root"
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "/does/not/exist" \
    --dry-run > /dev/null 2>&1; then
    print_fail "scripts/install rejects group-writable HOME path"
    return 1
  fi
  /bin/chmod 700 "$home_root"

  runtime_home="${home_root}/Library/Application Support/Codex Proxy"
  chatgpt_root="${home_root}/Applications/ChatGPT.app"
  chatgpt_app="${chatgpt_root}/Contents/MacOS/ChatGPT"
  app_server_path="${chatgpt_root}/Contents/Resources/codex app-server"
  fake_mitmdump="${home_root}/usr/bin/mitmdump"
  runtime_manifest="$runtime_home/.codex-proxy-manifest"
  cfg_file="$runtime_home/config/codex-proxy.conf"
  app_bundle="${home_root}/Applications/Codex Proxy.app"
  plist_file="${home_root}/Library/LaunchAgents/io.github.kumaxs.codex-proxy-relay.plist"

  /bin/mkdir -p "${chatgpt_app:h}" "${chatgpt_app:h}/Resources" "${fake_mitmdump:h}" \
    "${chatgpt_root}/Contents/Resources" "$runtime_home/config" "$runtime_home/mitmproxy"
  /usr/bin/touch "$chatgpt_app" "$fake_mitmdump" "${chatgpt_root}/Contents/Resources/codex" "$app_server_path" \
    "$runtime_home/launcher.log" "$runtime_home/launcher.log.1" "$runtime_home/relay.log" "$runtime_home/mitmproxy/pin.txt"
  /bin/chmod +x "$chatgpt_app" "${chatgpt_root}/Contents/Resources/codex" "$fake_mitmdump"

  out_file="$(make_tmpfile)"
  add_temp_path "$out_file"

  default_dry_run_file="$(make_tmpfile)"
  add_temp_path "$default_dry_run_file"
  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --dry-run \
    > "$default_dry_run_file" 2>&1; then
    print_fail "scripts/install dry-run default no-start validation" "$(/usr/bin/tail -n 80 "$default_dry_run_file")"
    return 1
  fi
  if ! /usr/bin/grep -q "start=0" "$default_dry_run_file"; then
    print_fail "scripts/install default no-start mode"
    return 1
  fi
  if [[ -e "$runtime_home/.codex-proxy-manifest" || -e "$app_bundle" || -e "$plist_file" ]]; then
    print_fail "scripts/install dry-run must not write managed targets"
    return 1
  fi

  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --dry-run > /dev/null 2>&1; then
    print_fail "scripts/install requires explicit upstream URL"
    return 1
  fi
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --home "$home_root/custom-runtime" \
    --dry-run > /dev/null 2>&1; then
    print_fail "scripts/install rejects unsupported custom runtime home"
    return 1
  fi

  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --no-start \
    > "$out_file" 2>&1; then
    print_fail "scripts/install --no-start isolated installation" "$(/usr/bin/tail -n 80 "$out_file")"
    return 1
  fi
  if /usr/bin/grep -q "launchctl" "$out_file"; then
    print_fail "scripts/install lifecycle guard"
    return 1
  fi
  if ! /usr/bin/grep -q "install complete" "$out_file"; then
    print_fail "scripts/install completion marker"
    return 1
  fi

  if ! [[ -d "$runtime_home/bin" && -d "$runtime_home/lib" && -d "$runtime_home/config" ]]; then
    print_fail "scripts/install output layout"
    return 1
  fi
  if [[ ! -f "$runtime_manifest" ]]; then
    print_fail "scripts/install manifest generation"
    return 1
  fi
  if [[ -x "$runtime_manifest" ]]; then
    print_fail "scripts/install manifest permissions"
    return 1
  fi
  manifest_mode="$(/usr/bin/stat -f '%A' "$runtime_manifest" 2>/dev/null || true)"
  if [[ -n "$manifest_mode" && "$manifest_mode" != "600" ]]; then
    print_fail "scripts/install manifest permissions"
    return 1
  fi
  manifest_format="$(/usr/bin/plutil -extract ManifestFormat raw "$runtime_manifest" 2>/dev/null || true)"
  manifest_version="$(/usr/bin/plutil -extract ManifestVersion raw "$runtime_manifest" 2>/dev/null || true)"
  manifest_bundle_id="$(/usr/bin/plutil -extract BundleId raw "$runtime_manifest" 2>/dev/null || true)"
  manifest_runtime_home="$(/usr/bin/plutil -extract RuntimeHome raw "$runtime_manifest" 2>/dev/null || true)"
  manifest_app_path="$(/usr/bin/plutil -extract AppPath raw "$runtime_manifest" 2>/dev/null || true)"
  if [[ "$manifest_format" != "codex-proxy-install" || "$manifest_version" != "1" || -z "$manifest_bundle_id" \
      || "$manifest_runtime_home" != "$runtime_home" || "$manifest_app_path" != "$app_bundle" ]]; then
    print_fail "scripts/install manifest schema"
    return 1
  fi
  if /bin/test -x "$runtime_manifest"; then
    print_fail "scripts/install manifest should not be executable"
    return 1
  fi
  if [[ ! -d "$app_bundle" ]]; then
    print_fail "scripts/install app deployment"
    return 1
  fi
  if [[ ! -f "$plist_file" ]]; then
    print_fail "scripts/install launchd plist deployment"
    return 1
  fi

  dry_run_file="$(make_tmpfile)"
  add_temp_path "$dry_run_file"
  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --dry-run \
    --no-start \
    > "$dry_run_file" 2>&1; then
    print_fail "scripts/install dry-run no-start validation" "$(/usr/bin/tail -n 80 "$dry_run_file")"
    return 1
  fi
  if ! /usr/bin/grep -q "start=0" "$dry_run_file"; then
    print_fail "scripts/install default no-start mode"
    return 1
  fi

  /bin/ln -s "pin.txt" "$runtime_home/mitmproxy/unsafe-link"
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --no-start > "$out_file" 2>&1; then
    print_fail "scripts/install rejects nested symlink in retained runtime state"
    return 1
  fi
  if [[ ! -L "$runtime_home/mitmproxy/unsafe-link" || ! -f "$runtime_manifest" || ! -d "$app_bundle" ]]; then
    print_fail "scripts/install restores prior installation after retained-state rejection"
    return 1
  fi
  /bin/rm -f "$runtime_home/mitmproxy/unsafe-link"

  /usr/bin/touch "$runtime_home/config/test-keep.txt"

  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$uninstall_script" > "$out_file" 2>&1; then
    print_fail "scripts/uninstall default isolation" "$(/usr/bin/tail -n 80 "$out_file")"
    return 1
  fi

  if [[ -d "$runtime_home/bin" || -d "$runtime_home/lib" || -f "$runtime_manifest" ]]; then
    print_fail "scripts/uninstall cleanup semantics"
    return 1
  fi
  if [[ ! -d "$runtime_home/config" || ! -f "$runtime_home/mitmproxy/pin.txt" || ! -f "$runtime_home/config/codex-proxy.conf" || ! -f "$runtime_home/config/test-keep.txt" ]]; then
    print_fail "scripts/uninstall keep-path semantics"
    return 1
  fi
  if [[ ! -f "$runtime_home/launcher.log" || ! -f "$runtime_home/launcher.log.1" || ! -f "$runtime_home/relay.log" ]]; then
    print_fail "scripts/uninstall keep-path semantics (log files)"
    return 1
  fi
  if [[ -f "$home_root/Applications/Codex Proxy.app/Codex Proxy" || -d "$app_bundle" ]]; then
    print_fail "scripts/uninstall app removal"
    return 1
  fi
  if [[ -f "$plist_file" ]]; then
    print_fail "scripts/uninstall launchd plist removal"
    return 1
  fi

  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --no-start > "$out_file" 2>&1; then
    print_fail "scripts/install repeat installation after retained-state uninstall" "$(/usr/bin/tail -n 80 "$out_file")"
    return 1
  fi
  if [[ ! -f "$runtime_home/config/test-keep.txt" || ! -f "$runtime_home/mitmproxy/pin.txt" \
      || ! -f "$runtime_home/launcher.log.1" ]]; then
    print_fail "scripts/install preserves retained config, mitmproxy, and rotated log state"
    return 1
  fi
  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$uninstall_script" \
    --purge-runtime --yes > "$out_file" 2>&1; then
    print_fail "scripts/uninstall explicit purge" "$(/usr/bin/tail -n 80 "$out_file")"
    return 1
  fi
  if [[ -e "$runtime_home" || -e "$app_bundle" || -e "$plist_file" ]]; then
    print_fail "scripts/uninstall purge removes exact managed targets"
    return 1
  fi

  # Listener ownership is exercised entirely through the lifecycle test hook;
  # no real port, launchd label, or proxy process is touched.
  listener_home="$(/usr/bin/mktemp -d "${TEST_TMP_PREFIX}-listener-home.XXXXXXXX")"
  /bin/chmod 700 "$listener_home"
  add_temp_path "$listener_home"
  listener_chatgpt_root="$listener_home/Applications/ChatGPT.app"
  listener_chatgpt_app="$listener_chatgpt_root/Contents/MacOS/ChatGPT"
  listener_mitmdump="$listener_home/usr/bin/mitmdump"
  listener_runtime="$listener_home/Library/Application Support/Codex Proxy"
  /bin/mkdir -p "${listener_chatgpt_app:h}" "${listener_chatgpt_root}/Contents/Resources" "${listener_mitmdump:h}"
  /usr/bin/touch "$listener_chatgpt_app" "$listener_chatgpt_root/Contents/Resources/codex" "$listener_mitmdump"
  /bin/chmod +x "$listener_chatgpt_app" "$listener_chatgpt_root/Contents/Resources/codex" "$listener_mitmdump"
  listener_output="$(make_tmpfile)"
  add_temp_path "$listener_output"
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 \
      CODEX_PROXY_TEST_LISTENER_PIDS=61001 \
      CODEX_PROXY_TEST_LAUNCHD_STATE=absent \
      HOME="$listener_home" /bin/zsh "$install_script" \
      --upstream-url "http://127.0.0.1:29758" \
      --mitmdump "$listener_mitmdump" \
      --chatgpt-app-path "$listener_chatgpt_app" \
      --dry-run > "$listener_output" 2>&1; then
    print_fail "scripts/install rejects unexpected listener without managed launchd job"
    return 1
  fi
  if [[ -d "$listener_runtime" ]]; then
    print_fail "unexpected-listener rejection must not create runtime state"
    return 1
  fi
  if ! /usr/bin/grep -qi "listener" "$listener_output"; then
    print_fail "unexpected-listener rejection explains ownership failure" "$(/usr/bin/tail -n 40 "$listener_output")"
    return 1
  fi
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 \
      CODEX_PROXY_TEST_LAUNCHD_STATE=print-error \
      HOME="$listener_home" /bin/zsh "$install_script" \
      --upstream-url "http://127.0.0.1:29758" \
      --mitmdump "$listener_mitmdump" \
      --chatgpt-app-path "$listener_chatgpt_app" \
      --dry-run > "$listener_output" 2>&1; then
    print_fail "scripts/install rejects launchd query errors in dry-run"
    return 1
  fi
  if ! /usr/bin/grep -qi "launchd query failed" "$listener_output"; then
    print_fail "launchd query error rejection explains fail-closed state" "$(/usr/bin/tail -n 40 "$listener_output")"
    return 1
  fi
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 \
      CODEX_PROXY_TEST_CHATGPT_PIDS=64001 \
      CODEX_PROXY_TEST_LAUNCHD_STATE=absent \
      HOME="$listener_home" /bin/zsh "$install_script" \
      --upstream-url "http://127.0.0.1:29758" \
      --mitmdump "$listener_mitmdump" \
      --chatgpt-app-path "$listener_chatgpt_app" \
      --dry-run > "$listener_output" 2>&1; then
    print_fail "scripts/install rejects a running ChatGPT/Codex bundle"
    return 1
  fi
  if [[ -d "$listener_runtime" ]] || ! /usr/bin/grep -qi "ChatGPT/Codex is running" "$listener_output"; then
    print_fail "running ChatGPT install rejection is read-only and explained" "$(/usr/bin/tail -n 40 "$listener_output")"
    return 1
  fi

  # Seed a valid managed installation, then force a partial old-job bootout.
  # Rollback must restore the backed-up files and must not bootstrap a second
  # job while the original label still reports loaded.
  if ! CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$home_root" /bin/zsh "$install_script" \
      --upstream-url "http://127.0.0.1:29758" \
      --mitmdump "$fake_mitmdump" \
      --chatgpt-app-path "$chatgpt_app" \
      --no-start > "$out_file" 2>&1; then
    print_fail "scripts/install partial-bootout fixture seed" "$(/usr/bin/tail -n 80 "$out_file")"
    return 1
  fi
  /usr/bin/touch "$runtime_home/partial-runtime-marker" "$app_bundle/partial-app-marker"
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 \
      CODEX_PROXY_TEST_CHATGPT_PIDS=64002 \
      CODEX_PROXY_TEST_LAUNCHD_STATE=absent \
      HOME="$home_root" /bin/zsh "$uninstall_script" > "$out_file" 2>&1; then
    print_fail "scripts/uninstall rejects a running ChatGPT/Codex bundle"
    return 1
  fi
  if [[ ! -d "$runtime_home" || ! -d "$app_bundle" || ! -f "$plist_file" ]] \
      || ! /usr/bin/grep -qi "ChatGPT/Codex is running" "$out_file"; then
    print_fail "running ChatGPT uninstall rejection preserves targets and explains failure" "$(/usr/bin/tail -n 60 "$out_file")"
    return 1
  fi
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 \
      CODEX_PROXY_TEST_APP_PIDS=63001 \
      CODEX_PROXY_TEST_LAUNCHD_STATE=absent \
      HOME="$home_root" /bin/zsh "$uninstall_script" > "$out_file" 2>&1; then
    print_fail "scripts/uninstall rejects a running Codex Proxy.app bundle"
    return 1
  fi
  if [[ ! -d "$runtime_home" || ! -d "$app_bundle" || ! -f "$plist_file" ]]; then
    print_fail "running app rejection must preserve uninstall targets"
    return 1
  fi
  if ! /usr/bin/grep -qi "running" "$out_file"; then
    print_fail "running app rejection explains process ownership" "$(/usr/bin/tail -n 60 "$out_file")"
    return 1
  fi
  partial_output="$(make_tmpfile)"
  add_temp_path "$partial_output"
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 \
      CODEX_PROXY_TEST_LISTENER_PIDS=62001 \
      CODEX_PROXY_TEST_LAUNCHD_STATE=loaded \
      CODEX_PROXY_TEST_LAUNCHD_PID=62001 \
      CODEX_PROXY_TEST_BOOTOUT_RESULT=partial-fail \
      HOME="$home_root" /bin/zsh "$install_script" \
      --upstream-url "http://127.0.0.1:29758" \
      --mitmdump "$fake_mitmdump" \
      --chatgpt-app-path "$chatgpt_app" \
      --start > "$partial_output" 2>&1; then
    print_fail "scripts/install partial bootout must fail closed"
    return 1
  fi
  if [[ ! -f "$runtime_home/partial-runtime-marker" || ! -f "$app_bundle/partial-app-marker" ]]; then
    print_fail "partial bootout rollback restores previous runtime/app files" "$(/usr/bin/tail -n 100 "$partial_output")"
    return 1
  fi
  if [[ "$(/usr/bin/plutil -extract Label raw "$plist_file" 2>/dev/null || true)" != "io.github.kumaxs.codex-proxy-relay" ]]; then
    print_fail "partial bootout rollback restores previous plist"
    return 1
  fi
  if ! /usr/bin/grep -q "remains loaded; refusing duplicate bootstrap" "$partial_output"; then
    print_fail "partial bootout rollback avoids duplicate bootstrap" "$(/usr/bin/tail -n 100 "$partial_output")"
    return 1
  fi
  partial_recovery="$(/usr/bin/awk -F': ' '/recovery data was retained at: / { print $2; exit }' "$partial_output")"
  if [[ -z "$partial_recovery" || ! -d "$partial_recovery" ]]; then
    print_fail "partial bootout rollback records recoverable workspace" "$(/usr/bin/tail -n 100 "$partial_output")"
    return 1
  fi
  add_temp_path "$partial_recovery"

  failure_home="$(/usr/bin/mktemp -d "${TEST_TMP_PREFIX}-rollback-home.XXXXXXXX")"
  failure_project="$(/usr/bin/mktemp -d "${TEST_TMP_PREFIX}-rollback-project.XXXXXXXX")"
  /bin/chmod 700 "$failure_home" "$failure_project"
  add_temp_path "$failure_home"
  add_temp_path "$failure_project"
  failure_runtime="$failure_home/Library/Application Support/Codex Proxy"
  failure_app="$failure_home/Applications/Codex Proxy.app"
  failure_plist="$failure_home/Library/LaunchAgents/io.github.kumaxs.codex-proxy-relay.plist"
  failure_output="$(make_tmpfile)"
  add_temp_path "$failure_output"

  /bin/cp -pR "$PROJECT_ROOT/." "$failure_project/"
  /bin/rm -f "$failure_project/assets/CodexProxy.icns"
  /bin/mkdir -p "$failure_runtime" "$failure_app" "${failure_plist:h}"
  /usr/bin/touch "$failure_runtime/original-runtime-marker" \
    "$failure_app/original-app-marker" "$failure_plist"
  if CODEX_PROXY_LIFECYCLE_TEST_MODE=1 HOME="$failure_home" /bin/zsh "$failure_project/scripts/install.sh" \
    --upstream-url "http://127.0.0.1:29758" \
    --mitmdump "$fake_mitmdump" \
    --chatgpt-app-path "$chatgpt_app" \
    --no-start > "$failure_output" 2>&1; then
    print_fail "scripts/install rollback fixture must fail after backup"
    return 1
  fi
  if [[ ! -f "$failure_runtime/original-runtime-marker" \
      || ! -f "$failure_app/original-app-marker" || ! -f "$failure_plist" ]]; then
    print_fail "scripts/install failure rollback restores all previous targets" "$(/usr/bin/tail -n 80 "$failure_output")"
    return 1
  fi
  if [[ -e "/private/tmp/com.github.kumaxs.codex-proxy-install-$(/usr/bin/id -u).lock" ]]; then
    print_fail "scripts/install failure rollback releases global install lock"
    return 1
  fi

  print_pass "scripts/install/uninstall listener ownership + rollback/reinstall keep/purge lifecycle isolation"
  return 0
}

run_launcher_fixture_suite() {
  local fixture_root cfg_file process_table socket_table runtime_home chatgpt_root chatgpt_exec
  local relay_ca cfg_port cfg_host upstream_port lock_dir output_file
  local app_server_cmd relay_port

  fixture_root="$(make_tmpdir)"
  add_temp_path "$fixture_root"
  cfg_file="${fixture_root}/config/codex-proxy.conf"
  process_table="${fixture_root}/process-table.tsv"
  socket_table="${fixture_root}/socket-table.tsv"
  lock_dir="${fixture_root}/launch-lock"
  runtime_home="${fixture_root}/Library/Application Support/Codex Proxy"
  chatgpt_root="${fixture_root}/Applications/ChatGPT.app"
  chatgpt_exec="${chatgpt_root}/Contents/MacOS/ChatGPT"
  relay_ca="${runtime_home}/mitmproxy/mitmproxy-ca-cert.pem"
  cfg_host="127.0.0.1"
  cfg_port="29759"
  upstream_port="29758"
  relay_port="$cfg_port"

  /bin/mkdir -p "${chatgpt_exec:h}/Resources" "${chatgpt_root}/Contents/Resources" "${runtime_home}/config" \
    "${runtime_home}/mitmproxy" "${runtime_home}/bin" "${fixture_root}/bin" "${fixture_root}/lib" "${fixture_root}/config"
  /bin/mkdir -p "$runtime_home/bin"
  /bin/chmod 700 "$runtime_home"
  /usr/bin/touch "$chatgpt_exec" "${chatgpt_root}/Contents/Resources/codex" \
    "${chatgpt_root}/Contents/Resources/codex app-server" "$relay_ca" \
    "$runtime_home/bin/mitmdump" "$cfg_file"
  /bin/chmod +x "$chatgpt_exec" "${chatgpt_root}/Contents/Resources/codex" "$runtime_home/bin/mitmdump"

  /bin/cp -f "$PROJECT_ROOT/lib/config.sh" "$fixture_root/lib/"
  /bin/cp -f "$PROJECT_ROOT/bin/launch-codex-proxied.sh" "$fixture_root/bin/"
  /bin/chmod +x "${fixture_root}/bin/launch-codex-proxied.sh"

  app_server_cmd="${chatgpt_root}/Contents/Resources/codex app-server"
  /bin/cat > "$cfg_file" <<EOF_CFG
UPSTREAM_PROXY_URL=http://${cfg_host}:${upstream_port}
LISTEN_HOST=${cfg_host}
LISTEN_PORT=${cfg_port}
MITMDUMP_PATH=${runtime_home}/bin/mitmdump
CHATGPT_APP_PATH=${chatgpt_exec}
PASSTHROUGH_REGEX=
EOF_CFG

  /bin/cat > "$process_table" <<EOF_PROC
111	${chatgpt_exec} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
222	${app_server_cmd} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
EOF_PROC
  /bin/cat > "$socket_table" <<EOF_SOCK
222	${chatgpt_root}/Contents/Resources/codex app-server -> 127.0.0.1:${cfg_port}
EOF_SOCK

  output_file="$(make_tmpfile)"
  add_temp_path "$output_file"
  if ! CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" \
      --config "$cfg_file" --verify-current > "$fixture_root/verify-current.ok" 2>"$output_file"; then
    print_fail "launcher TEST_MODE verify-current success fixture" "$(/usr/bin/tail -n 80 "$output_file")"
    return 1
  fi
  /bin/rm -f "$fixture_root/verify-current.ok"

  /bin/cat > "$socket_table" <<EOF_SOCK
222	${chatgpt_root}/Contents/Resources/codex app-server -> 127.0.0.1:${upstream_port}
EOF_SOCK
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject direct upstream socket"
    return 1
  fi

  /bin/cat > "$socket_table" <<EOF_SOCK
222	${chatgpt_root}/Contents/Resources/codex app-server -> 8.8.8.8:443
EOF_SOCK
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject external 443"
    return 1
  fi

  /bin/cat > "$socket_table" <<EOF_SOCK
111	${chatgpt_exec} -> 8.8.8.8:443
222	${chatgpt_root}/Contents/Resources/codex app-server -> 127.0.0.1:${cfg_port}
EOF_SOCK
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject main-process external 443"
    return 1
  fi

  /bin/cat > "$socket_table" <<EOF_SOCK
222	${chatgpt_root}/Contents/Resources/codex app-server -> 127.0.0.1:${cfg_port}
EOF_SOCK

  /usr/bin/sed -e 's/HTTPS_PROXY=[^ ]* / /' "$process_table" > "$fixture_root/launcher-bad-env.tsv"
  /bin/cp "$fixture_root/launcher-bad-env.tsv" "$process_table"
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject missing required env"
    return 1
  fi

  /usr/bin/sed -e 's/CODEX_CA_CERTIFICATE=[^ ]*//g' "$process_table" > "$fixture_root/launcher-missing-env.tsv"
  /bin/cp "$fixture_root/launcher-missing-env.tsv" "$process_table"
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject missing required env key"
    return 1
  fi

  /bin/cat > "$process_table" <<EOF_PROC
111	${chatgpt_exec} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 SOCKS_PROXY=socks5://127.0.0.1:1080
222	${app_server_cmd} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
EOF_PROC
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject alternate inherited proxy env"
    return 1
  fi

  /bin/cat > "$process_table" <<EOF_PROC
111	${chatgpt_exec} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
222	${chatgpt_exec} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
EOF_PROC
  if CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should reject duplicate main process"
    return 1
  fi

  /bin/cat > "$process_table" <<EOF_PROC
111	${chatgpt_exec} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
222	${app_server_cmd} HTTP_PROXY=http://127.0.0.1:${cfg_port} HTTPS_PROXY=http://127.0.0.1:${cfg_port} http_proxy=http://127.0.0.1:${cfg_port} https_proxy=http://127.0.0.1:${cfg_port} CODEX_CA_CERTIFICATE=${relay_ca} SSL_CERT_FILE=${relay_ca} NODE_EXTRA_CA_CERTS=${relay_ca} NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
EOF_PROC
  /bin/cat > "$socket_table" <<EOF_SOCK
222	${chatgpt_root}/Contents/Resources/codex app-server -> 127.0.0.1:${cfg_port}
EOF_SOCK
  if ! CODEX_PROXY_HOME="$runtime_home" \
      CODEX_PROXY_LAUNCHER_TEST_MODE=1 \
      CODEX_PROXY_TEST_PROCESS_TABLE="$process_table" \
      CODEX_PROXY_TEST_SOCKET_TABLE="$socket_table" \
      CODEX_PROXY_TEST_DRY_RUN=1 \
      CODEX_PROXY_TEST_LOCK_DIR="$lock_dir" \
      /bin/zsh "$fixture_root/bin/launch-codex-proxied.sh" --config "$cfg_file" --verify-current >/dev/null 2>&1; then
    print_fail "launcher TEST_MODE should accept repaired fixture"
    return 1
  fi

  /bin/rm -f "$fixture_root/launcher-bad-env.tsv" "$fixture_root/launcher-missing-env.tsv"
  print_pass "launcher TEST_MODE process/env/socket fault coverage"
  return 0
}

run_relay_installer_lock_suite() {
  local fixture_root runtime_home cfg_file mitmdump_path marker_path output_file
  local chatgpt_root chatgpt_exec codex_helper lock_path lock_owner

  fixture_root="$(make_tmpdir)"
  add_temp_path "$fixture_root"
  runtime_home="${fixture_root}/Library/Application Support/Codex Proxy"
  cfg_file="${runtime_home}/config/codex-proxy.conf"
  mitmdump_path="${fixture_root}/bin/fake-mitmdump"
  marker_path="${fixture_root}/mitmdump-ran.marker"
  output_file="$(make_tmpfile)"
  add_temp_path "$output_file"
  chatgpt_root="${fixture_root}/Applications/ChatGPT.app"
  chatgpt_exec="${chatgpt_root}/Contents/MacOS/ChatGPT"
  codex_helper="${chatgpt_root}/Contents/Resources/codex"

  /bin/mkdir -p "${cfg_file:h}" "${mitmdump_path:h}" "${chatgpt_exec:h}" "${codex_helper:h}" \
    "${runtime_home}/mitmproxy"
  /bin/chmod 700 "$fixture_root" "$runtime_home" "${runtime_home:h}" "${runtime_home:h:h}" \
    "${cfg_file:h}" "${mitmdump_path:h}" "${chatgpt_root:h}" "${chatgpt_exec:h}" "${codex_helper:h}"
  /usr/bin/touch "$chatgpt_exec" "$codex_helper"
  /bin/chmod 700 "$chatgpt_exec" "$codex_helper"

  /bin/cat > "$mitmdump_path" <<'EOF_RELAY_FAKE_MITMDUMP'
#!/bin/zsh
/usr/bin/printf '%s\n' "$*" > "${CODEX_PROXY_TEST_MITMDUMP_MARKER}"
exit 0
EOF_RELAY_FAKE_MITMDUMP
  /bin/chmod 700 "$mitmdump_path"
  /bin/cat > "$cfg_file" <<EOF_RELAY_CFG
UPSTREAM_PROXY_URL=http://127.0.0.1:29758
LISTEN_HOST=127.0.0.1
LISTEN_PORT=29759
MITMDUMP_PATH=${mitmdump_path}
CHATGPT_APP_PATH=${chatgpt_exec}
PASSTHROUGH_REGEX=
EOF_RELAY_CFG
  /bin/chmod 600 "$cfg_file"

  lock_path="/private/tmp/com.github.kumaxs.codex-proxy-install-$(/usr/bin/id -u).lock"
  if [[ -e "$lock_path" || -L "$lock_path" ]]; then
    print_fail "relay installer-lock fixture has no pre-existing global lock"
    return 1
  fi
  /bin/mkdir "$lock_path"
  /bin/chmod 700 "$lock_path"
  lock_owner="$(/usr/bin/id -u) $$"
  /usr/bin/printf '%s\n' "$lock_owner" > "$lock_path/owner-pid"
  /bin/chmod 600 "$lock_path/owner-pid"
  add_temp_path "$lock_path"

  if CODEX_PROXY_TEST_MITMDUMP_MARKER="$marker_path" \
      HOME="$fixture_root" /bin/zsh "$PROJECT_ROOT/bin/relay.sh" \
      --config "$cfg_file" > "$output_file" 2>&1; then
    print_fail "relay refuses to execute while installer transaction lock exists"
    return 1
  fi
  if [[ -e "$marker_path" ]]; then
    print_fail "relay installer-lock rejection does not execute fake mitmdump"
    return 1
  fi
  if ! /usr/bin/grep -Eqi "install transaction|install.*lock|transaction.*active" "$output_file"; then
    print_fail "relay installer-lock rejection explains the fail-closed state" "$(/usr/bin/tail -n 40 "$output_file")"
    return 1
  fi

  /bin/rm -f -- "$lock_path/owner-pid"
  /bin/rmdir -- "$lock_path"
  if [[ -e "$lock_path" || -L "$lock_path" ]]; then
    print_fail "relay installer-lock fixture cleanup before unlocked run"
    return 1
  fi

  if ! CODEX_PROXY_TEST_MITMDUMP_MARKER="$marker_path" \
      HOME="$fixture_root" /bin/zsh "$PROJECT_ROOT/bin/relay.sh" \
      --config "$cfg_file" > "$output_file" 2>&1; then
    print_fail "relay executes normally after installer lock is removed" "$(/usr/bin/tail -n 60 "$output_file")"
    return 1
  fi
  if [[ ! -s "$marker_path" ]]; then
    print_fail "relay unlocked run executes fake mitmdump"
    return 1
  fi

  print_pass "relay installer transaction lock gate and unlocked execution"
  return 0
}

run_static_scan_stage() {
  local scan_tool
  local -a scan_targets

  scan_targets=("${(@f)$(collect_scannable_sources)}")
  if (( ${#scan_targets[@]} == 0 )); then
    print_fail "Static safety scan source inventory empty"
    return 1
  fi

  if command -v rg >/dev/null 2>&1; then
    scan_tool="rg"
  elif command -v grep >/dev/null 2>&1; then
    scan_tool="grep"
  else
    print_fail "Static safety scan: no available scan tool (rg or grep)"
    return 1
  fi

  run_static_scan "$scan_tool" "${scan_targets[@]}"
}

run_all_suites() {
  run_scripts_syntax_check
  run_static_scan_stage
  run_template_lint_and_restrictions
  run_test_config_suite
  run_build_suite
  run_log_rotation_suite
  run_install_and_uninstall_suite
  run_launcher_fixture_suite
  run_relay_installer_lock_suite
}

print_usage() {
  print "Usage: $0 [--suite all|syntax|static|template|test-config|build|rotation|install|launcher|relay]"
}

main() {
  local suite="all"
  if (( $# > 0 )); then
    if [[ "$1" != "--suite" || $# -lt 2 ]]; then
      print_usage
      return 64
    fi
    suite="$2"
  fi

  case "$suite" in
    all) run_all_suites ;;
    syntax) run_scripts_syntax_check ;;
    static) run_static_scan_stage ;;
    template) run_template_lint_and_restrictions ;;
    test-config) run_test_config_suite ;;
    build) run_build_suite ;;
    rotation) run_log_rotation_suite ;;
    install) run_install_and_uninstall_suite ;;
    launcher) run_launcher_fixture_suite ;;
    relay) run_relay_installer_lock_suite ;;
    *)
      print_usage
      return 64
      ;;
  esac

  if (( TOTAL_FAIL == 0 )); then
    print "Tests complete: pass=$TOTAL_PASS fail=0"
    return 0
  fi
  print "Tests complete: pass=$TOTAL_PASS fail=$TOTAL_FAIL"
  return 1
}

main "$@"
