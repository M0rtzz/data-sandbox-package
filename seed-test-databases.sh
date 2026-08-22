#!/usr/bin/env bash
set -euo pipefail

# Create five different tables in each of the five test databases (25 total).
# The columns mirror devdata/gov_bank_sample.csv; every table receives distinct rows.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DATA_SANDBOX_ENV_FILE:-${SCRIPT_DIR}/data-sandbox.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

MYSQL55_PASSWORD="${DB_MYSQL55_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
MYSQL80_PASSWORD="${DB_MYSQL80_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
POSTGRES_PASSWORD="${DB_POSTGRES_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
GREATSQL_PASSWORD="${DB_GREATSQL_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
OPENGAUSS_PASSWORD="${DB_OPENGAUSS_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
MYSQL55_USER="${DB_MYSQL55_USER:-mysql}"
MYSQL80_USER="${DB_MYSQL80_USER:-mysql}"
POSTGRES_USER="${DB_POSTGRES_USER:-postgresql}"
GREATSQL_USER="${DB_GREATSQL_USER:-greatsql}"
OPENGAUSS_USER="${DB_OPENGAUSS_USER:-opengauss_remote}"
MYSQL55_DATABASE="${DB_MYSQL55_DATABASE:-${DB_MYSQL_DATABASE:-demo}}"
MYSQL80_DATABASE="${DB_MYSQL80_DATABASE:-${DB_MYSQL_DATABASE:-demo}}"
POSTGRES_DATABASE="${DB_POSTGRES_DATABASE:-demo}"
GREATSQL_DATABASE="${DB_GREATSQL_DATABASE:-demo}"
OPENGAUSS_DATABASE="${DB_OPENGAUSS_DATABASE:-postgres}"
MYSQL55_CONTAINER="${DB_MYSQL55_CONTAINER:-ds-test-mysql55}"
MYSQL80_CONTAINER="${DB_MYSQL80_CONTAINER:-ds-test-mysql80}"
POSTGRES_CONTAINER="${DB_POSTGRES_CONTAINER:-ds-test-postgres}"
GREATSQL_CONTAINER="${DB_GREATSQL_CONTAINER:-ds-test-greatsql}"
OPENGAUSS_CONTAINER="${DB_OPENGAUSS_CONTAINER:-ds-test-opengauss}"

mysql_exec() {
  local container="$1" user="${MYSQL55_USER}" password="${MYSQL55_PASSWORD}" database="${MYSQL55_DATABASE}"
  if [[ "${container}" == "${MYSQL80_CONTAINER}" ]]; then user="${MYSQL80_USER}"; password="${MYSQL80_PASSWORD}"; database="${MYSQL80_DATABASE}"; fi
  docker exec "${container}" mysql --default-character-set=utf8mb4 -u"${user}" -p"${password}" "${database}" -e "$2"
}

mysql_admin_exec() {
  local container="$1" password="${MYSQL55_PASSWORD}" database="${MYSQL55_DATABASE}"
  if [[ "${container}" == "${MYSQL80_CONTAINER}" ]]; then password="${MYSQL80_PASSWORD}"; database="${MYSQL80_DATABASE}"; fi
  docker exec "${container}" mysql --default-character-set=utf8mb4 -uroot -p"${password}" "${database}" -e "$2"
}

postgres_exec() {
  # Seed as the image's administrator; the configured integration user is
  # granted access below and is the user used by SecretPad.
  docker exec "$1" psql -U postgres -d "${POSTGRES_DATABASE}" -v ON_ERROR_STOP=1 -c "$2"
}

postgres_admin_exec() {
  docker exec "$1" psql -U postgres -d "${POSTGRES_DATABASE}" -v ON_ERROR_STOP=1 -c "$2"
}

GREATSQL_SOCKET="${DB_GREATSQL_SOCKET:-/data/GreatSQL/mysql.sock}"
greatsql_exec() { docker exec "$1" mysql --socket="${GREATSQL_SOCKET}" --default-character-set=utf8mb4 -u"${GREATSQL_USER}" -p"${GREATSQL_PASSWORD}" "${GREATSQL_DATABASE}" -e "$2"; }
greatsql_admin_exec() { docker exec "$1" mysql --socket="${GREATSQL_SOCKET}" --default-character-set=utf8mb4 -uroot -p"${GREATSQL_PASSWORD}" "${GREATSQL_DATABASE}" -e "$2"; }

