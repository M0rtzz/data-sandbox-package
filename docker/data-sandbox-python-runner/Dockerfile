# Reconstructed from the layer history of data-sandbox-python-runner:v2-ml
# (sha256:2e29cf942fe6e2b836db16d42a2c97b0747fea9a75f5ea4babaabb4be64316ec).
# The application files are recovered directly from that image.
# This is the digest behind the source image's local python:3.11-slim base.
FROM python@sha256:9c900dea9e8fb7e16277c179b555cc72d29a352dbc33cff48ad5a0412fd5bfc7

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    numpy==2.4.6 \
    pandas==3.0.5 \
    scipy==1.17.1 \
    scikit-learn==1.9.0 \
    joblib==1.5.3 \
    xgboost==3.2.0 \
    lightgbm==4.7.0

COPY data-sandbox-runner-lib/runner_common.py /app/runner_common.py
COPY data-sandbox-python-runner/python_runner.py /app/python_runner.py
RUN pip install --no-cache-dir torch==2.8.0+cpu --index-url https://download.pytorch.org/whl/cpu

COPY data-sandbox-python-runner/deep_learning_models.py /usr/local/lib/python3.11/site-packages/deep_learning_models.py
COPY data-sandbox-python-runner/modeling_ops.py /usr/local/lib/python3.11/site-packages/modeling_ops.py
COPY data-sandbox-python-runner/start.sh /app/start.sh
RUN chmod +x /app/start.sh

WORKDIR /app
CMD ["/app/start.sh"]
