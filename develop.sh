#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

# Build and run a fully isolated developer stack from the current checkout.
# This script never reads data-sandbox.env and never touches a shared deployment.
set -Eeuo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${PACKAGE_DIR}/.." && pwd)"
BACKEND_DIR="$(realpath -m "${WORKSPACE_DIR}/secretpad")"
FRONTEND_DIR="$(realpath -m "${WORKSPACE_DIR}/secretpad-frontend")"

# shellcheck source=deploy/common/log.sh
source "${PACKAGE_DIR}/deploy/common/log.sh"
# shellcheck source=deploy/common/utils.sh
source "${PACKAGE_DIR}/deploy/common/utils.sh"

case "${1:-help}" in
  -h|--help) COMMAND=help ;;
  *) COMMAND="${1:-help}" ;;
esac
if [ "$#" -gt 0 ]; then
  shift
fi

# 端口约定（见 CLAUDE.md §2）：后端 8099、Kuscia 24080-24084；避开 xzh(8088/9088/1908x/1918x)、
# 系统默认(8080/8083/13080-13084/18080-18084 等共享 alice 环境占用)与共享演示环境端口。
DEV_NAME="${DATA_SANDBOX_DEV_NAME:-$(id -un)}"
CONSOLE_PORT="${DATA_SANDBOX_DEV_PORT:-8099}"
GATEWAY_PORT="${DATA_SANDBOX_DEV_GATEWAY_PORT:-24080}"
API_HTTP_PORT="${DATA_SANDBOX_DEV_API_HTTP_PORT:-24082}"
API_GRPC_PORT="${DATA_SANDBOX_DEV_API_GRPC_PORT:-24083}"
INTERNAL_PORT="${DATA_SANDBOX_DEV_INTERNAL_PORT:-24081}"
METRICS_PORT="${DATA_SANDBOX_DEV_METRICS_PORT:-24084}"
ADMIN_USER="${DATA_SANDBOX_DEV_ADMIN_USER:-devadmin}"
EXPECTED_BRANCH="${DATA_SANDBOX_DEV_BRANCH:-}"
SKIP_BUILD=false
LOG_COMPONENT=secretpad
REQUIRE_PUSHED=false
KUSCIA_IMAGE="${DATA_SANDBOX_DEV_KUSCIA_IMAGE:-secretflow-registry.cn-hangzhou.cr.aliyuncs.com/secretflow/kuscia:0.13.0b0}"

usage() {
  cat <<'EOF'
Usage:
  ./develop.sh up [options]
  ./develop.sh status [options]
  ./develop.sh logs [options]
  ./develop.sh restart [options]
  ./develop.sh down [options]

Options:
  --name NAME            Developer identifier. Default: current system user.
  --port PORT            SecretPad console port. Default: 18088.
  --gateway-port PORT    Kuscia gateway port. Default: 18080.
  --api-http-port PORT   Kuscia HTTP API port. Default: 18082.
  --api-grpc-port PORT   Kuscia gRPC API port. Default: 18083.
  --internal-port PORT   Kuscia internal service port. Default: 13081.
  --metrics-port PORT    Kuscia metrics port. Default: 13084.
  --admin-user USER      SecretPad developer administrator. Default: devadmin.
  --branch BRANCH        Required branch. Default: develop/<developer-name>.
  --pushed-only          Build only clean, pushed, upstream-synced commits (release verification).
                         Default: build the current working tree on --branch, dirty changes allowed.
  --skip-build           Reuse the existing developer image.
  --component NAME       Log component: secretpad or kuscia.
  -h, --help             Show this help.

Environment overrides:
  DATA_SANDBOX_DEV_ROOT          Private runtime root. It must be below this checkout.
  DATA_SANDBOX_DEV_KUSCIA_IMAGE  Kuscia image used by the private stack.

The first `up` prompts for a private developer administrator password. Runtime
data, credentials, certificates, containers, ports, and the Docker network are
isolated from every shared Alice/Bob deployment.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) DEV_NAME="${2:?Missing value for --name}"; shift 2 ;;
    --port) CONSOLE_PORT="${2:?Missing value for --port}"; shift 2 ;;
    --gateway-port) GATEWAY_PORT="${2:?Missing value for --gateway-port}"; shift 2 ;;
    --api-http-port) API_HTTP_PORT="${2:?Missing value for --api-http-port}"; shift 2 ;;
    --api-grpc-port) API_GRPC_PORT="${2:?Missing value for --api-grpc-port}"; shift 2 ;;
    --internal-port) INTERNAL_PORT="${2:?Missing value for --internal-port}"; shift 2 ;;
    --metrics-port) METRICS_PORT="${2:?Missing value for --metrics-port}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:?Missing value for --admin-user}"; shift 2 ;;
    --branch) EXPECTED_BRANCH="${2:?Missing value for --branch}"; shift 2 ;;
    --pushed-only) REQUIRE_PUSHED=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --component) LOG_COMPONENT="${2:?Missing value for --component}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ "$COMMAND" = "help" ]; then
  usage
  exit 0
fi

case "$COMMAND" in
  up|status|logs|restart|down) ;;
  *) log_error "Unknown command: ${COMMAND}"; usage; exit 1 ;;
esac

