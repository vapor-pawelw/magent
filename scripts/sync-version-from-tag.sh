#!/usr/bin/env bash
# Post-build: patch CFBundleShortVersionString in the built Info.plist to match
# the latest git tag. This keeps debug builds in sync with the latest release
# without requiring manual edits to Project.swift.
#
# In CI the release workflow already sed-patches Project.swift before building,
# so this script just reinforces the same value harmlessly.

set -euo pipefail

VERSION=$(git -C "${SRCROOT}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
if [[ -z "$VERSION" ]]; then
    echo "sync-version-from-tag: no git tags found, skipping"
    exit 0
fi

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
if [[ ! -f "$PLIST" ]]; then
    echo "sync-version-from-tag: Info.plist not found at ${PLIST}, skipping"
    exit 0
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
echo "sync-version-from-tag: set CFBundleShortVersionString to $VERSION"
