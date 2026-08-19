# Data Sandbox Sampler 容器：Z-04 自定义代码执行（一次性 Kuscia Job）
#
# 功能：读取 Kuscia 挂载的 task_input_config（含授权输入子集 base64 + 用户脚本），
#       执行用户脚本写结果 CSV，然后常驻 HTTP 服务 :8000 提供 /status /result /log，
#       平台经 scope=Cluster 端点取回结果后 stopJob/deleteJob 终止容器。
#
# 公共逻辑委托 runner_common.py（与 jar/python runner 共享）。
#
# Build（从 docker/ 目录，共享 runner_common.py）:
#   cd docker && docker build -f data-sandbox-sampler/Dockerfile -t data-sandbox-sampler:latest .
FROM python:3.11-slim

COPY data-sandbox-runner-lib/runner_common.py /app/runner_common.py
COPY data-sandbox-sampler/sampler_server.py /app/sampler_server.py
COPY data-sandbox-sampler/start.sh /app/start.sh
RUN chmod +x /app/start.sh

WORKDIR /app
# AppImage 会覆盖 command；本地 docker run 默认走 start.sh
CMD ["/app/start.sh"]
