#!/usr/bin/env bash
set -euo pipefail

DUMP_DIR="${MYSQL_DUMP_DIR:-/mnt/dump}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
DB_NAME="${db_name:-${DB_NAME:-}}"
DB_USER="${db_user:-${DB_USER:-}}"
DB_USER_PASSWORD="${db_user_password:-${DB_USER_PASSWORD:-}}"

usage() {
  cat <<EOF
Usage: mysql-import-dump.sh <dump-file-name>

Examples:
  mysql-import-dump.sh mydump.sql
  mysql-import-dump.sh backup.sql.gz
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${1:-}" ]]; then
  usage
  echo
  echo "Available files in ${DUMP_DIR}:"
  ls -1 "${DUMP_DIR}" 2>/dev/null || true
  exit 1
fi

if [[ -n "${2:-}" ]]; then
  echo "Database argument is ignored. Using db_name from environment."
fi

dump_name="$1"
if [[ "${dump_name}" == *"/"* || "${dump_name}" == *"\\"* ]]; then
  echo "Only dump file names are allowed (no path). Expected file in ${DUMP_DIR}."
  exit 1
fi

dump_file="${DUMP_DIR}/${dump_name}"

if [[ ! -f "${dump_file}" ]]; then
  echo "Dump file not found: ${dump_file}"
  exit 1
fi

dump_hash_before="$(sha256sum "${dump_file}" | awk '{print $1}')"
if [[ "${dump_file}" == *.gz ]]; then
  gzip -t "${dump_file}"
fi

if [[ -z "${DB_NAME}" ]]; then
  echo "db_name must be set."
  exit 1
fi

if [[ -z "${DB_USER}" ]]; then
  echo "db_user must be set."
  exit 1
fi

if [[ -z "${DB_USER_PASSWORD}" ]]; then
  echo "db_user_password must be set."
  exit 1
fi

mysql_base=(
  mysql
  -h"${MYSQL_HOST}"
  -P"${MYSQL_PORT}"
  -u"${DB_USER}"
  -p"${DB_USER_PASSWORD}"
)

echo "Using database from db_name: ${DB_NAME}"
"${mysql_base[@]}" -D"${DB_NAME}" -e "SELECT 1;" >/dev/null

echo "Importing dump: ${dump_file} -> ${DB_NAME}"
if [[ "${dump_file}" == *.gz ]]; then
  gzip -dc "${dump_file}" | "${mysql_base[@]}" "${DB_NAME}"
else
  "${mysql_base[@]}" "${DB_NAME}" < "${dump_file}"
fi

dump_hash_after="$(sha256sum "${dump_file}" | awk '{print $1}')"
if [[ "${dump_hash_before}" != "${dump_hash_after}" ]]; then
  echo "Dump integrity check failed: file changed during import."
  exit 1
fi

echo "Import finished."
