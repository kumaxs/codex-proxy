#!/bin/zsh

set -u
set -o pipefail
umask 077

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly DEFAULT_JS_SCRIPT="${PROJECT_ROOT}/app/Codex-Proxy.js"
readonly DEFAULT_ICON_PATH="${PROJECT_ROOT}/assets/CodexProxy.icns"
readonly DEFAULT_BUNDLE_ID="io.github.kumaxs.codex-proxy"
readonly CURRENT_UID="$(/usr/bin/id -u)"

SCRIPT_PATH=""
OUTPUT_DIR=""
APP_NAME="Codex Proxy"
BUNDLE_ID="$DEFAULT_BUNDLE_ID"
DRY_RUN=0

BUILD_SUCCESS=0
APP_BUNDLE=""
DECOMPILED_FILE=""
SOURCE_FUNCS_FILE=""
DECOMPILED_FUNCS_FILE=""

usage() {
  cat <<'EOF_USAGE'
Usage: build-app.sh --script PATH --output-dir PATH [--name NAME] [--bundle-id ID] [--dry-run]
  --script       Path to JXA script.
  --output-dir   Directory to output .app.
  --name         App display name.
  --bundle-id    Bundle id.
  --dry-run      Validate and print planned actions only.
EOF_USAGE
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == --* ]]; then
    print -u2 "[ERROR] ${name} requires a value."
    exit 64
  fi
}

ensure_file_exists() {
  local target="$1"
  if [[ ! -r "$target" ]]; then
    print -u2 "[ERROR] missing readable file: $target"
    exit 1
  fi
}

is_valid_bundle_id() {
  local value="$1"
  /usr/bin/printf '%s\n' "$value" |
    /usr/bin/grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
}

validate_app_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    print -u2 "[ERROR] app name must not be empty."
    return 1
  fi
  if [[ "$name" == *"/"* || "$name" == *".."* ]]; then
    print -u2 "[ERROR] app name invalid: must not contain / or .."
    return 1
  fi
  if [[ "$name" == *$'\n'* || "$name" == *$'\r'* || "$name" == *$'\t'* ]]; then
    print -u2 "[ERROR] app name contains control characters."
    return 1
  fi
  return 0
}

normalize_bundle_id() {
  local value="$1"
  /usr/bin/tr '[:upper:]' '[:lower:]' <<< "$value"
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
    if (( mode_decimal & 512 )) && [[ "$target" == "/private/tmp" || "$target" == "/tmp" ]]; then
      return 0
    fi
    if (( (mode_decimal & 18) != 0 )); then
      return 1
    fi
    return 0
  fi

  return 1
}

safe_owner_for_target() {
  local target="$1"
  local owner
  local mode
  if ! /usr/bin/stat -f '%u' "$target" >/dev/null 2>&1; then
    return 0
  fi
  owner="$(/usr/bin/stat -f '%u' "$target" 2>/dev/null)" || return 1
  mode="$(/usr/bin/stat -f '%A' "$target" 2>/dev/null)" || return 1
  if ! is_mode_owner_allowed "$owner" "$mode" "$target"; then
    return 1
  fi
  return 0
}

check_path_chain() {
  local target="$1"
  local cursor="$target"

  while true; do
    if [[ "$cursor" == "/" ]]; then
      return 0
    fi

    if [[ -L "$cursor" ]]; then
      print -u2 "[ERROR] unsafe symlink component: $cursor"
      return 1
    fi
    if [[ -e "$cursor" ]] && ! safe_owner_for_target "$cursor"; then
      print -u2 "[ERROR] unsafe ownership/mode component: $cursor"
      return 1
    fi

    cursor="${cursor:h}"
    if [[ -z "$cursor" || "$cursor" == "." || "$cursor" == "/" ]]; then
      return 0
    fi
  done
}

prepare_output_dir() {
  local target="$1"
  if [[ "$target" == "/" ]]; then
    print -u2 "[ERROR] output directory must not be root."
    return 1
  fi
  if ! /bin/mkdir -p "$target"; then
    print -u2 "[ERROR] cannot create output directory: $target"
    return 1
  fi
  if [[ -L "$target" ]]; then
    print -u2 "[ERROR] output directory is a symlink: $target"
    return 1
  fi
  if ! check_path_chain "$target"; then
    return 1
  fi
  return 0
}

