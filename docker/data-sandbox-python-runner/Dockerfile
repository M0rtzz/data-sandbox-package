# Data Sandbox Python Runner 容器：Z-05 计算任务运行组件（PYTHON 执行，一次性 Kuscia Job）
#
# 功能：读取 Kuscia 挂载的 task_input_config（用户脚本 + 授权输入子集 + 参数 + 白名单），
#       前置 import 守卫 prologue 后执行写结果 CSV，然后常驻 HTTP :8000 提供 /status /result /log，
#       平台经 scope=Cluster 端点取回后 stopJob/deleteJob 终止。
#
# 白名单机制：仅预装 numpy/pandas（与 ds_dev_dependency 预置白名单一致，新条目须同步重镜像）；
#       容器无网络（network_policy + 仅结果 Cluster 端口）、无 pip，import 守卫为兜底。
#
# Build（从 docker/ 目录，共享 runner_common.py）:
#   cd docker && docker build -f data-sandbox-python-runner/Dockerfile -t data-sandbox-python-runner:latest .
FROM python:3.11-slim

RUN pip install --no-cache-dir numpy pandas

COPY data-sandbox-runner-lib/runner_common.py /app/runner_common.py
COPY data-sandbox-python-runner/python_runner.py /app/python_runner.py
COPY data-sandbox-python-runner/start.sh /app/start.sh
RUN chmod +x /app/start.sh

WORKDIR /app
# AppImage 会覆盖 command；本地 docker run 默认走 start.sh
CMD ["/app/start.sh"]
