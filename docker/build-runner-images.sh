#!/bin/bash
#
# Build the three Data Sandbox runner container images (Z-04/Z-05 计算任务运行组件):
#   data-sandbox-sampler / data-sandbox-jar-runner / data-sandbox-python-runner /
#   data-sandbox-tee-runner
#
# 每个镜像共享 docker/data-sandbox-runner-lib/runner_common.py，故统一从 docker/ 目录构建。
# 构建后需加载进 Kuscia master 节点并注册 AppImage（见 secretpad/scripts/deploy/data-sandbox/）。
#
# Usage:
#   ./build-runner-images.sh          # 构建全部三个
#   SAMPLER_ONLY=1 ./build-runner-images.sh   # 只构建 sampler（Z-04 回归）
#
# Overridable: DATA_SANDBOX_IMAGE_TAG (default latest)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

TAG="${DATA_SANDBOX_IMAGE_TAG:-latest}"

log() { echo "[build-runner-images] $*"; }

build() {
    local name="$1" dockerfile="$2"
    if [ -n "${SAMPLER_ONLY:-}" ] && [ "${name}" != "data-sandbox-sampler" ]; then
        return
    fi
    log "building ${name}:${TAG} (${dockerfile})"
    docker build -f "${dockerfile}" -t "${name}:${TAG}" .
}

build data-sandbox-sampler       data-sandbox-sampler/Dockerfile
build data-sandbox-jar-runner    data-sandbox-jar-runner/Dockerfile
build data-sandbox-python-runner data-sandbox-python-runner/Dockerfile
build data-sandbox-tee-runner    data-sandbox-tee-runner/Dockerfile

log "runner images built: data-sandbox-sampler / data-sandbox-jar-runner / data-sandbox-python-runner / data-sandbox-tee-runner (tag ${TAG})"
log "next: 加载进 Kuscia master 并注册 AppImage，见 secretpad/scripts/deploy/data-sandbox/"
