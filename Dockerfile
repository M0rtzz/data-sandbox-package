ARG BASE_IMAGE=secretflow-registry.cn-hangzhou.cr.aliyuncs.com/secretflow/secretpad:0.12.0b0
FROM ${BASE_IMAGE}

ARG DEV_IMAGE=false
ARG DEV_OWNER=""
ARG DEV_WORKSPACE=""

COPY artifacts/secretpad.jar /app/secretpad.jar
COPY config/schema/center/ /app/config/schema/center/
COPY config/schema/edge/ /app/config/schema/edge/
COPY config/schema/p2p/ /app/config/schema/p2p/

LABEL org.opencontainers.image.title="Data Sandbox MVP on SecretPad"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL io.hustnlp.data-sandbox.dev="${DEV_IMAGE}"
LABEL io.hustnlp.data-sandbox.dev-owner="${DEV_OWNER}"
LABEL io.hustnlp.data-sandbox.dev-workspace="${DEV_WORKSPACE}"
