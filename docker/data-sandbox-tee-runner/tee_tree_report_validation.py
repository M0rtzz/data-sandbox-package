"""可信父进程对树报告的第二次白名单校验。"""
import json
import math

from tee_contract_runtime import ContractError

TOP = {'schemaVersion', 'kind', 'treeIndex', 'treeCount', 'nodeCount', 'totalNodeCount',
       'leafCount', 'maxDepth', 'truncated', 'truncatedNodeCount', 'nodes'}
NODE = {'nodeId', 'feature', 'threshold', 'leftChild', 'rightChild', 'value', 'samples',
        'depth', 'isLeaf', 'truncatedChildren', 'splitType', 'comparison', 'missingChild',
        'missingDirection', 'categories', 'cover', 'gain'}
NODE_REQUIRED = NODE - {'cover', 'gain'}


def reject():
    raise ContractError('CONTRACT_INVALID', 'tree report is outside the permitted structure')


def numeric(value, depth=0):
    if value is None:
        return True
    if isinstance(value, (float, int)) and not isinstance(value, bool):
        return math.isfinite(value)
    return depth < 3 and isinstance(value, list) and all(numeric(v, depth + 1) for v in value)


def category_values(value):
    """校验类别集合只含有限数字或短文本，不接收任意对象。"""
    if not isinstance(value, list):
        return False
    for item in value:
        if isinstance(item, str):
            continue
        if isinstance(item, (float, int)) and not isinstance(item, bool) and math.isfinite(item):
            continue
        return False
    return True


def validate_report(value, features):
    if (not isinstance(value, dict) or set(value) != TOP
            or value.get('schemaVersion') != 'tree-report-v1'):
        reject()
    if value.get('kind') not in {'SKLEARN_TREE', 'XGBOOST', 'LIGHTGBM'}:
        reject()
    nodes = value.get('nodes')
    node_count = value.get('nodeCount')
    total_node_count = value.get('totalNodeCount')
    if (not isinstance(nodes, list) or not 1 <= len(nodes) <= 800
            or node_count != len(nodes) or not isinstance(node_count, int)
            or isinstance(node_count, bool) or not isinstance(total_node_count, int)
            or isinstance(total_node_count, bool) or total_node_count < node_count):
        reject()
    tree_index = value.get('treeIndex')
    if not isinstance(tree_index, int) or isinstance(tree_index, bool) or tree_index < 0:
        reject()
    tree_count = value.get('treeCount')
    if (tree_count is not None and (not isinstance(tree_count, int)
                                    or isinstance(tree_count, bool) or tree_count <= 0)):
        reject()
    if tree_count is not None and tree_index >= tree_count:
        reject()
    leaf_count = value.get('leafCount')
    max_depth = value.get('maxDepth')
    truncated = value.get('truncated')
    truncated_node_count = value.get('truncatedNodeCount')
    if (not isinstance(leaf_count, int) or isinstance(leaf_count, bool)
            or not 0 <= leaf_count <= node_count or (max_depth is not None and (
                not isinstance(max_depth, int) or isinstance(max_depth, bool) or max_depth < 0))
            or not isinstance(truncated, bool) or truncated != (total_node_count > node_count)
            or truncated_node_count != total_node_count - node_count):
        reject()
    if not isinstance(features, list) or any(not isinstance(item, str) or not item for item in features):
        reject()
    ids = set()
    for node in nodes:
        if not isinstance(node, dict) or set(node) - NODE or not NODE_REQUIRED.issubset(node):
            reject()
        node_id = node.get('nodeId')
        if not isinstance(node_id, (int, str)) or isinstance(node_id, bool) or node_id in ids:
            reject()
        ids.add(node_id)
        if not isinstance(node.get('feature'), str):
            reject()
        if node.get('feature') not in features and node.get('feature') != '':
            raise ContractError('POLICY_DENIED', 'tree report exposes an unauthorized feature')
        if (not isinstance(node.get('isLeaf'), bool)
                or not isinstance(node.get('depth'), int)
                or isinstance(node.get('depth'), bool) or node.get('depth') < 0):
            reject()
        if (node.get('threshold') is not None and not numeric(node.get('threshold'))
                and not category_values(node.get('threshold'))):
            reject()
        if not numeric(node.get('value')) or not numeric(node.get('samples')):
            reject()
        for field in ('cover', 'gain'):
            if field in node and not numeric(node.get(field)):
                reject()
        truncated_children = node.get('truncatedChildren')
        if (not isinstance(truncated_children, list)
                or len(set(truncated_children)) != len(truncated_children)
                or any(side not in {'left', 'right', 'missing'} for side in truncated_children)):
            reject()
        if node.get('splitType') not in {None, 'numerical', 'categorical'}:
            reject()
        if node.get('comparison') not in {None, 'le', 'lt', 'in', 'eq'}:
            reject()
        if node.get('missingDirection') not in {None, 'left', 'right'}:
            reject()
        categories = node.get('categories')
        if categories is not None and not category_values(categories):
            reject()
        if node.get('isLeaf'):
            if (node.get('feature') != '' or node.get('threshold') is not None
                    or node.get('leftChild') is not None or node.get('rightChild') is not None
                    or node.get('missingChild') is not None or node.get('missingDirection') is not None
                    or node.get('splitType') is not None or node.get('comparison') is not None
                    or categories is not None):
                reject()
        else:
            if node.get('splitType') is None or node.get('comparison') is None:
                reject()
            if node.get('splitType') == 'categorical' and node.get('comparison') != 'in':
                reject()
            if node.get('splitType') == 'numerical' and categories is not None:
                reject()
            if node.get('splitType') == 'categorical' and not categories:
                reject()
    parents = {}
    for node in nodes:
        truncated_children = node['truncatedChildren']
        for field in ('leftChild', 'rightChild'):
            child = node.get(field)
            if child is not None:
                if child not in ids or child in parents or child == node['nodeId']:
                    reject()
                parents[child] = node['nodeId']
            elif not node['isLeaf'] and field[:-5] not in truncated_children:
                reject()
        if node.get('missingChild') is not None and node['missingChild'] not in ids:
            reject()
        missing = node.get('missingChild')
        if missing is not None:
            if missing not in {node.get('leftChild'), node.get('rightChild')}:
                reject()
            expected = 'left' if missing == node.get('leftChild') else 'right'
            if node.get('missingDirection') != expected:
                reject()
        elif node.get('missingDirection') is not None:
            reject()
        if 'missing' in truncated_children and not value['truncated']:
            reject()
    roots = ids - parents.keys()
    if len(roots) != 1:
        reject()
    by_id = {n['nodeId']: n for n in nodes}
    visited, stack = set(), [(root, 0) for root in roots]
    while stack:
        current, expected_depth = stack.pop()
        if current in visited:
            reject()
        visited.add(current)
        node = by_id[current]
        if node['depth'] != expected_depth:
            reject()
        stack.extend((node[f], expected_depth + 1) for f in ('leftChild', 'rightChild')
                     if node.get(f) is not None)
    if visited != ids:
        reject()
    if sum(1 for node in nodes if node['isLeaf']) != leaf_count:
        reject()
    if max_depth != max(node['depth'] for node in nodes):
        reject()
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
    if len(encoded) > 1024 * 1024:
        raise ContractError('PAYLOAD_TOO_LARGE', 'tree report exceeds 1 MiB')
    return value
