#!/usr/bin/env bash
set -euo pipefail

# Start the five database servers used by the catalog integration test.
# Ports are exposed on the host so SecretPad can use host.docker.internal.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DATA_SANDBOX_ENV_FILE:-${SCRIPT_DIR}/data-sandbox.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

MYSQL55_PORT="${DB_MYSQL55_PORT:-${MYSQL55_PORT:-13306}}"
MYSQL80_PORT="${DB_MYSQL80_PORT:-${MYSQL80_PORT:-13307}}"
POSTGRES_PORT="${DB_POSTGRES_PORT:-${POSTGRES_PORT:-15432}}"
GREATSQL_PORT="${DB_GREATSQL_PORT:-${GREATSQL_PORT:-13308}}"
OPENGAUSS_PORT="${DB_OPENGAUSS_PORT:-${OPENGAUSS_PORT:-15433}}"
MYSQL55_PASSWORD="${DB_MYSQL55_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
MYSQL80_PASSWORD="${DB_MYSQL80_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
POSTGRES_PASSWORD="${DB_POSTGRES_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
GREATSQL_PASSWORD="${DB_GREATSQL_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
OPENGAUSS_PASSWORD="${DB_OPENGAUSS_PASSWORD:-${DB_TEST_PASSWORD:-Test@123456}}"
MYSQL55_DATABASE="${DB_MYSQL55_DATABASE:-${DB_MYSQL_DATABASE:-demo}}"
MYSQL80_DATABASE="${DB_MYSQL80_DATABASE:-${DB_MYSQL_DATABASE:-demo}}"
POSTGRES_DATABASE="${DB_POSTGRES_DATABASE:-demo}"
GREATSQL_DATABASE="${DB_GREATSQL_DATABASE:-demo}"
OPENGAUSS_DATABASE="${DB_OPENGAUSS_DATABASE:-demo}"
MYSQL55_IMAGE="${DB_MYSQL55_IMAGE:-mysql:5.5}"
MYSQL80_IMAGE="${DB_MYSQL80_IMAGE:-mysql:9.7.2}"
POSTGRES_IMAGE="${DB_POSTGRES_IMAGE:-postgres:18.6}"
GREATSQL_IMAGE="${DB_GREATSQL_IMAGE:-greatsql/greatsql:8.4.4-5}"
OPENGAUSS_IMAGE="${DB_OPENGAUSS_IMAGE:-opengauss/opengauss:5.0.0}"
MYSQL55_CONTAINER="${DB_MYSQL55_CONTAINER:-ds-test-mysql55}"
MYSQL80_CONTAINER="${DB_MYSQL80_CONTAINER:-ds-test-mysql80}"
POSTGRES_CONTAINER="${DB_POSTGRES_CONTAINER:-ds-test-postgres}"
GREATSQL_CONTAINER="${DB_GREATSQL_CONTAINER:-ds-test-greatsql}"
OPENGAUSS_CONTAINER="${DB_OPENGAUSS_CONTAINER:-ds-test-opengauss}"

ensure_container() {
  local name="$1"
  shift
  if docker container inspect "${name}" >/dev/null 2>&1; then
    docker start "${name}" >/dev/null
  else
    docker run -d --name "${name}" "$@" >/dev/null
  fi
}

wait_for_mysql() {
  local container="$1" password="$2"
  for _ in {1..60}; do
    if docker exec "${container}" mysqladmin --protocol=TCP -h127.0.0.1 -P3306 \
      -uroot -p"${password}" ping --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for MySQL container ${container}" >&2
  return 1
}

wait_for_greatsql() {
  local container="$1"
  for _ in {1..60}; do
    if docker exec "${container}" mysql --socket=/data/GreatSQL/mysql.sock \
      -uroot -p"${GREATSQL_PASSWORD}" -e 'select 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for GreatSQL container ${container}" >&2
  return 1
}

wait_for_postgres() {
  local container="$1"
  for _ in {1..60}; do
    if docker exec "${container}" pg_isready -U postgres -d "${POSTGRES_DATABASE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for PostgreSQL container ${container}" >&2
  return 1
}

ensure_container "${MYSQL55_CONTAINER}" \
  -e "MYSQL_ROOT_PASSWORD=${MYSQL55_PASSWORD}" -e "MYSQL_DATABASE=${MYSQL55_DATABASE}" \
  -p "${MYSQL55_PORT}:3306" "${MYSQL55_IMAGE}"

ensure_container "${MYSQL80_CONTAINER}" \
  -e "MYSQL_ROOT_PASSWORD=${MYSQL80_PASSWORD}" -e "MYSQL_DATABASE=${MYSQL80_DATABASE}" \
  -p "${MYSQL80_PORT}:3306" "${MYSQL80_IMAGE}"

ensure_container "${POSTGRES_CONTAINER}" \
  -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" -e "POSTGRES_DB=${POSTGRES_DATABASE}" \
  -p "${POSTGRES_PORT}:5432" "${POSTGRES_IMAGE}"

ensure_container "${GREATSQL_CONTAINER}" \
  -e "MYSQL_ROOT_PASSWORD=${GREATSQL_PASSWORD}" -e "MYSQL_DATABASE=${GREATSQL_DATABASE}" \
  -p "${GREATSQL_PORT}:3306" "${GREATSQL_IMAGE}"

ensure_container "${OPENGAUSS_CONTAINER}" \
  -e "GS_PASSWORD=${OPENGAUSS_PASSWORD}" \
  -p "${OPENGAUSS_PORT}:5432" "${OPENGAUSS_IMAGE}"

wait_for_mysql "${MYSQL55_CONTAINER}" "${MYSQL55_PASSWORD}"
wait_for_mysql "${MYSQL80_CONTAINER}" "${MYSQL80_PASSWORD}"
wait_for_greatsql "${GREATSQL_CONTAINER}"
wait_for_postgres "${POSTGRES_CONTAINER}"

echo "Database containers started."
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' \
  --filter "name=${MYSQL55_CONTAINER}" \
  --filter "name=${MYSQL80_CONTAINER}" \
  --filter "name=${POSTGRES_CONTAINER}" \
  --filter "name=${GREATSQL_CONTAINER}" \
  --filter "name=${OPENGAUSS_CONTAINER}"
