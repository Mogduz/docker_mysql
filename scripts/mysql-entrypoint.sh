#!/usr/bin/env bash
set -euo pipefail

DATADIR="/var/lib/mysql"
SOCKET="/var/run/mysqld/mysqld.sock"
ROOT_USER="${root_user:-${ROOT_USER:-root}}"
ROOT_PASSWORD="${root_password:-${ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}}"
DB_NAME="${db_name:-${DB_NAME:-${MYSQL_DATABASE:-}}}"
DB_USER="${db_user:-${DB_USER:-${MYSQL_USER:-}}}"
DB_USER_PASSWORD="${db_user_password:-${DB_USER_PASSWORD:-}}"
DUMP_DIR="${MYSQL_DUMP_DIR:-/mnt/dump}"
DUMP_FILE="${dump_file:-${DUMP_FILE:-}}"
DUMP_FILE_PATH=""

log() {
  echo "[mysql-entrypoint] $*"
}

fail() {
  echo "[mysql-entrypoint] ERROR: $*" >&2
  exit 1
}

count_tables_in_db() {
  local db_name_sql
  db_name_sql="${DB_NAME//\'/\'\'}"
  mysql --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" -Nse \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db_name_sql}';"
}

if [[ -z "${ROOT_PASSWORD}" ]]; then
  fail "root_password (or ROOT_PASSWORD / MYSQL_ROOT_PASSWORD) must be set."
fi

db_cfg_count=0
[[ -n "${DB_NAME}" ]] && ((db_cfg_count+=1))
[[ -n "${DB_USER}" ]] && ((db_cfg_count+=1))
[[ -n "${DB_USER_PASSWORD}" ]] && ((db_cfg_count+=1))

if (( db_cfg_count > 0 && db_cfg_count < 3 )); then
  fail "db_name, db_user and db_user_password must be set together."
fi

if [[ -n "${DUMP_FILE}" ]]; then
  if (( db_cfg_count != 3 )); then
    fail "dump_file requires db_name, db_user and db_user_password."
  fi

  if [[ "${DUMP_FILE}" == *"/"* || "${DUMP_FILE}" == *"\\"* ]]; then
    fail "dump_file must be a file name only (no path). File is read from ${DUMP_DIR}."
  fi

  DUMP_FILE_PATH="${DUMP_DIR}/${DUMP_FILE}"

  if [[ ! -f "${DUMP_FILE_PATH}" ]]; then
    fail "Configured dump_file not found: ${DUMP_FILE_PATH}"
  fi
fi

start_temp_mysql() {
  log "Starting temporary MySQL server on socket ${SOCKET}..."
  mysqld --user=mysql --datadir="${DATADIR}" --skip-networking --socket="${SOCKET}" &
  mysql_pid="$!"

  for i in {30..0}; do
    if mysqladmin --protocol=socket --socket="${SOCKET}" ping >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if [[ "${i}" == "0" ]]; then
    fail "Temporary MySQL startup failed during initialization."
  fi

  log "Temporary MySQL server is ready."
}

stop_temp_mysql() {
  log "Stopping temporary MySQL server..."
  mysqladmin --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" shutdown
  wait "${mysql_pid}"
  log "Temporary MySQL server stopped."
}