opengauss_exec() {
  docker exec "$1" env LD_LIBRARY_PATH=/usr/local/opengauss/lib /usr/local/opengauss/bin/gsql \
    -h 127.0.0.1 -p 5432 -U "${OPENGAUSS_USER}" -d "${OPENGAUSS_DATABASE}" \
    -W "${OPENGAUSS_PASSWORD}" -v ON_ERROR_STOP=1 \
    -c "set client_min_messages=warning; $2"
}

opengauss_admin_exec() {
  docker exec -u opengauss "$1" env LD_LIBRARY_PATH=/usr/local/opengauss/lib /usr/local/opengauss/bin/gsql \
    -U opengauss -d "${OPENGAUSS_DATABASE}" -v ON_ERROR_STOP=1 -c "$2"
}

prepare_opengauss_database() {
  local container="$1"
  # The image initializes postgres. Use the configured database when it is
  # different; renaming may be rejected while openGauss background sessions
  # are attached, so fall back to creating the target database.
  if [[ "${OPENGAUSS_DATABASE}" == "postgres" ]]; then
    return 0
  fi
  # Check/create the target database with the image administrator.  The
  # integration account may not exist yet on a reused container.
  opengauss_admin_exec "${container}" "select 1 from pg_database where datname='${OPENGAUSS_DATABASE}';" \
    | grep -q 1 && return 0
  docker exec -u opengauss "${container}" env LD_LIBRARY_PATH=/usr/local/opengauss/lib /usr/local/opengauss/bin/gsql \
    -U opengauss -d postgres -v ON_ERROR_STOP=1 \
    -c "alter database postgres rename to ${OPENGAUSS_DATABASE};" >/dev/null 2>&1 || true
  opengauss_admin_exec "${container}" "select 1 from pg_database where datname='${OPENGAUSS_DATABASE}';" \
    | grep -q 1 || \
    docker exec -u opengauss "${container}" env LD_LIBRARY_PATH=/usr/local/opengauss/lib /usr/local/opengauss/bin/gsql \
      -U opengauss -d postgres -v ON_ERROR_STOP=1 \
      -c "create database ${OPENGAUSS_DATABASE};"
}


schema_mysql="id int primary key, account_no varchar(32), name varchar(64), phone varchar(32), id_card varchar(32), branch varchar(128), card_type varchar(32), category varchar(8), balance decimal(12,2), trans_amount decimal(12,2), trans_date date, trans_type varchar(32), memo varchar(128)"
schema_pg="id integer primary key, account_no varchar(32), name varchar(64), phone varchar(32), id_card varchar(32), branch varchar(128), card_type varchar(32), category varchar(8), balance numeric(12,2), trans_amount numeric(12,2), trans_date date, trans_type varchar(32), memo varchar(128)"

seed_mysql_family() {
  local container="$1" prefix="$2"
  for table_no in 1 2 3 4 5; do
    local table="${prefix}_${table_no}"
    local sql="drop table if exists ${table}; create table ${table} (${schema_mysql}) default character set utf8mb4 collate utf8mb4_unicode_ci;"
    for row in 1 2 3 4 5; do
      local id=$((table_no * 100 + row))
      sql+=" insert into ${table} values (${id},'622188${table_no}000${row}','${prefix}_客户${row}','138000${table_no}${row}001','420101198${table_no}010${row}0037','${prefix}银行分行','借记卡','A',${id}1.17,${id}7.43,'2026-08-01','转账','测试数据');"
    done
    mysql_exec "$container" "$sql"
  done
}

seed_postgres_family() {
  local container="$1" prefix="$2"
  for table_no in 1 2 3 4 5; do
    local table="${prefix}_${table_no}"
    local sql="drop table if exists ${table}; create table ${table} (${schema_pg});"
    for row in 1 2 3 4 5; do
      local id=$((table_no * 100 + row))
      sql+=" insert into ${table} values (${id},'622188${table_no}000${row}','${prefix}_客户${row}','138000${table_no}${row}001','420101198${table_no}010${row}0037','${prefix}银行分行','借记卡','A',${id}1.17,${id}7.43,'2026-08-01','转账','测试数据');"
    done
    postgres_exec "$container" "$sql"
  done
}

seed_greatsql_family() {
  local container="$1" prefix="$2"
  for table_no in 1 2 3 4 5; do
    local table="${prefix}_${table_no}"
    local sql="drop table if exists ${table}; create table ${table} (${schema_mysql}) default character set utf8mb4 collate utf8mb4_unicode_ci;"
    for row in 1 2 3 4 5; do
      local id=$((table_no * 100 + row))
      sql+=" insert into ${table} values (${id},'622188${table_no}000${row}','${prefix}_客户${row}','138000${table_no}${row}001','420101198${table_no}010${row}0037','${prefix}银行分行','借记卡','A',${id}1.17,${id}7.43,'2026-08-01','转账','测试数据');"
    done
    greatsql_exec "$container" "$sql"
  done
}

