#!/bin/bash
# Embeds CHANGELOG.md, git commit hash, and incremental build number at build time.
# Called as an Xcode post-build script phase.

set -euo pipefail

OUTPUT_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
REPO_ROOT="${SRCROOT}"
PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"

# Copy CHANGELOG.md
cp "${REPO_ROOT}/CHANGELOG.md" "${OUTPUT_DIR}/CHANGELOG.md"

# Write build metadata (commit hash)
COMMIT_HASH=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "${COMMIT_HASH}" > "${OUTPUT_DIR}/BUILD_COMMIT"

# Set incremental build number from git commit count
BUILD_NUMBER=$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo "1")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"