import_dump_if_configured() {
  if [[ -z "${DUMP_FILE_PATH}" ]]; then
    log "No dump_file configured. Skipping auto-import."
    return
  fi

  tables_before="$(count_tables_in_db)"
  dump_hash_before="$(sha256sum "${DUMP_FILE_PATH}" | awk '{print $1}')"
  if [[ "${DUMP_FILE_PATH}" == *.gz ]]; then
    log "Validating compressed dump integrity with gzip -t..."
    gzip -t "${DUMP_FILE_PATH}"
  fi

  log "Auto-import enabled. Importing ${DUMP_FILE_PATH} into ${DB_NAME} as ${DB_USER}..."
  if [[ "${DUMP_FILE_PATH}" == *.gz ]]; then
    gzip -dc "${DUMP_FILE_PATH}" | mysql --protocol=socket --socket="${SOCKET}" \
      -u"${DB_USER}" -p"${DB_USER_PASSWORD}" "${DB_NAME}"
  else
    mysql --protocol=socket --socket="${SOCKET}" \
      -u"${DB_USER}" -p"${DB_USER_PASSWORD}" "${DB_NAME}" < "${DUMP_FILE_PATH}"
  fi

  dump_hash_after="$(sha256sum "${DUMP_FILE_PATH}" | awk '{print $1}')"
  if [[ "${dump_hash_before}" != "${dump_hash_after}" ]]; then
    fail "Auto-import integrity check failed: dump file changed during import."
  fi

  tables_after="$(count_tables_in_db)"
  tables_delta=$((tables_after - tables_before))
  log "Auto-import finished successfully."
  log "Imported tables summary for ${DB_NAME}: before=${tables_before}, after=${tables_after}, new=${tables_delta}."
}

log "Entrypoint started. Preparing MySQL runtime directories..."
mkdir -p /var/run/mysqld "${DATADIR}"
chown -R mysql:mysql /var/run/mysqld "${DATADIR}"

if [[ ! -d "${DATADIR}/mysql" ]]; then
  log "No existing data directory found. Initializing new MySQL data directory..."
  mysqld --initialize-insecure --user=mysql --datadir="${DATADIR}"

  start_temp_mysql

  root_user_sql="${ROOT_USER//\'/\'\'}"
  root_password_sql="${ROOT_PASSWORD//\'/\'\'}"

  mysql --protocol=socket --socket="${SOCKET}" -uroot <<-EOSQL
    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${root_password_sql}';
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${root_password_sql}';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
EOSQL

  if [[ "${ROOT_USER}" != "root" ]]; then
    log "Creating configured admin user '${ROOT_USER}'..."
    mysql --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" <<-EOSQL
      CREATE USER IF NOT EXISTS '${root_user_sql}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${root_password_sql}';
      CREATE USER IF NOT EXISTS '${root_user_sql}'@'%' IDENTIFIED WITH mysql_native_password BY '${root_password_sql}';
      GRANT ALL PRIVILEGES ON *.* TO '${root_user_sql}'@'localhost' WITH GRANT OPTION;
      GRANT ALL PRIVILEGES ON *.* TO '${root_user_sql}'@'%' WITH GRANT OPTION;
EOSQL
  fi

  if (( db_cfg_count == 3 )); then
    log "Creating application database/user and granting privileges..."
    db_name_sql="${DB_NAME//\`/\`\`}"
    db_user_sql="${DB_USER//\'/\'\'}"
    db_user_password_sql="${DB_USER_PASSWORD//\'/\'\'}"

    mysql --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" <<-EOSQL
      CREATE DATABASE IF NOT EXISTS \`${db_name_sql}\`;
      CREATE USER IF NOT EXISTS '${db_user_sql}'@'%' IDENTIFIED BY '${db_user_password_sql}';
      CREATE USER IF NOT EXISTS '${db_user_sql}'@'localhost' IDENTIFIED BY '${db_user_password_sql}';
      ALTER USER '${db_user_sql}'@'%' IDENTIFIED BY '${db_user_password_sql}';
      ALTER USER '${db_user_sql}'@'localhost' IDENTIFIED BY '${db_user_password_sql}';
      GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${db_user_sql}'@'%';
      GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${db_user_sql}'@'localhost';
      FLUSH PRIVILEGES;
EOSQL
  else
    log "No complete db_* configuration provided. Skipping application DB/user creation."
  fi

  import_dump_if_configured
  stop_temp_mysql
elif [[ -n "${DUMP_FILE_PATH}" ]]; then
  log "Existing data directory found. Running configured auto-import..."
  start_temp_mysql
  import_dump_if_configured
  stop_temp_mysql
else
  log "Existing data directory found. No auto-import requested."
fi

log "Starting MySQL server for normal operation..."
exec mysqld --user=mysql --datadir="${DATADIR}" --bind-address=0.0.0.0