ensure_icon() {
  local icon_path="$1"
  if [[ ! -r "$icon_path" ]]; then
    print -u2 "[ERROR] missing icon file: $icon_path"
    exit 1
  fi
}

extract_script_functions() {
  local source_file="$1"
  /usr/bin/awk '
    /^[[:space:]]*function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/ {
      gsub(/^[[:space:]]*function[[:space:]]+/, "", $0)
      sub(/\(.*/, "", $0)
      gsub(/[[:space:]]+/, "", $0)
      print $0
    }
  ' "$source_file"
}

extract_decompiled_functions() {
  local decompiled_file="$1"
  /usr/bin/awk '
    /^function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/ {
      gsub(/.*function[[:space:]]+/, "", $0)
      sub(/\(.*/, "", $0)
      gsub(/[[:space:]]+/, "", $0)
      print $0
    }
  ' "$decompiled_file"
}

check_decompile_consistency() {
  local source_file="$1"
  local decompiled_file="$2"
  local source_functions_file="$3"
  local decompiled_functions_file="$4"
  local source_count
  local decompiled_count
  local marker
  local source_function

  if ! extract_script_functions "$source_file" > "$source_functions_file"; then
    print -u2 "[ERROR] failed to extract source function names."
    return 1
  fi
  if ! extract_decompiled_functions "$decompiled_file" > "$decompiled_functions_file"; then
    print -u2 "[ERROR] failed to extract decompiled function names."
    return 1
  fi

  source_count="$(/usr/bin/wc -l < "$source_functions_file" | /usr/bin/tr -d '[:space:]')"
  decompiled_count="$(/usr/bin/wc -l < "$decompiled_functions_file" | /usr/bin/tr -d '[:space:]')"
  if [[ -z "$source_count" || -z "$decompiled_count" ]]; then
    print -u2 "[ERROR] decompile consistency failed: missing function metadata."
    return 1
  fi
  if (( source_count > decompiled_count )); then
    print -u2 "[ERROR] decompile consistency failed: expected at least ${source_count} functions, found ${decompiled_count}."
    return 1
  fi

  for source_function in "${(@f)"$(/bin/cat "$source_functions_file")"}"; do
    [[ -z "$source_function" ]] && continue
    if ! /usr/bin/grep -qFx "$source_function" "$decompiled_functions_file"; then
      print -u2 "[ERROR] decompile consistency failed: function not found in decompiled output: ${source_function}"
      return 1
    fi
  done

  for marker in \
    'runtimeHome = ObjC.unwrap($.NSHomeDirectory())' \
    "const launcherScript = runtimeHome + '/bin/launch-codex-proxied.sh'" \
    "const launcherBundleId = 'com.openai.codex'" \
    "function performLaunch" \
    "function quitChatGPTGracefully" \
    "const app = Application(launcherBundleId)" \
    "app.quit()" \
    "function run(argv)"; do
    if ! /usr/bin/grep -qF "$marker" "$decompiled_file"; then
      print -u2 "[ERROR] decompile consistency failed: missing marker '${marker}'."
      return 1
    fi
  done
  return 0
}

cleanup_build_artifacts() {
  local rc="$1"
  if (( BUILD_SUCCESS == 1 )); then
    return 0
  fi
  if [[ -n "${APP_BUNDLE}" && -e "${APP_BUNDLE}" ]]; then
    /bin/rm -rf -- "${APP_BUNDLE}"
  fi
  if [[ -n "${DECOMPILED_FILE}" && -e "${DECOMPILED_FILE}" ]]; then
    /bin/rm -f -- "${DECOMPILED_FILE}"
  fi
  if [[ -n "${SOURCE_FUNCS_FILE}" && -e "${SOURCE_FUNCS_FILE}" ]]; then
    /bin/rm -f -- "${SOURCE_FUNCS_FILE}"
  fi
  if [[ -n "${DECOMPILED_FUNCS_FILE}" && -e "${DECOMPILED_FUNCS_FILE}" ]]; then
    /bin/rm -f -- "${DECOMPILED_FUNCS_FILE}"
  fi
}

trap 'cleanup_build_artifacts $?' EXIT

while (( $# > 0 )); do
  case "$1" in
    --script|--js|--source)
      require_value "$1" "${2:-}"
      SCRIPT_PATH="$2"
      shift 2
      ;;
    --output-dir|--out-dir)
      require_value "$1" "${2:-}"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --name)
      require_value "$1" "${2:-}"
      APP_NAME="$2"
      shift 2
      ;;
    --bundle-id)
      require_value "$1" "${2:-}"
      BUNDLE_ID="$2"
      shift 2
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
      print -u2 "[ERROR] unsupported argument: $1"
      usage
      exit 64
      ;;
  esac
