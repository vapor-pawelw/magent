#!/usr/bin/env bash
# Patch CFBundleShortVersionString to match the latest git tag so debug builds
# show the real release version instead of the placeholder `1.0` baked into
# Project.swift.
#
# This script must patch BOTH plists:
#
#   1. The Tuist-generated SOURCE plist at
#      ${SRCROOT}/Derived/InfoPlists/Magent-Info.plist
#      Xcode's "Process Info.plist" phase reads this template and copies the
#      processed result into the bundle. If we only patched the built plist,
#      Process Info.plist would clobber our edit because, in practice,
#      run-script phases run *before* Process Info.plist in this target's
#      build order.
#
#   2. The built/processed plist inside the .app bundle (when present),
#      as a defense-in-depth in case the build order ever changes.
#
# In CI, the release workflow already sed-patches Project.swift before
# building, so this script just reinforces the same value harmlessly.

set -euo pipefail

VERSION=$(git -C "${SRCROOT}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
if [[ -z "$VERSION" ]]; then
    echo "sync-version-from-tag: no git tags found, skipping"
    exit 0
fi

patched_any=0

SOURCE_PLIST="${SRCROOT}/Derived/InfoPlists/Magent-Info.plist"
if [[ -f "$SOURCE_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$SOURCE_PLIST"
    echo "sync-version-from-tag: patched source plist at $SOURCE_PLIST -> $VERSION"
    patched_any=1
fi

if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${INFOPLIST_PATH:-}" ]]; then
    BUILT_PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
    if [[ -f "$BUILT_PLIST" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUILT_PLIST"
        echo "sync-version-from-tag: patched built plist at $BUILT_PLIST -> $VERSION"
        patched_any=1
    fi
fi

if [[ "$patched_any" -eq 0 ]]; then
    echo "sync-version-from-tag: no Info.plist found to patch, skipping"
fi
