"""历史训练聚合评估的边界验证。"""
import unittest
from tee_evaluation_report import evaluate, validate_evaluation
from tee_contract_runtime import ContractError

class EvaluationReportTest(unittest.TestCase):
    def test_binary_metrics_and_probability(self):
        result = evaluate(b'label,pred,pred_prob\n0,0,0.1\n1,1,0.9\n1,0,0.3\n',
                          {'label': 'label', 'taskType': 'classification'})
        self.assertAlmostEqual(result['metrics']['accuracy'], 2/3)
        self.assertEqual(result['metrics']['true_positive'], 1)
        self.assertEqual(result['metrics']['false_negative'], 1)
        self.assertEqual(result['metrics']['n'], 3)
        self.assertEqual(result['metrics']['auc'], 1)
        self.assertEqual(set(result), {'metrics'})

    def test_regression(self):
        result = evaluate(b'y,pred\n1,2\n3,3\n', {'label': 'y', 'taskType': 'regression'})
        self.assertEqual(result['metrics']['mae'], .5)
        self.assertNotIn('accuracy', result['metrics'])

    def test_missing_bound_label_rejected(self):
        with self.assertRaises(ContractError):
            evaluate(b'other,pred\n1,1\n', {'label': 'label'})

    def test_rows_and_non_finite_metrics_rejected(self):
        for report in ({'metrics': {'n': 1}, 'rows': [[1]]},
                       {'metrics': {'n': 1, 'accuracy': float('nan')}},
                       {'metrics': {'n': 1, 'secret': 2}}):
            with self.assertRaises(ContractError):
                validate_evaluation(report)

    def test_evaluation_keeps_prediction_columns_but_regular_tasks_remain_filtered(self):
        from runtime_main import report_input
        raw = b'age,label,pred,pred_prob\n20,1,1,0.9\n'
        task = {'contractVersion': 'tee-contract/2.0', 'operatorId': 'report.model_evaluation',
                'columns': ['age']}
        self.assertEqual(raw, report_input(task, 'DATA', raw))
        task['contractVersion'] = 'tee-contract/1.0'
        regular = report_input(task, 'DATA', raw)
        self.assertNotIn(b'pred', regular)
        self.assertNotIn(b'label', regular)
