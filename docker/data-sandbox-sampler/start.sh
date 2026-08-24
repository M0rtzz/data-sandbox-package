#!/bin/bash
#
# Data Sandbox Sampler 容器入口（Z-04 自定义代码执行）。
#
# 读 Kuscia 挂载的 /etc/kuscia/sampler-conf.json（AppImage configTemplates 渲染），
# 解码 task_input_config → 写输入/脚本/参数 → 执行用户脚本 → 写结果/日志，
# 然后常驻 HTTP :8000（KUSCIA_PORT_SAMPLER_NUMBER）供平台取回结果。
#
# 用法:
#   /app/start.sh [/etc/kuscia/sampler-conf.json]
set -euo pipefail

CONFIG="${1:-/etc/kuscia/sampler-conf.json}"

if [ ! -f "${CONFIG}" ]; then
    echo "[start.sh] config not found: ${CONFIG}" >&2
    exit 1
fi

exec python3 /app/sampler_server.py --config "${CONFIG}"
