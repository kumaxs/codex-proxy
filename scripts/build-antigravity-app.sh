#!/bin/zsh

set -u
set -o pipefail
umask 077

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly SCRIPT_PATH="${PROJECT_ROOT}/app/Antigravity-Proxy.js"
readonly SOURCE_APP="/Applications/Antigravity.app"
readonly SOURCE_ICON="${SOURCE_APP}/Contents/Resources/icon.icns"
readonly OUTPUT_DIR="${HOME}/Applications"
readonly APP_NAME="Antigravity Proxy"
readonly BUNDLE_ID="com.kumaxs.antigravity-proxy"
readonly APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
readonly CURRENT_UID="$(/usr/bin/id -u)"
REPLACE_EXISTING=0
DRY_RUN=0

usage() {
  print "Usage: build-antigravity-app.sh [--dry-run] [--replace]"
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --replace) REPLACE_EXISTING=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
if (( DRY_RUN == 1 )); then
  print "DRY-RUN: compile ${SCRIPT_PATH} as ${APP_BUNDLE}; set bundle ID ${BUNDLE_ID}; copy local Antigravity icon; ad-hoc sign; verify and install."
  exit 0
fi

[[ -r "$SCRIPT_PATH" ]] || { print -u2 "[ERROR] Missing launcher app source: ${SCRIPT_PATH}"; exit 1; }
[[ -r "$SOURCE_ICON" ]] || { print -u2 "[ERROR] Antigravity icon not found: ${SOURCE_ICON}"; exit 1; }
[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || { print -u2 "[ERROR] Applications output directory is missing or a symlink: ${OUTPUT_DIR}"; exit 1; }
[[ "$(/usr/bin/stat -f '%u' "$OUTPUT_DIR")" == "$CURRENT_UID" ]] || { print -u2 "[ERROR] Applications directory is not owned by the current user."; exit 1; }
if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  if (( REPLACE_EXISTING != 1 )) || [[ -L "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
    print -u2 "[ERROR] Refusing to overwrite existing or unsafe app bundle: ${APP_BUNDLE}"
    exit 1
  fi
fi

BUILD_ROOT="$(/usr/bin/mktemp -d /private/tmp/antigravity-proxy-build.XXXXXXXX)" || exit 1
readonly BUILD_ROOT
trap '/bin/rm -rf -- "$BUILD_ROOT"' EXIT INT TERM HUP
readonly BUILD_APP="${BUILD_ROOT}/${APP_NAME}.app"
readonly OLD_APP="${BUILD_ROOT}/previous.app"
readonly INFO_PLIST="${BUILD_APP}/Contents/Info.plist"
readonly RESOURCES_DIR="${BUILD_APP}/Contents/Resources"
readonly DECOMPILED="${BUILD_ROOT}/main.js"

if ! /usr/bin/osacompile -l JavaScript -o "$BUILD_APP" "$SCRIPT_PATH"; then
  print -u2 "[ERROR] osacompile failed."
  exit 1
fi

/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST" || exit 1
/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST" || exit 1
/usr/bin/plutil -replace CFBundleName -string "$APP_NAME" "$INFO_PLIST" || exit 1
/usr/bin/plutil -replace NSAppleEventsUsageDescription -string "Antigravity Proxy launches Antigravity with explicit proxy settings through the existing Codex Proxy service." "$INFO_PLIST" || exit 1
/bin/cp -f "$SOURCE_ICON" "${RESOURCES_DIR}/Antigravity.icns" || exit 1
/usr/bin/plutil -replace CFBundleIconFile -string "Antigravity.icns" "$INFO_PLIST" || exit 1
/bin/rm -f "${RESOURCES_DIR}/applet.icns" "${RESOURCES_DIR}/applet.rsrc" "${RESOURCES_DIR}/Assets.car" || exit 1

/usr/bin/codesign -s - --force --options runtime "$BUILD_APP" || { print -u2 "[ERROR] Ad-hoc signing failed."; exit 1; }
/usr/bin/codesign --verify --strict --deep "$BUILD_APP" || { print -u2 "[ERROR] Signature verification failed."; exit 1; }
/usr/bin/osadecompile "${BUILD_APP}/Contents/Resources/Scripts/main.scpt" > "$DECOMPILED" || { print -u2 "[ERROR] JXA decompile failed."; exit 1; }
/usr/bin/grep -Fq "launch-antigravity-proxied.sh" "$DECOMPILED" || { print -u2 "[ERROR] Built app is missing the expected launcher reference."; exit 1; }
/usr/bin/grep -Fq "Antigravity Proxy" "$DECOMPILED" || { print -u2 "[ERROR] Built app is missing the expected app identity."; exit 1; }
/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || { print -u2 "[ERROR] Built Info.plist is invalid."; exit 1; }

if [[ -e "$APP_BUNDLE" ]]; then
  /bin/mv "$APP_BUNDLE" "$OLD_APP" || { print -u2 "[ERROR] Could not stage the existing app bundle for replacement."; exit 1; }
  if ! /bin/mv "$BUILD_APP" "$APP_BUNDLE"; then
    /bin/mv "$OLD_APP" "$APP_BUNDLE" || print -u2 "[ERROR] CRITICAL: failed to restore the previous app bundle."
    print -u2 "[ERROR] Could not install the new app bundle."
    exit 1
  fi
else
  /bin/mv "$BUILD_APP" "$APP_BUNDLE" || { print -u2 "[ERROR] Could not install the app bundle."; exit 1; }
fi
if ! /usr/bin/codesign --verify --strict --deep "$APP_BUNDLE"; then
  print -u2 "[ERROR] Installed signature verification failed."
  if [[ -e "$OLD_APP" ]]; then
    /bin/rm -rf -- "$APP_BUNDLE"
    /bin/mv "$OLD_APP" "$APP_BUNDLE" || print -u2 "[ERROR] CRITICAL: failed to restore the previous app bundle."
  else
    /bin/rm -rf -- "$APP_BUNDLE"
  fi
  exit 1
fi
print "[PASS] Built and installed ${APP_BUNDLE}"
print "[PASS] Bundle ID: ${BUNDLE_ID}"
print "[PASS] Signature and decompiled launcher reference verified."
