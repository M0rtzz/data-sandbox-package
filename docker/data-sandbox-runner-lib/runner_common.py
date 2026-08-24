#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox runner 公共库（Z-05 计算任务运行组件）。

供 data-sandbox-sampler / data-sandbox-jar-runner / data-sandbox-python-runner
三个容器共用：Kuscia configTemplates 配置读取（双重 JSON 解析）、payload 解码、
输入写盘、子进程执行（超时保护）、结果/日志 HTTP 服务。

只依赖 stdlib，无第三方库（numpy/pandas 仅 python-runner 镜像预装，供用户脚本导入）。

约定（与 AppImage / DevJobExecutor 对齐）：
  - Kuscia configTemplates 把 payload 渲染为 /etc/kuscia/<name>-conf.json 里的字符串字段
    "task_input_config"，需 json.loads 二次解析得到原始 payload dict。
  - payload 关键字段：input_csv_b64（授权输入子集 base64）、params（参数 dict）；
    JAR 另有 jar_b64；PYTHON 另有 script + allowed_imports。
  - 子进程执行后写 output.csv；不写或缺省时以 stdout 兜底作为结果 CSV。
  - 常驻 HTTP :port 提供 GET /status -> "ok"、/result -> 结果 CSV、/log -> 执行日志；
    平台经 scope=Cluster 端点取回后 stopJob/deleteJob 终止容器。
"""
import base64
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def load_config(conf_path):
    """读取 Kuscia 挂载的 configTemplates 渲染文件，返回原始 payload dict。"""
    with open(conf_path, "r", encoding="utf-8") as f:
        conf = json.load(f)
    raw = conf.get("task_input_config")
    if not raw:
        raise ValueError("task_input_config missing in %s" % conf_path)
    # configTemplates 把 payload 渲染为 JSON 字符串，需二次解析
    return json.loads(raw) if isinstance(raw, str) else raw


def decode_str(b64_text):
    """base64 字符串 -> utf-8 文本。"""
    return base64.b64decode(b64_text.encode("ascii")).decode("utf-8")


def write_inputs(workdir, input_b64, params):
    """写输入 CSV 与参数 JSON，返回 (input_path, params_path)。"""
    os.makedirs(workdir, exist_ok=True)
    input_path = os.path.join(workdir, "input.csv")
    params_path = os.path.join(workdir, "params.json")
    with open(input_path, "w", encoding="utf-8", newline="") as f:
        f.write(decode_str(input_b64))
    with open(params_path, "w", encoding="utf-8") as f:
        json.dump(params, f, ensure_ascii=False)
    return input_path, params_path


def run_subprocess(cmd, log_path, timeout_secs, label):
    """执行子进程，stdout+stderr 合并写入 log_path；超时抛 TimeoutError；rc!=0 抛 RuntimeError。

    返回子进程 stdout。执行日志（含 [label] 前缀）由调用方在异常路径上也已写入。
    """
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "w", encoding="utf-8") as log:
        log.write("[%s] running: %s\n" % (label, " ".join(cmd)))
        log.flush()
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True,
                                  timeout=timeout_secs)
        except subprocess.TimeoutExpired as exc:
            log.write("[%s] timed out after %ds\n" % (label, timeout_secs))
            log.write(exc.stdout or "")
            log.flush()
            raise TimeoutError("%s timed out after %ds" % (label, timeout_secs))
        log.write(proc.stdout or "")
        log.flush()
        if proc.returncode != 0:
            raise RuntimeError("%s failed rc=%d" % (label, proc.returncode))
        return proc.stdout or ""


def fallback_result(output_csv, stdout, label, log_path):
    """脚本未写 output.csv（或为空）时以 stdout 兜底作为结果 CSV。返回输出字节数。"""
    if not os.path.exists(output_csv) or os.path.getsize(output_csv) == 0:
        with open(output_csv, "w", encoding="utf-8") as f:
            f.write(stdout or "")
    size = os.path.getsize(output_csv)
    with open(log_path, "a", encoding="utf-8") as log:
        log.write("[%s] output csv bytes=%d\n" % (label, size))
    return size


def make_handler(result_csv, run_log):
    """按结果/日志路径构建常驻结果服务 handler（GET /status /result /log）。"""

    class _Handler(BaseHTTPRequestHandler):
        def _send(self, body, ctype, code=200):  # noqa: N805
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            path = self.path.split("?")[0]
            if path == "/status":
                self._send(b"ok", "text/plain; charset=utf-8")
            elif path == "/result":
                try:
                    with open(result_csv, "rb") as f:
                        self._send(f.read(), "text/csv; charset=utf-8")
                except OSError:
                    self._send(b"result not ready", "text/plain; charset=utf-8", 503)
            elif path == "/log":
                try:
                    with open(run_log, "rb") as f:
                        self._send(f.read(), "text/plain; charset=utf-8")
                except OSError:
                    self._send(b"no log yet", "text/plain; charset=utf-8", 404)
            else:
                self._send(b"not found", "text/plain; charset=utf-8", 404)

        def log_message(self, fmt, *args):  # noqa: N805
            sys.stderr.write("[runner] %s\n" % (fmt % args))

    return _Handler


def serve(port, result_csv, run_log):
    """常驻 HTTP :port 提供 /status /result /log；容器跑完服务后由平台 stopJob/deleteJob 终止。"""
    server = HTTPServer(("0.0.0.0", port), make_handler(result_csv, run_log))
    server.serve_forever()
