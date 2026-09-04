#!/usr/bin/env python3
import io
import base64
import unittest

import joblib

from tee_contract_runtime import ContractError
from tee_execution import _classify, _execute_model_predict


class SumModel:
    def predict(self, frame):
        return frame.sum(axis=1).to_numpy()


class TeeModelPredictionTest(unittest.TestCase):
    def model_bytes(self):
        stream = io.BytesIO()
        joblib.dump(SumModel(), stream)
        return stream.getvalue()

    def parameters(self):
        return {
            "inputKinds": ["DATA", "MODEL"],
            "features": ["a", "b"],
            "modelKind": "linear_regression",
            "task": "regression",
            "maxRows": 10,
        }

    def test_scores_rows_without_returning_input_features(self):
        output = _execute_model_predict(
            [b"a,b,secret\n1,2,x\n3,4,y\n", self.model_bytes()], self.parameters())
        self.assertEqual("MODEL_API_PREDICTION", output.report_kind)
        self.assertEqual(["pred"], output.content["header"])
        self.assertEqual([[3], [7]], output.content["rows"])
        self.assertNotIn("secret", str(output.content))

    def test_rejects_missing_bound_feature(self):
        with self.assertRaises(ContractError) as caught:
            _execute_model_predict([b"a\n1\n", self.model_bytes()], self.parameters())
        self.assertEqual("POLICY_DENIED", caught.exception.error_code)

    def test_rejects_untyped_model_input(self):
        parameters = self.parameters()
        parameters["inputKinds"] = ["DATA", "DATA"]
        with self.assertRaises(ContractError):
            _execute_model_predict([b"a,b\n1,2\n", self.model_bytes()], parameters)

    def test_model_and_preprocessor_outputs_are_distinguishable(self):
        raw = (b"a\n1\nMODELB64:," + base64.b64encode(b"model")
               + b"\nPREPROC:," + base64.b64encode(b"preprocess") + b"\n")
        outputs = _classify({"operatorId": "ml.logistic_regression"}, raw)
        artifacts = [output.artifact_type for output in outputs if output.kind == "MODEL"]
        self.assertEqual(["MODEL", "PREPROCESSOR"], artifacts)


if __name__ == "__main__":
    unittest.main()
