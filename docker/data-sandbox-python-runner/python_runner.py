#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox Python Runner 容器主程序（Z-05 计算任务运行组件 / PYTHON 执行）。

职责（numpy/pandas 为镜像预装；脚本缺失依赖运行时 pip 自动安装）：
  1. 读取 Kuscia 挂载的 /etc/kuscia/py-conf.json（AppImage configTemplates 渲染），
     解码 task_input_config payload。
  2. payload = {"script": <python 源码>, "params": {...}, "input_csv_b64": <授权输入子集 base64>,
     "allowed_imports": [<平台记录的本次实际顶层 import>]}。
  3. 运行时依赖解析：AST 解析脚本顶层 import（extract_imports_ast），对非标准库且未安装
     （importlib.util.find_spec 为 None）的模块逐个 `pip install --quiet <mod>`（子进程、超时保护）。
     安装成败与最终依赖列表记录进 run.log（`[py] pip install <name>: ok/fail` / `[py] deps: imported=[...]`），
     平台取回 /log 落 ds_dev_run_log 即"本次任务导入了什么依赖库"。
  4. import 守卫允许集 = 脚本自身顶层 import ∪ stdlib ∪ 已安装（含 pip 新装，子进程启动时
     pkgutil.iter_modules 重新扫描天然放行），保证新装模块可导入；pip 安装失败的模块
     在运行时自然抛 ImportError（可接受降级，记录在案）。
  5. 以 `python3 script_guarded.py --input ... --output ... --params ...` 执行（子进程、超时保护），
     执行日志写 /tmp/py/run.log。
  6. 脚本未写 output.csv 时以 stdout 兜底作为结果 CSV。
  7. 常驻 HTTP :8000（Kuscia 注入 KUSCIA_PORT_PY_NUMBER）：/status /result /log。
     脚本失败时容器不退出，改为 /status 返回 "failed" 并保持提供 /log，平台取回失败原因日志后
     stopJob 终止容器（调试日志不再丢失，error_message 含真实错误如 ImportError）。

