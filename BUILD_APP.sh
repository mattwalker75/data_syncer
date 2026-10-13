#!/usr/bin/env bash
#
# BUILD_APP.sh — build "Data Syncer.app" from the Swift code in this folder.
#
# What it does: compiles the app (swift build, release), then puts the program, the icon and the
# app's Info.plist together as build/Data Syncer.app and signs it so it opens on this Mac.
# Run it again after pulling new code. INSTALL_APP.sh calls it for you and copies the app to /Applications.
#
# Usage:  ./BUILD_APP.sh [options…]
#
#   (no options)    Release build → build/Data Syncer.app
#   -d, --debug     Debug build (faster to compile, slower to run)
#   -o, --out DIR   Put the app somewhere else (default: build/)
#   -h, --help      This help.
#
# Needs: Xcode's command-line tools (swift). ./INSTALL_APP.sh --check tells you if they are missing.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
if [[ -t 1 ]]; then C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_BLU=$'\033[0;34m'; else C_RESET=''; C_RED=''; C_GRN=''; C_BLU=''; fi
info() { echo "${C_BLU}==>${C_RESET} $*"; }; ok() { echo "${C_GRN}OK ${C_RESET} $*"; }; err() { echo "${C_RED}ERROR${C_RESET} $*" >&2; }
usage() { awk 'NR>=3 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "${BASH_SOURCE[0]}"; }

CONFIG=release; OUT="$HERE/build"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--debug) CONFIG=debug ;;
    -o|--out) OUT="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; echo; usage; exit 2 ;;
  esac; shift
done

command -v swift >/dev/null 2>&1 || { err "The Swift compiler is not installed. Run ./INSTALL_APP.sh (it installs Xcode's command-line tools) and try again."; exit 1; }

APP_NAME="Data Syncer"
BUNDLE_ID="com.mattwalker.datasyncer"
VERSION="$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' Sources/DataSyncerCore/Version.swift | head -1)"
[[ -n "$VERSION" ]] || VERSION="0.0.0"

info "Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product DataSyncer 2>&1 | grep -vE '^\s*$' | tail -n 3 || true
BIN="$(swift build -c "$CONFIG" --product DataSyncer --show-bin-path)/DataSyncer"
[[ -x "$BIN" ]] || { err "The build did not produce the program (expected $BIN)."; exit 1; }

APP="$OUT/$APP_NAME.app"
info "Assembling ${APP}…"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp icon/DataSyncer.icns "$APP/Contents/Resources/DataSyncer.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>DataSyncer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Data Syncer — an on-demand, one-way backup and sync tool.</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
# an ad-hoc signature: enough for an app built and used on your own Macs (no Apple developer account needed)
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && ok "Signed (ad hoc)" || info "Could not sign the app; it should still open with a right-click → Open the first time."
ok "Built $APP (version $VERSION)"
