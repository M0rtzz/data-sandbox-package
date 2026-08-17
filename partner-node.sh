#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

# Create and operate a local P2P partner without using an all-in-one script.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${PACKAGE_DIR}/deploy/common/log.sh"
source "${PACKAGE_DIR}/deploy/common/utils.sh"
load_env "$PACKAGE_DIR"

usage() {
  cat <<'EOF'
Usage:
  ./partner-node.sh create [options]
  ./partner-node.sh resume [node-id] [-s PORT] [-w PASSWORD]
  ./partner-node.sh reset-password [node-id] [-s PORT] [-w PASSWORD]
  ./partner-node.sh status [node-id]
  ./partner-node.sh logs [node-id]
  ./partner-node.sh auth-code [node-id]
  ./partner-node.sh remove [node-id]

create options:
  -n NODE_ID        Partner node ID. Default: bob
  -s PORT           Partner console port. Default: 9088
  -p PORT           Kuscia gateway port. Default: 28080
  -k PORT           Kuscia HTTP API port. Default: 28082
  -g PORT           Kuscia gRPC API port. Default: 28083
  -q PORT           Kuscia internal service port. Default: 23081
  -x PORT           Kuscia metrics port. Default: 23084
  -P PROTOCOL       Kuscia protocol. Only mtls is supported. Default: mtls
  -b PORT           Reserved debug port. Accepted for CLI compatibility; unused.
  -d PATH           Runtime root. Must be under /nas/Misc/data-sandbox.
  -i NAME           Partner institution name. Default: DataSandbox-B
  -u USER           Partner administrator name. Default: adminb
  -w PASSWORD       Partner administrator password. Required.

resume/reset-password options:
  -s PORT           Partner console port. Default: the current port or 9088.
  -w PASSWORD       Partner administrator password. Prompted securely when omitted.

The command creates an independent Kuscia autonomy node and an independent
Data Sandbox console under DATA_SANDBOX_RUNTIME_ROOT. It never reads or runs
files from secretflow-allinone-package.
EOF
}

require_port_free() {
  local port=$1
  if docker ps --format '{{.Ports}}' | grep -Eq "(^|,| )[^,]*:${port}->"; then
    log_error "Host port ${port} is already used by a running Docker container."
    exit 1
  fi
}

