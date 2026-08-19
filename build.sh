#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${PACKAGE_DIR}/.." && pwd)"
BACKEND_DIR="${WORKSPACE_DIR}/secretpad"
FRONTEND_DIR="${WORKSPACE_DIR}/secretpad-frontend"
source "${PACKAGE_DIR}/deploy/common/log.sh"
source "${PACKAGE_DIR}/deploy/common/utils.sh"

require_command docker
require_command pnpm

log "Building local SecretPad frontend"
(
  cd "$FRONTEND_DIR"
  pnpm --filter secretpad build
)

STATIC_DIR="${BACKEND_DIR}/secretpad-web/src/main/resources/static"
TEMPLATE_INDEX="${BACKEND_DIR}/secretpad-web/src/main/resources/templates/index.html"
mkdir -p "$STATIC_DIR"
find "$STATIC_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "${FRONTEND_DIR}/apps/platform/dist/." "$STATIC_DIR/"
cp "${FRONTEND_DIR}/apps/platform/dist/index.html" "$TEMPLATE_INDEX"

log "Building backend with Maven and Java 17"
mkdir -p "${WORKSPACE_DIR}/.cache/m2"
# maven 以 root 运行（镜像默认），构建完成后把 /workspace 里 root 属主的产物改回开发者用户，
# 避免挂载的 BACKEND_DIR 被 root 污染而阻断后续本地 mvn 构建
docker run --rm \
  -e DEV_UID="$(id -u)" \
  -e DEV_GID="$(id -g)" \
  -v "${BACKEND_DIR}:/workspace" \
  -v "${WORKSPACE_DIR}/.cache/m2:/root/.m2" \
  -w /workspace \
  maven:3.9.9-eclipse-temurin-17-noble \
  sh -c 'mvn -DskipTests -Dfile.encoding=UTF-8 package && chown -R --from=root "$DEV_UID:$DEV_GID" /workspace'

mkdir -p "${PACKAGE_DIR}/artifacts" "${PACKAGE_DIR}/config/schema/center" "${PACKAGE_DIR}/config/schema/edge" "${PACKAGE_DIR}/config/schema/p2p"
cp "${BACKEND_DIR}/target/secretpad.jar" "${PACKAGE_DIR}/artifacts/secretpad.jar"
for profile in center edge p2p; do
  cp "${BACKEND_DIR}/config/schema/${profile}/V6__data_sandbox_mvp.sql" "${PACKAGE_DIR}/config/schema/${profile}/V6__data_sandbox_mvp.sql"
  cp "${BACKEND_DIR}/config/schema/${profile}/V7__data_sandbox_runtime.sql" "${PACKAGE_DIR}/config/schema/${profile}/V7__data_sandbox_runtime.sql"
  cp "${BACKEND_DIR}/config/schema/${profile}/V8__data_sandbox_resource.sql" "${PACKAGE_DIR}/config/schema/${profile}/V8__data_sandbox_resource.sql"
  cp "${BACKEND_DIR}/config/schema/${profile}/V9__data_sandbox_alerts.sql" "${PACKAGE_DIR}/config/schema/${profile}/V9__data_sandbox_alerts.sql"
  # Z-03：沙箱资源申请与审批
  cp "${BACKEND_DIR}/config/schema/${profile}/V10__sandbox_approval.sql" "${PACKAGE_DIR}/config/schema/${profile}/V10__sandbox_approval.sql"
  # Z-04：数据抽样与脱敏服务
  cp "${BACKEND_DIR}/config/schema/${profile}/V11__data_governance.sql" "${PACKAGE_DIR}/config/schema/${profile}/V11__data_governance.sql"
done

docker_build_args=()
if [ "${DATA_SANDBOX_DEV_IMAGE:-false}" = true ]; then
  docker_build_args+=(--build-arg DEV_IMAGE=true)
  docker_build_args+=(--build-arg "DEV_OWNER=${DATA_SANDBOX_DEV_IMAGE_OWNER:?Missing developer image owner}")
  docker_build_args+=(--build-arg "DEV_WORKSPACE=${DATA_SANDBOX_DEV_IMAGE_WORKSPACE:?Missing developer image workspace}")
fi
docker build "${docker_build_args[@]}" -t "${SECRETPAD_IMAGE:-data-sandbox-secretpad:mvp}" "$PACKAGE_DIR"
log_success "Build complete: ${SECRETPAD_IMAGE:-data-sandbox-secretpad:mvp}"
