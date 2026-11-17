#!/usr/bin/env bash
# Security scan: secrets (gitleaks, on the PR's commits) and vulnerable dependencies,
# IaC/Dockerfile misconfigurations and secrets in the tree (trivy). Fails on HIGH/CRITICAL.
source "$(dirname "$0")/lib.sh"

# Pinned tools, verified by SHA-256 (bump deliberately: update version + checksum together)
GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
TRIVY_VERSION=0.76.1
TRIVY_SHA256=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0
SEVERITY=${SECURITY_SEVERITY:-HIGH,CRITICAL}

tools=${RUNNER_TEMP:-/tmp}/agentlab-checks-tools
mkdir -p "$tools"
fetch() { # NAME URL SHA256
  local name=$1 url=$2 sum=$3 tgz="$tools/$1.tgz"
  [[ -x $tools/$name ]] && return
  curl -fsSL --retry 3 -o "$tgz" "$url"
  echo "$sum  $tgz" | sha256sum -c --quiet - || { echo "checksum mismatch for $name" >&2; exit 1; }
  tar -xzf "$tgz" -C "$tools" "$name"
  rm -f "$tgz"
}
fetch gitleaks "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" "$GITLEAKS_SHA256"
fetch trivy "https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" "$TRIVY_SHA256"

pr_context

section "Secrets (gitleaks)"
if ((IS_PR)); then
  scope=(git --log-opts="$BASE..$HEAD_SHA")
  echo "scanning the PR's commits ($(git rev-list --count "$BASE..$HEAD_SHA"))"
else
  scope=(dir)
  echo "scanning the working tree"
fi
if "$tools/gitleaks" "${scope[@]}" --redact --no-banner --exit-code 1 .; then
  ok "no secrets found"
else
  fail "gitleaks found secrets (see above). Remove them AND rotate them: they are in git history."
fi

section "Vulnerable dependencies, misconfigurations, secrets in files (trivy, $SEVERITY)"
if "$tools/trivy" fs --quiet --scanners vuln,misconfig,secret --severity "$SEVERITY" --ignore-unfixed \
  --skip-dirs .git --exit-code 1 --format table .; then
  ok "no $SEVERITY findings"
else
  fail "trivy found $SEVERITY issues (see above): upgrade the dependency or fix the configuration"
fi

echo
if ((FAILED)); then echo "security: FAILED"; exit 1; fi
echo "security: OK"
