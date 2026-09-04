#!/usr/bin/env bash
# Copyright 2026 Ant Group Co., Ltd.
# Licensed under the Apache License, Version 2.0.

# Manage one local Hugging Face model through vLLM's OpenAI-compatible API.
set -Eeuo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${HF_OPENAI_RUNTIME_DIR:-${PACKAGE_DIR}/.dev-runtime/hf-openai}"
VLLM_RUNTIME_DIR="${HF_OPENAI_VLLM_RUNTIME_DIR:-${PACKAGE_DIR}/.dev-runtime/vllm-runtime}"
PID_FILE="${RUNTIME_DIR}/server.pid"
START_TICKS_FILE="${RUNTIME_DIR}/server.start-ticks"
LOG_FILE="${RUNTIME_DIR}/server.log"
STATE_FILE="${RUNTIME_DIR}/server.state"

COMMAND="${1:-help}"
if [ "$#" -gt 0 ]; then
  shift
fi

MODEL_PATH="${HF_OPENAI_MODEL_PATH:-/nas/Models/deepseek-llm-7b-chat}"
SERVED_MODEL_NAME=""
HOST="127.0.0.1"
PORT="39089"
GPUS="${CUDA_VISIBLE_DEVICES:-0}"
TENSOR_PARALLEL_SIZE=""
MAX_MODEL_LEN="4096"
GPU_MEMORY_UTILIZATION="0.90"
DTYPE="auto"
QUANTIZATION=""
CHAT_TEMPLATE=""
API_KEY_FILE=""
STARTUP_TIMEOUT="1800"
TRUST_REMOTE_CODE=false
ENABLE_PREFIX_CACHING=true
TEST_MESSAGE="你好，请简短介绍你自己。"
VLLM_EXTRA_ARGS=()
VLLM_COMMAND=()
VLLM_PYTHON=""

usage() {
  cat <<'EOF'
Usage:
  ./serve-hf-model.sh prepare
  ./serve-hf-model.sh start [options]
  ./serve-hf-model.sh status
  ./serve-hf-model.sh test [--message TEXT]
  ./serve-hf-model.sh logs
  ./serve-hf-model.sh stop

Start options:
  --model PATH                 Local Hugging Face model directory.
                               Default: /nas/Models/deepseek-llm-7b-chat.
  --served-model-name NAME     Model name accepted by the OpenAI API.
                               Default: model directory basename.
  --host HOST                  Listen address. Default: 127.0.0.1.
  --port PORT                  Listen port. Default: 39089.
  --cuda-visible-devices LIST  Set CUDA_VISIBLE_DEVICES for vLLM, for example
                               0 or 0,1,2,3. Default: current environment or 0.
  --gpus LIST                  Alias for --cuda-visible-devices.
  --tensor-parallel-size N     Default: number of visible CUDA devices.
  --max-model-len N            Maximum context length. Default: 4096.
  --gpu-memory-utilization N   Per-GPU utilization in (0, 1]. Default: 0.90.
  --dtype TYPE                 auto, half, float16, bfloat16, or float32.
                               Default: auto.
  --quantization TYPE          Optional vLLM quantization mode, such as awq or gptq.
  --chat-template PATH         Optional local Jinja chat template.
  --api-key-file PATH          Optional one-line bearer token file (must not be
                               group/world accessible).
  --startup-timeout SECONDS    Wait for /health. Default: 1800.
  --trust-remote-code          Allow custom code from the local model directory.
  --no-prefix-caching          Disable vLLM prefix caching.
  --vllm-arg ARG               Append one advanced vLLM argument; repeat as needed.

The API endpoints are:
  GET  /v1/models
  POST /v1/chat/completions

For the confidential-mvp CipherGPU container, bind to 0.0.0.0 and then set:
  DATA_SANDBOX_DEV_VLLM_URL=http://host.docker.internal:39089/v1

Do not expose an unauthenticated vLLM port to an untrusted network. The platform's
encrypted inference endpoint should remain the customer-facing API.
EOF
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[INFO] %s\n' "$*"
}

