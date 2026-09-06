#!/usr/bin/env python3
"""Trusted execution adapters for BUILTIN, SQL, PYTHON and JAR programs."""
import base64
import csv
import hashlib
import json
import os
import re
import resource
import signal
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from tee_contract_runtime import ContractError

MAX_RUNTIME_SECONDS = 1800
MAX_REPORT_BYTES = 1024 * 1024
MODEL_MARKER = "MODELB64:"
PREPROC_MARKER = "PREPROC:"
EVALUATION_OPERATORS = {"ml.binary_classification", "ml.regression_evaluation"}
REPORT_OPERATORS = {
    "report.feature_importance": "FEATURE_IMPORTANCE",
    "report.tree_structure": "TREE_STRUCTURE",
}
MODEL_PREDICT_OPERATOR = "model.predict"


@dataclass
class Output:
    kind: str
    content: bytes | dict | list
    report_kind: str | None = None
    artifact_type: str | None = None


def execute(task, inputs, program_bytes, workdir):
    """Execute a signed task using only filtered inputs inside a tmpfs workdir."""
    if not inputs:
        raise ContractError("CONTRACT_INVALID", "task has no filtered inputs")
    root = Path(workdir)
    exec_uid = int(os.environ.get("TEE_EXEC_UID", "65532"))
    exec_gid = int(os.environ.get("TEE_EXEC_GID", "65532"))
    if exec_uid <= 0 or exec_gid <= 0:
        raise ContractError("CONTRACT_INVALID", "operator process must use an unprivileged identity")
    # Keep the directory owned by the trusted parent so it can collect and wipe
    # outputs without CAP_DAC_OVERRIDE/FOWNER.  The operator receives access
    # only through its dedicated group; it never owns the task directory.
    root.chmod(0o700)
    os.chown(root, 0, exec_gid)
    root.chmod(0o770)
    input_paths = []
    for index, content in enumerate(inputs):
        path = root / ("input-%d.csv" % index)
        path.write_bytes(content)
        path.chmod(0o400)
        os.chown(path, exec_uid, exec_gid)
        input_paths.append(path)
    output_path = root / "output.csv"
    program = task["program"]
    kind = program["kind"]
    parameters = dict(program.get("parameters") or {})
    if kind == "BUILTIN":
        builtin = Path(os.environ.get("TEE_BUILTIN_PROGRAM", "/opt/data-sandbox/modeling_ops.py"))
        _require_digest(builtin.read_bytes(), program["sha256"], "BUILTIN program")
        requested = parameters.get("op") or parameters.get("component")
        if requested and requested != task["operatorId"]:
            raise ContractError("CONTRACT_INVALID", "operator parameter does not match signed task")
        parameters["op"] = task["operatorId"]
        if task.get("contractVersion") == "tee-contract/2.0" and task["operatorId"] in ("report.tree_structure", "report.model_evaluation"):
            return [_execute_tree_report(task, input_paths, root, exec_uid, exec_gid)]
        if task["operatorId"] == MODEL_PREDICT_OPERATOR:
            return [_execute_model_predict(inputs, parameters)]
        command = [sys.executable, str(builtin)]
    elif kind == "PYTHON":
        path = root / "program.py"
        path.write_bytes(_verified_program(program, program_bytes))
        path.chmod(0o400)
        os.chown(path, exec_uid, exec_gid)
        command = [sys.executable, str(path)]
    elif kind == "JAR":
        path = root / "program.jar"
        path.write_bytes(_verified_program(program, program_bytes))
        path.chmod(0o400)
        os.chown(path, exec_uid, exec_gid)
        command = ["java", "-jar", str(path)]
    elif kind == "SQL":
        return _execute_sql(task, inputs, _verified_program(program, program_bytes), root)
    else:
        raise ContractError("CONTRACT_INVALID", "unsupported program kind")
    command += ["--input", str(input_paths[0]), "--output", str(output_path),
                "--params", json.dumps(parameters, separators=(",", ":"))]
    if len(input_paths) > 1:
        manifest = root / "inputs.json"
        manifest.write_text(json.dumps([str(path) for path in input_paths]), encoding="utf-8")
        manifest.chmod(0o400)
        os.chown(manifest, exec_uid, exec_gid)
    _run(command, root, exec_uid, exec_gid)
    if not output_path.is_file():
        raise ContractError("CONTRACT_INVALID", "program did not create output.csv")
    # The child creates mode-0600 output under its unprivileged uid.  Reclaim it
    # explicitly with CAP_CHOWN instead of granting the runtime broad DAC/FOWNER
    # capabilities merely so the trusted parent can classify and encrypt it.
    os.chown(output_path, 0, 0)
    output_path.chmod(0o400)
    return _classify(task, output_path.read_bytes())