done

SCRIPT_PATH="${SCRIPT_PATH:-$DEFAULT_JS_SCRIPT}"
if [[ -z "$OUTPUT_DIR" ]]; then
  print -u2 "[ERROR] --output-dir is required."
  usage
  exit 64
fi

if ! validate_app_name "$APP_NAME"; then
  exit 1
fi

ensure_file_exists "$SCRIPT_PATH"
ensure_file_exists "$DEFAULT_ICON_PATH"

BUNDLE_ID="$(normalize_bundle_id "$BUNDLE_ID")"
if ! is_valid_bundle_id "$BUNDLE_ID"; then
  print -u2 "[ERROR] invalid bundle id: $BUNDLE_ID"
  exit 64
fi

RAW_OUTPUT_DIR="${OUTPUT_DIR:a}"
if ! check_path_chain "$RAW_OUTPUT_DIR"; then
  exit 1
fi
OUTPUT_DIR="$RAW_OUTPUT_DIR"
if (( DRY_RUN == 1 )); then
  print "DRY-RUN: osacompile -l JavaScript -o ${OUTPUT_DIR}/${APP_NAME}.app ${SCRIPT_PATH}"
  print "DRY-RUN: set CFBundleIdentifier=${BUNDLE_ID}"
  print "DRY-RUN: set CFBundleDisplayName=${APP_NAME}"
  print "DRY-RUN: set CFBundleName=${APP_NAME}"
  print "DRY-RUN: copy icon ${DEFAULT_ICON_PATH} to CodexProxy.icns"
  print "DRY-RUN: remove default applet icon assets"
  print "DRY-RUN: ad-hoc sign and verify"
  print "DRY-RUN: validate decompile consistency"
  print "Bundle-id: $BUNDLE_ID"
  exit 0
fi

if ! prepare_output_dir "$OUTPUT_DIR"; then
  exit 1
fi

APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
DECOMPILED_FILE="${OUTPUT_DIR}/.codex-proxy-build.decompile"
SOURCE_FUNCS_FILE="${OUTPUT_DIR}/.codex-proxy-build.source.functions"
DECOMPILED_FUNCS_FILE="${OUTPUT_DIR}/.codex-proxy-build.decompile.functions"

if [[ -e "$APP_BUNDLE" ]]; then
  print -u2 "[ERROR] refusing to overwrite existing app bundle: $APP_BUNDLE"
  exit 1
fi

# Keep the lexical output path and re-check it immediately before the first
# write. Resolving with `:A` would silently follow a symlink introduced after
# the initial validation.
if [[ -L "$OUTPUT_DIR" ]] || ! check_path_chain "$OUTPUT_DIR"; then
  print -u2 "[ERROR] output directory changed or became unsafe before build: $OUTPUT_DIR"
  exit 1
fi

if ! /usr/bin/osacompile -l JavaScript -o "$APP_BUNDLE" "$SCRIPT_PATH"; then
  print -u2 "[ERROR] osacompile failed."
  exit 1
fi
if [[ ! -d "$APP_BUNDLE/Contents" ]]; then
  print -u2 "[ERROR] unexpected app output: $APP_BUNDLE"
  exit 1
fi

if ! /bin/mkdir -p "$RESOURCES_DIR"; then
  print -u2 "[ERROR] cannot prepare resource directory."
  exit 1
fi

if ! /usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"; then
  print -u2 "[ERROR] failed to set CFBundleIdentifier."
  exit 1
fi
if ! /usr/bin/plutil -replace CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"; then
  print -u2 "[ERROR] failed to set CFBundleDisplayName."
  exit 1
fi
if ! /usr/bin/plutil -replace CFBundleName -string "$APP_NAME" "$INFO_PLIST"; then
  print -u2 "[ERROR] failed to set CFBundleName."
  exit 1
fi
if ! /usr/bin/plutil -replace NSAppleEventsUsageDescription -string \
  "Codex Proxy uses Apple Events to request a graceful quit after explicit confirmation and to foreground ChatGPT after a successful launch." \
  "$INFO_PLIST"; then
  print -u2 "[ERROR] failed to set NSAppleEventsUsageDescription."
  exit 1