success() {
  printf '[SUCCESS] %s\n' "$*"
}

require_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    fail "Missing value for $1"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) require_value "$@"; MODEL_PATH="$2"; shift 2 ;;
    --served-model-name) require_value "$@"; SERVED_MODEL_NAME="$2"; shift 2 ;;
    --host) require_value "$@"; HOST="$2"; shift 2 ;;
    --port) require_value "$@"; PORT="$2"; shift 2 ;;
    --cuda-visible-devices|--gpus) require_value "$@"; GPUS="$2"; shift 2 ;;
    --tensor-parallel-size) require_value "$@"; TENSOR_PARALLEL_SIZE="$2"; shift 2 ;;
    --max-model-len) require_value "$@"; MAX_MODEL_LEN="$2"; shift 2 ;;
    --gpu-memory-utilization) require_value "$@"; GPU_MEMORY_UTILIZATION="$2"; shift 2 ;;
    --dtype) require_value "$@"; DTYPE="$2"; shift 2 ;;
    --quantization) require_value "$@"; QUANTIZATION="$2"; shift 2 ;;
    --chat-template) require_value "$@"; CHAT_TEMPLATE="$2"; shift 2 ;;
    --api-key-file) require_value "$@"; API_KEY_FILE="$2"; shift 2 ;;
    --startup-timeout) require_value "$@"; STARTUP_TIMEOUT="$2"; shift 2 ;;
    --message) require_value "$@"; TEST_MESSAGE="$2"; shift 2 ;;
    --trust-remote-code) TRUST_REMOTE_CODE=true; shift ;;
    --no-prefix-caching) ENABLE_PREFIX_CACHING=false; shift ;;
    --vllm-arg) require_value "$@"; VLLM_EXTRA_ARGS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

read_state() {
  local key=$1
  [ -f "$STATE_FILE" ] || return 1
  sed -n "s/^${key}=//p" "$STATE_FILE" | head -n 1
}

process_start_ticks() {
  local pid=$1
  [ -r "/proc/${pid}/stat" ] || return 1
  awk '{print $22}' "/proc/${pid}/stat"
}

managed_pid() {
  local pid expected actual
  [ -s "$PID_FILE" ] && [ -s "$START_TICKS_FILE" ] || return 1
  pid="$(<"$PID_FILE")"
  expected="$(<"$START_TICKS_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  actual="$(process_start_ticks "$pid" 2>/dev/null || true)"
  [ -n "$actual" ] && [ "$actual" = "$expected" ] || return 1
  printf '%s\n' "$pid"
}

local_api_host() {
  local configured=$1
  case "$configured" in
    0.0.0.0|"::"|"[::]") printf '127.0.0.1\n' ;;
    *) printf '%s\n' "$configured" ;;
  esac
}

authorization_args() {
  local api_key_file=${1:-} api_key
  if [ -n "$api_key_file" ]; then
    api_key="$(tr -d '\r\n' < "$api_key_file")"
    [ -n "$api_key" ] || fail "API key file is empty: $api_key_file"
    printf '%s\n' "Authorization: Bearer ${api_key}"
  fi
}

health_check() {
  local host=$1 port=$2
  curl -fsS --max-time 3 "http://${host}:${port}/health" >/dev/null 2>&1
}

