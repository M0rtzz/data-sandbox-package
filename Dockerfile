ARG BASE_IMAGE=secretflow-registry.cn-hangzhou.cr.aliyuncs.com/secretflow/secretpad:0.12.0b0
FROM ${BASE_IMAGE}

ARG DEV_IMAGE=false
ARG DEV_OWNER=""
ARG DEV_WORKSPACE=""

COPY artifacts/secretpad.jar /app/secretpad.jar
COPY config/schema/center/V6__data_sandbox_mvp.sql /app/config/schema/center/V6__data_sandbox_mvp.sql
COPY config/schema/edge/V6__data_sandbox_mvp.sql /app/config/schema/edge/V6__data_sandbox_mvp.sql
COPY config/schema/p2p/V6__data_sandbox_mvp.sql /app/config/schema/p2p/V6__data_sandbox_mvp.sql
COPY config/schema/center/V7__data_sandbox_runtime.sql /app/config/schema/center/V7__data_sandbox_runtime.sql
COPY config/schema/edge/V7__data_sandbox_runtime.sql /app/config/schema/edge/V7__data_sandbox_runtime.sql
COPY config/schema/p2p/V7__data_sandbox_runtime.sql /app/config/schema/p2p/V7__data_sandbox_runtime.sql
COPY config/schema/center/V8__data_sandbox_resource.sql /app/config/schema/center/V8__data_sandbox_resource.sql
COPY config/schema/edge/V8__data_sandbox_resource.sql /app/config/schema/edge/V8__data_sandbox_resource.sql
COPY config/schema/p2p/V8__data_sandbox_resource.sql /app/config/schema/p2p/V8__data_sandbox_resource.sql
COPY config/schema/center/V9__data_sandbox_alerts.sql /app/config/schema/center/V9__data_sandbox_alerts.sql
COPY config/schema/edge/V9__data_sandbox_alerts.sql /app/config/schema/edge/V9__data_sandbox_alerts.sql
COPY config/schema/p2p/V9__data_sandbox_alerts.sql /app/config/schema/p2p/V9__data_sandbox_alerts.sql
# Z-03：沙箱资源申请与审批
COPY config/schema/center/V10__sandbox_approval.sql /app/config/schema/center/V10__sandbox_approval.sql
COPY config/schema/edge/V10__sandbox_approval.sql /app/config/schema/edge/V10__sandbox_approval.sql
COPY config/schema/p2p/V10__sandbox_approval.sql /app/config/schema/p2p/V10__sandbox_approval.sql
# Z-04：数据抽样与脱敏服务
COPY config/schema/center/V11__data_governance.sql /app/config/schema/center/V11__data_governance.sql
COPY config/schema/edge/V11__data_governance.sql /app/config/schema/edge/V11__data_governance.sql
COPY config/schema/p2p/V11__data_governance.sql /app/config/schema/p2p/V11__data_governance.sql
# Z-05：计算任务开发能力（制品/版本/任务/依赖/调试日志）
COPY config/schema/center/V12__data_dev.sql /app/config/schema/center/V12__data_dev.sql
COPY config/schema/edge/V12__data_dev.sql /app/config/schema/edge/V12__data_dev.sql
COPY config/schema/p2p/V12__data_dev.sql /app/config/schema/p2p/V12__data_dev.sql

LABEL org.opencontainers.image.title="Data Sandbox MVP on SecretPad"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL io.hustnlp.data-sandbox.dev="${DEV_IMAGE}"
LABEL io.hustnlp.data-sandbox.dev-owner="${DEV_OWNER}"
LABEL io.hustnlp.data-sandbox.dev-workspace="${DEV_WORKSPACE}"
