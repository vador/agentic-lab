#!/usr/bin/env bash
# Entry point: run.sh guard|security
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
case ${1:-} in
  guard | security) exec "$here/$1.sh" ;;
  *) echo "usage: run.sh guard|security" >&2; exit 2 ;;
esac
