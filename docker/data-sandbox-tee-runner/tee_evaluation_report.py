"""对已核实训练的密文预测结果生成固定聚合指标，原始行不离开执行侧。"""
import csv
import io
import math
from tee_contract_runtime import ContractError

ALLOWED = {'accuracy', 'precision', 'recall', 'f1', 'auc', 'true_positive',
           'true_negative', 'false_positive', 'false_negative', 'mae', 'rmse', 'r2', 'n'}


def validate_evaluation(report):
    metrics = report.get('metrics') if isinstance(report, dict) else None
    if (not isinstance(report, dict) or set(report) != {'metrics'} or not isinstance(metrics, dict)
            or not metrics or not set(metrics) <= ALLOWED
            or type(metrics.get('n')) is not int or metrics['n'] <= 0
            or any(type(value) not in (int, float) or not math.isfinite(value) for value in metrics.values())):
        raise ContractError('CONTRACT_INVALID', 'invalid aggregate evaluation report')


def evaluate(content, parameters):
    from sklearn import metrics as sk
    reader = csv.DictReader(io.StringIO(content.decode('utf-8-sig')))
    header = reader.fieldnames or []
    label = parameters.get('label')
    prediction = 'pred' if 'pred' in header else 'prediction'
    if not label or label not in header or prediction not in header:
        raise ContractError('CONTRACT_INVALID', 'training result has no bound label and prediction')
    rows = list(reader)
    if not rows:
        raise ContractError('CONTRACT_INVALID', 'training result is empty')
    actual = [row[label] for row in rows]
    predicted = [row[prediction] for row in rows]
    values = {'n': len(rows)}
    if str(parameters.get('taskType', 'classification')).lower() == 'regression':
        actual, predicted = list(map(float, actual)), list(map(float, predicted))
        values.update(mae=float(sk.mean_absolute_error(actual, predicted)),
                      rmse=float(sk.root_mean_squared_error(actual, predicted)))
        if len(rows) > 1:
            values['r2'] = float(sk.r2_score(actual, predicted))
    else:
        # 历史输出可能将整数标签写成 1.0；只规范化数字，不改写其他类别值。
        def normalize(value):
            try:
                number = float(value)
                return str(int(number)) if number.is_integer() else str(number)
            except ValueError:
                return value
        actual, predicted = list(map(normalize, actual)), list(map(normalize, predicted))
        classes = set(actual) | set(predicted)
        binary = classes <= {'0', '1'}
        average = 'binary' if binary else 'macro'
        options = {'average': average, 'zero_division': 0}
        if binary:
            options['pos_label'] = '1'
        values.update(accuracy=float(sk.accuracy_score(actual, predicted)),
                      precision=float(sk.precision_score(actual, predicted, **options)),
                      recall=float(sk.recall_score(actual, predicted, **options)),
                      f1=float(sk.f1_score(actual, predicted, **options)))
        if binary:
            tn, fp, fn, tp = sk.confusion_matrix(actual, predicted, labels=['0', '1']).ravel()
            values.update(true_positive=int(tp), true_negative=int(tn),
                          false_positive=int(fp), false_negative=int(fn))
            if 'pred_prob' in header and len(set(actual)) == 2:
                values['auc'] = float(sk.roc_auc_score([int(value) for value in actual],
                                                      [float(row['pred_prob']) for row in rows]))
    report = {'metrics': values}
    validate_evaluation(report)
    return report