def _verified_program(program, content):
    if content is None:
        raise ContractError("CONTRACT_INVALID", "program object content is missing")
    _require_digest(content, program["sha256"], "program object")
    return content


def _require_digest(content, expected, label):
    if hashlib.sha256(content).hexdigest() != expected:
        raise ContractError("DATA_INTEGRITY_FAILED", label + " digest mismatch")


def _run(command, workdir, exec_uid, exec_gid):
    env = {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "LANG": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
        "TMPDIR": str(workdir),
    }
    process = subprocess.Popen(command, cwd=workdir, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=True,
                               preexec_fn=lambda: _limits(exec_uid, exec_gid))
    try:
        _, stderr = process.communicate(timeout=int(os.environ.get("TEE_TASK_TIMEOUT_SECONDS", MAX_RUNTIME_SECONDS)))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise ContractError("CONTRACT_INVALID", "program execution timed out")
    if process.returncode:
        # Never return program stdout/stderr: either may contain data rows.
        raise ContractError("CONTRACT_INVALID", "program execution failed")


def _limits(exec_uid, exec_gid):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.setgroups([])
    os.setgid(exec_gid)
    os.setuid(exec_uid)
    os.umask(0o077)


def _execute_sql(task, inputs, program_bytes, root):
    try:
        sql = program_bytes.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise ContractError("CONTRACT_INVALID", "SQL program is not UTF-8") from exc
    if not re.match(r"(?is)^\s*(select|with)\b", sql) or ";" in sql.rstrip(";"):
        raise ContractError("POLICY_DENIED", "SQL runtime accepts one read-only query")
    database = root / "sandbox.db"
    connection = sqlite3.connect(database)
    try:
        for index, content in enumerate(inputs):
            rows = list(csv.reader(content.decode("utf-8").splitlines()))
            if not rows:
                raise ContractError("DATA_INTEGRITY_FAILED", "empty CSV input")
            table = "input_%d" % index
            columns = rows[0]
            if not columns or len(set(columns)) != len(columns):
                raise ContractError("DATA_INTEGRITY_FAILED", "invalid CSV header")
            quoted = ",".join('"%s" TEXT' % value.replace('"', '""') for value in columns)
            connection.execute('CREATE TABLE "%s" (%s)' % (table, quoted))
            if rows[1:]:
                connection.executemany('INSERT INTO "%s" VALUES (%s)' %
                                       (table, ",".join("?" for _ in columns)), rows[1:])
        cursor = connection.execute(sql)
        if cursor.description is None:
            raise ContractError("POLICY_DENIED", "SQL did not return a result set")
        output = root / "output.csv"
        with output.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.writer(stream)
            writer.writerow([item[0] for item in cursor.description])
            writer.writerows(cursor.fetchall())
        return [Output("DATA", output.read_bytes())]
    finally:
        connection.close()


