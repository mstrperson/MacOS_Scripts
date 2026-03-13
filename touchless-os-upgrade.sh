#!/bin/bash

set -euo pipefail

ERASE=0
ENROLL=0
JAMF_BIN=""

usage() {
  cat <<'EOF'
Usage: sudo ./touchless-os-upgrade.sh [--erase] [--enroll] [--help]

Downloads the latest full macOS installer that Apple offers to this Mac and
starts a noninteractive OS install.

Options:
  --erase     Use startosinstall --eraseinstall. Default: disabled.
  --enroll    Run jamf -enroll --prompt before any softwareupdate activity.
              Default: disabled.
  --help      Show this help text.

Notes:
  - Run this script with sudo.
  - --erase is destructive and wipes the Mac during the install workflow.
  - If --enroll and --erase are combined, Jamf enrollment runs before the
    software update workflow and will not survive the wipe.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "This script only supports macOS."
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this script with sudo."
}

version_is_newer() {
  local left="$1"
  local right="$2"
  local IFS=.
  local i
  local left_part
  local right_part
  local -a left_parts
  local -a right_parts

  read -r -a left_parts <<< "$left"
  read -r -a right_parts <<< "$right"

  for ((i = 0; i < ${#left_parts[@]} || i < ${#right_parts[@]}; i++)); do
    left_part="${left_parts[i]:-0}"
    right_part="${right_parts[i]:-0}"

    if ((10#$left_part > 10#$right_part)); then
      return 0
    fi

    if ((10#$left_part < 10#$right_part)); then
      return 1
    fi
  done

  return 1
}

get_latest_full_installer() {
  local output
  local line
  local title
  local version
  local latest_title=""
  local latest_version=""

  log "Listing full macOS installers available from Apple..."
  output="$(LC_ALL=C softwareupdate --list-full-installers 2>&1)" || {
    printf '%s\n' "$output" >&2
    die "softwareupdate --list-full-installers failed."
  }

  while IFS= read -r line; do
    if [[ "$line" =~ Title:\ (.*),\ Version:\ ([0-9][0-9.]*), ]]; then
      title="${BASH_REMATCH[1]}"
      version="${BASH_REMATCH[2]}"

      if [ -z "$latest_version" ] || version_is_newer "$version" "$latest_version"; then
        latest_title="$title"
        latest_version="$version"
      fi
    fi
  done <<< "$output"

  [ -n "$latest_version" ] || die "Unable to determine the latest compatible macOS installer."

  printf '%s\t%s\n' "$latest_version" "$latest_title"
}

fetch_full_installer() {
  local version="$1"

  log "Downloading macOS installer version $version..."
  LC_ALL=C softwareupdate --fetch-full-installer --full-installer-version "$version" \
    || die "Failed to download macOS installer version $version."
}

find_installer_app() {
  local target_version="$1"
  local app
  local app_version
  local newest_app=""
  local newest_mtime=0
  local current_mtime

  while IFS= read -r -d '' app; do
    [ -x "$app/Contents/Resources/startosinstall" ] || continue

    app_version="$(
      /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$app/Contents/Info.plist" 2>/dev/null || true
    )"

    if [ "$app_version" = "$target_version" ]; then
      printf '%s\n' "$app"
      return 0
    fi

    current_mtime="$(stat -f '%m' "$app" 2>/dev/null || echo 0)"
    if [ "$current_mtime" -gt "$newest_mtime" ]; then
      newest_mtime="$current_mtime"
      newest_app="$app"
    fi
  done < <(find /Applications -maxdepth 1 -type d -name 'Install macOS*.app' -print0 2>/dev/null)

  if [ -n "$newest_app" ]; then
    log "Exact installer version match was not found; falling back to the newest installer app."
    printf '%s\n' "$newest_app"
    return 0
  fi

  return 1
}

run_jamf_enroll() {
  JAMF_BIN="$(command -v jamf 2>/dev/null || true)"
  if [ -z "$JAMF_BIN" ] && [ -x /usr/local/bin/jamf ]; then
    JAMF_BIN="/usr/local/bin/jamf"
  fi

  [ -n "$JAMF_BIN" ] || die "jamf was not found in PATH or at /usr/local/bin/jamf."

  if [ "$ERASE" -eq 1 ]; then
    log "Warning: Jamf enrollment will run before the software update workflow and will not survive the wipe."
  fi

  log "Running jamf -enroll --prompt..."
  "$JAMF_BIN" -enroll --prompt || die "jamf -enroll --prompt failed."
}

start_touchless_install() {
  local installer_app="$1"
  local startosinstall_path="$installer_app/Contents/Resources/startosinstall"
  local -a cmd

  [ -x "$startosinstall_path" ] || die "startosinstall was not found in $installer_app."

  cmd=(
    "$startosinstall_path"
    --agreetolicense
    --nointeraction
  )

  if [ "$ERASE" -eq 1 ]; then
    cmd+=(--eraseinstall)
  fi

  log "Starting macOS install from $installer_app"
  printf 'Executing:'
  printf ' %q' "${cmd[@]}"
  printf '\n'

  "${cmd[@]}"
}

main() {
  local latest_info
  local latest_version
  local latest_title
  local installer_app

  while [ $# -gt 0 ]; do
    case "$1" in
      --erase)
        ERASE=1
        ;;
      --enroll)
        ENROLL=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown option: $1"
        ;;
    esac
    shift
  done

  require_macos
  require_root

  if [ "$ENROLL" -eq 1 ]; then
    run_jamf_enroll
  fi

  latest_info="$(get_latest_full_installer)"
  latest_version="${latest_info%%	*}"
  latest_title="${latest_info#*	}"

  log "Latest compatible macOS installer: ${latest_title} (${latest_version})"
  fetch_full_installer "$latest_version"

  installer_app="$(find_installer_app "$latest_version")" \
    || die "Unable to locate the downloaded macOS installer in /Applications."

  log "Using installer app: $installer_app"

  start_touchless_install "$installer_app"
}

main "$@"
