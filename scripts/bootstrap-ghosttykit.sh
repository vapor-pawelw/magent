#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-ghosttykit.sh [--ref <git-ref>] [--work-dir <path>]

Builds GhosttyKit.xcframework from ghostty-org/ghostty and installs it into:
  Libraries/GhosttyKit.xcframework

Environment overrides:
  GHOSTTY_REF       Ghostty git ref to build (default: v1.2.3)
  GHOSTTY_WORK_DIR  Working directory for ghostty checkout (default: .build/ghostty-src)
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GHOSTTY_REF="${GHOSTTY_REF:-v1.2.3}"
WORK_DIR="${GHOSTTY_WORK_DIR:-$REPO_ROOT/.build/ghostty-src}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      if [[ $# -lt 2 ]]; then
        echo "--ref requires a value" >&2
        usage
        exit 1
      fi
      GHOSTTY_REF="$2"
      shift 2
      ;;
    --work-dir)
      if [[ $# -lt 2 ]]; then
        echo "--work-dir requires a value" >&2
        usage
        exit 1
      fi
      WORK_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

SOURCE_DIR="$WORK_DIR/ghostty"
OUTPUT_XCFRAMEWORK="$SOURCE_DIR/macos/GhosttyKit.xcframework"
DEST_XCFRAMEWORK="$REPO_ROOT/Libraries/GhosttyKit.xcframework"

require_cmd git
require_cmd zig
require_cmd rsync

mkdir -p "$WORK_DIR"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git init "$SOURCE_DIR" >/dev/null
  git -C "$SOURCE_DIR" remote add origin https://github.com/ghostty-org/ghostty.git
fi

echo "Fetching Ghostty ref: $GHOSTTY_REF"
git -C "$SOURCE_DIR" fetch --depth 1 origin "$GHOSTTY_REF"
git -C "$SOURCE_DIR" checkout --force FETCH_HEAD
git -C "$SOURCE_DIR" clean -fdx

echo "Building GhosttyKit.xcframework"
(
  cd "$SOURCE_DIR"
  zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework -Dxcframework-target=native
)

if [[ ! -d "$OUTPUT_XCFRAMEWORK" ]]; then
  echo "Expected output missing: $OUTPUT_XCFRAMEWORK" >&2
  exit 1
fi

rm -rf "$DEST_XCFRAMEWORK"
mkdir -p "$(dirname "$DEST_XCFRAMEWORK")"
rsync -a "$OUTPUT_XCFRAMEWORK/" "$DEST_XCFRAMEWORK/"

echo "Installed $DEST_XCFRAMEWORK from $GHOSTTY_REF"
