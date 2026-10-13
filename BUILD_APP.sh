#!/usr/bin/env bash
#
# BUILD_APP.sh — build "Data Syncer.app" from the Swift code in this folder.
#
# ────────────────────────────────────────────────────────────────────────────────────────────────────
# READ THIS -> This script should typically not be executed by a general user. Use the INSTALL_APP.sh program
# instead: it checks the tools, runs the tests, calls this script and installs the app.
# ────────────────────────────────────────────────────────────────────────────────────────────────────
#
# What it does: compiles the app (swift build, release), then puts the program, the icon and the
# app's Info.plist together as build/Data Syncer.app and signs it so it opens on this Mac.
#
# Usage:  ./BUILD_APP.sh [options…]
#
#   (no options)        Release build for this Mac's kind of chip → build/Data Syncer.app
#   -u, --universal     Build for Apple-silicon AND Intel Macs in one app (slower; for copying to other Macs)
#   -d, --debug         Debug build (faster to compile, slower to run)
#   -o, --out DIR       Put the app somewhere else (default: build/)
#   -s, --sign IDENTITY Sign with a certificate from your Keychain instead of the ad-hoc signature, so
#                       Full Disk Access and Keychain permissions survive rebuilds (see Docs/SCRIPTS.md).
#                       Also read from the DATASYNCER_SIGN_IDENTITY environment variable.
#   -h, --help          This help.
#
# Needs: Xcode's command-line tools (swift). ./INSTALL_APP.sh --check tells you if they are missing.
# The compiler's output goes to build/build.log; the last lines are shown when the build fails.
#
set -euo pipefail
ORIG_PWD="$PWD"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
if [[ -t 1 ]]; then C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_BLU=$'\033[0;34m'; C_HI=$'\033[1;33m'; else C_RESET=''; C_RED=''; C_GRN=''; C_BLU=''; C_HI=''; fi
info() { echo "${C_BLU}==>${C_RESET} $*"; }; ok() { echo "${C_GRN}OK ${C_RESET} $*"; }; err() { echo "${C_RED}ERROR${C_RESET} $*" >&2; }
# Prints the comment block above; the part between the two rules is shown bold and yellow on a terminal.
usage() { awk -v HI="$C_HI" -v R="$C_RESET" 'NR>=3 { if (/^#/) { sub(/^# ?/, ""); if (/^─/) { if (hi) { print HI $0 R; hi=0; next } hi=1 }; print (hi ? HI $0 R : $0) } else { exit } }' "${BASH_SOURCE[0]}"; }

MIN_MACOS=14
CONFIG=release; OUT="$HERE/build"; UNIVERSAL=0; SIGN="${DATASYNCER_SIGN_IDENTITY:--}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--debug) CONFIG=debug ;;
    -u|--universal) UNIVERSAL=1 ;;
    -o|--out) [[ $# -ge 2 ]] || { err "--out needs a folder"; exit 2; }; OUT="$2"; shift ;;
    -s|--sign) [[ $# -ge 2 ]] || { err "--sign needs the name of a certificate in your Keychain"; exit 2; }; SIGN="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; echo; usage; exit 2 ;;
  esac; shift
done
# a relative --out is relative to where the script was run from, not to the repo
[[ "$OUT" = /* ]] || OUT="$ORIG_PWD/$OUT"

command -v swift >/dev/null 2>&1 || { err "The Swift compiler is not installed. Run ./INSTALL_APP.sh (it installs Xcode's command-line tools) and try again."; exit 1; }

APP_NAME="Data Syncer"
BUNDLE_ID="com.mattwalker.datasyncer"
VERSION="$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' Sources/DataSyncerCore/Version.swift | head -1)"
[[ -n "$VERSION" ]] || VERSION="0.0.0"
mkdir -p build

ARCH_ARGS=()
if [[ $UNIVERSAL -eq 1 ]]; then ARCH_ARGS=(--arch arm64 --arch x86_64); info "Compiling ($CONFIG, universal: Apple silicon + Intel)…"; else info "Compiling ($CONFIG)…"; fi
# a failed compile must never let an older binary be packaged with the new version number
if ! swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product DataSyncer > build/build.log 2>&1; then
  tail -n 40 build/build.log >&2
  err "The build failed (the full output is in build/build.log)."
  exit 1
fi
BIN="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product DataSyncer --show-bin-path)/DataSyncer"
[[ -x "$BIN" ]] || { err "The build did not produce the program (expected $BIN)."; exit 1; }

APP="$OUT/$APP_NAME.app"
info "Assembling ${APP}…"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp icon/DataSyncer.icns "$APP/Contents/Resources/DataSyncer.icns"
# the usage descriptions are what macOS shows when it asks for the Desktop/Documents/drives/shares the app touches
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
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Data Syncer — an on-demand, one-way backup and sync tool.</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSDesktopFolderUsageDescription</key><string>Data Syncer copies the folders you pick as a source and writes your backups where you tell it to.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Data Syncer copies the folders you pick as a source and writes your backups where you tell it to.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Data Syncer copies the folders you pick as a source and writes your backups where you tell it to.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Data Syncer writes your backups to the drives you choose as destinations.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Data Syncer writes your backups to the shares you choose as destinations.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
# "-" is an ad-hoc signature: enough for an app built and used on your own Mac, but its identity changes with every
# build, so macOS forgets Full Disk Access and the Keychain asks again after each rebuild. A certificate from your
# Keychain (--sign) gives the app a stable identity. See Docs/SCRIPTS.md.
if codesign --force --sign "$SIGN" "$APP" 2> build/codesign.log; then
  if [[ "$SIGN" == "-" ]]; then ok "Signed (ad hoc — Full Disk Access must be granted again after each rebuild; see Docs/SCRIPTS.md for a stable signature)"
  else ok "Signed with “$SIGN”"; fi
else
  err "Could not sign the app:"; cat build/codesign.log >&2
  [[ "$SIGN" == "-" ]] || { err "Check the certificate's name in Keychain Access (it must be a Code Signing certificate)."; exit 1; }
fi
if [[ $UNIVERSAL -eq 1 ]]; then ok "Built $APP (version $VERSION, universal)"; else ok "Built $APP (version $VERSION, $(uname -m) only)"; fi
