#!/usr/bin/env python3
"""树报告解析器的真实小模型和参数边界测试。"""

import io
import copy
import os
import stat
import tempfile
from datetime import datetime, timezone
from pathlib import Path
import unittest

try:
    from tee_contract_runtime import ContractError, validate_task_spec
    from tee_execution import _execute_tree_report
    from tee_tree_report import parse_tree
    from tee_tree_report_validation import validate_report
    _IMPORT_ERROR = None
except ModuleNotFoundError as exc:
    # 本机开发环境可以没有 TEE 镜像中的密码学依赖，交给镜像执行真实测试。
    ContractError = None
    validate_task_spec = None
    _execute_tree_report = None
    parse_tree = None
    validate_report = None
    _IMPORT_ERROR = exc

try:
    import xgboost as xgb
except (ImportError, OSError):
    xgb = None

try:
    import lightgbm as lgb
except (ImportError, OSError):
    lgb = None


def _joblib_bytes(model):
    import joblib

    if hasattr(joblib, "dumps"):
        return joblib.dumps(model)
    stream = io.BytesIO()
    joblib.dump(model, stream)
    return stream.getvalue()


@unittest.skipIf(_IMPORT_ERROR is not None, "TEE 镜像依赖未安装: %s" % _IMPORT_ERROR)
class TeeTreeReportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from sklearn.tree import DecisionTreeClassifier
        except ImportError:
            cls.model = None
            return
        cls.model = DecisionTreeClassifier(max_depth=2, random_state=0)
        cls.model.fit([[0.0, 1.0], [1.0, 0.0], [2.0, 1.0], [3.0, 0.0]], [0, 0, 1, 1])

    def test_real_sklearn_tree_has_compatible_nodes(self):
        if self.model is None:
            self.skipTest("sklearn is supplied by the TEE image")
        report = parse_tree(_joblib_bytes(self.model), {
            "features": ["age", "income"],
            "modelKind": "ml.decision_tree",
            "treeIndex": 0,
        })
        self.assertIs(validate_report(report, ["age", "income"]), report)
        self.assertEqual(report["kind"], "SKLEARN_TREE")
        self.assertEqual(report["treeIndex"], 0)
        self.assertFalse(report["truncated"])
        self.assertGreater(report["nodeCount"], 1)
        self.assertEqual(report["totalNodeCount"], report["nodeCount"])
        expected = {"nodeId", "feature", "threshold", "leftChild", "rightChild",
                    "value", "samples", "depth", "isLeaf", "missingChild",
                    "missingDirection", "splitType", "comparison", "categories",
                    "truncatedChildren"}
        for node in report["nodes"]:
            self.assertTrue(expected.issubset(node))
            self.assertIn(node["splitType"], (None, "numerical"))
            if node["isLeaf"]:
                self.assertIsNone(node["leftChild"])
                self.assertIsNone(node["rightChild"])

    def test_rejects_bad_tree_index_values(self):
        if self.model is None:
            self.skipTest("sklearn is supplied by the TEE image")
        model_bytes = _joblib_bytes(self.model)
        for value in (-1, True, 1.5, "0"):
            with self.subTest(treeIndex=value):
                with self.assertRaises(ContractError) as context:
                    parse_tree(model_bytes, {"features": ["age", "income"],
                                              "modelKind": "decision_tree", "treeIndex": value})
                self.assertEqual(context.exception.error_code, "CONTRACT_INVALID")

    def test_rejects_missing_or_duplicate_features(self):
        if self.model is None:
            self.skipTest("sklearn is supplied by the TEE image")
        model_bytes = _joblib_bytes(self.model)
        for features in ([], ["age", "age"], ["age", 1]):
            with self.subTest(features=features):
                with self.assertRaises(ContractError) as context:
                    parse_tree(model_bytes, {"features": features, "treeIndex": 0})
                self.assertEqual(context.exception.error_code, "CONTRACT_INVALID")

    def test_rejects_model_kind_mismatch(self):
        if self.model is None:
            self.skipTest("sklearn is supplied by the TEE image")
        with self.assertRaises(ContractError) as context:
            parse_tree(_joblib_bytes(self.model), {"features": ["age", "income"],
                                                   "modelKind": "xgboost", "treeIndex": 0})
        self.assertEqual(context.exception.error_code, "CONTRACT_INVALID")

    def test_parent_validator_rejects_malicious_tree_fields(self):
        if self.model is None:
            self.skipTest("sklearn is supplied by the TEE image")
        report = parse_tree(_joblib_bytes(self.model), {
            "features": ["age", "income"], "modelKind": "decision_tree", "treeIndex": 0,
        })
        for mutate in (
            lambda item: item["nodes"][0].update({"modelBytes": "secret"}),
            lambda item: item["nodes"][0].update({"missingChild": "deleted"}),
            lambda item: item.update({"truncated": True, "truncatedNodeCount": 0}),
        ):
            candidate = copy.deepcopy(report)
            mutate(candidate)
            with self.assertRaises(ContractError) as context:
                validate_report(candidate, ["age", "income"])
            self.assertEqual(context.exception.error_code, "CONTRACT_INVALID")

    def test_execute_tree_report_uses_isolated_cli_and_fixed_output(self):
        """验证上游解密后的 MODEL 路径到非 root CLI 输出的真实链路。"""
        if self.model is None:
            self.skipTest("sklearn is supplied by the TEE image")
        if os.geteuid() != 0:
            self.skipTest("integrated child identity test requires the TEE parent to be root")
        exec_uid, exec_gid = 65532, 65532
        with tempfile.TemporaryDirectory(prefix="tree-report-test-") as directory:
            root = Path(directory)
            os.chown(root, 0, exec_gid)
            os.chmod(root, 0o770)
            model_path = root / "input-0"
            with open(model_path, "wb") as stream:
                stream.write(_joblib_bytes(self.model))
            os.chown(model_path, exec_uid, exec_gid)
            os.chmod(model_path, 0o400)
            task = {
                "columns": ["age", "income"],
                "program": {"parameters": {
                    "inputKinds": ["MODEL"], "features": ["age", "income"],
                    "modelKind": "decision_tree", "treeIndex": 0,
                    "parserVersion": "tree-report/1",
                }},
            }
            output = _execute_tree_report(task, [model_path], root, exec_uid, exec_gid)
            self.assertEqual(output.kind, "REPORT")
            self.assertEqual(output.report_kind, "TREE_STRUCTURE")
            self.assertIs(validate_report(output.content, ["age", "income"]), output.content)
            self.assertEqual(output.content["kind"], "SKLEARN_TREE")
            output_path = root / "tree-report.json"
            self.assertTrue(output_path.is_file())
            output_mode = stat.S_IMODE(output_path.stat().st_mode)
            self.assertEqual(output_mode, 0o400)

    @unittest.skipUnless(xgb is not None, "XGBoost 由 TEE 镜像提供")
    def test_real_xgboost_tree_has_compatible_nodes(self):
        model = xgb.XGBClassifier(n_estimators=2, max_depth=2, learning_rate=0.5,
                                  n_jobs=1, random_state=0, verbosity=0)
        model.fit([[0.0, 1.0], [1.0, 0.0], [2.0, 1.0], [3.0, 0.0]], [0, 0, 1, 1])
        report = parse_tree(_joblib_bytes(model), {
            "features": ["age", "income"], "modelKind": "xgboost", "treeIndex": 0,
        })
        self.assertIs(validate_report(report, ["age", "income"]), report)
        self.assertEqual(report["kind"], "XGBOOST")
        self.assertGreater(report["nodeCount"], 0)
        self.assertTrue(any(node["isLeaf"] for node in report["nodes"]))
        self.assertTrue(all(node["nodeId"] is not None for node in report["nodes"]))

    @unittest.skipUnless(lgb is not None, "LightGBM 由 TEE 镜像提供")
    def test_real_lightgbm_tree_has_compatible_nodes(self):
        model = lgb.LGBMClassifier(n_estimators=2, num_leaves=4, learning_rate=0.5,
                                   n_jobs=1, random_state=0, verbosity=-1)
        model.fit([[0.0, 1.0], [1.0, 0.0], [2.0, 1.0], [3.0, 0.0]], [0, 0, 1, 1])
        report = parse_tree(_joblib_bytes(model), {
            "features": ["age", "income"], "modelKind": "lightgbm", "treeIndex": 0,
        })
        self.assertIs(validate_report(report, ["age", "income"]), report)
        self.assertEqual(report["kind"], "LIGHTGBM")
        self.assertGreater(report["nodeCount"], 0)
        self.assertTrue(any(node["isLeaf"] for node in report["nodes"]))
        self.assertTrue(all(node["nodeId"] is not None for node in report["nodes"]))

    def test_contract_v2_tree_report_binding_is_valid(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        task = self._v2_task()
        validate_task_spec(task, "tee-audience", task["runtimeImageDigest"], now=now)

    def test_contract_v2_tree_report_binding_rejects_tampering(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        for mutate in (
            lambda task: task["program"]["parameters"].update({"inputKinds": ["DATA"]}),
            lambda task: task["program"]["parameters"].update({"parserVersion": "tree-report/2"}),
            lambda task: task["outputPolicy"].update({"reportKinds": ["FEATURE_IMPORTANCE"]}),
            lambda task: task.update({"columns": ["age"]}),
        ):
            task = self._v2_task()
            mutate(task)
            with self.assertRaises(ContractError) as context:
                validate_task_spec(task, "tee-audience", task["runtimeImageDigest"], now=now)
            self.assertEqual(context.exception.error_code, "CONTRACT_INVALID")

    @staticmethod
    def _v2_task():
        digest = "a" * 64
        features = ["age", "income"]
        return {
            "contractVersion": "tee-contract/2.0",
            "taskId": "tree-task",
            "requestId": "tree-request",
            "issuer": "center",
            "audience": "tee-audience",
            "sandboxId": "sandbox",
            "operatorId": "report.tree_structure",
            "nonce": "tree-nonce",
            "runtimeImageDigest": digest,
            "issuedAt": "2026-01-01T00:00:00Z",
            "expiresAt": "2026-01-01T00:04:00Z",
            "columns": features,
            "inputs": [{
                "assetId": "asset-model",
                "keyId": "key-model",
                "policyId": "policy-model",
                "objectId": "object-model",
                "assetVersion": 1,
                "keyVersion": 1,
                "policyVersion": 1,
                "plaintextBytes": 128,
                "ciphertextSha256": digest,
            }],
            "program": {
                "kind": "BUILTIN",
                "sha256": digest,
                "parameters": {
                    "op": "report.tree_structure",
                    "inputKinds": ["MODEL"],
                    "features": features,
                    "modelKind": "decision_tree",
                    "treeIndex": 0,
                    "parserVersion": "tree-report/1",
                },
            },
            "outputPolicy": {
                "encryptData": True,
                "encryptModel": True,
                "exportRequiresAllContributors": True,
                "reportKinds": ["TREE_STRUCTURE"],
            },
        }


if __name__ == "__main__":
    unittest.main()
