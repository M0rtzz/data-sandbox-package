#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PACKAGE_DIR}/deploy/common/log.sh"
source "${PACKAGE_DIR}/deploy/common/utils.sh"
load_env "$PACKAGE_DIR"

command=${1:-status}
case "$command" in
  status)
    docker ps -a --filter "name=^/${SECRETPAD_CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
    ;;
  logs)
    docker logs --tail 300 -f "$SECRETPAD_CONTAINER"
    ;;
  diagnose)
    curl -ksS "http://127.0.0.1:${SECRETPAD_PORT}/actuator/health"; echo
    docker exec "$SECRETPAD_CONTAINER" sh -c 'test -w "$DATA_SANDBOX_SNAPSHOT_ROOT" && echo snapshot-storage=OK || echo snapshot-storage=FAILED'
    ;;
  restore)
    backup_id=${2:-}
    [ -n "$backup_id" ] || { log_error "Usage: ./ops.sh restore <backup-id>"; exit 1; }
    db_source="$(mount_source "$SECRETPAD_CONTAINER" /app/db)"
    pending="${db_source}/restore-pending.sqlite"
    [ -f "$pending" ] || { log_error "Staged restore file not found: ${pending}"; exit 1; }
    timestamp="$(date +%Y%m%d-%H%M%S)"
    docker stop "$SECRETPAD_CONTAINER" >/dev/null
    cp "${db_source}/secretpad.sqlite" "${db_source}/secretpad.sqlite.before-restore-${timestamp}"
    cp "$pending" "${db_source}/secretpad.sqlite"
    rm -f "$pending"
    docker start "$SECRETPAD_CONTAINER" >/dev/null
    log_success "Restored ${backup_id}; previous database retained with timestamp ${timestamp}."
    ;;
  rollback)
    previous="${SECRETPAD_CONTAINER}-before-data-sandbox"
    require_container "$previous"
    docker stop "$SECRETPAD_CONTAINER" >/dev/null 2>&1 || true
    docker rename "$SECRETPAD_CONTAINER" "${SECRETPAD_CONTAINER}-failed-$(date +%Y%m%d-%H%M%S)"
    docker rename "$previous" "$SECRETPAD_CONTAINER"
    docker start "$SECRETPAD_CONTAINER" >/dev/null
    log_success "Previous SecretPad container restored."
    ;;
  *)
    log_error "Unknown command: ${command}. Use status, logs, diagnose, restore or rollback."
    exit 1
    ;;
esac
