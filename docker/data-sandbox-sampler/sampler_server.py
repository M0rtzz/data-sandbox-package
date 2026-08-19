#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox Sampler 容器主程序（Z-04 自定义代码执行）。

职责（只依赖 stdlib，无第三方库）：
  1. 读取 Kuscia 挂载的 /etc/kuscia/sampler-conf.json —— AppImage configTemplates 把
     "task_input_config" 渲染为 JSON 字符串字段，需二次 JSON 解析得到原始 payload。
  2. payload = {"script": <python 源码>, "input_csv_b64": <base64 授权输入子集 CSV>,
     "params": {...}}。base64 解码写 /tmp/sampler/input.csv，脚本写 script.py，参数写 params.json。
  3. 以 `python3 script.py --input ... --output ... --params ...` 执行用户脚本（子进程、
     超时保护），执行日志写 /tmp/sampler/run.log。
  4. 脚本结束后启动常驻 HTTP 服务 :8000（Kuscia 注入 KUSCIA_PORT_SAMPLER_NUMBER）：
       GET /status  -> "ok"
       GET /result  -> 结果 CSV（脚本写 output.csv 或缺省用其 stdout）
       GET /log     -> 执行日志
     平台经 scope=Cluster 端点取回结果后 stopJob/deleteJob 终止容器。

约定：
  - 用户脚本写结果 CSV 到 --output 指定路径（保留表头）；不写则用其 stdout 作为结果 CSV。
  - 脚本崩溃 → 容器 exit != 0 → Kuscia Job Failed → 平台标记 FAILED。
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

WORKDIR = "/tmp/sampler"
CONF_DEFAULT = "/etc/kuscia/sampler-conf.json"
RESULT_CSV = os.path.join(WORKDIR, "output.csv")
RUN_LOG = os.path.join(WORKDIR, "run.log")
INPUT_CSV = os.path.join(WORKDIR, "input.csv")
SCRIPT_PATH = os.path.join(WORKDIR, "script.py")
PARAMS_PATH = os.path.join(WORKDIR, "params.json")
SCRIPT_TIMEOUT_SECS = int(os.environ.get("SAMPLER_SCRIPT_TIMEOUT_SECS", "240"))

_GLOBAL_LOAD = threading.Lock()


def decode_and_run(conf_path):
    """解码 task_input_config → 写输入/脚本/参数 → 执行用户脚本 → 写结果与日志。"""
    with open(conf_path, "r", encoding="utf-8") as f:
        conf = json.load(f)

    raw = conf.get("task_input_config")
    if not raw:
        raise ValueError("task_input_config missing in " + conf_path)
    # Kuscia configTemplates 把 payload 渲染为 JSON 字符串，需二次解析
    payload = json.loads(raw) if isinstance(raw, str) else raw

    script = payload.get("script") or ""
    input_b64 = payload.get("input_csv_b64") or ""
    params = payload.get("params") or {}
    if not script.strip():
        raise ValueError("script empty")
    if not input_b64.strip():
        raise ValueError("input_csv_b64 empty")

    os.makedirs(WORKDIR, exist_ok=True)
    with open(INPUT_CSV, "w", encoding="utf-8", newline="") as f:
        f.write(base64.b64decode(input_b64.encode("ascii")).decode("utf-8"))
    with open(SCRIPT_PATH, "w", encoding="utf-8") as f:
        f.write(script)
    with open(PARAMS_PATH, "w", encoding="utf-8") as f:
        json.dump(params, f, ensure_ascii=False)

    cmd = [
        sys.executable, SCRIPT_PATH,
        "--input", INPUT_CSV,
        "--output", RESULT_CSV,
        "--params", PARAMS_PATH,
    ]
    with open(RUN_LOG, "w", encoding="utf-8") as log:
        log.write("[sampler] running script with %d input rows\n"
                  % (sum(1 for _ in open(INPUT_CSV, encoding="utf-8")) - 1))
        log.flush()
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True,
                                  timeout=SCRIPT_TIMEOUT_SECS)
        except subprocess.TimeoutExpired as exc:
            log.write("[sampler] script timed out after %ds\n" % SCRIPT_TIMEOUT_SECS)
            log.write((exc.stdout or ""))
            log.flush()
            raise RuntimeError("script timed out after %ds" % SCRIPT_TIMEOUT_SECS)
        log.write(proc.stdout or "")
        log.flush()
        if proc.returncode != 0:
            raise RuntimeError("script failed rc=%d" % proc.returncode)

    # 缺省：脚本未写 output.csv 时用其 stdout 作为结果 CSV
    if not os.path.exists(RESULT_CSV) or os.path.getsize(RESULT_CSV) == 0:
        with open(RESULT_CSV, "w", encoding="utf-8") as f:
            f.write(proc.stdout or "")
    size = os.path.getsize(RESULT_CSV)
    with open(RUN_LOG, "a", encoding="utf-8") as log:
        log.write("[sampler] output csv bytes=%d\n" % size)
    return size


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.split("?")[0] == "/status":
            self._send(b"ok", "text/plain; charset=utf-8")
        elif self.path.split("?")[0] == "/result":
            try:
                with open(RESULT_CSV, "rb") as f:
                    self._send(f.read(), "text/csv; charset=utf-8")
            except OSError:
                self._send(b"result not ready", "text/plain; charset=utf-8", 503)
        elif self.path.split("?")[0] == "/log":
            try:
                with open(RUN_LOG, "rb") as f:
                    self._send(f.read(), "text/plain; charset=utf-8")
            except OSError:
                self._send(b"no log yet", "text/plain; charset=utf-8", 404)
        else:
            self._send(b"not found", "text/plain; charset=utf-8", 404)

    def _send(self, body, ctype, code=200):  # noqa: N805
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # noqa: N805
        sys.stderr.write("[sampler] %s\n" % (fmt % args))


def main():
    ap = argparse.ArgumentParser(description="Data Sandbox Sampler")
    ap.add_argument("--config", default=CONF_DEFAULT)
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("KUSCIA_PORT_SAMPLER_NUMBER", "8000")))
    args = ap.parse_args()

    size = decode_and_run(args.config)
    print("[sampler] script finished, output bytes=%d, serving on :%d"
          % (size, args.port), flush=True)

    server = HTTPServer(("0.0.0.0", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # 脚本失败 → 非零退出 → Kuscia Job Failed
        sys.stderr.write("[sampler] FATAL: %s\n" % exc)
        sys.exit(1)
