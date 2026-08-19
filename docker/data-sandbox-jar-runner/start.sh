#!/bin/bash
#
# Data Sandbox JAR Runner 容器入口（Z-05 计算任务运行组件 / JAR 执行）。
#
# 读 Kuscia 挂载的 /etc/kuscia/jar-conf.json（AppImage configTemplates 渲染），
# 解码 task_input_config -> 写 app.jar/输入/参数 -> java -jar 执行 -> 写结果/日志，
# 然后常驻 HTTP :8000（KUSCIA_PORT_JAR_NUMBER）供平台取回结果。
#
# 用法:
#   /app/start.sh [/etc/kuscia/jar-conf.json]
set -euo pipefail

CONFIG="${1:-/etc/kuscia/jar-conf.json}"

if [ ! -f "${CONFIG}" ]; then
    echo "[start.sh] config not found: ${CONFIG}" >&2
    exit 1
fi

exec python3 /app/jar_runner.py --config "${CONFIG}"
