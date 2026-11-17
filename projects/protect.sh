#!/usr/bin/env bash
# Create or update the protection of main on one repo, or on every repo of an org:
#  - only the admin may push to / merge into main (agents go through PRs)
#  - the CI checks in REQUIRED_CHECKS must be green before merging, and the admin cannot override that
# Idempotent: re-run after changing REQUIRED_CHECKS or adding CI jobs (perf, security, ...).
source "$(dirname "$0")/../lib/common.sh"
need curl jq

usage() {
  cat <<EOF
Usage: lab project protect <org> [--repo NAME] [--checks "lint unit ..."]

  --repo     only this repository (default: every repository of the org)
  --checks   required checks for this run (default from config: "$REQUIRED_CHECKS")
             "job" = job of workflow "ci"; "workflow/job" = job of another workflow
EOF
}

org=${1:-}
[[ -n $org && $org != -* ]] || { usage; exit 1; }
shift
repo="" checks=$REQUIRED_CHECKS
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --checks) checks=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

# "unit" -> "ci / unit (pull_request)", "security/sast" -> "security / sast (pull_request)"
contexts=()
for c in $checks; do
  if [[ $c == */* ]]; then wf=${c%%/*} job=${c#*/}; else wf=ci job=$c; fi
  contexts+=("$wf / $job (pull_request)")
done
contexts_json=$(printf '%s\n' "${contexts[@]}" | jq -R . | jq -s 'map(select(length > 0))')

if [[ -n $repo ]]; then
  repos=("$repo")
else
  mapfile -t repos < <(gitea_api GET "/orgs/$org/repos?limit=50" | jq -r '.[].name')
  ((${#repos[@]})) || die "no repositories in org $org"
fi

body=$(jq -n --arg a "$GITEA_ADMIN_USER" --argjson ctx "$contexts_json" '{
    rule_name: "main", branch_name: "main",
    enable_push: true, enable_push_whitelist: true, push_whitelist_usernames: [$a],
    enable_merge_whitelist: true, merge_whitelist_usernames: [$a],
    enable_status_check: ($ctx | length > 0), status_check_contexts: $ctx,
    block_admin_merge_override: true,
    block_on_rejected_reviews: true, block_on_outdated_branch: false
  }')

for r in "${repos[@]}"; do
  if gitea_api GET "/repos/$org/$r/branch_protections" | jq -e 'any(.[]; .rule_name == "main")' >/dev/null; then
    gitea_api PATCH "/repos/$org/$r/branch_protections/main" "$(jq 'del(.rule_name, .branch_name)' <<<"$body")" >/dev/null
  else
    gitea_api POST "/repos/$org/$r/branch_protections" "$body" >/dev/null
  fi
  log "$org/$r: main protected; required checks: ${checks:-(none)}"
done
