"""实际训练、跨进程重载、可信预测及评估报告的端到端组件测试。"""
import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import accuracy_score, mean_squared_error

from deep_learning_models import TabularNeuralModel
from modeling_ops import run
from tee_evaluation_report import evaluate
from tee_execution import _classify, _execute_model_predict


class DeepLearningTest(unittest.TestCase):
    def frame(self, regression=False):
        rng = np.random.default_rng(7)
        values = rng.normal(size=(96, 3))
        frame = pd.DataFrame(values, columns=["age", "income", "tenure_months"])
        score = values.mean(axis=1)
        frame["label"] = 100 + 30 * score if regression else (score > 0).astype(int)
        return frame

    def test_training_weights_reports_and_trusted_prediction(self):
        for kind in ("cnn", "rnn", "lstm", "dnn", "decision_tree"):
            for task in ("classification", "regression"):
                with self.subTest(kind=kind, task=task), tempfile.TemporaryDirectory() as directory:
                    frame = self.frame(task == "regression")
                    source, result = Path(directory)/"input.csv", Path(directory)/"output.csv"
                    frame.to_csv(source, index=False)
                    params = {"op": "ml."+kind, "features": list(frame.columns[:-1]),
                              "label": "label", "task": task, "epochs": 50, "max_iter": 500}
                    rows, has_model = run(params["op"], str(source), str(result), params)
                    self.assertEqual(len(frame), rows)
                    self.assertTrue(has_model)
                    outputs = _classify({"operatorId": params["op"]}, result.read_bytes())
                    model_content = next(o.content for o in outputs if o.kind == "MODEL")
                    data = next(o.content for o in outputs if o.kind == "DATA")
                    model = joblib.load(io.BytesIO(model_content))
                    predicted = pd.read_csv(io.BytesIO(data))
                    if kind in ("cnn", "rnn", "lstm"):
                        self.assertTrue(model.state_dict_)
                        self.assertTrue(all(isinstance(v, np.ndarray) for v in model.state_dict_.values()))
                        np.testing.assert_allclose(model.predict(frame[list(reversed(params["features"]))]),
                                                   predicted["pred"], rtol=1e-5, atol=1e-5)
                    report = evaluate(data, {"label": "label", "taskType": task})["metrics"]
                    self.assertEqual(len(frame), report["n"])
                    if task == "classification":
                        self.assertAlmostEqual(accuracy_score(frame.label, predicted.pred), report["accuracy"])
                        if kind in ("cnn", "rnn", "lstm"):
                            self.assertGreater(report["accuracy"], 0.65)
                        self.assertTrue(predicted.pred_prob.between(0, 1).all())
                    else:
                        self.assertAlmostEqual(mean_squared_error(frame.label, predicted.pred)**0.5, report["rmse"])
                        if kind in ("cnn", "rnn", "lstm"):
                            self.assertLess(report["rmse"], float(frame.label.std()))
                    binding = {"inputKinds": ["DATA", "MODEL"], "features": params["features"],
                               "modelKind": kind, "task": task, "maxRows": 100}
                    scored = _execute_model_predict([source.read_bytes(), model_content], binding)
                    np.testing.assert_allclose(np.asarray(scored.content["rows"])[:, 0], predicted.pred,
                                               rtol=1e-5, atol=1e-5)
                    path = Path(directory)/"model.pkl"
                    path.write_bytes(model_content)
                    script = ("import joblib,pandas as pd,json,sys; "
                              "m=joblib.load(sys.argv[1]); f=pd.read_csv(sys.argv[2]); "
                              "print(json.dumps(m.predict(f[sys.argv[3:]]).tolist()))")
                    fresh = subprocess.check_output([sys.executable, "-c", script, str(path), str(source),
                                                     *params["features"]], text=True)
                    np.testing.assert_allclose(json.loads(fresh), predicted.pred, rtol=1e-5, atol=1e-5)
                    print(json.dumps({"kind":kind,"task":task,"bytes":len(model_content),"metrics":report}), flush=True)

    def test_rejects_invalid_labels_and_hyperparameters(self):
        frame = self.frame()
        for target in (np.zeros(len(frame)), np.full(len(frame), 0.7), np.full(len(frame), np.nan)):
            with self.assertRaises(ValueError):
                TabularNeuralModel("cnn").fit(frame.iloc[:, :3], target)
        for params in ({"epochs": 0}, {"epochs": 1.5}, {"epochs": 501},
                       {"learning_rate": float("nan")}, {"learning_rate": -1}, {"task": "unknown"}):
            with self.assertRaises(ValueError):
                TabularNeuralModel("cnn", **params)

    def test_operator_rejects_invalid_feature_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"input.csv"
            self.frame().to_csv(path, index=False)
            for features in ([], ["missing"], ["age", "age"], ["label"]):
                with self.assertRaises(ValueError):
                    run("ml.cnn", str(path), str(Path(directory)/"output.csv"),
                        {"op": "ml.cnn", "features": features, "label": "label"})

    def test_single_feature_missing_values_and_row_independence(self):
        frame = self.frame()
        frame.loc[0, "age"] = np.nan
        for kind in ("cnn", "rnn", "lstm"):
            model = TabularNeuralModel(kind, epochs=2).fit(frame[["age"]], frame.label)
            np.testing.assert_array_equal(model.predict(frame[["age"]].iloc[::-1]), model.predict(frame[["age"]])[::-1])
            with self.assertRaises(ValueError):
                model.predict(frame[["income"]])


if __name__ == "__main__":
    unittest.main()
