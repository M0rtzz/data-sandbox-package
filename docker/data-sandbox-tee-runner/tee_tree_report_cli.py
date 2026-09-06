#!/usr/bin/env python3
"""非 root 模型解析子进程，不接收密钥、证书或网络凭据。"""
import json
import sys
from pathlib import Path
from tee_tree_report import parse_tree
from tee_contract_runtime import ContractError

if __name__ == '__main__':
    try:
        parameters = json.loads(sys.argv[3])
        if parameters.get('op') == 'report.model_evaluation':
            from tee_evaluation_report import evaluate
            result = evaluate(Path(sys.argv[1]).read_bytes(), parameters)
        else:
            result = parse_tree(Path(sys.argv[1]).read_bytes(), parameters)
    except ContractError as error:
        result = {'errorCode': error.error_code}
    except Exception:
        result = {'errorCode': 'CONTRACT_INVALID'}
    Path(sys.argv[2]).write_text(json.dumps(result, ensure_ascii=False, allow_nan=False,
                                          separators=(',', ':')), encoding='utf-8')