node_dir() {
  local node_id=$1
  local registry="${DATA_SANDBOX_RUNTIME_ROOT}/partners/.${node_id}.runtime-root"
  if [ -f "$registry" ]; then
    local registered_root
    registered_root="$(<"$registry")"
    if [[ "$registered_root" == /nas/Misc/data-sandbox/* ]]; then
      printf '%s/partners/%s' "$registered_root" "$node_id"
      return
    fi
  fi
  printf '%s/partners/%s' "$DATA_SANDBOX_RUNTIME_ROOT" "$node_id"
}

local_node_dir() {
  printf '%s/partners/%s' "$DATA_SANDBOX_LOCAL_RUNTIME_ROOT" "$1"
}

kuscia_container() {
  printf '%s-%s' "$DATA_SANDBOX_PARTNER_KUSCIA_PREFIX" "$1"
}

secretpad_container() {
  printf '%s-%s' "$DATA_SANDBOX_PARTNER_SECRETPAD_PREFIX" "$1"
}

wait_for_kuscia() {
  local container=$1
  local attempt=0
  # A fresh K3s/containerd runtime can take over two minutes on this host.
  while [ "$attempt" -lt 240 ]; do
    if docker exec "$container" sh -lc 'test -f /home/kuscia/var/certs/domain.crt && curl -ksS --max-time 2 https://127.0.0.1:1080/healthZ >/dev/null' >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

copy_image_tree() {
  local image=$1
  local source=$2
  local destination=$3
  local temporary
  temporary="data-sandbox-init-$RANDOM-$RANDOM"
  docker create --name "$temporary" "$image" >/dev/null
  trap 'docker rm -f "$temporary" >/dev/null 2>&1 || true' RETURN
  docker cp "$temporary:${source}" "$destination"
  docker rm -f "$temporary" >/dev/null
  trap - RETURN
}

sqlite_exec() {
  local db_dir=$1
  local sql=$2
  docker run --rm --entrypoint sqlite3 -v "${db_dir}:/db" \
    "$SECRETPAD_IMAGE" /db/secretpad.sqlite "$sql"
}

sqlite_query() {
  local db_dir=$1
  local sql=$2
  docker run --rm --entrypoint sqlite3 -v "${db_dir}:/db" \
    "$SECRETPAD_IMAGE" -noheader /db/secretpad.sqlite "$sql"
}

read_admin_password() {
  local supplied=${1:-}
  local password_confirm

  ADMIN_PASSWORD="$supplied"
  if [ -z "$ADMIN_PASSWORD" ]; then
    read -r -s -p "Partner administrator password: " ADMIN_PASSWORD
    printf '\n'
    read -r -s -p "Confirm partner administrator password: " password_confirm
    printf '\n'
    [ "$ADMIN_PASSWORD" = "$password_confirm" ] || {
      log_error "Passwords do not match."
      return 1
    }
  fi
  [ "${#ADMIN_PASSWORD}" -ge 8 ] || {
    log_error "Administrator password must contain at least 8 characters."
    return 1
  }
}

update_admin_password() {
  local db_dir=$1
  local admin_user=$2
  local admin_password=$3
  local password_hash

  password_hash="$(printf '%s' "$admin_password" | sha256sum | awk '{print $1}')"
  sqlite_exec "$db_dir" "update user_accounts
    set password_hash='${password_hash}',
        failed_attempts=0,
        passwd_reset_failed_attempts=0,
        locked_invalid_time=null,
        gmt_passwd_reset_release=null,
        gmt_modified=CURRENT_TIMESTAMP
    where name='${admin_user}' and is_deleted=0;"
}

create_partner() {
  local node_id=bob
  local console_port=9088
  local gateway_port=28080
  local api_http_port=28082
  local api_grpc_port=28083
  local internal_port=23081
  local metrics_port=23084
  local institution_name=DataSandbox-B
  local admin_user=adminb
  local admin_password=
  local protocol=mtls
  local debug_port=
  local runtime_root="$DATA_SANDBOX_RUNTIME_ROOT"

  OPTIND=1
  while getopts ':n:s:p:k:g:q:x:i:u:w:P:b:d:h' option; do
    case "$option" in
      n) node_id=$OPTARG ;;
      s) console_port=$OPTARG ;;
      p) gateway_port=$OPTARG ;;
      k) api_http_port=$OPTARG ;;
      g) api_grpc_port=$OPTARG ;;
      q) internal_port=$OPTARG ;;
      x) metrics_port=$OPTARG ;;
      i) institution_name=$OPTARG ;;
      u) admin_user=$OPTARG ;;
      w) admin_password=$OPTARG ;;
      P) protocol=$OPTARG ;;
      b) debug_port=$OPTARG ;;
      d) runtime_root=$OPTARG ;;
      h) usage; return 0 ;;
      :) log_error "Option -$OPTARG needs a value."; return 1 ;;
      *) usage; return 1 ;;
    esac
  done

  [[ "$node_id" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || {
    log_error "Node ID must be a DNS subdomain."; return 1;
  }
  if [ "${#institution_name}" -lt 4 ] || [ "${#institution_name}" -gt 32 ]; then
    log_error "Institution name must contain 4 to 32 characters."
    return 1
  fi
  [[ "$admin_user" =~ ^[a-zA-Z0-9_-]{4,64}$ ]] || {
    log_error "Administrator name must contain 4 to 64 letters, digits, underscores or hyphens."; return 1;
  }
  [ "$protocol" = mtls ] || { log_error "Only mtls is supported by the local P2P test partner."; return 1; }
  [[ "$runtime_root" == /nas/Misc/data-sandbox/* ]] || {
    log_error "Partner runtime must stay below /nas/Misc/data-sandbox/."; return 1;
  }
  read_admin_password "$admin_password" || return 1
  admin_password="$ADMIN_PASSWORD"

  require_command docker
  require_command curl
  require_command sha256sum
  docker image inspect "$DATA_SANDBOX_KUSCIA_IMAGE" >/dev/null 2>&1 || {
    log_error "Kuscia image is missing: ${DATA_SANDBOX_KUSCIA_IMAGE}"; return 1;
  }
  docker image inspect "$SECRETPAD_IMAGE" >/dev/null 2>&1 || {
    log_error "Data Sandbox image is missing: ${SECRETPAD_IMAGE}. Run ./build.sh first."; return 1;
  }
  docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || {
    log_error "Docker network not found: ${DOCKER_NETWORK}"; return 1;
  }

  local kuscia_ctr secretpad_ctr root local_root config_dir data_dir log_dir image_dir k3s_dir containerd_dir pad_root pad_db_dir
  kuscia_ctr="$(kuscia_container "$node_id")"
  secretpad_ctr="$(secretpad_container "$node_id")"
  root="${runtime_root}/partners/${node_id}"
  local_root="${DATA_SANDBOX_LOCAL_RUNTIME_ROOT}/partners/${node_id}"
  config_dir="$root/kuscia"
  data_dir="$root/data"
  log_dir="$root/log"
  image_dir="$local_root/images"
  k3s_dir="$local_root/k3s"
  containerd_dir="$local_root/containerd"
  pad_root="$root/secretpad"
  pad_db_dir="$local_root/secretpad-db"

  [[ "$DATA_SANDBOX_LOCAL_RUNTIME_ROOT" == /data/xzh/Workspaces/Misc/data-sandbox/* ]] || {
    log_error "Kuscia local runtime must stay below /data/xzh/Workspaces/Misc/data-sandbox/."; return 1;
  }
  local fs_type
  fs_type="$(stat -f -c '%T' "$DATA_SANDBOX_LOCAL_RUNTIME_ROOT" 2>/dev/null || stat -f -c '%T' "$(dirname "$DATA_SANDBOX_LOCAL_RUNTIME_ROOT")")"
  case "$fs_type" in
    ext2/ext3|xfs|btrfs) ;;
    *) log_error "Kuscia local runtime requires ext4/xfs/btrfs, found ${fs_type}."; return 1 ;;
  esac

  if docker inspect "$kuscia_ctr" >/dev/null 2>&1 || docker inspect "$secretpad_ctr" >/dev/null 2>&1 || [ -e "$root" ] || [ -e "$local_root" ]; then
    log_error "Partner ${node_id} already exists. Use ./partner-node.sh status ${node_id}, or remove it explicitly first."
    return 1
  fi
  for port in "$console_port" "$gateway_port" "$api_http_port" "$api_grpc_port" "$internal_port" "$metrics_port"; do
    require_port_free "$port"
  done
  [ -z "$debug_port" ] || log_warn "Debug port ${debug_port} is accepted for compatibility but not exposed by the packaged node."

  mkdir -p "$DATA_SANDBOX_LOCAL_RUNTIME_ROOT"
  mkdir -p "$config_dir" "$data_dir" "$log_dir" "$image_dir" "$k3s_dir" "$containerd_dir" "$pad_root" "$pad_db_dir"
  mkdir -p "${DATA_SANDBOX_RUNTIME_ROOT}/partners"
  printf '%s\n' "$runtime_root" >"${DATA_SANDBOX_RUNTIME_ROOT}/partners/.${node_id}.runtime-root"
  log "Generating independent Kuscia configuration for ${node_id}"
  docker run --rm "$DATA_SANDBOX_KUSCIA_IMAGE" kuscia init \
    --mode autonomy --domain "$node_id" --protocol mtls --runtime runc >"$config_dir/kuscia.yaml"

  log "Starting Kuscia partner container ${kuscia_ctr}"
  docker run -d --init --privileged --restart always --name "$kuscia_ctr" --hostname "$kuscia_ctr" \
    --network "$DOCKER_NETWORK" \
    -p "${internal_port}:80" -p "${gateway_port}:1080" -p "${api_http_port}:8082" \
    -p "${api_grpc_port}:8083" -p "${metrics_port}:9091" \
    -v "$config_dir/kuscia.yaml:/home/kuscia/etc/conf/kuscia.yaml" \
    -v "$data_dir:/home/kuscia/var/storage/data" \
    -v "$log_dir:/home/kuscia/var/stdout" \
    -v "$image_dir:/home/kuscia/var/images" \
    -v "$k3s_dir:/home/kuscia/var/k3s/server/db" \
    -v "$containerd_dir:/home/kuscia/containerd" \
    "$DATA_SANDBOX_KUSCIA_IMAGE" bin/kuscia start -c etc/conf/kuscia.yaml >/dev/null

  if ! wait_for_kuscia "$kuscia_ctr"; then
    log_error "Kuscia did not become healthy. Inspect: docker logs ${kuscia_ctr}"
    return 1
  fi

  # Generate the Java-compatible Kuscia API client certificate without using an external script.
  docker exec "$kuscia_ctr" sh -lc '
    set -eu
    cd /home/kuscia/var/certs
    openssl genpkey -out kusciaapi-client.key -algorithm RSA -pkeyopt rsa_keygen_bits:2048
    openssl req -new -key kusciaapi-client.key -out kusciaapi-client.csr -subj "/CN=KusciaAPIClient"
    openssl x509 -req -in kusciaapi-client.csr -CA ca.crt -CAkey ca.key -days 1000 -sha256 -CAcreateserial -out kusciaapi-client.crt
  '

  log "Creating independent Data Sandbox console data for ${node_id}"
  copy_image_tree "$SECRETPAD_IMAGE" /app/config "$pad_root"
  mkdir -p "$pad_root/log" "$pad_root/data" "$pad_root/config/certs"
  docker run --rm --entrypoint /bin/sh \
    -v "$pad_db_dir:/app/db" -v "$pad_root/config:/app/config" \
    "$SECRETPAD_IMAGE" -lc '
      set -eu
      rm -f /app/db/secretpad.sqlite
      sqlite3 /app/db/secretpad.sqlite ".read /app/config/schema/p2p/V1__init.sql"
      sqlite3 /app/db/secretpad.sqlite "select 1 from user_accounts limit 1;" >/dev/null
    '
  local password_hash
  password_hash="$(printf '%s' "$admin_password" | sha256sum | awk '{print $1}')"
  sqlite_exec "$pad_db_dir" "delete from user_accounts; insert into user_accounts(name, password_hash, owner_type, owner_id, is_deleted) values ('${admin_user}', '${password_hash}', 'P2P', '${node_id}', 0);"
  docker run --rm --entrypoint /bin/sh -v "$pad_root/config:/tmp/config" "$SECRETPAD_IMAGE" -lc '
    keytool -delete -alias secretpad-server -keystore /tmp/config/server.jks \
      -keypass secretpad -storepass secretpad >/dev/null 2>&1 || true
    keytool -genkey -keystore /tmp/config/server.jks -keyalg RSA -keysize 2048 -validity 3650 \
      -keypass secretpad -storepass secretpad \
      -dname "OU=DataSandbox,O=HUSTNLP,L=Wuhan,ST=Hubei,C=CN,CN=DataSandbox" -alias secretpad-server
  ' </dev/null

  docker cp "$kuscia_ctr:/home/kuscia/var/certs/ca.crt" "$pad_root/config/certs/ca.crt"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/token" "$pad_root/config/certs/token"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/kusciaapi-client.crt" "$pad_root/config/certs/client.crt"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/kusciaapi-client.key" "$pad_root/config/certs/client.pem"

  local node_address
  node_address="${DATA_SANDBOX_PARTNER_KUSCIA_PREFIX}-${node_id}:1080"
  log "Starting Data Sandbox partner console ${secretpad_ctr}"
  docker run -d --init --restart always --name "$secretpad_ctr" --network "$DOCKER_NETWORK" \
    -p "${console_port}:8080" \
    -v "$pad_root/config:/app/config" -v "$pad_db_dir:/app/db" \
    -v "$pad_root/data:/app/data" -v "$pad_root/log:/app/log" \
    -v "${DATA_SANDBOX_SNAPSHOT_ROOT}:${DATA_SANDBOX_SNAPSHOT_ROOT}" \
    -v "${DATA_SANDBOX_BACKUP_ROOT}:${DATA_SANDBOX_BACKUP_ROOT}" \
    -e SPRING_PROFILES_ACTIVE=p2p -e NODE_ID="$node_id" -e DEPLOY_MODE=MPC \
    -e INST_NAME="$institution_name" -e KUSCIA_PROTOCOL=mtls \
    -e KUSCIA_API_ADDRESS="${kuscia_ctr}:8083" -e KUSCIA_GW_ADDRESS="${kuscia_ctr}:80" \
    -e SECRETPAD_USER_NAME="$admin_user" -e SECRETPAD_PASSWORD="$admin_password" \
    -e SECRETPAD_DATA_SANDBOX_KUSCIA_ENABLED="${DATA_SANDBOX_KUSCIA_ENABLED}" \
    -e SECRETPAD_DATA_SANDBOX_SNAPSHOT_ROOT="$DATA_SANDBOX_SNAPSHOT_ROOT" \
    -e SECRETPAD_DATA_SANDBOX_BACKUP_ROOT="$DATA_SANDBOX_BACKUP_ROOT" \
    -e SECRETPAD_DATA_SANDBOX_STATUS_SYNC_MS="${DATA_SANDBOX_STATUS_SYNC_MS:-30000}" \
    -e SPRINGDOC_API_DOCS_ENABLED=true -e SPRINGDOC_SWAGGER_UI_ENABLED=true \
    -e SPRING_WEB_RESOURCES_CACHE_CACHECONTROL_NO_STORE=true \
    "$SECRETPAD_IMAGE" >/dev/null

  if ! wait_for_secretpad "$console_port" 120; then
    log_error "Partner console did not become healthy. Inspect: docker logs ${secretpad_ctr}"
    return 1
  fi

  # P2pDataInit creates the node record at first launch. Store the Docker-network
  # endpoint before producing an authentication code, rather than the unusable 127.0.0.1 default.
  docker stop "$secretpad_ctr" >/dev/null
  sqlite_exec "$pad_db_dir" "update node set net_address='${node_address}' where node_id='${node_id}';"
  docker start "$secretpad_ctr" >/dev/null
  if ! wait_for_secretpad "$console_port" 120; then
    log_error "Partner console did not restart after its node endpoint was configured."
    return 1
  fi

  log_success "Partner ${node_id} is ready at http://127.0.0.1:${console_port}"
  log "Partner gateway address: https://${node_address}"
  log "Run ./partner-node.sh auth-code ${node_id} and paste the output into Alice -> 合作节点 -> 添加合作节点."
}

resume_partner() {
  local node_id=bob
  local console_port=9088
  local admin_password=
  local institution_name=
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    node_id=$1
    shift
  fi
  # Preserve the previously supported, although undocumented, positional port.
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    console_port=$1
    shift
  fi
  OPTIND=1
  while getopts ':s:w:i:h' option; do
    case "$option" in
      s) console_port=$OPTARG ;;
      w) admin_password=$OPTARG ;;
      i) institution_name=$OPTARG ;;
      h) usage; return 0 ;;
      :) log_error "Option -$OPTARG needs a value."; return 1 ;;
      *) usage; return 1 ;;
    esac
  done

  local kuscia_ctr secretpad_ctr root local_root pad_root pad_db_dir admin_user node_address
  kuscia_ctr="$(kuscia_container "$node_id")"
  secretpad_ctr="$(secretpad_container "$node_id")"
  root="$(node_dir "$node_id")"
  local_root="$(local_node_dir "$node_id")"
  pad_root="$root/secretpad"
  pad_db_dir="$local_root/secretpad-db"
  node_address="${DATA_SANDBOX_PARTNER_KUSCIA_PREFIX}-${node_id}:1080"

  require_container "$kuscia_ctr"
  [ -f "$pad_root/config/server.jks" ] || { log_error "Partner configuration is incomplete: ${pad_root}/config"; return 1; }
  [ -f "$pad_db_dir/secretpad.sqlite" ] || { log_error "Partner database is incomplete: ${pad_db_dir}"; return 1; }
  if docker inspect "$secretpad_ctr" >/dev/null 2>&1; then
    log_error "Partner console container already exists: ${secretpad_ctr}"
    return 1
  fi
  admin_user="$(sqlite_query "$pad_db_dir" "select name from user_accounts where is_deleted=0 order by id limit 1;")"
  [ -n "$admin_user" ] || { log_error "Partner administrator record is missing."; return 1; }
  if [ -z "$institution_name" ]; then
    institution_name="$(sqlite_query "$pad_db_dir" "select name from inst where is_deleted=0 order by id limit 1;")"
  fi
  [ -n "$institution_name" ] || institution_name=DataSandbox-B
  read_admin_password "$admin_password" || return 1
  admin_password="$ADMIN_PASSWORD"
  update_admin_password "$pad_db_dir" "$admin_user" "$admin_password"

  mkdir -p "$pad_root/config/certs" "$pad_root/data" "$pad_root/log"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/ca.crt" "$pad_root/config/certs/ca.crt"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/token" "$pad_root/config/certs/token"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/kusciaapi-client.crt" "$pad_root/config/certs/client.crt"
  docker cp "$kuscia_ctr:/home/kuscia/var/certs/kusciaapi-client.key" "$pad_root/config/certs/client.pem"

  log "Resuming Data Sandbox partner console ${secretpad_ctr}"
  docker run -d --init --restart always --name "$secretpad_ctr" --network "$DOCKER_NETWORK" \
    -p "${console_port}:8080" \
    -v "$pad_root/config:/app/config" -v "$pad_db_dir:/app/db" \
    -v "$pad_root/data:/app/data" -v "$pad_root/log:/app/log" \
    -v "${DATA_SANDBOX_SNAPSHOT_ROOT}:${DATA_SANDBOX_SNAPSHOT_ROOT}" \
    -v "${DATA_SANDBOX_BACKUP_ROOT}:${DATA_SANDBOX_BACKUP_ROOT}" \
    -e SPRING_PROFILES_ACTIVE=p2p -e NODE_ID="$node_id" -e DEPLOY_MODE=MPC \
    -e INST_NAME="$institution_name" -e KUSCIA_PROTOCOL=mtls \
    -e KUSCIA_API_ADDRESS="${kuscia_ctr}:8083" -e KUSCIA_GW_ADDRESS="${kuscia_ctr}:80" \
    -e SECRETPAD_USER_NAME="$admin_user" -e SECRETPAD_PASSWORD="$admin_password" \
    -e SECRETPAD_DATA_SANDBOX_KUSCIA_ENABLED="${DATA_SANDBOX_KUSCIA_ENABLED}" \
    -e SECRETPAD_DATA_SANDBOX_SNAPSHOT_ROOT="$DATA_SANDBOX_SNAPSHOT_ROOT" \
    -e SECRETPAD_DATA_SANDBOX_BACKUP_ROOT="$DATA_SANDBOX_BACKUP_ROOT" \
    -e SECRETPAD_DATA_SANDBOX_STATUS_SYNC_MS="${DATA_SANDBOX_STATUS_SYNC_MS:-30000}" \
    -e SPRINGDOC_API_DOCS_ENABLED=true -e SPRINGDOC_SWAGGER_UI_ENABLED=true \
    -e SPRING_WEB_RESOURCES_CACHE_CACHECONTROL_NO_STORE=true \
    "$SECRETPAD_IMAGE" >/dev/null

  if ! wait_for_secretpad "$console_port" 180; then
    log_error "Partner console did not become healthy. Inspect: docker logs ${secretpad_ctr}"
    return 1
  fi
  docker stop "$secretpad_ctr" >/dev/null
  sqlite_exec "$pad_db_dir" "update node set net_address='${node_address}' where node_id='${node_id}';"
  docker start "$secretpad_ctr" >/dev/null
  if ! wait_for_secretpad "$console_port" 180; then
    log_error "Partner console did not restart after its node endpoint was configured."
    return 1
  fi
  log_success "Partner ${node_id} is ready at http://127.0.0.1:${console_port}"
}

reset_partner_password() {
  local node_id=bob
  local console_port=
  local admin_password=
  local institution_name=
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    node_id=$1
    shift
  fi
  OPTIND=1
  while getopts ':s:w:h' option; do
    case "$option" in
      s) console_port=$OPTARG ;;
      w) admin_password=$OPTARG ;;
      h) usage; return 0 ;;
      :) log_error "Option -$OPTARG needs a value."; return 1 ;;
      *) usage; return 1 ;;
    esac
  done

  local secretpad_ctr
  secretpad_ctr="$(secretpad_container "$node_id")"
  if docker inspect "$secretpad_ctr" >/dev/null 2>&1; then
    if [ -z "$console_port" ]; then
      console_port="$(docker inspect --format '{{with (index .HostConfig.PortBindings "8080/tcp")}}{{(index . 0).HostPort}}{{end}}' "$secretpad_ctr")"
    fi
    institution_name="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$secretpad_ctr" | sed -n 's/^INST_NAME=//p' | head -n 1)"
  fi
  [ -n "$console_port" ] || console_port=9088

  read_admin_password "$admin_password" || return 1
  admin_password="$ADMIN_PASSWORD"

  if docker inspect "$secretpad_ctr" >/dev/null 2>&1; then
    log "Recreating Data Sandbox partner console ${secretpad_ctr}"
    docker rm -f "$secretpad_ctr" >/dev/null
  fi
  resume_partner "$node_id" -s "$console_port" -w "$admin_password" -i "$institution_name"
  log_success "Password for partner ${node_id} has been reset."
}

show_status() {
  local node_id=${1:-bob}
  docker ps -a --filter "name=^/$(kuscia_container "$node_id")$" --filter "name=^/$(secretpad_container "$node_id")$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
}

show_logs() {
  local node_id=${1:-bob}
  docker logs --tail 300 -f "$(secretpad_container "$node_id")"
}

show_auth_code() {
  local node_id=${1:-bob}
  local db_file
  require_command jq
  db_file="$(local_node_dir "$node_id")/secretpad-db/secretpad.sqlite"
  [ -f "$db_file" ] || { log_error "Partner ${node_id} has not been created."; return 1; }
  local node_name address master inst_id institution_name cert_text json
  IFS='|' read -r _ node_name address master inst_id < <(sqlite_query "$(dirname "$db_file")" "select node_id, name, net_address, master_node_id, inst_id from node where node_id='${node_id}' and is_deleted=0;")
  [ -n "${node_name:-}" ] || { log_error "Partner node record is not ready."; return 1; }
  institution_name="$(sqlite_query "$(dirname "$db_file")" "select name from inst where inst_id='${inst_id}' and is_deleted=0 limit 1;")"
  # Kuscia CreateDomain expects cert to be a Base64-encoded PEM certificate.
  # Read the canonical value from the local Domain resource instead of
  # re-encoding the certificate file in the packaging script.
  cert_text="$(docker exec "$(kuscia_container "$node_id")" \
    kubectl get domain "$node_id" -o jsonpath='{.spec.cert}')"
  [ -n "$cert_text" ] || {
    log_error "Partner ${node_id} domain certificate is missing."
    return 1
  }
  json="$(jq -cn \
    --arg masterNodeId "$master" \
    --arg dstNodeId "$node_id" \
    --arg name "$node_name" \
    --arg dstNetAddress "https://${address}" \
    --arg certText "$cert_text" \
    --arg instId "$inst_id" \
    --arg instName "$institution_name" \
    '{masterNodeId: $masterNodeId, dstNodeId: $dstNodeId, name: $name,
      dstNetAddress: $dstNetAddress, certText: $certText,
      instId: $instId, instName: $instName}')"
  printf '%s' "$json" | base64 -w 0
  printf '\n'
}

remove_partner() {
  local node_id=${1:-bob}
  local root
  root="$(node_dir "$node_id")"
  docker rm -f "$(secretpad_container "$node_id")" "$(kuscia_container "$node_id")" >/dev/null 2>&1 || true
  log_warn "Containers for ${node_id} were removed. Business files remain at ${root}; local runtime files remain at ${DATA_SANDBOX_LOCAL_RUNTIME_ROOT}/partners/${node_id}."
}

command=${1:-}
case "$command" in
  create) shift; create_partner "$@" ;;
  resume) shift; resume_partner "$@" ;;
  reset-password) shift; reset_partner_password "$@" ;;
  status) shift; show_status "$@" ;;
  logs) shift; show_logs "$@" ;;
  auth-code) shift; show_auth_code "$@" ;;
  remove) shift; remove_partner "$@" ;;
  -h|--help|help|'') usage ;;
  *) log_error "Unknown command: ${command}"; usage; exit 1 ;;
esac