prepare_runtime() {
  command -v uv >/dev/null 2>&1 || fail "uv is required to prepare the isolated vLLM runtime"
  local base_python=${HF_OPENAI_BASE_PYTHON:-python3}
  command -v "$base_python" >/dev/null 2>&1 || fail "Python is unavailable: $base_python"
  mkdir -p "$(dirname "$VLLM_RUNTIME_DIR")"
  info "Preparing an isolated Transformers 4 runtime at $VLLM_RUNTIME_DIR"
  uv venv --clear --system-site-packages --python "$base_python" "$VLLM_RUNTIME_DIR"
  uv pip install --no-deps --python "${VLLM_RUNTIME_DIR}/bin/python" \
    'transformers==4.55.4' 'tokenizers==0.21.4' 'huggingface-hub==0.36.2' \
    'setuptools>=77.0.3,<80'
  "${VLLM_RUNTIME_DIR}/bin/python" - <<'PY'
import tokenizers
import transformers
import vllm
print(f"vLLM={vllm.__version__}")
print(f"Transformers={transformers.__version__}")
print(f"Tokenizers={tokenizers.__version__}")
PY
  success "Isolated vLLM runtime is ready"
}

resolve_vllm_command() {
  if [ -n "${VLLM_BIN:-}" ]; then
    command -v "$VLLM_BIN" >/dev/null 2>&1 || fail "vLLM executable is unavailable: $VLLM_BIN"
    VLLM_COMMAND=("$VLLM_BIN")
    return
  fi
  if [ -x "${VLLM_RUNTIME_DIR}/bin/python" ]; then
    VLLM_PYTHON="${VLLM_RUNTIME_DIR}/bin/python"
    VLLM_COMMAND=("$VLLM_PYTHON" -m vllm.entrypoints.cli.main)
  else
    command -v vllm >/dev/null 2>&1 \
      || fail "vLLM is not installed; install it or run $0 prepare"
    VLLM_COMMAND=("$(command -v vllm)")
    VLLM_PYTHON="${HF_OPENAI_BASE_PYTHON:-python3}"
  fi

  local versions transformers_major
  versions="$("$VLLM_PYTHON" - <<'PY'
import transformers
import vllm
print(f"{vllm.__version__}|{transformers.__version__}")
PY
)" || fail "The selected Python environment cannot import vLLM and Transformers"
  transformers_major="${versions#*|}"
  transformers_major="${transformers_major%%.*}"
  if [ "$transformers_major" -ge 5 ]; then
    fail "Incompatible runtime vLLM=${versions%%|*}, Transformers=${versions#*|}; run $0 prepare"
  fi
}

