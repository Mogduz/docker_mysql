#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  echo "Usage: ./import-dump.sh <dump-file-name>"
  exit 1
fi

if [[ "${1}" == *"/"* || "${1}" == *"\\"* ]]; then
  echo "Only dump file names are allowed (no path)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_DIR}"

docker compose exec -T mysql mysql-import-dump.sh "$@"
