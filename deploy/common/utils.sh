#!/usr/bin/env bash
#
# Copyright 2024 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "Required command not found: $1"
        exit 1
    }
}

require_container() {
    docker inspect "$1" >/dev/null 2>&1 || {
        log_error "Container not found: $1"
        exit 1
    }
}

mount_source() {
    local container=$1
    local destination=$2
    docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"${destination}"'"}}{{.Source}}{{end}}{{end}}' "$container"
}

container_network() {
    docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{break}}{{end}}' "$1"
}

wait_for_secretpad() {
    local port=$1
    local retries=${2:-60}
    local attempt=0
    while [ "$attempt" -lt "$retries" ]; do
        if curl -ksS --max-time 2 "http://127.0.0.1:${port}/api/v1alpha1/health" >/dev/null 2>&1 ||
            curl -ksS --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    return 1
}

load_env() {
    local package_dir=$1
    local env_file="${package_dir}/data-sandbox.env"
    if [ ! -f "$env_file" ]; then
        cp "${package_dir}/data-sandbox.env.example" "$env_file"
        chmod 600 "$env_file"
        log_warn "Created ${env_file}; review it before production use."
    fi
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}
