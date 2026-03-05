#!/usr/bin/env bash

set -euo pipefail

SCHEME="${MAGENT_SCHEME:-Magent}"
CONFIGURATION="${MAGENT_CONFIGURATION:-Debug}"
APP_NAME="${MAGENT_APP_NAME:-Magent}"
WORKSPACE="${MAGENT_WORKSPACE:-Magent.xcworkspace}"
GHOSTTY_LIB_REL="Libraries/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
}

build_dir_from_xcodebuild() {
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*CONFIGURATION_BUILD_DIR = //p' \
    | head -n1
}

ensure_build_prerequisites() {
  local root="$1"
  local ghostty_lib="$root/$GHOSTTY_LIB_REL"
  local needs_mise=0

  if [[ ! -f "$ghostty_lib" ]]; then
    echo "Missing $GHOSTTY_LIB_REL"
    needs_mise=1
  fi

  if [[ ! -d "$root/$WORKSPACE" ]]; then
    echo "Missing $WORKSPACE"
    needs_mise=1
  fi

  if [[ "$needs_mise" -eq 0 ]]; then
    return
  fi

  require_cmd mise

  echo "Installing toolchain with mise..."
  mise install

  if [[ ! -f "$ghostty_lib" ]]; then
    if [[ ! -x "$root/scripts/bootstrap-ghosttykit.sh" ]]; then
      echo "Missing bootstrap script: scripts/bootstrap-ghosttykit.sh" >&2
      exit 1
    fi

    echo "Bootstrapping GhosttyKit.xcframework..."
    mise x -- "$root/scripts/bootstrap-ghosttykit.sh"
  fi

  if [[ ! -d "$root/$WORKSPACE" ]]; then
    echo "Generating $WORKSPACE..."
    mise x -- tuist generate --no-open
  fi

  if [[ ! -f "$ghostty_lib" ]]; then
    echo "Still missing $GHOSTTY_LIB_REL after bootstrap." >&2
    exit 1
  fi

  if [[ ! -d "$root/$WORKSPACE" ]]; then
    echo "Still missing $WORKSPACE after Tuist generate." >&2
    exit 1
  fi
}

main() {
  require_cmd xcodebuild
  require_cmd sed
  require_cmd open
  require_cmd pgrep

  local root build_dir app_path binary_path pids
  root="$(repo_root)"
  cd "$root"
  ensure_build_prerequisites "$root"

  echo "Killing running $APP_NAME instances..."
  killall "$APP_NAME" 2>/dev/null || true
  sleep 0.5

  build_dir="$(build_dir_from_xcodebuild)"
  if [[ -z "$build_dir" ]]; then
    echo "Failed to resolve CONFIGURATION_BUILD_DIR for scheme '$SCHEME'." >&2
    exit 1
  fi

  app_path="$build_dir/$APP_NAME.app"
  binary_path="$app_path/Contents/MacOS/$APP_NAME"

  echo "Building $SCHEME ($CONFIGURATION)..."
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIGURATION" build

  if [[ ! -d "$app_path" ]]; then
    echo "Built app not found at: $app_path" >&2
    exit 1
  fi

  echo "Launching $app_path..."
  if ! open -n "$app_path"; then
    echo "open failed, launching binary directly..."
    "$binary_path" >/tmp/magent-relaunch.log 2>&1 &
  fi

  sleep 1
  pids="$(pgrep -x "$APP_NAME" || true)"
  if [[ -z "$pids" ]]; then
    echo "Launch failed: no running '$APP_NAME' process found." >&2
    exit 1
  fi

  echo "Running PID(s):"
  echo "$pids"
}

main "$@"