def _classify(task, raw):
    lines = raw.splitlines(keepends=True)
    data_lines, model_outputs = [], []
    for line in lines:
        stripped = line.decode("utf-8", errors="strict").rstrip("\r\n")
        if stripped.startswith(MODEL_MARKER + ","):
            try:
                model_outputs.append(Output("MODEL",
                                            base64.b64decode(stripped.split(",", 1)[1], validate=True),
                                            artifact_type="MODEL"))
            except Exception as exc:
                raise ContractError("DATA_INTEGRITY_FAILED", "invalid model marker") from exc
        elif stripped.startswith(PREPROC_MARKER + ","):
            try:
                model_outputs.append(Output("MODEL",
                                            base64.b64decode(stripped.split(",", 1)[1], validate=True),
                                            artifact_type="PREPROCESSOR"))
            except Exception as exc:
                raise ContractError("DATA_INTEGRITY_FAILED", "invalid preprocessing marker") from exc
        else:
            data_lines.append(line)
    clean = b"".join(data_lines)
    operator = task["operatorId"]
    if operator in EVALUATION_OPERATORS:
        report = _metric_report(clean)
        return [Output("REPORT", report, "EVALUATION_METRICS")]
    if operator in REPORT_OPERATORS:
        report = _structured_report(clean, REPORT_OPERATORS[operator])
        return [Output("REPORT", report, REPORT_OPERATORS[operator])]
    outputs = [Output("DATA", clean)] if clean.strip() else []
    outputs.extend(model_outputs)
    if not outputs:
        raise ContractError("CONTRACT_INVALID", "program produced no classified output")
    return outputs


def _metric_report(content):
    if len(content) > MAX_REPORT_BYTES:
        raise ContractError("PAYLOAD_TOO_LARGE", "report exceeds 1 MiB")
    rows = list(csv.DictReader(content.decode("utf-8").splitlines()))
    allowed = {"accuracy", "precision", "recall", "f1", "auc", "true_positive",
               "true_negative", "false_positive", "false_negative", "mae", "rmse", "r2", "n"}
    metrics = {}
    for row in rows:
        if set(row) != {"metric", "value"} or row["metric"] not in allowed \
                or row["metric"] in metrics:
            raise ContractError("CONTRACT_INVALID", "evaluation report structure is not whitelisted")
        try:
            number = float(row["value"])
            metrics[row["metric"]] = int(number) if row["metric"] == "n" else number
        except (TypeError, ValueError) as exc:
            raise ContractError("CONTRACT_INVALID", "evaluation metric is not numeric") from exc
    if not metrics:
        raise ContractError("CONTRACT_INVALID", "evaluation report is empty")
    return {"metrics": metrics}


def _structured_report(content, report_kind):
    if len(content) > MAX_REPORT_BYTES:
        raise ContractError("PAYLOAD_TOO_LARGE", "report exceeds 1 MiB")
    try:
        parsed = json.loads(content.decode("utf-8"))
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", report_kind + " report must be JSON") from exc
    if not isinstance(parsed, dict):
        raise ContractError("CONTRACT_INVALID", report_kind + " report must be an object")
    if report_kind == "FEATURE_IMPORTANCE":
        features = parsed.get("features")
        if not isinstance(features, list) or any(not isinstance(item, dict)
                or set(item) != {"feature", "importance"}
                or not isinstance(item["feature"], str)
                or not isinstance(item["importance"], (int, float)) for item in features):
            raise ContractError("CONTRACT_INVALID", "feature importance structure is not whitelisted")
    elif report_kind == "TREE_STRUCTURE":
        if set(parsed) - {"format", "tree", "nodeCount", "maxDepth"}:
            raise ContractError("CONTRACT_INVALID", "tree report structure is not whitelisted")
        if parsed.get("format") not in {"json-tree-v1", "text-tree-v1"}:
            raise ContractError("CONTRACT_INVALID", "tree report format is not whitelisted")
    return parsed


