ARG BASE_IMAGE=secretflow-registry.cn-hangzhou.cr.aliyuncs.com/secretflow/secretpad:0.12.0b0
FROM ${BASE_IMAGE}

ARG DEV_IMAGE=false
ARG DEV_OWNER=""
ARG DEV_WORKSPACE=""

COPY artifacts/secretpad.jar /app/secretpad.jar
COPY config/schema/center/V6__data_sandbox_mvp.sql /app/config/schema/center/V6__data_sandbox_mvp.sql
COPY config/schema/edge/V6__data_sandbox_mvp.sql /app/config/schema/edge/V6__data_sandbox_mvp.sql
COPY config/schema/p2p/V6__data_sandbox_mvp.sql /app/config/schema/p2p/V6__data_sandbox_mvp.sql

LABEL org.opencontainers.image.title="Data Sandbox MVP on SecretPad"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL io.hustnlp.data-sandbox.dev="${DEV_IMAGE}"
LABEL io.hustnlp.data-sandbox.dev-owner="${DEV_OWNER}"
LABEL io.hustnlp.data-sandbox.dev-workspace="${DEV_WORKSPACE}"
