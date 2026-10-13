#!/usr/bin/env bash
#
# INSTALL_APP.sh — set up Data Syncer on this Mac.
#
# What it needs:
#   REQUIRED  macOS 14 or newer, on an Apple-silicon or Intel Mac.
#   REQUIRED  Xcode's command-line tools (the Swift compiler) — this script offers to install them.
#
# Usage:  ./INSTALL_APP.sh [options…]
#
#   (no options)    Check the tools, run the tests, build "Data Syncer.app" (BUILD_APP.sh) and
#                   copy it to /Applications (asking first).
#   -t, --to DIR    Put the finished app in DIR instead of /Applications — for example
#                   ./INSTALL_APP.sh --to ~/Desktop   (DIR must already exist).
#   -u, --universal Build one app that runs on Apple-silicon and Intel Macs (for copying to another Mac).
#   -s, --sign ID   Sign with a certificate from your Keychain, so Full Disk Access and Keychain
#                   permissions survive rebuilds (see Docs/SCRIPTS.md). Or set DATASYNCER_SIGN_IDENTITY.
#   -k, --skip-tests  Don't run the tests first (quicker when you just pulled new code).
#   -n, --no-copy   Build only; leave the app in build/ and don't touch /Applications.
#   -y, --yes       Don't ask before installing tools, installing on a failed test run, or replacing
#                   an app that is already there.
#   -c, --check     Only report what is installed or missing; change nothing.
#   -h, --help      This help.
#
# Safe to run again at any time — for example after pulling new code (it rebuilds and replaces the app).
# Then open Data Syncer from /Applications (or build/Data Syncer.app).
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
if [[ -t 1 ]]; then C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'; C_BLU=$'\033[0;34m'; else C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; fi
info() { echo "${C_BLU}==>${C_RESET} $*"; }; ok() { echo "${C_GRN}OK ${C_RESET} $*"; }; warn() { echo "${C_YEL}!! ${C_RESET} $*"; }; err() { echo "${C_RED}ERROR${C_RESET} $*" >&2; }
usage() { awk 'NR>=3 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "${BASH_SOURCE[0]}"; }

MIN_MACOS=14
COPY=1; YES=0; CHECK_ONLY=0; SKIP_TESTS=0; DEST="/Applications"; BUILD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--to)        [[ $# -ge 2 ]] || { err "--to needs a folder, for example --to ~/Desktop"; exit 2; }; DEST="${2/#\~/$HOME}"; shift ;;
    -u|--universal) BUILD_ARGS+=(--universal) ;;
    -s|--sign)      [[ $# -ge 2 ]] || { err "--sign needs the name of a certificate in your Keychain"; exit 2; }; BUILD_ARGS+=(--sign "$2"); shift ;;
    -k|--skip-tests) SKIP_TESTS=1 ;;
    -n|--no-copy)   COPY=0 ;;
    -y|--yes)       YES=1 ;;
    -c|--check)     CHECK_ONLY=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "Unknown option: $1"; echo; usage; exit 2 ;;
  esac; shift
done
confirm() { [[ $YES -eq 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
if [[ $COPY -eq 1 || $CHECK_ONLY -eq 1 ]]; then
  resolved="$(cd "$DEST" 2>/dev/null && pwd)" || { err "The folder $DEST doesn't exist. Make it first, or pick another with --to."; exit 2; }
  DEST="$resolved"
fi
TARGET="$DEST/Data Syncer.app"

echo "Data Syncer — install"; echo
# ---- macOS version
major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$major" -ge $MIN_MACOS ]]; then ok "macOS $(sw_vers -productVersion)"; else err "Data Syncer needs macOS $MIN_MACOS or newer (this Mac has $(sw_vers -productVersion))."; [[ $CHECK_ONLY -eq 1 ]] || exit 1; fi
# ---- the Swift compiler
if xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; then
  ok "Swift $(swift --version 2>/dev/null | head -1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p')"
else
  warn "Xcode's command-line tools (the Swift compiler) are not installed"
  if [[ $CHECK_ONLY -eq 0 ]] && confirm "Install them now? (macOS opens its own installer; run this script again when it finishes)"; then
    xcode-select --install 2>/dev/null || true
    echo "When the installer finishes, run ./INSTALL_APP.sh again."
  fi
  exit 1
fi
if [[ $CHECK_ONLY -eq 1 ]]; then
  [[ -d "build/Data Syncer.app" ]] && ok "App built (build/Data Syncer.app)" || warn "App not built yet"
  if [[ -d "$TARGET" ]]; then
    ok "App in $DEST"
    arch="$(lipo -archs "$TARGET/Contents/MacOS/Data Syncer" 2>/dev/null || echo '?')"
    sig="$(codesign -dv "$TARGET" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    echo "    built for: ${arch} · signed: ${sig:-ad hoc (permissions must be granted again after each rebuild)}"
  else
    warn "App not in $DEST"
  fi
  exit 0
fi
# ---- tests
mkdir -p build
if [[ $SKIP_TESTS -eq 1 ]]; then
  info "Skipping the tests (--skip-tests)"
else
  info "Running the tests (a minute or so; a private ssh server is started for some of them)…"
  if swift test > build/test.log 2>&1; then
    ok "Tests pass ($(grep -E '^\s*Executed [0-9]+ tests' build/test.log | tail -1 | sed -E 's/.*Executed ([0-9]+) tests.*/\1/') tests)"
  else
    warn "Some tests failed — see build/test.log:"
    grep -E "error: -\[|Fatal error" build/test.log | head -5 | sed 's/^/    /'
    if ! confirm "Build and install anyway?"; then exit 1; fi
  fi
fi
# ---- build
./BUILD_APP.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} || { err "The build failed."; exit 1; }
# ---- install
if [[ $COPY -eq 1 ]]; then
  if [[ -d "$TARGET" ]]; then
    if confirm "Replace the Data Syncer already in $DEST?"; then
      rm -rf "$TARGET" || { err "Could not remove the old app in $DEST (is it open, or is the folder read-only?)."; exit 1; }
    else COPY=0; fi
  elif ! confirm "Copy Data Syncer.app to $DEST?"; then COPY=0; fi
fi
if [[ $COPY -eq 1 ]]; then
  # ditto copies an app bundle exactly (Apple's recommended way)
  ditto "build/Data Syncer.app" "$TARGET" || { err "Could not copy the app to $DEST."; exit 1; }
  ok "Installed $TARGET"
  echo; echo "Next:  open \"$TARGET\""
  [[ "$DEST" == "/Applications" ]] && echo "       (or find Data Syncer in Launchpad)"
  echo "       To use it on another Mac, copy the whole \"Data Syncer.app\" over (AirDrop, a USB drive, a share)."
  echo "       Build with --universal if the other Mac has a different kind of chip; see Docs/SCRIPTS.md for the"
  echo "       one-time \"Open Anyway\" step macOS asks for an app that isn't from the App Store."
else
  echo; echo "Next:  open \"$HERE/build/Data Syncer.app\""
fi
exit 0
