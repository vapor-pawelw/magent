#!/usr/bin/env bash

# Relaunch Magent without rebuilding.
# Only builds if no existing binary is found in DerivedData.

set -euo pipefail

SCHEME="${MAGENT_SCHEME:-Magent}"
CONFIGURATION="${MAGENT_CONFIGURATION:-Debug}"
APP_NAME="${MAGENT_APP_NAME:-Magent}"
WORKSPACE="${MAGENT_WORKSPACE:-Magent.xcworkspace}"

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
}

build_dir_from_xcodebuild() {
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*CONFIGURATION_BUILD_DIR = //p' \
    | head -n1
}

main() {
  local root build_dir app_path binary_path pids
  root="$(repo_root)"
  cd "$root"

  build_dir="$(build_dir_from_xcodebuild)"
  if [[ -z "$build_dir" ]]; then
    echo "Failed to resolve CONFIGURATION_BUILD_DIR for scheme '$SCHEME'." >&2
    exit 1
  fi

  app_path="$build_dir/$APP_NAME.app"
  binary_path="$app_path/Contents/MacOS/$APP_NAME"

  if [[ ! -f "$binary_path" ]]; then
    echo "No existing binary at $binary_path — building..."
    xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration "$CONFIGURATION" build
    if [[ ! -f "$binary_path" ]]; then
      echo "Build did not produce expected binary at: $binary_path" >&2
      exit 1
    fi
  else
    echo "Found existing binary at $binary_path, skipping build."
  fi

  echo "Killing running $APP_NAME instances..."
  killall "$APP_NAME" 2>/dev/null || true
  sleep 0.5

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