def _execute_tree_report(task, input_paths, root, exec_uid, exec_gid):
    # 反序列化只在无身份凭据的非 root 子进程内进行，父进程只接收白名单 JSON。
    parameters = task["program"]["parameters"]
    evaluation = task["operatorId"] == "report.model_evaluation"
    if len(input_paths) != 1 or parameters.get("inputKinds") != (["DATA"] if evaluation else ["MODEL"]):
        raise ContractError("CONTRACT_INVALID", "tree report requires one MODEL input")
    output_path = root / "tree-report.json"
    command = [sys.executable, str(Path(__file__).with_name("tee_tree_report_cli.py")),
               str(input_paths[0]), str(output_path), json.dumps(parameters, separators=(",", ":"))]
    _run(command, root, exec_uid, exec_gid)
    if not output_path.is_file() or output_path.is_symlink():
        raise ContractError("CONTRACT_INVALID", "tree report output is missing")
    os.chown(output_path, 0, 0)
    output_path.chmod(0o400)
    if output_path.stat().st_size > MAX_REPORT_BYTES:
        raise ContractError("PAYLOAD_TOO_LARGE", "tree report exceeds 1 MiB")
    parsed = json.loads(output_path.read_text(encoding="utf-8"))
    if set(parsed) == {"errorCode"}:
        code = parsed["errorCode"]
        raise ContractError(code if code in {"CONTRACT_INVALID", "PAYLOAD_TOO_LARGE", "POLICY_DENIED"}
                            else "CONTRACT_INVALID", "trusted tree report failed")
    if evaluation:
        from tee_evaluation_report import validate_evaluation
        validate_evaluation(parsed)
        return Output("REPORT", parsed, "EVALUATION_METRICS")
    from tee_tree_report_validation import validate_report
    validate_report(parsed, task["columns"])
    return Output("REPORT", parsed, "TREE_STRUCTURE")


def _execute_model_predict(inputs, parameters):
    """Load an encrypted joblib model and score API rows inside the trusted runtime."""
    if len(inputs) != 2:
        raise ContractError("CONTRACT_INVALID", "model prediction requires DATA and MODEL inputs")
    if parameters.get("inputKinds") != ["DATA", "MODEL"]:
        raise ContractError("CONTRACT_INVALID", "model prediction input kinds are invalid")
    features = parameters.get("features")
    if not isinstance(features, list) or not features or len(set(features)) != len(features) \
            or any(not isinstance(value, str) or not value for value in features):
        raise ContractError("CONTRACT_INVALID", "model features are invalid")
    max_rows = parameters.get("maxRows", 1000)
    if not isinstance(max_rows, int) or isinstance(max_rows, bool) or max_rows <= 0 or max_rows > 1000:
        raise ContractError("CONTRACT_INVALID", "model prediction row limit is invalid")
    try:
        import io
        import joblib
        import pandas as pd
        frame = pd.read_csv(io.BytesIO(bytes(inputs[0])), encoding="utf-8")
        if frame.empty or len(frame) > max_rows:
            raise ContractError("PAYLOAD_TOO_LARGE", "model prediction rows exceed signed limit")
        if any(name not in frame.columns for name in features):
            raise ContractError("POLICY_DENIED", "model feature is unavailable")
        model = joblib.load(io.BytesIO(bytes(inputs[1])))
        selected = frame[features]
        predicted = model.predict(selected)
        header = ["cluster" if str(parameters.get("modelKind") or "") == "kmeans" else "pred"]
        rows = [[_json_scalar(value)] for value in predicted]
        if str(parameters.get("task") or "") == "classification" and hasattr(model, "predict_proba"):
            probabilities = model.predict_proba(selected)
            if getattr(probabilities, "ndim", 0) == 2 and probabilities.shape[1] == 2:
                header.append("pred_prob")
                for index, value in enumerate(probabilities[:, 1]):
                    rows[index].append(_json_scalar(value))
        report = {"header": header, "rows": rows, "resultRows": len(rows)}
        encoded = json.dumps(report, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if len(encoded) > MAX_REPORT_BYTES:
            raise ContractError("PAYLOAD_TOO_LARGE", "model prediction report exceeds 1 MiB")
        return Output("REPORT", report, "MODEL_API_PREDICTION")
    except ContractError:
        raise
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", "trusted model prediction failed") from exc


def _json_scalar(value):
    if hasattr(value, "item"):
        value = value.item()
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return str(value)
