# Data Sandbox JAR Runner 容器：Z-05 计算任务运行组件（JAR 执行，一次性 Kuscia Job）
#
# 功能：读取 Kuscia 挂载的 task_input_config（JAR 字节 base64 + 授权输入子集 + 参数），
#       写 /app/app.jar + input.csv + params.json，java -jar 执行写结果 CSV，然后常驻
#       HTTP :8000 提供 /status /result /log，平台经 scope=Cluster 端点取回后 stopJob/deleteJob 终止。
#
# Build（从 docker/ 目录，共享 runner_common.py）:
#   cd docker && docker build -f data-sandbox-jar-runner/Dockerfile -t data-sandbox-jar-runner:latest .
FROM eclipse-temurin:17-jre

COPY data-sandbox-runner-lib/runner_common.py /app/runner_common.py
COPY data-sandbox-jar-runner/jar_runner.py /app/jar_runner.py
COPY data-sandbox-jar-runner/start.sh /app/start.sh
RUN chmod +x /app/start.sh

WORKDIR /app
# AppImage 会覆盖 command；本地 docker run 默认走 start.sh
CMD ["/app/start.sh"]
