#!/usr/bin/env bash

set -euo pipefail

RELEASE_WORKFLOW_NAME="Release"
DEFAULT_HOMEBREW_TAP_REPO="vapor-pawelw/homebrew-magent"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

infer_owner_repo() {
  local remote_url
  remote_url="$(git config --get remote.origin.url || true)"
  if [[ -z "$remote_url" ]]; then
    return 1
  fi

  if [[ "$remote_url" =~ ^git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$remote_url" =~ ^https://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$remote_url" =~ ^ssh://git@github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

default_next_patch() {
  local latest_tag="$1"
  local clean
  clean="${latest_tag#v}"
  if [[ "$clean" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    local major minor patch
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    echo "${major}.${minor}.$((patch + 1))"
    return 0
  fi
  return 1
}

confirm() {
  local prompt="$1"
  local response
  read -r -p "$prompt [y/N]: " response
  [[ "${response,,}" == "y" || "${response,,}" == "yes" ]]
}

wait_for_release_run_id() {
  local owner_repo="$1"
  local tag="$2"
  local run_id=""
  local attempt

  for attempt in $(seq 1 36); do
    run_id="$(gh run list \
      --repo "$owner_repo" \
      --workflow "$RELEASE_WORKFLOW_NAME" \
      --limit 40 \
      --json databaseId,event,headBranch,createdAt \
      --jq ".[] | select(.event == \"push\" and .headBranch == \"$tag\") | .databaseId" | head -n1 || true)"

    if [[ -n "$run_id" ]]; then
      echo "$run_id"
      return 0
    fi

    sleep 5
  done

  return 1
}

verify_release_asset() {
  local owner_repo="$1"
  local tag="$2"

  if ! gh release view "$tag" --repo "$owner_repo" --json assets --jq '.assets[].name' | grep -qx "Magent.zip"; then
    echo "Release exists but Magent.zip was not found on $tag." >&2
    return 1
  fi
}

read_homebrew_cask() {
  local tap_repo="$1"
  gh api -H "Accept: application/vnd.github.raw" "repos/${tap_repo}/contents/Casks/magent.rb"
}

verify_homebrew_version() {
  local tap_repo="$1"
  local version="$2"
  local cask_content cask_version cask_sha

  cask_content="$(read_homebrew_cask "$tap_repo")"
  cask_version="$(printf '%s\n' "$cask_content" | sed -n 's/^[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  cask_sha="$(printf '%s\n' "$cask_content" | sed -n 's/^[[:space:]]*sha256[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  if [[ "$cask_version" != "$version" ]]; then
    echo "Homebrew cask is at version '$cask_version', expected '$version'." >&2
    return 1
  fi

  if [[ -z "$cask_sha" ]]; then
    echo "Homebrew cask has an empty sha256 field." >&2
    return 1
  fi

  echo "$cask_sha"
}

wait_for_homebrew_update() {
  local tap_repo="$1"
  local version="$2"
  local sha=""
  local attempt

  for attempt in $(seq 1 30); do
    if sha="$(verify_homebrew_version "$tap_repo" "$version" 2>/dev/null)"; then
      printf '%s\n' "$sha"
      return 0
    fi
    sleep 10
  done

  return 1
}

main() {
  require_cmd git
  require_cmd gh
  require_cmd sed
  require_cmd grep

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Run this script from inside a git repository." >&2
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
    exit 1
  fi

  local owner_repo
  owner_repo="$(infer_owner_repo || true)"
  if [[ -z "$owner_repo" ]]; then
    echo "Could not infer GitHub owner/repo from origin remote." >&2
    exit 1
  fi

  local tap_repo
  tap_repo="${MAGENT_HOMEBREW_TAP_REPO:-$DEFAULT_HOMEBREW_TAP_REPO}"

  local branch latest_tag default_version version tag
  branch="$(git branch --show-current)"
  latest_tag="$(git tag --sort=-v:refname | head -n1 || true)"
  default_version=""
  if [[ -n "$latest_tag" ]]; then
    default_version="$(default_next_patch "$latest_tag" || true)"
  fi

  echo "Repository: $owner_repo"
  echo "Current branch: ${branch:-detached}"
  if [[ -n "$latest_tag" ]]; then
    echo "Latest tag: $latest_tag"
  else
    echo "No tags found yet."
  fi

  if [[ -n "$default_version" ]]; then
    read -r -p "Version to release (e.g. 1.2.3) [$default_version]: " version
    version="${version:-$default_version}"
  else
    read -r -p "Version to release (e.g. 1.2.3): " version
  fi

  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version '$version'. Use semantic version format like 1.2.3." >&2
    exit 1
  fi

  tag="v${version}"

  if [[ "$branch" != "main" ]]; then
    echo "Warning: you are not on 'main' (current: ${branch:-detached})."
    if ! confirm "Continue anyway"; then
      echo "Aborted."
      exit 0
    fi
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Warning: working tree has uncommitted changes."
    if ! confirm "Continue anyway"; then
      echo "Aborted."
      exit 0
    fi
  fi

  if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "Tag '$tag' already exists locally." >&2
    exit 1
  fi
  if git ls-remote --tags origin "refs/tags/${tag}" | grep -q .; then
    echo "Tag '$tag' already exists on origin." >&2
    exit 1
  fi

  local commit
  commit="$(git rev-parse --short HEAD)"
  echo
  echo "Release plan:"
  echo "- Create and push tag: $tag"
  echo "- Source commit: $commit"
  echo "- Watch workflow: $RELEASE_WORKFLOW_NAME"
  echo "- Verify GitHub release contains Magent.zip"
  echo "- Verify Homebrew tap ${tap_repo} points to version ${version}"
  echo

  if ! confirm "Proceed with this release"; then
    echo "Aborted."
    exit 0
  fi

  git tag "$tag"
  if ! git push origin "$tag"; then
    echo "Failed to push tag. Cleaning up local tag '$tag'." >&2
    git tag -d "$tag" >/dev/null 2>&1 || true
    exit 1
  fi

  echo "Tag pushed. Waiting for GitHub Actions run..."
  local run_id
  run_id="$(wait_for_release_run_id "$owner_repo" "$tag" || true)"
  if [[ -z "$run_id" ]]; then
    echo "Could not find the '${RELEASE_WORKFLOW_NAME}' run for tag ${tag}." >&2
    echo "Check manually with: gh run list --workflow \"${RELEASE_WORKFLOW_NAME}\" --repo ${owner_repo}" >&2
    exit 1
  fi

  echo "Watching workflow run $run_id..."
  gh run watch "$run_id" --repo "$owner_repo" --exit-status

  echo "Verifying GitHub release assets..."
  verify_release_asset "$owner_repo" "$tag"

  echo "Verifying Homebrew tap update in ${tap_repo}..."
  local cask_sha
  cask_sha="$(wait_for_homebrew_update "$tap_repo" "$version" || true)"
  if [[ -z "$cask_sha" ]]; then
    echo "Release completed, but Homebrew tap did not update to ${version} in time." >&2
    echo "Check manually: https://github.com/${tap_repo}/blob/main/Casks/magent.rb" >&2
    exit 1
  fi

  local release_url
  release_url="$(gh release view "$tag" --repo "$owner_repo" --json url --jq '.url')"

  echo
  echo "Release complete."
  echo "- Tag: ${tag}"
  echo "- GitHub release: ${release_url}"
  echo "- Homebrew cask: https://github.com/${tap_repo}/blob/main/Casks/magent.rb"
  echo "- Homebrew sha256: ${cask_sha}"
}

main "$@"
