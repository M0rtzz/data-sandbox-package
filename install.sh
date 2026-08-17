#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the familiar autonomy invocation, but implement it entirely in this
# package rather than delegating to the old all-in-one package.
if [ "${1:-}" = "autonomy" ]; then
    shift
    exec "${PACKAGE_DIR}/partner-node.sh" create "$@"
fi

source "${PACKAGE_DIR}/deploy/common/log.sh"
source "${PACKAGE_DIR}/deploy/common/utils.sh"
load_env "$PACKAGE_DIR"

require_command docker
require_command curl
require_container "$SOURCE_SECRETPAD_CONTAINER"
docker image inspect "$SECRETPAD_IMAGE" >/dev/null 2>&1 || {
    log_error "Image not found: ${SECRETPAD_IMAGE}. Run ./build.sh first."
    exit 1
}
PREVIOUS_CONTAINER="${SECRETPAD_CONTAINER}-before-data-sandbox"
TARGET_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$SECRETPAD_IMAGE")"
CURRENT_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$SOURCE_SECRETPAD_CONTAINER")"
if [ "$CURRENT_IMAGE_ID" = "$TARGET_IMAGE_ID" ] && docker inspect "$PREVIOUS_CONTAINER" >/dev/null 2>&1; then
    if wait_for_secretpad "$SECRETPAD_PORT" 5; then
        log_success "Data Sandbox MVP is already installed and healthy at http://127.0.0.1:${SECRETPAD_PORT}/edge?tab=sandbox-manager"
        exit 0
    fi
    log_error "Data Sandbox MVP container is present but health probe failed. Run ./ops.sh logs or ./ops.sh rollback."
    exit 1
fi

CONFIG_SOURCE="$(mount_source "$SOURCE_SECRETPAD_CONTAINER" /app/config)"
DB_SOURCE="$(mount_source "$SOURCE_SECRETPAD_CONTAINER" /app/db)"
DATA_SOURCE="$(mount_source "$SOURCE_SECRETPAD_CONTAINER" /app/data)"
LOG_SOURCE="$(mount_source "$SOURCE_SECRETPAD_CONTAINER" /app/log)"
NETWORK="$(container_network "$SOURCE_SECRETPAD_CONTAINER")"
NETWORK="${NETWORK:-$DOCKER_NETWORK}"

[ -n "$CONFIG_SOURCE" ] && [ -n "$DB_SOURCE" ] || {
    log_error "Cannot discover /app/config or /app/db bind mounts from ${SOURCE_SECRETPAD_CONTAINER}"
    exit 1
}
mkdir -p "$DATA_SANDBOX_SNAPSHOT_ROOT" "$DATA_SANDBOX_BACKUP_ROOT"
docker exec "$SOURCE_SECRETPAD_CONTAINER" sh -lc 'mkdir -p /app/config/schema/center /app/config/schema/edge /app/config/schema/p2p'
for profile in center edge p2p; do
    docker cp "${PACKAGE_DIR}/config/schema/${profile}/V6__data_sandbox_mvp.sql" \
        "${SOURCE_SECRETPAD_CONTAINER}:/app/config/schema/${profile}/V6__data_sandbox_mvp.sql"
done

RUNTIME_ENV="${PACKAGE_DIR}/.runtime.env.$$"
trap 'rm -f "$RUNTIME_ENV"' EXIT
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$SOURCE_SECRETPAD_CONTAINER" >"$RUNTIME_ENV"
cat >>"$RUNTIME_ENV" <<EOF
SECRETPAD_DATA_SANDBOX_KUSCIA_ENABLED=${DATA_SANDBOX_KUSCIA_ENABLED}
SECRETPAD_DATA_SANDBOX_SNAPSHOT_ROOT=${DATA_SANDBOX_SNAPSHOT_ROOT}
SECRETPAD_DATA_SANDBOX_BACKUP_ROOT=${DATA_SANDBOX_BACKUP_ROOT}
SECRETPAD_DATA_SANDBOX_STATUS_SYNC_MS=${DATA_SANDBOX_STATUS_SYNC_MS:-30000}
SPRINGDOC_API_DOCS_ENABLED=true
SPRINGDOC_SWAGGER_UI_ENABLED=true
# Umi uses stable filenames for route chunks. Prevent browsers from combining
# a cached previous bundle with the newly deployed runtime after an upgrade.
SPRING_WEB_RESOURCES_CACHE_CACHECONTROL_NO_STORE=true
EOF
chmod 600 "$RUNTIME_ENV"

if docker inspect "$PREVIOUS_CONTAINER" >/dev/null 2>&1; then
    log_error "Rollback container already exists: ${PREVIOUS_CONTAINER}. Resolve it before installing again."
    exit 1
fi

log "Stopping current SecretPad and retaining it as ${PREVIOUS_CONTAINER}"
docker stop "$SOURCE_SECRETPAD_CONTAINER" >/dev/null
docker rename "$SOURCE_SECRETPAD_CONTAINER" "$PREVIOUS_CONTAINER"

run_args=(--init --name "$SECRETPAD_CONTAINER" --restart always --network "$NETWORK" -p "${SECRETPAD_PORT}:8080" --env-file "$RUNTIME_ENV")
run_args+=(-v "${CONFIG_SOURCE}:/app/config" -v "${DB_SOURCE}:/app/db")
[ -n "$DATA_SOURCE" ] && run_args+=(-v "${DATA_SOURCE}:/app/data")
[ -n "$LOG_SOURCE" ] && run_args+=(-v "${LOG_SOURCE}:/app/log")
run_args+=(-v "${DATA_SANDBOX_SNAPSHOT_ROOT}:${DATA_SANDBOX_SNAPSHOT_ROOT}")
run_args+=(-v "${DATA_SANDBOX_BACKUP_ROOT}:${DATA_SANDBOX_BACKUP_ROOT}")

if ! docker run -d "${run_args[@]}" "$SECRETPAD_IMAGE" >/dev/null; then
    log_error "New container failed to start; restoring previous container."
    docker rename "$PREVIOUS_CONTAINER" "$SECRETPAD_CONTAINER"
    docker start "$SECRETPAD_CONTAINER" >/dev/null
    exit 1
fi

if ! wait_for_secretpad "$SECRETPAD_PORT" 90; then
    log_error "Health probe failed. Run ./ops.sh logs or ./ops.sh rollback."
    exit 1
fi

log_success "Data Sandbox MVP is running at http://127.0.0.1:${SECRETPAD_PORT}/edge?tab=sandbox-manager"
log_warn "Rotate administrator credentials if they have ever appeared in historical logs."
