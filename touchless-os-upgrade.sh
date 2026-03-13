#!/bin/bash

set -euo pipefail

ERASE=0
ENROLL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --erase)
      ERASE=1
      ;;
    --enroll)
      ENROLL=1
      ;;
    --help|-h)
      cat <<'EOF'
Usage: ./touchless-os-upgrade.sh [--erase] [--enroll] [--help]

This script expects Install macOS Tahoe.app to be in the same folder as the script.

Options:
  --erase     Run startosinstall with --eraseinstall.
  --enroll    Run sudo jamf enroll -prompt before startosinstall.
  --help      Show this help text.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
INSTALLER_APP="$SCRIPT_DIR/Install macOS Tahoe.app"
STARTOSINSTALL="$INSTALLER_APP/Contents/Resources/startosinstall"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: This script only supports macOS." >&2
  exit 1
fi

echo "Current macOS version: $(sw_vers -productVersion 2>/dev/null || echo unknown)" >&2

if [ ! -d "$INSTALLER_APP" ]; then
  echo "Error: $INSTALLER_APP was not found." >&2
  exit 1
fi

if [ ! -x "$STARTOSINSTALL" ]; then
  echo "Error: startosinstall was not found in $INSTALLER_APP." >&2
  exit 1
fi

if [ "$ERASE" -eq 1 ] && [ "$ENROLL" -eq 1 ]; then
  echo "Skipping --enroll because --erase was passed." >&2
fi

if [ "$ERASE" -eq 0 ] && [ "$ENROLL" -eq 1 ]; then
  JAMF_BIN="$(command -v jamf 2>/dev/null || true)"
  if [ -z "$JAMF_BIN" ] && [ -x /usr/local/bin/jamf ]; then
    JAMF_BIN="/usr/local/bin/jamf"
  fi

  if [ -z "$JAMF_BIN" ]; then
    echo "Error: jamf was not found in PATH or at /usr/local/bin/jamf." >&2
    exit 1
  fi

  echo "Running sudo jamf enroll -prompt..." >&2
  sudo "$JAMF_BIN" enroll -prompt
fi

echo "Using installer app: $INSTALLER_APP" >&2
echo "Removing quarantine attribute from installer app..." >&2
sudo xattr -dr com.apple.quarantine "$INSTALLER_APP" 2>/dev/null || true

if [ "$ERASE" -eq 1 ]; then
  echo "Starting startosinstall with --eraseinstall..." >&2
  sudo "$STARTOSINSTALL" --agreetolicense --nointeraction --passprompt --eraseinstall
else
  echo "Starting startosinstall..." >&2
  sudo "$STARTOSINSTALL" --agreetolicense --nointeraction --passprompt
fi
