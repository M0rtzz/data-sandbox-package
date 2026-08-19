#!/bin/bash
#
# Data Sandbox Python Runner 容器入口（Z-05 计算任务运行组件 / PYTHON 执行）。
#
# 读 Kuscia 挂载的 /etc/kuscia/py-conf.json（AppImage configTemplates 渲染），
# 解码 task_input_config -> 写 guard+脚本/输入/参数 -> python 执行 -> 写结果/日志，
# 然后常驻 HTTP :8000（KUSCIA_PORT_PY_NUMBER）供平台取回结果。
#
# 用法:
#   /app/start.sh [/etc/kuscia/py-conf.json]
set -euo pipefail

CONFIG="${1:-/etc/kuscia/py-conf.json}"

if [ ! -f "${CONFIG}" ]; then
    echo "[start.sh] config not found: ${CONFIG}" >&2
    exit 1
fi

exec python3 /app/python_runner.py --config "${CONFIG}"
