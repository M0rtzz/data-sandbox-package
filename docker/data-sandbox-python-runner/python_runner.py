#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox Python Runner 容器主程序（Z-05 计算任务运行组件 / PYTHON 执行）。

职责（只依赖 stdlib，numpy/pandas 为镜像预装供用户脚本导入）：
  1. 读取 Kuscia 挂载的 /etc/kuscia/py-conf.json（AppImage configTemplates 渲染），
     解码 task_input_config payload。
  2. payload = {"script": <python 源码>, "params": {...}, "input_csv_b64": <授权输入子集 base64>,
     "allowed_imports": [<平台白名单放行的顶层模块名>]}。
  3. 给用户脚本前置「import 守卫 prologue」：用 builtins.__import__ 包裹，顶层模块必须 ∈
     allowed_imports ∪ sys.stdlib_module_names，否则抛 ImportError("dependency not allowed: <top>")
     -> 脚本失败 -> 容器退出非零 -> Job Failed（平台日志可见明确错误）。
  4. 以 `python3 script_guarded.py --input ... --output ... --params ...` 执行（子进程、超时保护），
     执行日志写 /tmp/py/run.log。
  5. 脚本未写 output.csv 时以 stdout 兜底作为结果 CSV。
  6. 常驻 HTTP :8000（Kuscia 注入 KUSCIA_PORT_PY_NUMBER）：/status /result /log。

硬保证（镜像层 + 调度层）：容器无网络（network_policy + 仅结果 Cluster 端口）、无 pip、仅预装白名单包；
即使 import 守卫被绕过，也无法导入非白名单三方包。
"""
import argparse
import os
import sys

sys.path.insert(0, "/app")  # runner_common.py 位于镜像 /app 下
import runner_common as rc  # noqa: E402

WORKDIR = "/tmp/py"
RESULT_CSV = os.path.join(WORKDIR, "output.csv")
RUN_LOG = os.path.join(WORKDIR, "run.log")
SCRIPT_PATH = os.path.join(WORKDIR, "script_guarded.py")
CONF_DEFAULT = "/etc/kuscia/py-conf.json"
SCRIPT_TIMEOUT_SECS = int(os.environ.get("PY_SCRIPT_TIMEOUT_SECS", "240"))

IMPORT_GUARD_PROLOGUE = '''
import builtins as _ds_builtins, sys as _ds_sys
_ds_allowed = set(__DS_ALLOWED_IMPORTS__) | set(getattr(_ds_sys, "stdlib_module_names", ()))
_ds_orig_import = _ds_builtins.__import__
def _ds_guarded_import(_ds_name, _ds_globals=None, _ds_locals=None, _ds_fromlist=(), _ds_level=0):
    if _ds_level > 0:
        # 相对导入（from .x import ...）仅在当前已放行的顶层包内解析，直接放行
        return _ds_orig_import(_ds_name, _ds_globals, _ds_locals, _ds_fromlist, _ds_level)
    _ds_top = _ds_name.split(".")[0]
    if _ds_top not in _ds_allowed:
        raise ImportError("dependency not allowed: " + _ds_top)
    return _ds_orig_import(_ds_name, _ds_globals, _ds_locals, _ds_fromlist, _ds_level)
_ds_builtins.__import__ = _ds_guarded_import
'''

_ALLOWED_PLACEHOLDER = "__DS_ALLOWED_IMPORTS__"


def build_guard(allowed_imports):
    """生成 import 守卫 prologue 源码：allowed_imports 经 repr 嵌入为列表字面量（防注入），逐项顶层化。"""
    tops = sorted({i.split(".")[0] for i in (allowed_imports or []) if i and i.strip()})
    return IMPORT_GUARD_PROLOGUE.replace(_ALLOWED_PLACEHOLDER, "[" + ", ".join(repr(t) for t in tops) + "]")


def decode_and_run(conf_path):
    payload = rc.load_config(conf_path)
    script = payload.get("script") or ""
    input_b64 = payload.get("input_csv_b64") or ""
    params = payload.get("params") or {}
    allowed = payload.get("allowed_imports") or []
    if not script.strip():
        raise ValueError("script empty")
    if not input_b64.strip():
        raise ValueError("input_csv_b64 empty")

    os.makedirs(WORKDIR, exist_ok=True)
    with open(SCRIPT_PATH, "w", encoding="utf-8") as f:
        f.write(build_guard(allowed))
        f.write("\n")
        f.write(script)
    input_path, params_path = rc.write_inputs(WORKDIR, input_b64, params)

    cmd = [
        sys.executable, SCRIPT_PATH,
        "--input", input_path,
        "--output", RESULT_CSV,
        "--params", params_path,
    ]
    stdout = rc.run_subprocess(cmd, RUN_LOG, SCRIPT_TIMEOUT_SECS, "py")
    return rc.fallback_result(RESULT_CSV, stdout, "py", RUN_LOG)


def main():
    ap = argparse.ArgumentParser(description="Data Sandbox Python Runner")
    ap.add_argument("--config", default=CONF_DEFAULT)
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("KUSCIA_PORT_PY_NUMBER", "8000")))
    args = ap.parse_args()

    size = decode_and_run(args.config)
    print("[py] finished, output bytes=%d, serving on :%d" % (size, args.port), flush=True)
    rc.serve(args.port, RESULT_CSV, RUN_LOG)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # 执行失败 -> 非零退出 -> Kuscia Job Failed
        sys.stderr.write("[py] FATAL: %s\n" % exc)
        sys.exit(1)
