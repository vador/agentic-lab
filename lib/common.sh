#!/usr/bin/env bash
# Shared helpers — sourced by every host-side script.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env.example
source "$LAB_ROOT/config.env.example"
if [[ -f "$LAB_ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  source "$LAB_ROOT/config.env"
fi

export LIBVIRT_DEFAULT_URI="qemu:///system"
SECRETS_DIR="$LAB_ROOT/.secrets"
GITEA_API_URL="http://127.0.0.1:${GITEA_HTTP_PORT}"               # used from the host
GITEA_INTERNAL_URL="http://gitea.${LAB_DOMAIN}:${GITEA_HTTP_PORT}"  # used from VMs
VM_PREFIX="lab-"
LAB_TZ="$(readlink -f /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##')"
[[ -n $LAB_TZ && $LAB_TZ != /* ]] || LAB_TZ=UTC

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }
need() { local c; for c in "$@"; do command -v "$c" >/dev/null || die "missing command '$c' (run: lab host install)"; done; }
confirm() { local a; read -r -p "$1 [y/N] " a; [[ $a == [yY]* ]]; }

randpw() {
  local s
  s=$(head -c 256 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9')
  printf '%s\n' "${s:0:${1:-32}}"
}

ensure_secrets_dir() { mkdir -p "$SECRETS_DIR/bots"; chmod 700 "$SECRETS_DIR" "$SECRETS_DIR/bots"; }

# virsh / virt-install / docker, falling back to sudo until your new group membership is active
_VSH="" _DK=""
vsh() {
  if [[ -z $_VSH ]]; then
    if virsh -q list >/dev/null 2>&1; then _VSH="virsh"; else _VSH="sudo virsh -c $LIBVIRT_DEFAULT_URI"; fi
  fi
  $_VSH "$@"
}
vinst() { if virsh -q list >/dev/null 2>&1; then virt-install "$@"; else sudo virt-install "$@"; fi; }
dk() {
  if [[ -z $_DK ]]; then
    if docker info >/dev/null 2>&1; then _DK="docker"; else _DK="sudo docker"; fi
  fi
  $_DK "$@"
}

# ---- Gitea API (admin token created by `lab services up`) ----
gitea_token() {
  [[ -s "$SECRETS_DIR/gitea-admin-token" ]] || die "no Gitea admin token; run: lab services up"
  cat "$SECRETS_DIR/gitea-admin-token"
}
gitea_api() { # METHOD PATH [JSON]
  local method=$1 path=$2 data=${3:-}
  local args=(-sS --fail-with-body -X "$method" -H "Authorization: token $(gitea_token)" -H 'Accept: application/json')
  if [[ -n $data ]]; then args+=(-H 'Content-Type: application/json' --data "$data"); fi
  curl "${args[@]}" "$GITEA_API_URL/api/v1$path"
}
gitea_exists() { # PATH -> 0 if GET returns 200
  [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $(gitea_token)" "$GITEA_API_URL/api/v1$1") == 200 ]]
}
