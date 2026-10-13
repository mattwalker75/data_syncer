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
#   -n, --no-copy   Build only; leave the app in build/ and don't touch /Applications.
#   -y, --yes       Don't ask before installing tools or replacing an app that is already there.
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

COPY=1; YES=0; CHECK_ONLY=0; DEST="/Applications"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--to)      [[ $# -ge 2 ]] || { err "--to needs a folder, for example --to ~/Desktop"; exit 2; }; DEST="${2/#\~/$HOME}"; shift ;;
    -n|--no-copy) COPY=0 ;;
    -y|--yes)     YES=1 ;;
    -c|--check)   CHECK_ONLY=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) err "Unknown option: $1"; echo; usage; exit 2 ;;
  esac; shift
done
confirm() { [[ $YES -eq 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }
if [[ $COPY -eq 1 && ! -d "$DEST" ]]; then err "The folder $DEST doesn't exist. Make it first, or pick another with --to."; exit 2; fi
DEST="$(cd "$DEST" && pwd)"; TARGET="$DEST/Data Syncer.app"

echo "Data Syncer — install"; echo
# ---- macOS version
major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$major" -ge 14 ]]; then ok "macOS $(sw_vers -productVersion)"; else err "Data Syncer needs macOS 14 or newer (this Mac has $(sw_vers -productVersion))."; [[ $CHECK_ONLY -eq 1 ]] || exit 1; fi
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
  [[ -d "$TARGET" ]] && ok "App in $DEST" || warn "App not in $DEST"
  exit 0
fi
# ---- tests
mkdir -p build
info "Running the tests…"
if swift test > build/test.log 2>&1; then ok "Tests pass ($(grep -c "passed (" build/test.log) checks)"; else warn "Some tests failed — see build/test.log"; fi
# ---- build
./BUILD_APP.sh || { err "The build failed."; exit 1; }
# ---- install
if [[ $COPY -eq 1 ]]; then
  if [[ -d "$TARGET" ]]; then
    if confirm "Replace the Data Syncer already in $DEST?"; then rm -rf "$TARGET"; else COPY=0; fi
  elif ! confirm "Copy Data Syncer.app to $DEST?"; then COPY=0; fi
fi
if [[ $COPY -eq 1 ]]; then
  cp -R "build/Data Syncer.app" "$DEST/" && ok "Installed $TARGET"
  echo; echo "Next:  open \"$TARGET\""
  [[ "$DEST" == "/Applications" ]] && echo "       (or find Data Syncer in Launchpad)"
  echo "       To use it on another Mac, copy the whole \"Data Syncer.app\" over (AirDrop, a USB drive, a share); nothing else is needed."
else
  echo; echo "Next:  open \"$HERE/build/Data Syncer.app\""
fi
exit 0
