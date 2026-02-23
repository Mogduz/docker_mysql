#!/usr/bin/env bash
set -euo pipefail

DATADIR="/var/lib/mysql"
SOCKET="/var/run/mysqld/mysqld.sock"
ROOT_USER="${root_user:-${ROOT_USER:-root}}"
ROOT_PASSWORD="${root_password:-${ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}}"
DB_NAME="${db_name:-${DB_NAME:-${MYSQL_DATABASE:-}}}"
DB_USER="${db_user:-${DB_USER:-${MYSQL_USER:-}}}"
DB_PASSWORD="${db_password:-${DB_PASSWORD:-${MYSQL_PASSWORD:-}}}"
DUMP_DIR="${MYSQL_DUMP_DIR:-/mnt/dump}"
DUMP_FILE="${dump_file:-${DUMP_FILE:-}}"
DUMP_FILE_PATH=""

if [[ -z "${ROOT_PASSWORD}" ]]; then
  echo "root_password (or ROOT_PASSWORD / MYSQL_ROOT_PASSWORD) must be set."
  exit 1
fi

db_cfg_count=0
[[ -n "${DB_NAME}" ]] && ((db_cfg_count+=1))
[[ -n "${DB_USER}" ]] && ((db_cfg_count+=1))
[[ -n "${DB_PASSWORD}" ]] && ((db_cfg_count+=1))

if (( db_cfg_count > 0 && db_cfg_count < 3 )); then
  echo "db_name, db_user and db_password must be set together."
  exit 1
fi

if [[ -n "${DUMP_FILE}" ]]; then
  if (( db_cfg_count != 3 )); then
    echo "dump_file requires db_name, db_user and db_password."
    exit 1
  fi

  if [[ "${DUMP_FILE}" = /* ]]; then
    DUMP_FILE_PATH="${DUMP_FILE}"
  else
    DUMP_FILE_PATH="${DUMP_DIR}/${DUMP_FILE}"
  fi

  if [[ ! -f "${DUMP_FILE_PATH}" ]]; then
    echo "Configured dump_file not found: ${DUMP_FILE_PATH}"
    exit 1
  fi
fi

start_temp_mysql() {
  mysqld --user=mysql --datadir="${DATADIR}" --skip-networking --socket="${SOCKET}" &
  mysql_pid="$!"

  for i in {30..0}; do
    if mysqladmin --protocol=socket --socket="${SOCKET}" ping >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if [[ "${i}" == "0" ]]; then
    echo "MySQL startup failed during initialization."
    exit 1
  fi
}

stop_temp_mysql() {
  mysqladmin --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" shutdown
  wait "${mysql_pid}"
}

import_dump_if_configured() {
  if [[ -z "${DUMP_FILE_PATH}" ]]; then
    return
  fi

  dump_hash_before="$(sha256sum "${DUMP_FILE_PATH}" | awk '{print $1}')"
  if [[ "${DUMP_FILE_PATH}" == *.gz ]]; then
    gzip -t "${DUMP_FILE_PATH}"
  fi

  echo "Auto-import enabled. Importing ${DUMP_FILE_PATH} into ${DB_NAME} as ${DB_USER}..."
  if [[ "${DUMP_FILE_PATH}" == *.gz ]]; then
    gzip -dc "${DUMP_FILE_PATH}" | mysql --protocol=socket --socket="${SOCKET}" \
      -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}"
  else
    mysql --protocol=socket --socket="${SOCKET}" \
      -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" < "${DUMP_FILE_PATH}"
  fi

  dump_hash_after="$(sha256sum "${DUMP_FILE_PATH}" | awk '{print $1}')"
  if [[ "${dump_hash_before}" != "${dump_hash_after}" ]]; then
    echo "Auto-import integrity check failed: dump file changed during import."
    exit 1
  fi

  echo "Auto-import finished."
}

mkdir -p /var/run/mysqld "${DATADIR}"
chown -R mysql:mysql /var/run/mysqld "${DATADIR}"

if [[ ! -d "${DATADIR}/mysql" ]]; then
  echo "Initializing MySQL data directory..."
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
    mysql --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" <<-EOSQL
      CREATE USER IF NOT EXISTS '${root_user_sql}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${root_password_sql}';
      CREATE USER IF NOT EXISTS '${root_user_sql}'@'%' IDENTIFIED WITH mysql_native_password BY '${root_password_sql}';
      GRANT ALL PRIVILEGES ON *.* TO '${root_user_sql}'@'localhost' WITH GRANT OPTION;
      GRANT ALL PRIVILEGES ON *.* TO '${root_user_sql}'@'%' WITH GRANT OPTION;
EOSQL
  fi

  if (( db_cfg_count == 3 )); then
    db_name_sql="${DB_NAME//\`/\`\`}"
    db_user_sql="${DB_USER//\'/\'\'}"
    db_password_sql="${DB_PASSWORD//\'/\'\'}"

    mysql --protocol=socket --socket="${SOCKET}" -uroot -p"${ROOT_PASSWORD}" <<-EOSQL
      CREATE DATABASE IF NOT EXISTS \`${db_name_sql}\`;
      CREATE USER IF NOT EXISTS '${db_user_sql}'@'%' IDENTIFIED BY '${db_password_sql}';
      CREATE USER IF NOT EXISTS '${db_user_sql}'@'localhost' IDENTIFIED BY '${db_password_sql}';
      ALTER USER '${db_user_sql}'@'%' IDENTIFIED BY '${db_password_sql}';
      ALTER USER '${db_user_sql}'@'localhost' IDENTIFIED BY '${db_password_sql}';
      GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${db_user_sql}'@'%';
      GRANT ALL PRIVILEGES ON \`${db_name_sql}\`.* TO '${db_user_sql}'@'localhost';
      FLUSH PRIVILEGES;
EOSQL
  fi

  import_dump_if_configured
  stop_temp_mysql
elif [[ -n "${DUMP_FILE_PATH}" ]]; then
  start_temp_mysql
  import_dump_if_configured
  stop_temp_mysql
fi

exec mysqld --user=mysql --datadir="${DATADIR}" --bind-address=0.0.0.0
