#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

# Build and run a fully isolated developer stack from the current checkout.
# It reads data-sandbox.env for shared deployment and image defaults, while
# keeping its own DATA_SANDBOX_DEV_* ports and runtime directory isolated.
set -Eeuo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${PACKAGE_DIR}/.." && pwd)"
BACKEND_DIR="$(realpath -m "${WORKSPACE_DIR}/secretpad")"
FRONTEND_DIR="$(realpath -m "${WORKSPACE_DIR}/secretpad-frontend")"

# shellcheck source=deploy/common/log.sh
source "${PACKAGE_DIR}/deploy/common/log.sh"
# shellcheck source=deploy/common/utils.sh
source "${PACKAGE_DIR}/deploy/common/utils.sh"
load_env "${PACKAGE_DIR}"

case "${1:-help}" in
  -h|--help) COMMAND=help ;;
  *) COMMAND="${1:-help}" ;;
esac
if [ "$#" -gt 0 ]; then
  shift
fi

DEV_NAME="${DATA_SANDBOX_DEV_NAME:-$(id -un)}"
CONSOLE_PORT="${DATA_SANDBOX_DEV_PORT:-19088}"
GATEWAY_PORT="${DATA_SANDBOX_DEV_GATEWAY_PORT:-19080}"
API_HTTP_PORT="${DATA_SANDBOX_DEV_API_HTTP_PORT:-19082}"
API_GRPC_PORT="${DATA_SANDBOX_DEV_API_GRPC_PORT:-19083}"
INTERNAL_PORT="${DATA_SANDBOX_DEV_INTERNAL_PORT:-19081}"
METRICS_PORT="${DATA_SANDBOX_DEV_METRICS_PORT:-19084}"
ADMIN_USER="${DATA_SANDBOX_DEV_ADMIN_USER:-devadmin}"
ADVERTISE_HOST="${DATA_SANDBOX_DEV_ADVERTISE_HOST:-}"
EXPECTED_BRANCH="${DATA_SANDBOX_DEV_BRANCH:-}"
SKIP_BUILD=false
REQUIRE_PUSHED=false
LOG_COMPONENT=secretpad
KUSCIA_IMAGE="${DATA_SANDBOX_DEV_KUSCIA_IMAGE:-secretflow-registry.cn-hangzhou.cr.aliyuncs.com/secretflow/kuscia:0.13.0b0}"
MINIO_IMAGE="${DATA_SANDBOX_DEV_MINIO_IMAGE:-minio/minio:RELEASE.2025-04-22T22-12-26Z}"
SAMPLER_IMAGE="${DATA_SANDBOX_DEV_SAMPLER_IMAGE:-data-sandbox-sampler:latest}"
SAMPLER_DOCKER_DIR="${PACKAGE_DIR}/docker/data-sandbox-sampler"
RUNNER_LIB_DIR="${PACKAGE_DIR}/docker/data-sandbox-runner-lib"

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
  --port PORT            SecretPad console port. Default: 19088.
  --gateway-port PORT    Kuscia gateway port. Default: 19080.
  --api-http-port PORT   Kuscia HTTP API port. Default: 19082.
  --api-grpc-port PORT   Kuscia gRPC API port. Default: 19083.
  --internal-port PORT   Kuscia internal service port. Default: 19081.
  --metrics-port PORT    Kuscia metrics port. Default: 19084.
  --advertise-host HOST  Host that peers use to reach this instance's gateway.
                         Default: this machine's outbound IP address.
  --admin-user USER      SecretPad developer administrator. Default: devadmin.
  --branch BRANCH        Required branch. Default: develop/<developer-name>.
  --skip-build           Reuse the existing developer image.
  --pushed-only          Require clean worktrees synchronized with upstream before building.
  --component NAME       Log component: secretpad or kuscia.
  -h, --help             Show this help.

Environment overrides:
  DATA_SANDBOX_DEV_ROOT          Private runtime root. It must be below this checkout.
  DATA_SANDBOX_DEV_KUSCIA_IMAGE  Kuscia image used by the private stack.
  DATA_SANDBOX_DEV_MINIO_IMAGE   MinIO image used for private immutable assets.
  DATA_SANDBOX_DEV_SAMPLER_IMAGE Sampler image used by custom governance tasks.

