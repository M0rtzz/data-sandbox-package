#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox JAR Runner 容器主程序（Z-05 计算任务运行组件 / JAR 执行）。

职责（只依赖 stdlib）：
  1. 读取 Kuscia 挂载的 /etc/kuscia/jar-conf.json（AppImage configTemplates 渲染），
     解码 task_input_config payload。
  2. payload = {"jar_b64": <JAR 字节 base64>, "params": {...}, "input_csv_b64": <授权输入子集 base64>}。
     base64 解码写 /app/app.jar、input.csv、params.json。
  3. 以 `java -jar /app/app.jar --input ... --output ... --params ...` 执行 JAR（子进程、超时保护），
     同步注入环境变量 DS_INPUT_CSV / DS_OUTPUT_CSV / DS_PARAMS_JSON；执行日志写 /tmp/jar/run.log。
  4. JAR 未写 output.csv 时以 stdout 兜底作为结果 CSV。
  5. 启动常驻 HTTP :8000（Kuscia 注入 KUSCIA_PORT_JAR_NUMBER）：
       GET /status -> ok；GET /result -> 结果 CSV；GET /log -> 执行日志。
     平台经 scope=Cluster 端点取回结果后 stopJob/deleteJob 终止容器。

JAR 运行契约（前端 tooltip / 说明书注明）：
  - CLI 程序把结果 CSV（含表头）写到 --output 指定路径；不写则用 stdout 作为结果 CSV。
  - 长驻服务（非一次性 CLI）超过脚本超时上限会被 kill -> 容器退出非零 -> Job Failed。
"""
import argparse
import base64
import os
import sys

sys.path.insert(0, "/app")  # runner_common.py 位于镜像 /app 下
import runner_common as rc  # noqa: E402

WORKDIR = "/tmp/jar"
RESULT_CSV = os.path.join(WORKDIR, "output.csv")
RUN_LOG = os.path.join(WORKDIR, "run.log")
CONF_DEFAULT = "/etc/kuscia/jar-conf.json"
JAR_PATH = "/app/app.jar"
SCRIPT_TIMEOUT_SECS = int(os.environ.get("JAR_SCRIPT_TIMEOUT_SECS", "240"))


def decode_and_run(conf_path):
    payload = rc.load_config(conf_path)
    jar_b64 = payload.get("jar_b64") or ""
    input_b64 = payload.get("input_csv_b64") or ""
    params = payload.get("params") or {}
    if not jar_b64.strip():
        raise ValueError("jar_b64 empty")
    if not input_b64.strip():
        raise ValueError("input_csv_b64 empty")

    os.makedirs(WORKDIR, exist_ok=True)
    with open(JAR_PATH, "wb") as f:
        f.write(base64.b64decode(jar_b64.encode("ascii")))
    input_path, params_path = rc.write_inputs(WORKDIR, input_b64, params)

    cmd = [
        "java", "-jar", JAR_PATH,
        "--input", input_path,
        "--output", RESULT_CSV,
        "--params", params_path,
    ]
    env = dict(os.environ)
    env["DS_INPUT_CSV"] = input_path
    env["DS_OUTPUT_CSV"] = RESULT_CSV
    env["DS_PARAMS_JSON"] = params_path
    stdout = rc.run_subprocess(cmd, RUN_LOG, SCRIPT_TIMEOUT_SECS, "jar")
    return rc.fallback_result(RESULT_CSV, stdout, "jar", RUN_LOG)


def main():
    ap = argparse.ArgumentParser(description="Data Sandbox JAR Runner")
    ap.add_argument("--config", default=CONF_DEFAULT)
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("KUSCIA_PORT_JAR_NUMBER", "8000")))
    args = ap.parse_args()

    size = decode_and_run(args.config)
    print("[jar] finished, output bytes=%d, serving on :%d" % (size, args.port), flush=True)
    rc.serve(args.port, RESULT_CSV, RUN_LOG)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # 执行失败 -> 非零退出 -> Kuscia Job Failed
        sys.stderr.write("[jar] FATAL: %s\n" % exc)
        sys.exit(1)
