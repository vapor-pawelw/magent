#!/usr/bin/env bash

set -euo pipefail

DEFAULT_REPO="vapor-pawelw/mAgent"
CHANGELOG_FILE="CHANGELOG.md"
FROM_VERSION=""
DRY_RUN=0
REPO="$DEFAULT_REPO"

usage() {
  cat <<USAGE
Usage: $0 [--repo <owner/repo>] [--from-version <x.y.z>] [--dry-run]

Rewrites GitHub release notes so each release body matches the corresponding
version section in CHANGELOG.md.
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

version_gte() {
  local a="$1"
  local b="$2"
  local smallest
  smallest="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
  [[ "$smallest" == "$b" ]]
}

extract_version_section() {
  local file="$1"
  local version="$2"
  awk -v version="$version" '
    BEGIN { in_version = 0; found = 0 }
    $0 ~ ("^## " version " - ") {
      in_version = 1
      found = 1
      print
      next
    }
    /^## / {
      if (in_version == 1) {
        exit
      }
    }
    in_version == 1 {
      print
    }
    END {
      if (found == 0) {
        exit 2
      }
    }
  ' "$file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --from-version)
      FROM_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd gh
require_cmd awk

if [[ ! -f "$CHANGELOG_FILE" ]]; then
  echo "Missing ${CHANGELOG_FILE}" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

temp_notes="$(mktemp)"
trap 'rm -f "$temp_notes"' EXIT

versions=()
while IFS= read -r version; do
  versions+=("$version")
done < <(awk '/^## [0-9]+\.[0-9]+\.[0-9]+ - / { print $2 }' "$CHANGELOG_FILE")

if [[ "${#versions[@]}" -eq 0 ]]; then
  echo "No version sections found in ${CHANGELOG_FILE}." >&2
  exit 1
fi

updated=0
skipped=0

for version in "${versions[@]}"; do
  if [[ -n "$FROM_VERSION" ]] && ! version_gte "$version" "$FROM_VERSION"; then
    continue
  fi

  tag="v${version}"

  if ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    echo "skip ${tag}: release does not exist in ${REPO}"
    skipped=$((skipped + 1))
    continue
  fi

  if ! extract_version_section "$CHANGELOG_FILE" "$version" >"$temp_notes"; then
    echo "skip ${tag}: no matching section in ${CHANGELOG_FILE}"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ ! -s "$temp_notes" ]]; then
    echo "skip ${tag}: extracted notes are empty"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "would update ${tag}"
  else
    gh release edit "$tag" --repo "$REPO" --notes-file "$temp_notes" >/dev/null
    echo "updated ${tag}"
  fi
  updated=$((updated + 1))
done

echo "done: updated=${updated} skipped=${skipped} dry_run=${DRY_RUN}"