The default `up` builds the current working tree, so developers can test before
committing. `--pushed-only` enables the stricter commit-and-push check used for
release verification. Runtime data, credentials, certificates, containers, ports,
and the Docker network are isolated from every shared Alice/Bob deployment.
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
    --advertise-host) ADVERTISE_HOST="${2:?Missing value for --advertise-host}"; shift 2 ;;
    --branch) EXPECTED_BRANCH="${2:?Missing value for --branch}"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --pushed-only) REQUIRE_PUSHED=true; shift ;;
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
MINIO_CONTAINER="${DEV_PREFIX}-minio"
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
MINIO_DATA_DIR="${DEV_ROOT}/minio"
SNAPSHOT_DIR="${DEV_ROOT}/snapshots"
BACKUP_DIR="${DEV_ROOT}/backups"
CREDENTIAL_FILE="${DEV_ROOT}/secretpad.env"
MANIFEST_FILE="${DEV_ROOT}/build-manifest.txt"

owner_label="io.hustnlp.data-sandbox.dev-owner"
workspace_label="io.hustnlp.data-sandbox.dev-workspace"
managed_label="io.hustnlp.data-sandbox.dev"

reject_foreign_paths() {
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

verify_checkout() {
  local repository=$1
  local branch
  git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log_error "Not a Git repository: ${repository}"
    exit 1
  }
  branch="$(git -C "$repository" branch --show-current)"
  [ "$branch" = "$EXPECTED_BRANCH" ] || {
    log_error "${repository} is on ${branch:-detached HEAD}; expected ${EXPECTED_BRANCH}."
    exit 1
  }
  if [ "$REQUIRE_PUSHED" = false ]; then
    return 0
  fi
  [ -z "$(git -C "$repository" status --porcelain)" ] || {
    log_error "Uncommitted or untracked files exist in ${repository}. Commit and push them first."
    exit 1
  }
  local upstream counts
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

check_host_inotify_limits() {
  local instances_file=/proc/sys/fs/inotify/max_user_instances
  local watches_file=/proc/sys/fs/inotify/max_user_watches
  local instances watches
  local minimum_instances=1024
  local minimum_watches=1048576

  # Kuscia's embedded containerd watches its CNI and runtime directories.  A
  # low host inotify quota makes the Kuscia process exit immediately, which
  # Docker reports only as a restart loop.
  if [ ! -r "$instances_file" ] || [ ! -r "$watches_file" ]; then
    return 0
  fi
  instances="$(<"$instances_file")"
  watches="$(<"$watches_file")"
  if [ "$instances" -ge "$minimum_instances" ] && [ "$watches" -ge "$minimum_watches" ]; then
    return 0
  fi

  log_error "Host inotify limits are too low for Kuscia (instances=${instances}, watches=${watches})."
  log_error "Run as root, then retry:"
  log_error "  sudo sysctl -w fs.inotify.max_user_instances=${minimum_instances}"
  log_error "  sudo sysctl -w fs.inotify.max_user_watches=${minimum_watches}"
  log_error "For persistence, add both settings to /etc/sysctl.d/99-data-sandbox.conf and run sudo sysctl --system."
  exit 1
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

# 本机对外 IP。各开发实例的容器分处独立 Docker 网络，容器名只在同网络内可解析，
# 跨实例协作必须经宿主机与已映射的网关端口。
resolve_advertise_host() {
  if [ -n "$ADVERTISE_HOST" ]; then
    printf '%s' "$ADVERTISE_HOST"
    return 0
  fi
  local address
  address="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  if [ -z "$address" ]; then
    address="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$address"
}

sqlite_query() {
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
  mkdir -p "$MINIO_DATA_DIR" "$SNAPSHOT_DIR" "$BACKUP_DIR"
  chmod 700 "$DEV_ROOT"
}

build_developer_image() {
  local generated_template="${BACKEND_DIR}/secretpad-web/src/main/resources/templates/index.html"
  local template_backup="${DEV_ROOT}/.build-template-backup"
  local template_exists=false
  local backend_status_before frontend_status_before backend_status_after frontend_status_after
  verify_checkout "$BACKEND_DIR"
  verify_checkout "$FRONTEND_DIR"
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
  backend_status_before="$(git -C "$BACKEND_DIR" status --porcelain)"
  frontend_status_before="$(git -C "$FRONTEND_DIR" status --porcelain)"
  if [ -e "$generated_template" ]; then
    cp -a "$generated_template" "$template_backup"
    template_exists=true
  fi
  if ! DATA_SANDBOX_DEV_IMAGE=true \
      DATA_SANDBOX_DEV_IMAGE_OWNER="$(id -un)" \
      DATA_SANDBOX_DEV_IMAGE_WORKSPACE="$WORKSPACE_DIR" \
      SECRETPAD_IMAGE="$SECRETPAD_IMAGE" \
      "${PACKAGE_DIR}/build.sh"; then
    if [ "$template_exists" = true ]; then
      cp -a "$template_backup" "$generated_template"
    else
      rm -f "$generated_template"
    fi
    rm -f "$template_backup"
    log_error "Developer image build failed."
    exit 1
  fi
  if [ "$template_exists" = true ]; then
    cp -a "$template_backup" "$generated_template"
  else
    rm -f "$generated_template"
  fi
  rm -f "$template_backup"
  backend_status_after="$(git -C "$BACKEND_DIR" status --porcelain)"
  frontend_status_after="$(git -C "$FRONTEND_DIR" status --porcelain)"
  [ "$backend_status_before" = "$backend_status_after" ] || {
    log_error "The build changed source files in ${BACKEND_DIR}."
    exit 1
  }
  [ "$frontend_status_before" = "$frontend_status_after" ] || {
    log_error "The build changed source files in ${FRONTEND_DIR}."
    exit 1
  }
  verify_managed_image "$SECRETPAD_IMAGE"
}

sampler_source_hash() {
  sha256sum \
    "${SAMPLER_DOCKER_DIR}/Dockerfile" \
    "${SAMPLER_DOCKER_DIR}/sampler_server.py" \
    "${SAMPLER_DOCKER_DIR}/start.sh" \
    "${RUNNER_LIB_DIR}/runner_common.py" \
    | sha256sum | awk '{print $1}'
}

build_sampler_image() {
  local required_file source_hash current_hash
  for required_file in \
      "${SAMPLER_DOCKER_DIR}/Dockerfile" \
      "${SAMPLER_DOCKER_DIR}/sampler_server.py" \
      "${SAMPLER_DOCKER_DIR}/start.sh" \
      "${RUNNER_LIB_DIR}/runner_common.py"; do
    [ -f "$required_file" ] || {
      log_error "Sampler build file is missing: ${required_file}"
      exit 1
    }
  done

  source_hash="$(sampler_source_hash)"
  current_hash="$(docker image inspect --format '{{index .Config.Labels "io.hustnlp.data-sandbox.sampler-source-sha256"}}' \
    "$SAMPLER_IMAGE" 2>/dev/null || true)"
  if [ "$current_hash" = "$source_hash" ]; then
    log "Sampler image is current: ${SAMPLER_IMAGE}"
    return
  fi

  log "Building sampler image ${SAMPLER_IMAGE}"
  docker build \
    --label "io.hustnlp.data-sandbox.sampler-source-sha256=${source_hash}" \
    -f "${SAMPLER_DOCKER_DIR}/Dockerfile" \
    -t "$SAMPLER_IMAGE" \
    "${PACKAGE_DIR}/docker"
}

import_sampler_image() {
  local host_image_id image_tar container_image_tar
  host_image_id="$(docker image inspect --format '{{.Id}}' "$SAMPLER_IMAGE")"
  if docker exec "$KUSCIA_CONTAINER" /home/kuscia/bin/crictl images -q 2>/dev/null \
      | grep -Fxq "$host_image_id"; then
    log "Sampler image is already imported into ${KUSCIA_CONTAINER}"
    return
  fi

  image_tar="$(mktemp "${KUSCIA_IMAGE_DIR}/data-sandbox-sampler.XXXXXX.tar")"
  container_image_tar="/home/kuscia/var/images/$(basename "$image_tar")"
  log "Importing ${SAMPLER_IMAGE} into ${KUSCIA_CONTAINER}"
  docker save -o "$image_tar" "$SAMPLER_IMAGE"
  if ! docker exec "$KUSCIA_CONTAINER" /home/kuscia/bin/ctr \
      --address /home/kuscia/containerd/run/containerd.sock \
      -n k8s.io images import "$container_image_tar"; then
    rm -f "$image_tar"
    log_error "Failed to import ${SAMPLER_IMAGE} into ${KUSCIA_CONTAINER}."
    exit 1
  fi
  rm -f "$image_tar"

  docker exec "$KUSCIA_CONTAINER" /home/kuscia/bin/crictl images -q 2>/dev/null \
    | grep -Fxq "$host_image_id" || {
      log_error "Imported sampler image ID does not match the host image: ${host_image_id}"
      exit 1
    }
}

ensure_sampler_runtime() {
  local register_script appimage
  register_script="${BACKEND_DIR}/scripts/deploy/data-sandbox/register-data-sandbox-sampler-appimages.sh"
  [ -x "$register_script" ] || {
    log_error "Sampler AppImage registration script is missing or not executable: ${register_script}"
    exit 1
  }

  build_sampler_image
  import_sampler_image
  DATA_SANDBOX_SAMPLER_IMAGE="$SAMPLER_IMAGE" "$register_script" "$KUSCIA_CONTAINER"
  for appimage in data-sandbox-sampler data-sandbox-sampler-nonet; do
    docker exec "$KUSCIA_CONTAINER" kubectl get appimage.kuscia.secretflow "$appimage" >/dev/null 2>&1 || {
      log_error "Sampler AppImage registration failed: ${appimage}"
      exit 1
    }
  done
  log_success "Sampler image and AppImages are ready in ${KUSCIA_CONTAINER}."
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
    local kuscia_status kuscia_nofile
    kuscia_status="$(docker inspect --format '{{.State.Status}}' "$KUSCIA_CONTAINER")"
    kuscia_nofile="$(docker inspect --format '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}:{{.Hard}}{{end}}{{end}}' "$KUSCIA_CONTAINER")"
    # Older developer containers were created without a file-descriptor limit.
    # Recreate those containers so containerd can install its CNI watchers.
    if [ "$kuscia_status" = "restarting" ] || [ "$kuscia_nofile" != "1048576:1048576" ]; then
      docker rm -f "$KUSCIA_CONTAINER" >/dev/null
      kuscia_status=""
    fi
    if [ -n "$kuscia_status" ]; then
      docker start "$KUSCIA_CONTAINER" >/dev/null
    else
      require_port_available "$INTERNAL_PORT" "$KUSCIA_CONTAINER"
      require_port_available "$GATEWAY_PORT" "$KUSCIA_CONTAINER"
      require_port_available "$API_HTTP_PORT" "$KUSCIA_CONTAINER"
      require_port_available "$API_GRPC_PORT" "$KUSCIA_CONTAINER"
      require_port_available "$METRICS_PORT" "$KUSCIA_CONTAINER"
      log "Starting private Kuscia container ${KUSCIA_CONTAINER}"
      docker run -d --init --privileged --restart unless-stopped \
        --ulimit nofile=1048576:1048576 \
        --name "$KUSCIA_CONTAINER" --hostname "$KUSCIA_CONTAINER" \
        --network "$DEV_NETWORK" \
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
  else
    require_port_available "$INTERNAL_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$GATEWAY_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$API_HTTP_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$API_GRPC_PORT" "$KUSCIA_CONTAINER"
    require_port_available "$METRICS_PORT" "$KUSCIA_CONTAINER"
    log "Starting private Kuscia container ${KUSCIA_CONTAINER}"
    docker run -d --init --privileged --restart unless-stopped \
      --ulimit nofile=1048576:1048576 \
      --name "$KUSCIA_CONTAINER" --hostname "$KUSCIA_CONTAINER" \
      --network "$DEV_NETWORK" \
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
}

ensure_credentials() {
  if [ -f "$CREDENTIAL_FILE" ]; then
    chmod 600 "$CREDENTIAL_FILE"
    ADMIN_USER="$(credential_value SECRETPAD_USER_NAME)"
    ensure_minio_credentials
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
    printf 'SECRETPAD_USER_NAME=%s\n' "$ADMIN_USER"
    printf 'SECRETPAD_PASSWORD=%s\n' "$password"
    printf 'SECRETPAD_DATA_SANDBOX_KUSCIA_ENABLED=true\n'
    printf 'SECRETPAD_DATA_SANDBOX_SNAPSHOT_ROOT=/app/dev-data/snapshots\n'
    printf 'SECRETPAD_DATA_SANDBOX_BACKUP_ROOT=/app/dev-data/backups\n'
    printf 'SECRETPAD_DATA_SANDBOX_STATUS_SYNC_MS=30000\n'
    printf 'MINIO_ROOT_USER=data-sandbox-%s\n' "$DEV_NAME"
    printf 'MINIO_ROOT_PASSWORD=%s\n' "$(printf '%s' "$password" | sha256sum | awk '{print $1}')"
    printf 'MINIO_KMS_SECRET_KEY=data-sandbox-key:%s\n' "$(printf '%s' "${password}:${DEV_NAME}:kms" | openssl dgst -sha256 -binary | openssl base64 -A)"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_ENDPOINT=http://%s:9000\n' "$MINIO_CONTAINER"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_ACCESS_KEY=data-sandbox-%s\n' "$DEV_NAME"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_SECRET_KEY=%s\n' "$(printf '%s' "$password" | sha256sum | awk '{print $1}')"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_BUCKET=data-sandbox-assets\n'
    printf 'SPRINGDOC_API_DOCS_ENABLED=true\n'
    printf 'SPRINGDOC_SWAGGER_UI_ENABLED=true\n'
    printf 'SPRING_WEB_RESOURCES_CACHE_CACHECONTROL_NO_STORE=true\n'
    printf 'JAVA_OPTS=-server -Xms512m -Xmx1536m\n'
  } >"$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
}

ensure_minio_credentials() {
  grep -q '^MINIO_ROOT_USER=' "$CREDENTIAL_FILE" && return
  local password secret kms_key
  password="$(credential_value SECRETPAD_PASSWORD)"
  secret="$(printf '%s' "$password" | sha256sum | awk '{print $1}')"
  kms_key="$(printf '%s' "${password}:${DEV_NAME}:kms" | openssl dgst -sha256 -binary | openssl base64 -A)"
  {
    printf 'MINIO_ROOT_USER=data-sandbox-%s\n' "$DEV_NAME"
    printf 'MINIO_ROOT_PASSWORD=%s\n' "$secret"
    printf 'MINIO_KMS_SECRET_KEY=data-sandbox-key:%s\n' "$kms_key"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_ENDPOINT=http://%s:9000\n' "$MINIO_CONTAINER"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_ACCESS_KEY=data-sandbox-%s\n' "$DEV_NAME"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_SECRET_KEY=%s\n' "$secret"
    printf 'SECRETPAD_DATA_ASSETS_MINIO_BUCKET=data-sandbox-assets\n'
  } >>"$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
}

credential_value() {
  local key=$1
  sed -n "s/^${key}=//p" "$CREDENTIAL_FILE" | head -n 1
}

start_minio() {
  if verify_managed_container "$MINIO_CONTAINER"; then
    docker rm -f "$MINIO_CONTAINER" >/dev/null
  fi
  log "Starting private MinIO container ${MINIO_CONTAINER}"
  docker run -d --init --restart unless-stopped \
    --name "$MINIO_CONTAINER" --network "$DEV_NETWORK" \
    --label "${managed_label}=true" \
    --label "${owner_label}=$(id -un)" \
    --label "${workspace_label}=${WORKSPACE_DIR}" \
    -e "MINIO_ROOT_USER=$(credential_value MINIO_ROOT_USER)" \
    -e "MINIO_ROOT_PASSWORD=$(credential_value MINIO_ROOT_PASSWORD)" \
    -e "MINIO_KMS_SECRET_KEY=$(credential_value MINIO_KMS_SECRET_KEY)" \
    -v "${MINIO_DATA_DIR}:/data" \
    "$MINIO_IMAGE" server /data >/dev/null

  local attempt=0
  while [ "$attempt" -lt 60 ]; do
    if docker exec "$KUSCIA_CONTAINER" curl -fsS --max-time 2 \
      "http://${MINIO_CONTAINER}:9000/minio/health/live" >/dev/null 2>&1; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  log_error "Private MinIO did not become healthy: docker logs ${MINIO_CONTAINER}"
  exit 1
}

initialize_secretpad_data() {
  if [ ! -f "${SECRETPAD_CONFIG_DIR}/application.yaml" ]; then
    log "Copying private SecretPad configuration"
    copy_image_tree "$SECRETPAD_IMAGE" /app/config "$SECRETPAD_ROOT"
  fi
  local config_file
  for config_file in \
    "${SECRETPAD_CONFIG_DIR}/application.yaml" \
    "${SECRETPAD_CONFIG_DIR}/application-p2p.yaml" \
    "${SECRETPAD_CONFIG_DIR}/application-edge.yaml" \
    "${SECRETPAD_CONFIG_DIR}/application-test.yaml"; do
    if [ -f "$config_file" ] && \
      ! grep -q 'org.secretflow.secretpad.persistence.entity.ProjectAssetDO' "$config_file"; then
      if ! grep -q 'org.secretflow.secretpad.persistence.entity.ProjectDatatableDO' "$config_file"; then
        log_error "Unable to update data sync entities: ProjectDatatableDO is missing from ${config_file}"
        exit 1
      fi
      log "Adding project asset synchronization to ${config_file}"
      sed -i \
        '/org.secretflow.secretpad.persistence.entity.ProjectDatatableDO/a\    - org.secretflow.secretpad.persistence.entity.ProjectAssetDO' \
        "$config_file"
    fi
    if [ -f "$config_file" ] && \
      ! grep -q 'org.secretflow.secretpad.persistence.entity.SandboxApprovalSyncDO' "$config_file"; then
      if ! grep -q 'org.secretflow.secretpad.persistence.entity.ProjectAssetDO' "$config_file"; then
        log_error "Unable to update data sync entities: ProjectAssetDO is missing from ${config_file}"
        exit 1
      fi
      log "Adding sandbox approval synchronization to ${config_file}"
      sed -i \
        '/org.secretflow.secretpad.persistence.entity.ProjectAssetDO/a\    - org.secretflow.secretpad.persistence.entity.SandboxApprovalSyncDO' \
        "$config_file"
    fi
    if [ -f "$config_file" ] && grep -q '^flyway:' "$config_file" && \
      ! grep -q '^    out-of-order:' "$config_file"; then
      log "Enabling out-of-order Flyway recovery in ${config_file}"
      sed -i '/^      - filesystem:.*schema\//a\    out-of-order: true' "$config_file"
    fi
    if [ -f "$config_file" ] && grep -q '^flyway:' "$config_file" && \
      ! grep -q '^    validate-on-migrate:' "$config_file"; then
      log "Disabling Flyway checksum validation for developer runtime in ${config_file}"
      sed -i '/^    out-of-order: true/a\    validate-on-migrate: false\n    ignore-migration-patterns:\n      - '\''*:missing'\''' "$config_file"
    fi
  done
  local profile version
  for profile in center edge p2p; do
    mkdir -p "${SECRETPAD_CONFIG_DIR}/schema/${profile}"
    # Remove migrations from older builds before copying the current chain;
    # otherwise renamed migrations can leave duplicate Flyway versions behind.
    find "${SECRETPAD_CONFIG_DIR}/schema/${profile}" -maxdepth 1 -type f -name 'V*.sql' -delete
    # Copy the complete migration chain, including V7-V13. Older versions of
    # this script copied only V6 and V14+, causing missing tables such as
    # ds_resource_allocation in freshly built developer runtimes.
    cp "${BACKEND_DIR}/config/schema/${profile}"/V*.sql \
      "${SECRETPAD_CONFIG_DIR}/schema/${profile}/"
    # V13 duplicates V17 and cannot be safely replayed out of order.
    rm -f "${SECRETPAD_CONFIG_DIR}/schema/${profile}/V13__model_test.sql"
  done
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

register_secretpad_service() {
  local attempt=0
  log "Registering the private console service in Kuscia for ${DOMAIN_ID}"

  if ! docker exec "$KUSCIA_CONTAINER" kubectl get service secretpad \
      -n "$DOMAIN_ID" >/dev/null 2>&1; then
    docker exec "$KUSCIA_CONTAINER" \
      scripts/deploy/create_secretpad_svc.sh "$SECRETPAD_CONTAINER" "$DOMAIN_ID" \
      >/dev/null
  fi

  # Node-to-node calls must use the internal 9001 connector. That connector
  # authenticates the kuscia-origin-source header as a node identity; routing
  # them to the browser-facing 8080 connector would incorrectly require a
  # User-Token and make data synchronization fail with HTTP 404.
  docker exec "$KUSCIA_CONTAINER" kubectl patch service secretpad \
    -n "$DOMAIN_ID" --type merge \
    -p "{\"spec\":{\"externalName\":\"${SECRETPAD_CONTAINER}\",\"ports\":[{\"port\":9001,\"protocol\":\"TCP\",\"targetPort\":9001}]}}" \
    >/dev/null

  while [ "$attempt" -lt 60 ]; do
    if docker exec "$KUSCIA_CONTAINER" curl -fsS --max-time 2 \
      -H "Host: secretpad.${DOMAIN_ID}.svc" \
      "http://127.0.0.1:80/api/v1alpha1/data/sync" \
      >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  log_error "The private console service route did not become available: secretpad.${DOMAIN_ID}.svc"
  return 1
}

start_secretpad() {
  require_port_available "$CONSOLE_PORT" "$SECRETPAD_CONTAINER"
  if verify_managed_container "$SECRETPAD_CONTAINER"; then
    docker rm -f "$SECRETPAD_CONTAINER" >/dev/null
  fi
  log "Starting private SecretPad container ${SECRETPAD_CONTAINER}"
  docker run -d --init --restart unless-stopped \
    --name "$SECRETPAD_CONTAINER" --network "$DEV_NETWORK" \
    --add-host host.docker.internal:host-gateway \
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

  # 本节点对外通告的地址，会被打进节点认证码并由对端直接用于建立路由，
  # 因此以当前实际值为准判断是否需要更新，不能只在首次部署时写一次。
  local advertise_host node_address current_address
  advertise_host="$(resolve_advertise_host)"
  if [ -z "$advertise_host" ]; then
    log_error "Unable to determine this machine's address; pass --advertise-host explicitly."
    exit 1
  fi
  node_address="https://${advertise_host}:${GATEWAY_PORT}"
  current_address="$(sqlite_query "select net_address from node where node_id='${DOMAIN_ID}';" 2>/dev/null || true)"
  if [ "$current_address" != "$node_address" ]; then
    log "Advertising node ${DOMAIN_ID} at ${node_address}"
    docker stop "$SECRETPAD_CONTAINER" >/dev/null
    sqlite_exec "update node set net_address='${node_address}' where node_id='${DOMAIN_ID}';"
    touch "${SECRETPAD_ROOT}/.node-address-configured"
    docker start "$SECRETPAD_CONTAINER" >/dev/null
    wait_for_secretpad "$CONSOLE_PORT" 180 || {
      log_error "Private SecretPad failed after configuring its node address."
      exit 1
    }
  fi

  register_secretpad_service || exit 1
}

write_manifest() {
  local backend_sha frontend_sha image_id sampler_image_id
  backend_sha="$(git -C "$BACKEND_DIR" rev-parse HEAD)"
  frontend_sha="$(git -C "$FRONTEND_DIR" rev-parse HEAD)"
  image_id="$(docker image inspect --format '{{.Id}}' "$SECRETPAD_IMAGE")"
  sampler_image_id="$(docker image inspect --format '{{.Id}}' "$SAMPLER_IMAGE")"
  umask 077
  {
    printf 'built_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'developer=%s\n' "$(id -un)"
    printf 'workspace=%s\n' "$WORKSPACE_DIR"
    printf 'secretpad_commit=%s\n' "$backend_sha"
    printf 'secretpad_frontend_commit=%s\n' "$frontend_sha"
    printf 'secretpad_image=%s\n' "$SECRETPAD_IMAGE"
    printf 'secretpad_image_id=%s\n' "$image_id"
    printf 'sampler_image=%s\n' "$SAMPLER_IMAGE"
    printf 'sampler_image_id=%s\n' "$sampler_image_id"
    if [ "$REQUIRE_PUSHED" = true ]; then
      printf 'source_mode=pushed\n'
    else
      printf 'source_mode=working-tree\n'
    fi
    printf 'console_port=%s\n' "$CONSOLE_PORT"
    printf 'kuscia_gateway_port=%s\n' "$GATEWAY_PORT"
    printf 'advertise_host=%s\n' "$(resolve_advertise_host)"
  } >"$MANIFEST_FILE"
}

show_status() {
  printf 'Developer: %s\n' "$DEV_NAME"
  printf 'Workspace: %s\n' "$WORKSPACE_DIR"
  printf 'Runtime:   %s\n' "$DEV_ROOT"
  printf 'Console:   http://127.0.0.1:%s/edge?tab=sandbox-manager\n' "$CONSOLE_PORT"
  printf '\nContainers:\n'
  for container in "$KUSCIA_CONTAINER" "$MINIO_CONTAINER" "$SECRETPAD_CONTAINER"; do
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

require_personal_checkout
require_command docker
require_command curl
require_command realpath
require_command git
require_command openssl
require_command sha256sum

case "$COMMAND" in
  up)
    require_command sha256sum
    check_host_inotify_limits
    ensure_runtime_directories
    build_developer_image
    ensure_network
    start_kuscia
    ensure_sampler_runtime
    ensure_credentials
    start_minio
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
      minio) target="$MINIO_CONTAINER" ;;
      *) log_error "Log component must be secretpad, kuscia, or minio."; exit 1 ;;
    esac
    verify_managed_container "$target" || { log_error "Container not found: ${target}"; exit 1; }
    exec docker logs --tail 300 -f "$target"
    ;;
  restart)
    check_host_inotify_limits
    verify_managed_container "$KUSCIA_CONTAINER" || { log_error "Private Kuscia is not created."; exit 1; }
    verify_managed_container "$MINIO_CONTAINER" || { log_error "Private MinIO is not created."; exit 1; }
    verify_managed_container "$SECRETPAD_CONTAINER" || { log_error "Private SecretPad is not created."; exit 1; }
    docker restart "$KUSCIA_CONTAINER" >/dev/null
    wait_for_kuscia_dev || { log_error "Private Kuscia did not become healthy."; exit 1; }
    ensure_sampler_runtime
    docker restart "$MINIO_CONTAINER" >/dev/null
    docker restart "$SECRETPAD_CONTAINER" >/dev/null
    wait_for_secretpad "$CONSOLE_PORT" 180 || { log_error "Private SecretPad did not become healthy."; exit 1; }
    register_secretpad_service || exit 1
    log_success "Private developer system restarted."
    ;;
  down)
    if verify_managed_container "$SECRETPAD_CONTAINER"; then
      docker stop "$SECRETPAD_CONTAINER" >/dev/null
    fi
    if verify_managed_container "$MINIO_CONTAINER"; then
      docker stop "$MINIO_CONTAINER" >/dev/null
    fi
    if verify_managed_container "$KUSCIA_CONTAINER"; then
      docker stop "$KUSCIA_CONTAINER" >/dev/null
    fi
    log_success "Private developer system stopped. Runtime data was retained at ${DEV_ROOT}."
    ;;
esac