[[ "$DEV_NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || {
  log_error "Developer name must contain lowercase letters, digits, or hyphens."
  exit 1
}
[[ "$ADMIN_USER" =~ ^[a-zA-Z0-9_-]{4,64}$ ]] || {
  log_error "Administrator name must contain 4 to 64 safe characters."
  exit 1
}

for port in "$CONSOLE_PORT" "$GATEWAY_PORT" "$API_HTTP_PORT" "$API_GRPC_PORT" "$INTERNAL_PORT" "$METRICS_PORT"; do
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    log_error "Invalid unprivileged TCP port: ${port}"
    exit 1
  fi
done

if [ -z "$EXPECTED_BRANCH" ]; then
  EXPECTED_BRANCH="develop/${DEV_NAME}"
fi

DEV_ROOT="${DATA_SANDBOX_DEV_ROOT:-${WORKSPACE_DIR}/.dev-runtime/${DEV_NAME}}"
DEV_ROOT="$(realpath -m "$DEV_ROOT")"
DEV_PREFIX="data-sandbox-dev-${DEV_NAME}"
KUSCIA_CONTAINER="${DEV_PREFIX}-kuscia"
SECRETPAD_CONTAINER="${DEV_PREFIX}-secretpad"
DEV_NETWORK="${DEV_PREFIX}"
SECRETPAD_IMAGE="data-sandbox-secretpad:dev-${DEV_NAME}"
DOMAIN_ID="dev-${DEV_NAME}"

KUSCIA_ROOT="${DEV_ROOT}/kuscia"
KUSCIA_CONFIG_DIR="${KUSCIA_ROOT}/config"
KUSCIA_DATA_DIR="${KUSCIA_ROOT}/data"
KUSCIA_LOG_DIR="${KUSCIA_ROOT}/log"
KUSCIA_IMAGE_DIR="${KUSCIA_ROOT}/images"
KUSCIA_K3S_DIR="${KUSCIA_ROOT}/k3s"
KUSCIA_CONTAINERD_DIR="${KUSCIA_ROOT}/containerd"
SECRETPAD_ROOT="${DEV_ROOT}/secretpad"
SECRETPAD_CONFIG_DIR="${SECRETPAD_ROOT}/config"
SECRETPAD_DB_DIR="${SECRETPAD_ROOT}/db"
SECRETPAD_DATA_DIR="${SECRETPAD_ROOT}/data"
SECRETPAD_LOG_DIR="${SECRETPAD_ROOT}/log"
SNAPSHOT_DIR="${DEV_ROOT}/snapshots"
BACKUP_DIR="${DEV_ROOT}/backups"
CREDENTIAL_FILE="${DEV_ROOT}/secretpad.env"
MANIFEST_FILE="${DEV_ROOT}/build-manifest.txt"

owner_label="io.hustnlp.data-sandbox.dev-owner"
workspace_label="io.hustnlp.data-sandbox.dev-workspace"
managed_label="io.hustnlp.data-sandbox.dev"

reject_foreign_paths() {
  local path
  for path in "$PACKAGE_DIR" "$WORKSPACE_DIR" "$BACKEND_DIR" "$FRONTEND_DIR" "$DEV_ROOT"; do
    case "$path" in
      /data/xzh|/data/xzh/*|/home/xzh|/home/xzh/*|/nas/Users/xzh|/nas/Users/xzh/*)
        log_error "Developer isolation rejected a path owned by xzh: ${path}"
        exit 1
        ;;
    esac
  done
  case "$DEV_ROOT" in
    "${WORKSPACE_DIR}"/.dev-runtime/*) ;;
    *)
      log_error "DATA_SANDBOX_DEV_ROOT must stay below ${WORKSPACE_DIR}/.dev-runtime/."
      exit 1
      ;;
  esac
}

require_personal_checkout() {
  local current_uid path path_uid
  current_uid="$(id -u)"
  [ "$current_uid" -ne 0 ] || {
    log_error "Do not run develop.sh with sudo or as root."
    exit 1
  }
  reject_foreign_paths
  for path in "$PACKAGE_DIR" "$BACKEND_DIR" "$FRONTEND_DIR"; do
    [ -d "$path" ] || { log_error "Required checkout is missing: ${path}"; exit 1; }
    path_uid="$(stat -c '%u' "$path")"
    [ "$path_uid" = "$current_uid" ] || {
      log_error "Checkout is not owned by the current user: ${path}"
      exit 1
    }
  done
}

verify_pushed_checkout() {
  local repository=$1
  local branch upstream counts
  git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log_error "Not a Git repository: ${repository}"
    exit 1
  }
  [ -z "$(git -C "$repository" status --porcelain)" ] || {
    log_error "Uncommitted or untracked files exist in ${repository}. Commit and push them first."
    exit 1
  }
  branch="$(git -C "$repository" branch --show-current)"
  [ "$branch" = "$EXPECTED_BRANCH" ] || {
    log_error "${repository} is on ${branch:-detached HEAD}; expected ${EXPECTED_BRANCH}."
    exit 1
  }
  upstream="$(git -C "$repository" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || {
    log_error "${repository} has no upstream branch. Push ${EXPECTED_BRANCH} first."
    exit 1
  }
  git -C "$repository" fetch --quiet || {
    log_error "Cannot refresh the remote state for ${repository}. Check Git access."
    exit 1
  }
  counts="$(git -C "$repository" rev-list --left-right --count "${upstream}...HEAD")"
  [ "$counts" = $'0\t0' ] || {
    log_error "${repository} differs from ${upstream} (${counts}). Pull or push before building."
    exit 1
  }
}

# 双模式分支校验（对齐 data-sandbox-package develop/xzh 的管理员测试方法）：
#   - 默认：仅要求当前分支 == --branch（允许未提交改动，直接在分支上测试，测试通过后再提交推送）
#   - --pushed-only：走 verify_pushed_checkout 的严格校验（clean + upstream 同步），用于发布验证
verify_branch() {
  local repository=$1
  git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log_error "Not a Git repository: ${repository}"
    exit 1
  }
  local branch
  branch="$(git -C "$repository" branch --show-current)"
  [ "$branch" = "$EXPECTED_BRANCH" ] || {
    log_error "${repository} is on ${branch:-detached HEAD}; expected ${EXPECTED_BRANCH}."
    exit 1
  }
  if [ "$REQUIRE_PUSHED" = true ]; then
    verify_pushed_checkout "$repository"
  else
    log "Working-tree mode: ${repository} 构建当前工作树（分支 ${branch}，未提交改动允许，测试通过后再提交推送）。"
  fi
}

verify_managed_container() {
  local container=$1
  local actual_owner actual_workspace managed
  if ! docker inspect "$container" >/dev/null 2>&1; then
    return 1
  fi
  managed="$(docker inspect --format "{{index .Config.Labels \"${managed_label}\"}}" "$container")"
  actual_owner="$(docker inspect --format "{{index .Config.Labels \"${owner_label}\"}}" "$container")"
  actual_workspace="$(docker inspect --format "{{index .Config.Labels \"${workspace_label}\"}}" "$container")"
  if [ "$managed" != "true" ] || [ "$actual_owner" != "$(id -un)" ] || [ "$actual_workspace" != "$WORKSPACE_DIR" ]; then
    log_error "Refusing to operate an unowned container: ${container}"
    exit 1
  fi
  return 0
}

verify_managed_image() {
  local image=$1
  local actual_owner actual_workspace managed
  docker image inspect "$image" >/dev/null 2>&1 || return 1
  managed="$(docker image inspect --format "{{index .Config.Labels \"${managed_label}\"}}" "$image")"
  actual_owner="$(docker image inspect --format "{{index .Config.Labels \"${owner_label}\"}}" "$image")"
  actual_workspace="$(docker image inspect --format "{{index .Config.Labels \"${workspace_label}\"}}" "$image")"
  if [ "$managed" != "true" ] || [ "$actual_owner" != "$(id -un)" ] || [ "$actual_workspace" != "$WORKSPACE_DIR" ]; then
    log_error "Refusing to use an image not built by this developer checkout: ${image}"
    exit 1
  fi
  return 0
}

ensure_network() {
  if docker network inspect "$DEV_NETWORK" >/dev/null 2>&1; then
    local actual_owner actual_workspace
    actual_owner="$(docker network inspect --format "{{index .Labels \"${owner_label}\"}}" "$DEV_NETWORK")"
    actual_workspace="$(docker network inspect --format "{{index .Labels \"${workspace_label}\"}}" "$DEV_NETWORK")"
    if [ "$actual_owner" != "$(id -un)" ] || [ "$actual_workspace" != "$WORKSPACE_DIR" ]; then
      log_error "Refusing to use an unowned Docker network: ${DEV_NETWORK}"
      exit 1
    fi
    return
  fi
  docker network create \
    --label "${managed_label}=true" \
    --label "${owner_label}=$(id -un)" \
    --label "${workspace_label}=${WORKSPACE_DIR}" \
    "$DEV_NETWORK" >/dev/null
}

require_port_available() {
  local port=$1
  local allowed_container=$2
  local owners
  owners="$(docker ps --filter "publish=${port}" --format '{{.Names}}')"
  if [ -n "$owners" ] && [ "$owners" != "$allowed_container" ]; then
    log_error "Port ${port} is already published by: ${owners}"
    exit 1
  fi
}

copy_image_tree() {
  local image=$1
  local source=$2
  local destination=$3
  local temporary="${DEV_PREFIX}-init-${RANDOM}-${RANDOM}"
  docker create --name "$temporary" "$image" >/dev/null
  trap 'docker rm -f "$temporary" >/dev/null 2>&1 || true' RETURN
  docker cp "${temporary}:${source}" "$destination"
  docker rm -f "$temporary" >/dev/null
  trap - RETURN
}

sqlite_exec() {
  local sql=$1
  docker run --rm --entrypoint sqlite3 \
    -v "${SECRETPAD_DB_DIR}:/db" \
    "$SECRETPAD_IMAGE" /db/secretpad.sqlite "$sql"
}

wait_for_kuscia_dev() {
  local attempt=0
  while [ "$attempt" -lt 240 ]; do
    if docker exec "$KUSCIA_CONTAINER" sh -lc \
      'test -f /home/kuscia/var/certs/domain.crt && curl -ksS --max-time 2 https://127.0.0.1:1080/healthZ >/dev/null' \
      >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

ensure_runtime_directories() {
  local fs_type
  mkdir -p "$DEV_ROOT"
  [ "$(stat -c '%u' "$DEV_ROOT")" = "$(id -u)" ] || {
    log_error "Runtime root is not owned by the current user: ${DEV_ROOT}"
    exit 1
  }
  fs_type="$(stat -f -c '%T' "$DEV_ROOT")"
  case "$fs_type" in
    ext2/ext3|xfs|btrfs) ;;
    *)
      log_error "Private Kuscia runtime requires ext4/xfs/btrfs, found ${fs_type} at ${DEV_ROOT}."
      exit 1
      ;;
  esac
  mkdir -p "$KUSCIA_CONFIG_DIR" "$KUSCIA_DATA_DIR" "$KUSCIA_LOG_DIR"
  mkdir -p "$KUSCIA_IMAGE_DIR" "$KUSCIA_K3S_DIR" "$KUSCIA_CONTAINERD_DIR"
  mkdir -p "$SECRETPAD_ROOT" "$SECRETPAD_DB_DIR" "$SECRETPAD_DATA_DIR" "$SECRETPAD_LOG_DIR"
  mkdir -p "$SNAPSHOT_DIR" "$BACKUP_DIR"
  chmod 700 "$DEV_ROOT"
}

build_developer_image() {
  local generated_template="secretpad-web/src/main/resources/templates/index.html"
  verify_branch "$BACKEND_DIR"
  verify_branch "$FRONTEND_DIR"
  if [ "$SKIP_BUILD" = true ]; then
    verify_managed_image "$SECRETPAD_IMAGE" || {
      log_error "Developer image not found: ${SECRETPAD_IMAGE}. Run up without --skip-build."
      exit 1
    }
    return
  fi
  if [ "$REQUIRE_PUSHED" = true ]; then
    log "Building developer image ${SECRETPAD_IMAGE} from pushed commits"
  else
    log "Building developer image ${SECRETPAD_IMAGE} from the current working tree"
  fi
  if ! DATA_SANDBOX_DEV_IMAGE=true \
      DATA_SANDBOX_DEV_IMAGE_OWNER="$(id -un)" \
      DATA_SANDBOX_DEV_IMAGE_WORKSPACE="$WORKSPACE_DIR" \
      SECRETPAD_IMAGE="$SECRETPAD_IMAGE" \
      "${PACKAGE_DIR}/build.sh"; then
    git -C "$BACKEND_DIR" restore --worktree -- "$generated_template"
    log_error "Developer image build failed."
    exit 1
  fi
  git -C "$BACKEND_DIR" restore --worktree -- "$generated_template"
  if [ "$REQUIRE_PUSHED" = true ]; then
    [ -z "$(git -C "$BACKEND_DIR" status --porcelain)" ] || {
      log_error "The build left unexpected changes in ${BACKEND_DIR}."
      exit 1
    }
    [ -z "$(git -C "$FRONTEND_DIR" status --porcelain)" ] || {
      log_error "The build left unexpected changes in ${FRONTEND_DIR}."
      exit 1
    }
  fi
  verify_managed_image "$SECRETPAD_IMAGE"
}

start_kuscia() {
  docker image inspect "$KUSCIA_IMAGE" >/dev/null 2>&1 || {
    log_error "Kuscia image is missing: ${KUSCIA_IMAGE}"
    exit 1
  }
  if [ ! -s "${KUSCIA_CONFIG_DIR}/kuscia.yaml" ]; then
    log "Generating private Kuscia configuration for ${DOMAIN_ID}"
    docker run --rm "$KUSCIA_IMAGE" kuscia init \
      --mode autonomy --domain "$DOMAIN_ID" --protocol mtls --runtime runc \
      >"${KUSCIA_CONFIG_DIR}/kuscia.yaml"
    chmod 600 "${KUSCIA_CONFIG_DIR}/kuscia.yaml"
  fi

  if verify_managed_container "$KUSCIA_CONTAINER"; then
    docker start "$KUSCIA_CONTAINER" >/dev/null
  else
    require_port_available "$INTERNAL_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$GATEWAY_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$API_HTTP_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$API_GRPC_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$METRICS_PORT" "$KUSCIA_CONTAINER"
    # Rootless Docker 下 Kuscia 无法从网关自动探测宿主机 IP（"host IP unknown" 循环重启），
    # 显式注入私有网桥网关地址
    local host_ip_env=()
    local host_ip
    host_ip="$(docker network inspect "$DEV_NETWORK" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
    if [ -n "$host_ip" ]; then
      host_ip_env=(-e "KUSCIA_HOST_IP=${host_ip}")
    fi
    log "Starting private Kuscia container ${KUSCIA_CONTAINER} (host_ip=${host_ip:-auto})"
    docker run -d --init --privileged --restart unless-stopped \
      --name "$KUSCIA_CONTAINER" --hostname "$KUSCIA_CONTAINER" \
      --network "$DEV_NETWORK" \
      "${host_ip_env[@]}" \
      --label "${managed_label}=true" \
      --label "${owner_label}=$(id -un)" \
      --label "${workspace_label}=${WORKSPACE_DIR}" \
      -p "${INTERNAL_PORT}:80" -p "${GATEWAY_PORT}:1080" \
      -p "${API_HTTP_PORT}:8082" -p "${API_GRPC_PORT}:8083" \
      -p "${METRICS_PORT}:9091" \
      -v "${KUSCIA_CONFIG_DIR}/kuscia.yaml:/home/kuscia/etc/conf/kuscia.yaml" \
      -v "${KUSCIA_DATA_DIR}:/home/kuscia/var/storage/data" \
      -v "${KUSCIA_LOG_DIR}:/home/kuscia/var/stdout" \
      -v "${KUSCIA_IMAGE_DIR}:/home/kuscia/var/images" \
      -v "${KUSCIA_K3S_DIR}:/home/kuscia/var/k3s/server/db" \
      -v "${KUSCIA_CONTAINERD_DIR}:/home/kuscia/containerd" \
      "$KUSCIA_IMAGE" bin/kuscia start -c etc/conf/kuscia.yaml >/dev/null
  fi

  if ! wait_for_kuscia_dev; then
    log_error "Private Kuscia did not become healthy: docker logs ${KUSCIA_CONTAINER}"
    exit 1
  fi

  if ! docker exec "$KUSCIA_CONTAINER" test -f /home/kuscia/var/certs/kusciaapi-client.crt >/dev/null 2>&1; then
    log "Generating a private Kuscia API client certificate"
    docker exec "$KUSCIA_CONTAINER" sh -lc '
      set -eu
      cd /home/kuscia/var/certs
      openssl genpkey -out kusciaapi-client.key -algorithm RSA -pkeyopt rsa_keygen_bits:2048
      openssl req -new -key kusciaapi-client.key -out kusciaapi-client.csr -subj "/CN=KusciaAPIClient"
      openssl x509 -req -in kusciaapi-client.csr -CA ca.crt -CAkey ca.key -days 1000 \
        -sha256 -CAcreateserial -out kusciaapi-client.crt
    '
  fi

  ensure_ws_tunnel
}

# 在 kuscia 容器内启动 WS/TCP 隧道：kuscia 0.13.0b0 网关无 upgrade_configs，WS 升级被
# 403 拒绝，Jupyter 内核/终端需经隧道直连 pod（见 scripts/ws-tunnel.py 头部说明）。
# 隧道进程随 kuscia 容器 restart 而消失，本函数幂等，每次 up/restart 都会重跑。
ensure_ws_tunnel() {
  docker cp "${PACKAGE_DIR}/scripts/ws-tunnel.py" "$KUSCIA_CONTAINER":/opt/ws-tunnel.py
  docker exec "$KUSCIA_CONTAINER" pkill -f '/opt/ws-tunnel.py' >/dev/null 2>&1 || true
  docker exec -d "$KUSCIA_CONTAINER" sh -c 'while true; do python3 /opt/ws-tunnel.py; sleep 2; done'
  local ok=0
  for _ in 1 2 3 4 5 6 7 8; do
    if docker exec "$KUSCIA_CONTAINER" python3 -c \
        'import socket;s=socket.create_connection(("127.0.0.1",10082),timeout=2);s.close()' \
        >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  if [ "$ok" -ne 1 ]; then
    log_error "ws-tunnel did not start listening on ${KUSCIA_CONTAINER}:10082 (see /opt/ws-tunnel.log in the container)"
    exit 1
  fi
  log "ws-tunnel 已启动：${KUSCIA_CONTAINER}:10082"
}

stop_ws_tunnel() {
  if verify_managed_container "$KUSCIA_CONTAINER" &&
     docker inspect --format '{{.State.Running}}' "$KUSCIA_CONTAINER" 2>/dev/null | grep -qx true; then
    docker exec "$KUSCIA_CONTAINER" pkill -f '/opt/ws-tunnel.py' >/dev/null 2>&1 || true
  fi
}

ensure_credentials() {
  if [ -f "$CREDENTIAL_FILE" ]; then
    chmod 600 "$CREDENTIAL_FILE"
    ADMIN_USER="$(credential_value SECRETPAD_USER_NAME)"
    # 幂等补齐新阶段引入的环境变量（存量 env 不会自动获得新键）
    if [ -z "$(credential_value DATA_SANDBOX_METRICS_URL)" ]; then
      {
        printf 'DATA_SANDBOX_METRICS_URL=http://%s:9091\n' "$KUSCIA_CONTAINER"
        printf 'DATA_SANDBOX_METRICS_ENABLED=true\n'
      } >>"$CREDENTIAL_FILE"
      chmod 600 "$CREDENTIAL_FILE"
      log "已向 secretpad.env 追加 DATA_SANDBOX_METRICS_* 环境变量。"
    fi
    # 幂等补齐 Kuscia 网关地址（KUSCIA_GW_ADDRESS → secretpad.gateway）：Dev 端点跳板对
    # .svc 集群端点经 Kuscia envoy（容器 :80 按 Host 头路由到沙箱容器）转发，secretpad
    # 容器与 kuscia 同 docker 网络，用容器名 + :80 即可被 Docker DNS 解析。
    # 注意：这是 base 配置 `${KUSCIA_GW_ADDRESS:127.0.0.1:80}` 的环境占位符，非 @Value 前缀变量。
    if [ -z "$(credential_value KUSCIA_GW_ADDRESS)" ]; then
      printf 'KUSCIA_GW_ADDRESS=%s:80\n' "$KUSCIA_CONTAINER" >>"$CREDENTIAL_FILE"
      chmod 600 "$CREDENTIAL_FILE"
      log "已向 secretpad.env 追加 KUSCIA_GW_ADDRESS=${KUSCIA_CONTAINER}:80。"
    fi
    # 幂等补齐指标采集前缀变量（与无前缀的 DATA_SANDBOX_METRICS_* 并存，前缀变量才能被 @Value 绑定）
    if [ -z "$(credential_value SECRETPAD_DATA_SANDBOX_METRICS_URL)" ]; then
      {
        printf 'SECRETPAD_DATA_SANDBOX_METRICS_URL=http://%s:9091\n' "$KUSCIA_CONTAINER"
        printf 'SECRETPAD_DATA_SANDBOX_METRICS_ENABLED=true\n'
        printf 'SECRETPAD_DATA_SANDBOX_METRICS_INTERVAL=30000\n'
      } >>"$CREDENTIAL_FILE"
      chmod 600 "$CREDENTIAL_FILE"
      log "已向 secretpad.env 追加 SECRETPAD_DATA_SANDBOX_METRICS_* 前缀变量。"
    fi
    # 幂等补齐 JDK HttpClient Host 头放行（Dev 端点跳板 envoy 按 Host 头路由；必须 JVM 启动参数，
    # deployed 环境 System.setProperty 晚于 JDK Utils 静态初始化而失效 → restricted header: "host"）
    if ! credential_value JAVA_OPTS | grep -q 'jdk.httpclient.allowRestrictedHeaders=host'; then
      sed -i "s|^JAVA_OPTS=.*|& -Djdk.httpclient.allowRestrictedHeaders=host|" "$CREDENTIAL_FILE"
      chmod 600 "$CREDENTIAL_FILE"
      log "已向 secretpad.env 的 JAVA_OPTS 追加 -Djdk.httpclient.allowRestrictedHeaders=host。"
    fi
    # 幂等补齐 WS 隧道网关地址（secretpad.data-sandbox.websocket-gateway）：kuscia 网关不支持
    # WS 升级，桥的 WS 连接改走 kuscia 容器内隧道（:10082）。与 KUSCIA_GW_ADDRESS(:80) 并存：
    # HTTP 走网关、WS 走隧道。首次应用必须走 up（secretpad 容器 recreate 才读新 env）。
    if [ -z "$(credential_value SECRETPAD_DATA_SANDBOX_WEBSOCKET_GATEWAY)" ]; then
      printf 'SECRETPAD_DATA_SANDBOX_WEBSOCKET_GATEWAY=%s:10082\n' "$KUSCIA_CONTAINER" >>"$CREDENTIAL_FILE"
      chmod 600 "$CREDENTIAL_FILE"
      log "已向 secretpad.env 追加 SECRETPAD_DATA_SANDBOX_WEBSOCKET_GATEWAY=${KUSCIA_CONTAINER}:10082。"
    fi
    return
  fi
  local password password_confirm
  read -r -s -p "Developer administrator password: " password
  printf '\n'
  read -r -s -p "Confirm developer administrator password: " password_confirm
  printf '\n'
  [ "$password" = "$password_confirm" ] || {
    log_error "Passwords do not match."
    exit 1
  }
  [ "${#password}" -ge 8 ] || {
    log_error "Developer administrator password must contain at least 8 characters."
    exit 1
  }
  if [[ "$password" == *$'\n'* ]] || [[ "$password" == *$'\r'* ]]; then
    log_error "Developer administrator password cannot contain a line break."
    exit 1
  fi
  umask 077
  {
    printf 'SPRING_PROFILES_ACTIVE=p2p\n'
    printf 'NODE_ID=%s\n' "$DOMAIN_ID"
    printf 'DEPLOY_MODE=MPC\n'
    printf 'INST_NAME=DataSandbox-%s\n' "$DEV_NAME"
    printf 'KUSCIA_PROTOCOL=mtls\n'
    printf 'KUSCIA_API_ADDRESS=%s:8083\n' "$KUSCIA_CONTAINER"
    printf 'KUSCIA_GW_ADDRESS=%s:80\n' "$KUSCIA_CONTAINER"
    printf 'SECRETPAD_DATA_SANDBOX_WEBSOCKET_GATEWAY=%s:10082\n' "$KUSCIA_CONTAINER"
    printf 'SECRETPAD_USER_NAME=%s\n' "$ADMIN_USER"
    printf 'SECRETPAD_PASSWORD=%s\n' "$password"
    printf 'SECRETPAD_DATA_SANDBOX_KUSCIA_ENABLED=true\n'
    printf 'SECRETPAD_DATA_SANDBOX_SNAPSHOT_ROOT=/app/dev-data/snapshots\n'
    printf 'SECRETPAD_DATA_SANDBOX_BACKUP_ROOT=/app/dev-data/backups\n'
    printf 'SECRETPAD_DATA_SANDBOX_STATUS_SYNC_MS=30000\n'
    printf 'DATA_SANDBOX_METRICS_URL=http://%s:9091\n' "$KUSCIA_CONTAINER"
    printf 'DATA_SANDBOX_METRICS_ENABLED=true\n'
    printf 'SECRETPAD_DATA_SANDBOX_METRICS_URL=http://%s:9091\n' "$KUSCIA_CONTAINER"
    printf 'SECRETPAD_DATA_SANDBOX_METRICS_ENABLED=true\n'
    printf 'SECRETPAD_DATA_SANDBOX_METRICS_INTERVAL=30000\n'
    printf 'SPRINGDOC_API_DOCS_ENABLED=true\n'
    printf 'SPRINGDOC_SWAGGER_UI_ENABLED=true\n'
    printf 'SPRING_WEB_RESOURCES_CACHE_CACHECONTROL_NO_STORE=true\n'
    # -Djdk.httpclient.allowRestrictedHeaders=host 必须作为 JVM 启动参数：deployed 环境里
    # System.setProperty 晚于 JDK HttpClient Utils 静态初始化（restricted header: "host"）。
    printf 'JAVA_OPTS=-server -Xms512m -Xmx1536m -Djdk.httpclient.allowRestrictedHeaders=host\n'
  } >"$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
}

credential_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$CREDENTIAL_FILE" | head -n 1
}

initialize_secretpad_data() {
  if [ ! -f "${SECRETPAD_CONFIG_DIR}/application.yaml" ]; then
    log "Copying private SecretPad configuration"
    copy_image_tree "$SECRETPAD_IMAGE" /app/config "$SECRETPAD_ROOT"
  fi
  # 宿主 config 目录挂载覆盖镜像内 schema，新迁移（V8+）需幂等复制到宿主；
  # cp -n 保证后续版本也能自动出现，且不覆盖 V1-V7。
  log "Synchronizing schema migrations into the host config directory"
  docker run --rm --entrypoint /bin/sh \
    -v "${SECRETPAD_CONFIG_DIR}:/tmp/config" \
    "$SECRETPAD_IMAGE" -lc '
      set -eu
      for mode in center edge p2p; do
        mkdir -p "/tmp/config/schema/${mode}"
        for f in /app/config/schema/${mode}/V*.sql; do
          [ -e "$f" ] && cp -n "$f" "/tmp/config/schema/${mode}/" || true
        done
      done
    ' </dev/null
  mkdir -p "${SECRETPAD_CONFIG_DIR}/certs"

  if [ ! -f "${SECRETPAD_DB_DIR}/secretpad.sqlite" ]; then
    log "Initializing private SecretPad database"
    docker run --rm --entrypoint /bin/sh \
      -v "${SECRETPAD_DB_DIR}:/app/db" \
      -v "${SECRETPAD_CONFIG_DIR}:/app/config" \
      "$SECRETPAD_IMAGE" -lc '
        set -eu
        sqlite3 /app/db/secretpad.sqlite ".read /app/config/schema/p2p/V1__init.sql"
        sqlite3 /app/db/secretpad.sqlite "select 1 from user_accounts limit 1;" >/dev/null
      '
    local password_hash
    password_hash="$(printf '%s' "$(credential_value SECRETPAD_PASSWORD)" | sha256sum | awk '{print $1}')"
    sqlite_exec "delete from user_accounts;
      insert into user_accounts(name, password_hash, owner_type, owner_id, is_deleted)
      values ('${ADMIN_USER}', '${password_hash}', 'P2P', '${DOMAIN_ID}', 0);"
  fi

  if [ ! -f "${SECRETPAD_CONFIG_DIR}/.dev-key-created" ]; then
    docker run --rm --entrypoint /bin/sh \
      -v "${SECRETPAD_CONFIG_DIR}:/tmp/config" \
      "$SECRETPAD_IMAGE" -lc '
        keytool -delete -alias secretpad-server -keystore /tmp/config/server.jks \
          -keypass secretpad -storepass secretpad >/dev/null 2>&1 || true
        keytool -genkey -keystore /tmp/config/server.jks -keyalg RSA -keysize 2048 \
          -validity 3650 -keypass secretpad -storepass secretpad \
          -dname "OU=Development,O=HUSTNLP,L=Wuhan,ST=Hubei,C=CN,CN=DataSandbox" \
          -alias secretpad-server
      ' </dev/null
    touch "${SECRETPAD_CONFIG_DIR}/.dev-key-created"
  fi

  docker cp "${KUSCIA_CONTAINER}:/home/kuscia/var/certs/ca.crt" "${SECRETPAD_CONFIG_DIR}/certs/ca.crt"
  docker cp "${KUSCIA_CONTAINER}:/home/kuscia/var/certs/token" "${SECRETPAD_CONFIG_DIR}/certs/token"
  docker cp "${KUSCIA_CONTAINER}:/home/kuscia/var/certs/kusciaapi-client.crt" "${SECRETPAD_CONFIG_DIR}/certs/client.crt"
  docker cp "${KUSCIA_CONTAINER}:/home/kuscia/var/certs/kusciaapi-client.key" "${SECRETPAD_CONFIG_DIR}/certs/client.pem"
}

start_secretpad() {
  require_port_available "$CONSOLE_PORT" "$SECRETPAD_CONTAINER"
  if verify_managed_container "$SECRETPAD_CONTAINER"; then
    docker rm -f "$SECRETPAD_CONTAINER" >/dev/null
  fi
  log "Starting private SecretPad container ${SECRETPAD_CONTAINER}"
  docker run -d --init --restart unless-stopped \
    --name "$SECRETPAD_CONTAINER" --network "$DEV_NETWORK" \
    --label "${managed_label}=true" \
    --label "${owner_label}=$(id -un)" \
    --label "${workspace_label}=${WORKSPACE_DIR}" \
    -p "${CONSOLE_PORT}:8080" \
    --env-file "$CREDENTIAL_FILE" \
    -v "${SECRETPAD_CONFIG_DIR}:/app/config" \
    -v "${SECRETPAD_DB_DIR}:/app/db" \
    -v "${SECRETPAD_DATA_DIR}:/app/data" \
    -v "${SECRETPAD_LOG_DIR}:/app/log" \
    -v "${SNAPSHOT_DIR}:/app/dev-data/snapshots" \
    -v "${BACKUP_DIR}:/app/dev-data/backups" \
    "$SECRETPAD_IMAGE" >/dev/null

  if ! wait_for_secretpad "$CONSOLE_PORT" 180; then
    log_error "Private SecretPad did not become healthy: docker logs ${SECRETPAD_CONTAINER}"
    exit 1
  fi

  if [ ! -f "${SECRETPAD_ROOT}/.node-address-configured" ]; then
    docker stop "$SECRETPAD_CONTAINER" >/dev/null
    sqlite_exec "update node set net_address='https://${KUSCIA_CONTAINER}:1080' where node_id='${DOMAIN_ID}';"
    touch "${SECRETPAD_ROOT}/.node-address-configured"
    docker start "$SECRETPAD_CONTAINER" >/dev/null
    wait_for_secretpad "$CONSOLE_PORT" 180 || {
      log_error "Private SecretPad failed after configuring its node address."
      exit 1
    }
  fi
}

write_manifest() {
  local backend_sha frontend_sha image_id
  backend_sha="$(git -C "$BACKEND_DIR" rev-parse HEAD)"
  frontend_sha="$(git -C "$FRONTEND_DIR" rev-parse HEAD)"
  image_id="$(docker image inspect --format '{{.Id}}' "$SECRETPAD_IMAGE")"
  umask 077
  {
    printf 'built_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'developer=%s\n' "$(id -un)"
    printf 'workspace=%s\n' "$WORKSPACE_DIR"
    printf 'secretpad_commit=%s\n' "$backend_sha"
    printf 'secretpad_frontend_commit=%s\n' "$frontend_sha"
    printf 'secretpad_image=%s\n' "$SECRETPAD_IMAGE"
    printf 'secretpad_image_id=%s\n' "$image_id"
    printf 'console_port=%s\n' "$CONSOLE_PORT"
    printf 'kuscia_gateway_port=%s\n' "$GATEWAY_PORT"
  } >"$MANIFEST_FILE"
}

show_status() {
  printf 'Developer: %s\n' "$DEV_NAME"
  printf 'Workspace: %s\n' "$WORKSPACE_DIR"
  printf 'Runtime:   %s\n' "$DEV_ROOT"
  printf 'Console:   http://127.0.0.1:%s/edge?tab=sandbox-manager\n' "$CONSOLE_PORT"
  printf '\nContainers:\n'
  for container in "$KUSCIA_CONTAINER" "$SECRETPAD_CONTAINER"; do
    if verify_managed_container "$container"; then
      docker inspect --format '  {{.Name}}: {{.State.Status}} ({{.Config.Image}})' "$container"
    else
      printf '  %s: not created\n' "$container"
    fi
  done
  if [ -f "$MANIFEST_FILE" ]; then
    printf '\nBuild manifest:\n'
    sed 's/^/  /' "$MANIFEST_FILE"
  fi
}

# Stage 0 门禁：优先使用 rootful docker（沙箱容器才能真正启动）。
# 安全：不自动 sudo、不改系统配置；仅做可达性判断并给出管理员操作指引。
check_docker_privilege() {
  if [ -n "${DOCKER_HOST:-}" ]; then
    docker info >/dev/null 2>&1 || {
      log_error "已显式指定 DOCKER_HOST=${DOCKER_HOST}，但该 daemon 不可达。"
      exit 1
    }
    log "Using explicit Docker daemon: ${DOCKER_HOST}"
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    log "Rootful Docker 可用（默认 daemon）。"
    return 0
  fi
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    log_error "已在 docker 组，但当前会话尚未获得 /var/run/docker.sock 权限，请重新登录（或 newgrp docker）后再运行。"
    exit 1
  fi
  log_error "Rootful Docker 不可用：/var/run/docker.sock 当前无权限。需要管理员将 $(id -un) 加入 docker 组（重新登录生效）或配置 passwordless sudo。"
  log_error "回退：DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock ./develop.sh up 使用 rootless daemon（沙箱容器仍受限）。"
  exit 1
}

require_personal_checkout
require_command docker
require_command curl
require_command realpath
require_command git

case "$COMMAND" in
  up)
    require_command sha256sum
    check_docker_privilege
    ensure_runtime_directories
    build_developer_image
    ensure_network
    start_kuscia
    ensure_credentials
    initialize_secretpad_data
    start_secretpad
    write_manifest
    log_success "Private developer system is ready at http://127.0.0.1:${CONSOLE_PORT}/edge?tab=sandbox-manager"
    log "Administrator: ${ADMIN_USER}"
    ;;
  status)
    show_status
    ;;
  logs)
    case "$LOG_COMPONENT" in
      secretpad) target="$SECRETPAD_CONTAINER" ;;
      kuscia) target="$KUSCIA_CONTAINER" ;;
      *) log_error "Log component must be secretpad or kuscia."; exit 1 ;;
    esac
    verify_managed_container "$target" || { log_error "Container not found: ${target}"; exit 1; }
    exec docker logs --tail 300 -f "$target"
    ;;
  restart)
    verify_managed_container "$KUSCIA_CONTAINER" || { log_error "Private Kuscia is not created."; exit 1; }
    verify_managed_container "$SECRETPAD_CONTAINER" || { log_error "Private SecretPad is not created."; exit 1; }
    docker restart "$KUSCIA_CONTAINER" >/dev/null
    wait_for_kuscia_dev || { log_error "Private Kuscia did not become healthy."; exit 1; }
    ensure_credentials
    ensure_ws_tunnel
    docker restart "$SECRETPAD_CONTAINER" >/dev/null
    wait_for_secretpad "$CONSOLE_PORT" 180 || { log_error "Private SecretPad did not become healthy."; exit 1; }
    log_success "Private developer system restarted."
    ;;
  down)
    stop_ws_tunnel
    if verify_managed_container "$SECRETPAD_CONTAINER"; then
      docker stop "$SECRETPAD_CONTAINER" >/dev/null
    fi
    if verify_managed_container "$KUSCIA_CONTAINER"; then
      docker stop "$KUSCIA_CONTAINER" >/dev/null
    fi
    log_success "Private developer system stopped. Runtime data was retained at ${DEV_ROOT}."
    ;;
esac
