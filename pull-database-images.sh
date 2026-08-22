#!/usr/bin/env bash
set -euo pipefail

# Pull the server images used by the data-catalog JDBC integration tests.
# MySQL 5.5 and 8.0 cover the legacy/current JDBC compatibility paths.
# Override any tag when testing a different server version, for example:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DATA_SANDBOX_ENV_FILE:-${SCRIPT_DIR}/data-sandbox.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

MYSQL_55_IMAGE="${DB_MYSQL55_MIRROR_IMAGE:-${MYSQL_55_IMAGE:-docker.1ms.run/library/mysql:5.5}}"
MYSQL_80_IMAGE="${DB_MYSQL80_MIRROR_IMAGE:-${MYSQL_80_IMAGE:-docker.1ms.run/library/mysql:9.7.2}}"
POSTGRES_IMAGE="${DB_POSTGRES_MIRROR_IMAGE:-${POSTGRES_IMAGE:-docker.1ms.run/library/postgres:18.6}}"
GREATSQL_IMAGE="${DB_GREATSQL_MIRROR_IMAGE:-${GREATSQL_IMAGE:-docker.1ms.run/greatsql/greatsql:8.4.4-5}}"
OPENGAUSS_IMAGE="${DB_OPENGAUSS_MIRROR_IMAGE:-${OPENGAUSS_IMAGE:-docker.1ms.run/opengauss/opengauss:5.0.0}}"
MYSQL_55_OFFICIAL="${DB_MYSQL55_IMAGE:-mysql:5.5}"
MYSQL_80_OFFICIAL="${DB_MYSQL80_IMAGE:-mysql:9.7.2}"
POSTGRES_OFFICIAL="${DB_POSTGRES_IMAGE:-postgres:18.6}"
GREATSQL_OFFICIAL="${DB_GREATSQL_IMAGE:-greatsql/greatsql:8.4.4-5}"
OPENGAUSS_OFFICIAL="${DB_OPENGAUSS_IMAGE:-opengauss/opengauss:5.0.0}"

pull_as_official() {
    local mirror_image="$1"
    local official_image="$2"
    echo "Pulling ${mirror_image}"
    docker pull "${mirror_image}"
    echo "Tagging ${official_image}"
    docker tag "${mirror_image}" "${official_image}"
    if [[ "${mirror_image}" != "${official_image}" ]]; then
    docker rmi "${mirror_image}" >/dev/null
    fi
}

pull_as_official "${MYSQL_55_IMAGE}" "${MYSQL_55_OFFICIAL}"
pull_as_official "${MYSQL_80_IMAGE}" "${MYSQL_80_OFFICIAL}"
pull_as_official "${POSTGRES_IMAGE}" "${POSTGRES_OFFICIAL}"
pull_as_official "${GREATSQL_IMAGE}" "${GREATSQL_OFFICIAL}"
pull_as_official "${OPENGAUSS_IMAGE}" "${OPENGAUSS_OFFICIAL}"

echo "All database images pulled and retagged successfully."