validate_start_options() {
  [ -n "$MODEL_PATH" ] || fail "Model path is empty"
  [ -d "$MODEL_PATH" ] || fail "Model directory does not exist: $MODEL_PATH"
  MODEL_PATH="$(realpath "$MODEL_PATH")"
  [ -r "${MODEL_PATH}/config.json" ] || fail "Hugging Face config.json is missing or unreadable"
  [ -n "$SERVED_MODEL_NAME" ] || SERVED_MODEL_NAME="$(basename "$MODEL_PATH")"
  [[ "$SERVED_MODEL_NAME" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Invalid served model name"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    fail "Port must be between 1024 and 65535"
  fi
  [[ "$MAX_MODEL_LEN" =~ ^[1-9][0-9]*$ ]] || fail "--max-model-len must be positive"
  [[ "$STARTUP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "--startup-timeout must be positive"
  [[ "$GPUS" =~ ^[0-9]+(,[0-9]+)*$ ]] \
    || fail "--cuda-visible-devices must look like 0 or 0,1,2,3"

  local gpu_count
  gpu_count="$(awk -F, '{print NF}' <<<"$GPUS")"
  [ -n "$TENSOR_PARALLEL_SIZE" ] || TENSOR_PARALLEL_SIZE="$gpu_count"
  [[ "$TENSOR_PARALLEL_SIZE" =~ ^[1-9][0-9]*$ ]] \
    || fail "--tensor-parallel-size must be positive"
  [ "$TENSOR_PARALLEL_SIZE" -le "$gpu_count" ] \
    || fail "Tensor parallel size exceeds the number of selected GPUs"

  python3 - "$GPU_MEMORY_UTILIZATION" <<'PY' || fail "--gpu-memory-utilization must be in (0, 1]"
import sys
value = float(sys.argv[1])
raise SystemExit(0 if 0 < value <= 1 else 1)
PY

  resolve_vllm_command
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi is required"

  local gpu
  IFS=',' read -r -a selected_gpus <<<"$GPUS"
  for gpu in "${selected_gpus[@]}"; do
    nvidia-smi -i "$gpu" --query-gpu=name --format=csv,noheader >/dev/null 2>&1 \
      || fail "GPU $gpu is unavailable"
  done

  if [ -n "$CHAT_TEMPLATE" ]; then
    [ -r "$CHAT_TEMPLATE" ] || fail "Chat template is unreadable: $CHAT_TEMPLATE"
    CHAT_TEMPLATE="$(realpath "$CHAT_TEMPLATE")"
  fi
  if [ -n "$API_KEY_FILE" ]; then
    if [ ! -f "$API_KEY_FILE" ] || [ ! -r "$API_KEY_FILE" ]; then
      fail "API key file is unreadable: $API_KEY_FILE"
    fi
    API_KEY_FILE="$(realpath "$API_KEY_FILE")"
    local mode
    mode="$(stat -c '%a' "$API_KEY_FILE")"
    [ $((8#$mode & 077)) -eq 0 ] \
      || fail "API key file must not be accessible by group or other users (use chmod 600)"
  fi
}

start_server() {
  validate_start_options
  if pid="$(managed_pid 2>/dev/null)"; then
    fail "vLLM is already running with PID $pid; stop it first"
  fi
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"

  local check_host
  check_host="$(local_api_host "$HOST")"
  if health_check "$check_host" "$PORT"; then
    fail "An HTTP service is already listening on ${HOST}:${PORT}"
  fi
  if command -v ss >/dev/null 2>&1 && ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$PORT$"; then
    fail "TCP port $PORT is already in use"
  fi

  local -a command
  command=(
    "${VLLM_COMMAND[@]}" serve "$MODEL_PATH"
    --served-model-name "$SERVED_MODEL_NAME"
    --host "$HOST"
    --port "$PORT"
    --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"
    --max-model-len "$MAX_MODEL_LEN"
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
    --dtype "$DTYPE"
    --disable-uvicorn-access-log
  )
  $ENABLE_PREFIX_CACHING && command+=(--enable-prefix-caching)
  $TRUST_REMOTE_CODE && command+=(--trust-remote-code)
  [ -z "$QUANTIZATION" ] || command+=(--quantization "$QUANTIZATION")
  [ -z "$CHAT_TEMPLATE" ] || command+=(--chat-template "$CHAT_TEMPLATE")
  command+=("${VLLM_EXTRA_ARGS[@]}")

  local api_key=""
  if [ -n "$API_KEY_FILE" ]; then
    api_key="$(tr -d '\r\n' < "$API_KEY_FILE")"
    [ -n "$api_key" ] || fail "API key file is empty"
  fi

  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  info "Starting ${SERVED_MODEL_NAME} from ${MODEL_PATH} on GPU(s) ${GPUS}"
  if [ -n "$api_key" ]; then
    nohup env CUDA_VISIBLE_DEVICES="$GPUS" VLLM_API_KEY="$api_key" \
      setsid "${command[@]}" >>"$LOG_FILE" 2>&1 </dev/null &
  else
    nohup env CUDA_VISIBLE_DEVICES="$GPUS" \
      setsid "${command[@]}" >>"$LOG_FILE" 2>&1 </dev/null &
  fi
  local pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  process_start_ticks "$pid" > "$START_TICKS_FILE"
  chmod 600 "$PID_FILE" "$START_TICKS_FILE"
  {
    printf 'model_path=%s\n' "$MODEL_PATH"
    printf 'served_model_name=%s\n' "$SERVED_MODEL_NAME"
    printf 'host=%s\n' "$HOST"
    printf 'port=%s\n' "$PORT"
    printf 'gpus=%s\n' "$GPUS"
    printf 'tensor_parallel_size=%s\n' "$TENSOR_PARALLEL_SIZE"
    printf 'api_key_file=%s\n' "$API_KEY_FILE"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"

  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! managed_pid >/dev/null 2>&1; then
      tail -n 80 "$LOG_FILE" >&2 || true
      fail "vLLM exited before becoming healthy; see $LOG_FILE"
    fi
    if health_check "$check_host" "$PORT"; then
      success "OpenAI-compatible API is ready: http://${check_host}:${PORT}/v1"
      printf 'Model: %s\n' "$SERVED_MODEL_NAME"
      printf 'Chat:  POST http://%s:%s/v1/chat/completions\n' "$check_host" "$PORT"
      if [ "$HOST" != "127.0.0.1" ] && [ "$HOST" != "localhost" ]; then
        printf 'CipherGPU: export DATA_SANDBOX_DEV_VLLM_URL=http://host.docker.internal:%s/v1\n' "$PORT"
      fi
      return 0
    fi
    sleep 2
  done
  fail "Startup timed out after ${STARTUP_TIMEOUT}s; process is still running, inspect: $0 logs"
}

show_status() {
  local pid host port model gpus
  if ! pid="$(managed_pid 2>/dev/null)"; then
    printf 'Status: stopped\n'
    return 1
  fi
  host="$(read_state host)"
  port="$(read_state port)"
  model="$(read_state served_model_name)"
  gpus="$(read_state gpus)"
  printf 'Status: running\nPID:    %s\nModel:  %s\nGPUs:   %s\nAPI:    http://%s:%s/v1\nLog:    %s\n' \
    "$pid" "$model" "$gpus" "$(local_api_host "$host")" "$port" "$LOG_FILE"
}

stop_server() {
  local pid deadline
  if ! pid="$(managed_pid 2>/dev/null)"; then
    info "vLLM is not running"
    return 0
  fi
  info "Stopping vLLM process group $pid"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  deadline=$((SECONDS + 60))
  while managed_pid >/dev/null 2>&1 && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
  done
  if managed_pid >/dev/null 2>&1; then
    fail "vLLM did not stop within 60 seconds; inspect PID $pid"
  fi
  rm -f "$PID_FILE" "$START_TICKS_FILE"
  success "vLLM stopped"
}

test_server() {
  local host port model api_key_file payload response_file http_code
  managed_pid >/dev/null 2>&1 || fail "vLLM is not running"
  host="$(local_api_host "$(read_state host)")"
  port="$(read_state port)"
  model="$(read_state served_model_name)"
  api_key_file="$(read_state api_key_file 2>/dev/null || true)"
  payload="$(python3 - "$model" "$TEST_MESSAGE" <<'PY'
import json
import sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "temperature": 0.2,
    "max_tokens": 128,
}, ensure_ascii=False))
PY
)"
  response_file="$(mktemp)"
  trap 'rm -f "$response_file"' RETURN
  local -a curl_args=(
    -sS --max-time 180 -o "$response_file" -w '%{http_code}'
    -H 'Content-Type: application/json'
  )
  if [ -n "$api_key_file" ]; then
    curl_args+=(-H "$(authorization_args "$api_key_file")")
  fi
  http_code="$(curl "${curl_args[@]}" -d "$payload" \
    "http://${host}:${port}/v1/chat/completions")"
  cat "$response_file"
  printf '\n'
  [[ "$http_code" =~ ^2 ]] || fail "Chat request failed with HTTP $http_code"
}

case "$COMMAND" in
  prepare) prepare_runtime ;;
  start) start_server ;;
  status) show_status ;;
  test) test_server ;;
  logs)
    [ -f "$LOG_FILE" ] || fail "Log file does not exist"
    tail -n 200 -f "$LOG_FILE"
    ;;
  stop) stop_server ;;
  help|-h|--help) usage ;;
  *) fail "Unknown command: $COMMAND" ;;
esac
