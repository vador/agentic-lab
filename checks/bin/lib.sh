#!/usr/bin/env bash
# Shared helpers for the checks. Expects to run in an actions/checkout'ed repo (fetch-depth: 0).
set -euo pipefail

FAILED=0
fail() { echo "::error::$*"; echo "  ✗ $*"; FAILED=1; }
warn() { echo "::warning::$*"; echo "  ! $*"; }
ok()   { echo "  ✓ $*"; }
section() { echo; echo "── $* ──"; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true

# Sets IS_PR, BASE (merge-base with the target branch), HEAD_SHA, AUTHOR
pr_context() {
  IS_PR=0 BASE="" HEAD_SHA=$(git rev-parse HEAD) AUTHOR=""
  if [[ ${GITHUB_EVENT_NAME:-} == pull_request* && -f ${GITHUB_EVENT_PATH:-} ]]; then
    local base_sha
    base_sha=$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")
    HEAD_SHA=$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")
    AUTHOR=$(jq -r '.pull_request.user.login // empty' "$GITHUB_EVENT_PATH")
    local base_ref
    base_ref=$(jq -r '.pull_request.base.ref // "main"' "$GITHUB_EVENT_PATH")
    git cat-file -e "$base_sha^{commit}" 2>/dev/null || git fetch -q origin "$base_ref" || true
    git cat-file -e "$base_sha^{commit}" 2>/dev/null || base_sha=$(git rev-parse "origin/$base_ref")
    BASE=$(git merge-base "$base_sha" "$HEAD_SHA")
    IS_PR=1
  fi
}

# Agents commit and open PRs as bot-<org>; everyone else counts as a human.
is_agent() { [[ $AUTHOR == bot-* ]]; }