seed_opengauss_family() {
  local container="$1" prefix="$2"
  for table_no in 1 2 3 4 5; do
    local table="${prefix}_${table_no}"
    local sql="drop table if exists ${table}; create table ${table} (${schema_pg});"
    for row in 1 2 3 4 5; do
      local id=$((table_no * 100 + row))
      sql+=" insert into ${table} values (${id},'622188${table_no}000${row}','${prefix}_客户${row}','138000${table_no}${row}001','420101198${table_no}010${row}0037','${prefix}银行分行','借记卡','A',${id}1.17,${id}7.43,'2026-08-01','转账','测试数据');"
    done
    opengauss_exec "$container" "$sql"
  done
}

mysql_admin_exec "${MYSQL55_CONTAINER}" "create user '${MYSQL55_USER}'@'%' identified by '${MYSQL55_PASSWORD}';" 2>/dev/null || true
mysql_admin_exec "${MYSQL80_CONTAINER}" "create user '${MYSQL80_USER}'@'%' identified by '${MYSQL80_PASSWORD}';" 2>/dev/null || true
mysql_admin_exec "${MYSQL55_CONTAINER}" "alter database ${MYSQL55_DATABASE} character set utf8mb4 collate utf8mb4_unicode_ci;"
mysql_admin_exec "${MYSQL80_CONTAINER}" "alter database ${MYSQL80_DATABASE} character set utf8mb4 collate utf8mb4_unicode_ci;"
mysql_admin_exec "${MYSQL55_CONTAINER}" "grant all privileges on ${MYSQL55_DATABASE}.* to '${MYSQL55_USER}'@'%'; flush privileges;"
mysql_admin_exec "${MYSQL80_CONTAINER}" "grant all privileges on ${MYSQL80_DATABASE}.* to '${MYSQL80_USER}'@'%'; flush privileges;"
seed_mysql_family "${MYSQL55_CONTAINER}" gov_mysql55
seed_mysql_family "${MYSQL80_CONTAINER}" gov_mysql80
postgres_admin_exec "${POSTGRES_CONTAINER}" "create role ${POSTGRES_USER} login password '${POSTGRES_PASSWORD}';" 2>/dev/null || true
postgres_admin_exec "${POSTGRES_CONTAINER}" "grant all privileges on database ${POSTGRES_DATABASE} to ${POSTGRES_USER};"
postgres_admin_exec "${POSTGRES_CONTAINER}" "grant all on schema public to ${POSTGRES_USER};"
seed_postgres_family "${POSTGRES_CONTAINER}" gov_postgres
postgres_admin_exec "${POSTGRES_CONTAINER}" "grant select on all tables in schema public to ${POSTGRES_USER};"

greatsql_admin_exec "${GREATSQL_CONTAINER}" "create user '${GREATSQL_USER}'@'%' identified by '${GREATSQL_PASSWORD}';" 2>/dev/null || true
greatsql_admin_exec "${GREATSQL_CONTAINER}" "alter database ${GREATSQL_DATABASE} character set utf8mb4 collate utf8mb4_unicode_ci;"
greatsql_admin_exec "${GREATSQL_CONTAINER}" "grant all privileges on ${GREATSQL_DATABASE}.* to '${GREATSQL_USER}'@'%'; flush privileges;"
seed_greatsql_family "${GREATSQL_CONTAINER}" gov_greatsql

prepare_opengauss_database "${OPENGAUSS_CONTAINER}"
# Containers are intentionally reusable.  Synchronize the integration account
# password; an already matching password is harmlessly ignored by openGauss.
opengauss_admin_exec "${OPENGAUSS_CONTAINER}" "create user ${OPENGAUSS_USER} password '${OPENGAUSS_PASSWORD}';" 2>/dev/null || \
  opengauss_admin_exec "${OPENGAUSS_CONTAINER}" "alter user ${OPENGAUSS_USER} password '${OPENGAUSS_PASSWORD}';" 2>/dev/null || true
opengauss_admin_exec "${OPENGAUSS_CONTAINER}" "grant all privileges on database ${OPENGAUSS_DATABASE} to ${OPENGAUSS_USER}; grant all privileges on schema public to ${OPENGAUSS_USER}; grant all privileges on all tables in schema public to ${OPENGAUSS_USER};"
seed_opengauss_family "${OPENGAUSS_CONTAINER}" gov_opengauss

echo "Seeded 25 tables (5 tables in each database)."
