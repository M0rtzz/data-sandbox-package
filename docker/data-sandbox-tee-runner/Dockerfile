# P5 trusted runtime: cryptographic wrapper plus the recovered sandbox runtimes.
FROM eclipse-temurin:17-jre AS jar-runtime

FROM python@sha256:9c900dea9e8fb7e16277c179b555cc72d29a352dbc33cff48ad5a0412fd5bfc7

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 65532 teeexec \
    && useradd --no-create-home --uid 65532 --gid 65532 --shell /usr/sbin/nologin teeexec

COPY --from=jar-runtime /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"
ENV PYTHONDONTWRITEBYTECODE=1
ENV TEE_EXEC_UID=65532
ENV TEE_EXEC_GID=65532

RUN pip install --no-cache-dir \
    cryptography==50.0.1 \
    numpy==2.4.6 \
    pandas==3.0.5 \
    scipy==1.17.1 \
    scikit-learn==1.9.0 \
    joblib==1.5.3 \
    xgboost==3.2.0 \
    lightgbm==4.7.0

COPY data-sandbox-python-runner/modeling_ops.py /opt/data-sandbox/modeling_ops.py
COPY data-sandbox-tee-runner/runtime_main.py \
     data-sandbox-tee-runner/tee_execution.py \
     data-sandbox-tee-runner/tee_contract_runtime.py \
     data-sandbox-tee-runner/tee_api_client.py \
     data-sandbox-tee-runner/tee_evaluation_report.py \
     data-sandbox-tee-runner/tee_tree_report.py \
     data-sandbox-tee-runner/tee_tree_report_cli.py \
     data-sandbox-tee-runner/tee_tree_report_validation.py /app/

RUN chmod 0555 /opt/data-sandbox/modeling_ops.py /app/runtime_main.py \
    && mkdir -p /app/trust \
    && chmod 0555 /app /app/trust

WORKDIR /app
ENTRYPOINT ["python", "/app/runtime_main.py"]