fi
for unused_privacy_key in \
  NSAppleMusicUsageDescription \
  NSCalendarsUsageDescription \
  NSCameraUsageDescription \
  NSContactsUsageDescription \
  NSHomeKitUsageDescription \
  NSMicrophoneUsageDescription \
  NSPhotoLibraryUsageDescription \
  NSRemindersUsageDescription \
  NSSiriUsageDescription \
  NSSystemAdministrationUsageDescription; do
  /usr/bin/plutil -remove "$unused_privacy_key" "$INFO_PLIST" >/dev/null 2>&1 || true
done
if /usr/bin/plutil -remove CFBundleIconName "$INFO_PLIST" >/dev/null 2>&1; then
  true
fi
if ! /bin/cp -f "$DEFAULT_ICON_PATH" "$RESOURCES_DIR/CodexProxy.icns"; then
  print -u2 "[ERROR] icon copy failed."
  exit 1
fi
if ! /usr/bin/plutil -replace CFBundleIconFile -string "CodexProxy.icns" "$INFO_PLIST"; then
  print -u2 "[ERROR] failed to set CFBundleIconFile."
  exit 1
fi
if ! /bin/rm -f "$RESOURCES_DIR/applet.icns" "$RESOURCES_DIR/applet.rsrc" "$RESOURCES_DIR/Assets.car"; then
  print -u2 "[ERROR] failed to remove default applet icon assets."
  exit 1
fi

if ! /usr/bin/codesign -s - --force --options runtime "$APP_BUNDLE"; then
  print -u2 "[ERROR] ad-hoc signing failed."
  exit 1
fi
if ! /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"; then
  print -u2 "[ERROR] codesign verification failed."
  exit 1
fi
if ! /usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST" >/dev/null 2>&1; then
  print -u2 "[ERROR] Info.plist missing CFBundleIdentifier."
  exit 1
fi
if ! /usr/bin/plutil -extract CFBundleIconFile raw "$INFO_PLIST" >/dev/null 2>&1; then
  print -u2 "[ERROR] Info.plist missing CFBundleIconFile."
  exit 1
fi

if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST" 2>/dev/null)" != "$BUNDLE_ID" ]]; then
  print -u2 "[ERROR] Info.plist bundle identifier mismatch."
  exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleName raw "$INFO_PLIST" 2>/dev/null)" != "$APP_NAME" ]]; then
  print -u2 "[ERROR] Info.plist display name mismatch."
  exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$INFO_PLIST" 2>/dev/null)" != "$APP_NAME" ]]; then
  print -u2 "[ERROR] Info.plist bundle name mismatch."
  exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw "$INFO_PLIST" 2>/dev/null)" != "CodexProxy.icns" ]]; then
  print -u2 "[ERROR] Info.plist icon entry mismatch."
  exit 1
fi
if [[ ! -f "$RESOURCES_DIR/CodexProxy.icns" ]]; then
  print -u2 "[ERROR] icon file missing: ${RESOURCES_DIR}/CodexProxy.icns"
  exit 1
fi
if [[ -e "$RESOURCES_DIR/applet.icns" || -e "$RESOURCES_DIR/applet.rsrc" || -e "$RESOURCES_DIR/Assets.car" ]]; then
  print -u2 "[ERROR] default applet icon remnants remain."
  exit 1
fi

if ! /usr/bin/osadecompile "${APP_BUNDLE}/Contents/Resources/Scripts/main.scpt" > "$DECOMPILED_FILE"; then
  print -u2 "[ERROR] osadecompile failed."
  exit 1
fi
if ! check_decompile_consistency "$SCRIPT_PATH" "$DECOMPILED_FILE" "$SOURCE_FUNCS_FILE" "$DECOMPILED_FUNCS_FILE"; then
  exit 1
fi

if ! /bin/cat "$DECOMPILED_FILE" >/dev/null 2>&1; then
  print -u2 "[ERROR] osadecompile output unreadable."
  exit 1
fi

BUILD_SUCCESS=1
/bin/rm -f "$DECOMPILED_FILE" "$SOURCE_FUNCS_FILE" "$DECOMPILED_FUNCS_FILE"

print "Built app: $APP_BUNDLE"
print "Bundle-id: $BUNDLE_ID"
