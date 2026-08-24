#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox Sampler 容器主程序（Z-04 自定义代码执行）。

职责（只依赖 stdlib，无第三方库），委托 runner_common 完成公共逻辑：
  1. 读取 Kuscia 挂载的 /etc/kuscia/sampler-conf.json —— AppImage configTemplates 把
     "task_input_config" 渲染为 JSON 字符串字段，runner_common.load_config 二次解析。
  2. payload = {"script": <python 源码>, "input_csv_b64": <base64 授权输入子集 CSV>,
     "params": {...}}。base64 解码写 /tmp/sampler/input.csv，脚本写 script.py，参数写 params.json。
  3. 以 `python3 script.py --input ... --output ...` 执行用户脚本；params 非空时追加
     `--params ...`，兼容无需自定义参数的脚本。执行日志写 /tmp/sampler/run.log。
  4. 脚本未写 output.csv 时以 stdout 兜底作为结果 CSV。
  5. 启动常驻 HTTP :8000（Kuscia 注入 KUSCIA_PORT_SAMPLER_NUMBER）：
       GET /status -> ok；GET /result -> 结果 CSV；GET /log -> 执行日志。
     平台经 scope=Cluster 端点取回结果后 stopJob/deleteJob 终止容器。

约定：
  - 用户脚本写结果 CSV 到 --output 指定路径（保留表头）；不写则用其 stdout 作为结果 CSV。
  - 脚本崩溃 -> 容器 exit != 0 -> Kuscia Job Failed -> 平台标记 FAILED。
"""
import argparse
import os
import sys

sys.path.insert(0, "/app")  # runner_common.py 位于镜像 /app 下
import runner_common as rc  # noqa: E402

WORKDIR = "/tmp/sampler"
RESULT_CSV = os.path.join(WORKDIR, "output.csv")
RUN_LOG = os.path.join(WORKDIR, "run.log")
SCRIPT_PATH = os.path.join(WORKDIR, "script.py")
CONF_DEFAULT = "/etc/kuscia/sampler-conf.json"
SCRIPT_TIMEOUT_SECS = int(os.environ.get("SAMPLER_SCRIPT_TIMEOUT_SECS", "240"))


def decode_and_run(conf_path):
    """解码 task_input_config → 写输入/脚本/参数 → 执行用户脚本 → 写结果与日志。"""
    payload = rc.load_config(conf_path)
    script = payload.get("script") or ""
    input_b64 = payload.get("input_csv_b64") or ""
    params = payload.get("params") or {}
    if not script.strip():
        raise ValueError("script empty")
    if not input_b64.strip():
        raise ValueError("input_csv_b64 empty")

    input_path, params_path = rc.write_inputs(WORKDIR, input_b64, params)
    with open(SCRIPT_PATH, "w", encoding="utf-8") as f:
        f.write(script)

    cmd = [
        sys.executable, SCRIPT_PATH,
        "--input", input_path,
        "--output", RESULT_CSV,
    ]
    if params:
        cmd.extend(["--params", params_path])
    stdout = rc.run_subprocess(cmd, RUN_LOG, SCRIPT_TIMEOUT_SECS, "sampler")
    return rc.fallback_result(RESULT_CSV, stdout, "sampler", RUN_LOG)


def main():
    ap = argparse.ArgumentParser(description="Data Sandbox Sampler")
    ap.add_argument("--config", default=CONF_DEFAULT)
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("KUSCIA_PORT_SAMPLER_NUMBER", "8000")))
    args = ap.parse_args()

    size = decode_and_run(args.config)
    print("[sampler] script finished, output bytes=%d, serving on :%d"
          % (size, args.port), flush=True)

    rc.serve(args.port, RESULT_CSV, RUN_LOG)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # 脚本失败 → 非零退出 → Kuscia Job Failed
        sys.stderr.write("[sampler] FATAL: %s\n" % exc)
        sys.exit(1)
