FROM python:3.11-slim

WORKDIR /app

COPY data-sandbox-runner-lib/runner_common.py /app/runner_common.py
COPY data-sandbox-sampler/sampler_server.py /app/sampler_server.py
COPY data-sandbox-sampler/start.sh /app/start.sh

RUN chmod +x /app/start.sh

EXPOSE 8000

CMD ["/app/start.sh"]