降级语义：容器网络（network_policy=GOVERNANCE）若不放行 PyPI egress，pip 安装记录 fail，
脚本 import 自然报 ModuleNotFoundError -> 任务失败日志明确；不影响 SQL/JAR/FUNCTION 等其他类型。
"""
import argparse
import ast
import base64
import importlib.util
import json
import os
import subprocess
import sys

sys.path.insert(0, "/app")  # runner_common.py 位于镜像 /app 下
import runner_common as rc  # noqa: E402

WORKDIR = "/tmp/py"
RESULT_CSV = os.path.join(WORKDIR, "output.csv")
RUN_LOG = os.path.join(WORKDIR, "run.log")
SCRIPT_PATH = os.path.join(WORKDIR, "script_guarded.py")
DB_PATH = "/workspace/sandbox_data.db"
CONF_DEFAULT = "/etc/kuscia/py-conf.json"
SCRIPT_TIMEOUT_SECS = int(os.environ.get("PY_SCRIPT_TIMEOUT_SECS", "240"))
# 运行时 pip 自动安装（缺失依赖）：单模块安装超时 / 索引 / 总开关
PIP_INSTALL_TIMEOUT_SECS = int(os.environ.get("PY_PIP_TIMEOUT_SECS", "120"))
PIP_INDEX_URL = os.environ.get("PIP_INDEX_URL", "https://pypi.org/simple")
PIP_AUTO_INSTALL_ENABLED = os.environ.get("PY_PIP_AUTO_INSTALL", "1") != "0"

IMPORT_GUARD_PROLOGUE = '''
import builtins as _ds_builtins, sys as _ds_sys
# 放行集 = 脚本自身顶层 import（__DS_ALLOWED_IMPORTS__，运行时 AST 解析所得）∪ 标准库 ∪ 已安装顶层包。
# 关键：已安装集用 pkgutil.iter_modules() 在子进程启动时重新扫描——pip 自动安装的模块（dateutil 等）
#       在此天然放行；已安装包的传递依赖同样在已安装集内，不会误伤。硬边界 = 实际可导入集。
_ds_allowed = set(__DS_ALLOWED_IMPORTS__) | set(getattr(_ds_sys, "stdlib_module_names", ())) | {"__main__"}
import pkgutil as _ds_pkgutil
for _ds_m in _ds_pkgutil.iter_modules():
    _ds_allowed.add(_ds_m.name)
_ds_orig_import = _ds_builtins.__import__
def _ds_guarded_import(_ds_name, _ds_globals=None, _ds_locals=None, _ds_fromlist=(), _ds_level=0, **_ds_kw):
    if _ds_kw:
        # 兼容 __import__(..., level=N) 关键字调用（包内相对导入等），未知关键字兜底透传
        _ds_level = _ds_kw.pop("level", _ds_level)
        if _ds_kw:
            return _ds_orig_import(_ds_name, _ds_globals, _ds_locals, _ds_fromlist, _ds_level)
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


def check_ast_imports(script, allowed, name="user_script.py"):
    """运行时 AST 导入拦截：解析脚本顶层 import/from-import，仅放行 allowed_imports ∪ stdlib ∪ __main__。

    builtins.__import__ 守卫对动态导入防不住（importlib 等），本扫描在子进程启动前对
    静态顶层导入做白名单强校验；白名单包的传递依赖（pandas -> dateutil 等）在镜像内已安装，
    不会被本扫描检查（只查用户脚本自身顶层 import），硬边界仍是镜像预装集。
    """
    tops = sorted({i.split(".")[0] for i in (allowed or []) if i and i.strip()})
    allowed_set = set(tops) | set(getattr(sys, "stdlib_module_names", ())) | {"__main__"}
    try:
        tree = ast.parse(script, filename=name)
    except SyntaxError as exc:
        raise ValueError("脚本语法错误: %s (line %s)" % (exc.msg, exc.lineno))
    banned = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                top = alias.name.split(".")[0]
                if top and top not in allowed_set:
                    banned.append(top)
        elif isinstance(node, ast.ImportFrom):
            if node.level > 0:
                continue  # 相对导入仅在已放行顶层包内解析，放行
            mod = node.module or ""
            top = mod.split(".")[0]
            if top and top not in allowed_set:
                banned.append(top)
    if banned:
        raise ValueError("dependency not allowed: %s（白名单: %s）"
                         % (", ".join(sorted(set(banned))), ", ".join(tops)))


def extract_imports_ast(script, name="user_script.py"):
    """AST 解析脚本顶层 import/from-import，返回去重的顶层模块名列表（首个点前部分）。

    与 check_ast_imports 共用 ast.walk 遍历逻辑；相对导入（from .x import ...）忽略。
    语法错误在此抛 ValueError（与 check_ast_imports 一致）。
    """
    try:
        tree = ast.parse(script, filename=name)
    except SyntaxError as exc:
        raise ValueError("脚本语法错误: %s (line %s)" % (exc.msg, exc.lineno))
    tops = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                top = alias.name.split(".")[0]
                if top and top not in tops:
                    tops.append(top)
        elif isinstance(node, ast.ImportFrom):
            if node.level > 0:
                continue
            mod = node.module or ""
            top = mod.split(".")[0]
            if top and top not in tops:
                tops.append(top)
    return tops


def module_installed(top):
    """用 importlib.util.find_spec 判断顶层模块当前是否可导入。"""
    try:
        return importlib.util.find_spec(top) is not None
    except (ImportError, ValueError, AttributeError):
        return False


def install_missing(top_levels):
    """对非标准库、未安装的顶层模块逐个 pip install；返回安装记录行列表。

    pip 失败的模块不中断整体执行（记录 fail，脚本运行时 import 自然报错）。
    """
    stdlib = set(getattr(sys, "stdlib_module_names", ()))
    lines = []
    for top in sorted(set(top_levels)):
        if not top or top in stdlib or module_installed(top):
            continue
        if not PIP_AUTO_INSTALL_ENABLED:
            lines.append("[py] pip disabled, skip install: %s" % top)
            continue
        try:
            proc = subprocess.run(
                [sys.executable, "-m", "pip", "install", "--quiet",
                 "--disable-pip-version-check", "--no-input",
                 "--index-url", PIP_INDEX_URL, top],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                timeout=PIP_INSTALL_TIMEOUT_SECS)
            if proc.returncode == 0:
                lines.append("[py] pip install %s: ok" % top)
            else:
                detail = (proc.stdout or "").strip().splitlines()
                tail = detail[-1][:200] if detail else "rc=%d" % proc.returncode
                lines.append("[py] pip install %s: fail (%s)" % (top, tail))
        except subprocess.TimeoutExpired:
            lines.append("[py] pip install %s: fail (timeout after %ds)"
                         % (top, PIP_INSTALL_TIMEOUT_SECS))
        except Exception as exc:
            lines.append("[py] pip install %s: fail (%s)" % (top, exc))
    return lines


def _prepend_pip_log(pip_lines, deps_record):
    """把 pip 安装记录与依赖列表补写进 run.log 开头。

    run.log 由 run_subprocess 以 "w" 覆盖写（重新开始），故在子进程执行结束后再把
    安装记录/依赖列表插到最前面；失败路径（run_subprocess 抛异常）同样在 finally 中补写。
    """
    if not pip_lines and not deps_record:
        return
    try:
        if os.path.exists(RUN_LOG):
            with open(RUN_LOG, "r", encoding="utf-8") as f:
                body = f.read()
        else:
            body = ""
        head = "\n".join(pip_lines)
        if deps_record:
            head += ("\n" if head else "") + deps_record
        with open(RUN_LOG, "w", encoding="utf-8") as f:
            f.write(head + ("\n" if head and body else "") + body)
    except OSError:
        pass  # 补写失败不阻断主流程


def decode_and_run(conf_path):
    payload = rc.load_config(conf_path)
    script = payload.get("script") or ""
    input_b64 = payload.get("input_csv_b64") or ""
    params = payload.get("params") or {}
    input_table = payload.get("input_table") or ""
    db_b64 = payload.get("sandbox_db_b64") or ""
    if not script.strip():
        raise ValueError("script empty")
    if not input_b64.strip():
        raise ValueError("input_csv_b64 empty")

    # 沙箱 DB 快照：解码写 /workspace/sandbox_data.db，子进程 env 继承父进程（SANDBOX_DB_PATH 透传）
    if db_b64:
        try:
            os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
            with open(DB_PATH, "wb") as f:
                f.write(base64.b64decode(db_b64.encode("ascii")))
            os.environ["SANDBOX_DB_PATH"] = DB_PATH
            sys.stderr.write("[py] sandbox db snapshot %d bytes -> %s\n" % (os.path.getsize(DB_PATH), DB_PATH))
        except Exception as exc:
            raise ValueError("sandbox_db_b64 decode failed: %s" % exc)

    # 运行时依赖解析：AST 提取脚本顶层 import -> 非标准库且未安装的模块 pip 自动安装
    # allowed（守卫允许集）以脚本自身 AST 顶层 import 为准，不再依赖平台传的整个白名单；
    # 这样 pip 新装的模块也能被 import 守卫放行。
    allowed = extract_imports_ast(script)
    pip_lines = install_missing(allowed)
    deps_record = "[py] deps: imported=[" + ", ".join(allowed) + "]" if allowed else "[py] deps: imported=[]"

    # 运行时 AST 导入拦截：allowed=脚本自身顶层 import，天然不会拒绝（语法错误已在上步抛出）
    check_ast_imports(script, allowed)

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
        "--params", json.dumps(params),
    ]
    if input_table:
        cmd += ["--input-table", input_table]
    try:
        stdout = rc.run_subprocess(cmd, RUN_LOG, SCRIPT_TIMEOUT_SECS, "py")
        return rc.fallback_result(RESULT_CSV, stdout, "py", RUN_LOG)
    finally:
        # 把 pip 安装记录与依赖列表插到 run.log 开头（无论子进程成败）
        _prepend_pip_log(pip_lines, deps_record)


def main():
    ap = argparse.ArgumentParser(description="Data Sandbox Python Runner")
    ap.add_argument("--config", default=CONF_DEFAULT)
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("KUSCIA_PORT_PY_NUMBER", "8000")))
    args = ap.parse_args()

    status = "ok"
    try:
        size = decode_and_run(args.config)
        print("[py] finished, output bytes=%d, serving on :%d" % (size, args.port), flush=True)
    except Exception as exc:  # 脚本执行失败：不退出，记录原因并标记 failed，常驻供平台取回 /log
        with open(RUN_LOG, "a", encoding="utf-8") as f:
            f.write("[py] EXECUTION FAILED: %s\n" % exc)
        sys.stderr.write("[py] execution failed: %s\n" % exc)
        status = "failed"
    rc.serve(args.port, RESULT_CSV, RUN_LOG, status=status)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # 致命错误（如端口占用）-> 非零退出 -> Kuscia Job Failed
        sys.stderr.write("[py] FATAL: %s\n" % exc)
        sys.exit(1)
