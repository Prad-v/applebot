#!/usr/bin/env bash
# Fails when source code changed without any change under tests/.
#
# Usage (CI):  tests/ci/check_tests_present.sh <base-ref>
#   <base-ref> defaults to origin/$GITHUB_BASE_REF for pull requests, or the previous commit.
# Escape hatch for pure refactors/docs: include "[skip-tests-check]" in the head commit message.
set -euo pipefail

base="${1:-}"
if [[ -z "$base" ]]; then
  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    base="origin/${GITHUB_BASE_REF}"
  elif [[ -n "${GITHUB_EVENT_BEFORE:-}" && "${GITHUB_EVENT_BEFORE}" != "0000000000000000000000000000000000000000" ]]; then
    base="${GITHUB_EVENT_BEFORE}"
  else
    base="HEAD~1"
  fi
fi

if git log -1 --pretty=%B | grep -qF "[skip-tests-check]"; then
  echo "tests-present check skipped by commit message."
  exit 0
fi

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "Base ref '$base' not found; nothing to compare (first commit?). Passing."
  exit 0
fi

changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || git diff --name-only "$base" HEAD)"

source_changes="$(echo "$changed" | grep -E '^(ios/Kit/|ios/App/|backend/services/)' || true)"
test_changes="$(echo "$changed" | grep -E '^tests/' || true)"

if [[ -n "$source_changes" && -z "$test_changes" ]]; then
  echo "ERROR: source files changed but nothing under tests/ did:"
  echo "$source_changes" | sed 's/^/  - /'
  echo
  echo "Add or update tests in tests/ (the single test folder). For pure refactors, add [skip-tests-check] to the commit message."
  exit 1
fi

echo "tests-present check passed."
