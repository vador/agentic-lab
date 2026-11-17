#!/usr/bin/env bash
# Test + pipeline integrity: catches the usual ways an agent "makes CI green" without fixing anything.
# Applies to PRs opened by agents (bot-*). Human PRs are trusted and only get a summary.
source "$(dirname "$0")/lib.sh"

# Test files, by common conventions (Python, JS/TS, Go, Java/Kotlin/C#, Ruby, Rust tests/ dirs)
TEST_FILES='(^|/)(tests?|__tests__|specs?|e2e)/|(^|/)test_[^/]*\.py$|_test\.(py|go)$|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)(Test[^/]*|[^/]*Tests?)\.(java|kt|cs)$|_spec\.rb$'
# Lines that declare a test
TEST_DECL='^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+test_|^[[:space:]]*func[[:space:]]+Test[A-Z_0-9]|^[[:space:]]*(it|test)(\.each\(.*\))?[[:space:]]*\(|@Test\b|#\[(tokio::)?test\]|^[[:space:]]*it[[:space:]]+["'"'"']'
# Added lines with these fail: skipped/focused tests, coverage or security exclusions
FORBIDDEN='pytest\.mark\.(skip|xfail)|pytest\.skip\(|unittest\.skip|@skip(If|Unless)?\b|\b(it|test|describe|context)\.(skip|only|todo)\(|\bx(it|test|describe)\(|\bf(it|describe)\(|\bt\.Skip(Now|f)?\(|@Disabled\b|@Ignore\b|#\[ignore\]|pragma:?[[:space:]]*no[[:space:]]*cover|istanbul[[:space:]]+ignore|c8[[:space:]]+ignore|#[[:space:]]*nosec|//[[:space:]]*#nosec|gitleaks:allow|trivy:ignore|nosemgrep'
# Added lines with these only warn: lint/type suppressions (sometimes legitimate)
SUPPRESSIONS='#[[:space:]]*noqa|eslint-disable|@ts-(ignore|nocheck|expect-error)|#[[:space:]]*type:[[:space:]]*ignore|//[[:space:]]*nolint|pylint:[[:space:]]*disable|@SuppressWarnings|#!?\[allow\('
# Changes to these files only warn: test/coverage configuration
TEST_CONFIG='(^|/)(pytest\.ini|\.coveragerc|setup\.cfg|tox\.ini|codecov\.ya?ml|\.nycrc(\.json)?|(jest|vitest|karma|playwright)\.config\.[cm]?[jt]s)$'

count_tests() { # REV -> number of test declarations in test files at REV
  local rev=$1 files
  mapfile -t files < <(git ls-tree -r --name-only "$rev" | grep -E "$TEST_FILES" || true)
  ((${#files[@]})) || { echo 0; return; }
  git grep -hcE "$TEST_DECL" "$rev" -- "${files[@]}" 2>/dev/null | awk '{s += $1} END {print s + 0}'
}

pr_context
if ((!IS_PR)); then
  echo "Not a pull request: integrity checks only apply to PRs."
  exit 0
fi
echo "PR by '$AUTHOR': $(git log --oneline -1 "$HEAD_SHA" | cut -c1-80)"
echo "Compared with merge-base $(git rev-parse --short "$BASE")"

if ! is_agent; then
  echo "Author is a human: integrity rules are not enforced (summary only)."
fi

section "Pipeline integrity (paths only humans may change)"
mapfile -t touched < <(git diff --name-only "$BASE" "$HEAD_SHA" | grep -E "$HUMAN_ONLY_PATHS" || true)
if ((${#touched[@]})); then
  for f in "${touched[@]}"; do
    if is_agent; then fail "agent changed human-only file: $f"; else warn "human changed pipeline file: $f"; fi
  done
else
  ok "no pipeline / scanner-config changes"
fi

section "Deleted test files"
mapfile -t deleted < <(git diff --name-only --diff-filter=D -M "$BASE" "$HEAD_SHA" | grep -E "$TEST_FILES" || true)
if ((${#deleted[@]})); then
  for f in "${deleted[@]}"; do
    if is_agent; then fail "test file deleted: $f"; else warn "test file deleted: $f"; fi
  done
else
  ok "no test files deleted"
fi

section "Number of tests"
before=$(count_tests "$BASE")
after=$(count_tests "$HEAD_SHA")
if ((after < before)); then
  if is_agent; then fail "tests went from $before to $after"; else warn "tests went from $before to $after"; fi
else
  ok "tests: $before → $after"
fi

section "Skipped tests, coverage / security exclusions, suppressions"
# Added lines, prefixed with their file name (docs excluded)
added=$(git diff -U0 "$BASE" "$HEAD_SHA" -- . ':(exclude)*.md' ':(exclude)*.rst' ':(exclude)*.txt' |
  awk '/^\+\+\+ b\// {f = substr($0, 7); next} /^\+/ && !/^\+\+\+/ {print f ": " substr($0, 2)}')
hits=$(grep -E "$FORBIDDEN" <<<"$added" || true)
if [[ -n $hits ]]; then
  while IFS= read -r l; do
    if is_agent; then fail "forbidden marker added → ${l:0:160}"; else warn "marker added → ${l:0:160}"; fi
  done <<<"$hits"
else
  ok "no skipped/focused tests or coverage/security exclusions added"
fi
sup=$(grep -E "$SUPPRESSIONS" <<<"$added" || true)
if [[ -n $sup ]]; then
  while IFS= read -r l; do warn "suppression added (review it) → ${l:0:160}"; done <<<"$sup"
fi
mapfile -t cfg < <(git diff --name-only "$BASE" "$HEAD_SHA" | grep -E "$TEST_CONFIG" || true)
for f in "${cfg[@]}"; do warn "test/coverage config changed (review it): $f"; done

echo
if ((FAILED)); then
  echo "guard: FAILED — fix the code instead of weakening tests or the pipeline."
  echo "If the change is intended, a human must make it (agents cannot)."
  exit 1
fi
echo "guard: OK"
