#!/usr/bin/env python3
"""在可信执行侧把 joblib 树模型转换成受限的 JSON 树报告。

模型反序列化和本模块的调用边界由可信运行时负责。本模块只读取模型的
结构化树属性，输出固定字段；不会把模型对象、训练数据或任意对象属性放入
报告。XGBoost 和 LightGBM 的树结构接口随版本变化，因此适配代码集中在本
文件内，便于在运行镜像中和相应库版本一起测试。
"""

import io
import json
import math
from collections.abc import Mapping, Sequence

from tee_contract_runtime import ContractError


MAX_NODES = 800
MAX_REPORT_BYTES = 1024 * 1024
REPORT_SCHEMA = "tree-report-v1"

_SKLEARN_KINDS = {
    "decision_tree", "ml.decision_tree", "sklearn", "sklearn_tree",
    "random_forest", "extra_trees", "gradient_boosting", "random_forest_regressor",
    "random_forest_classifier", "extra_trees_regressor", "extra_trees_classifier",
    "sklearn_tree_ensemble", "sklearn_ensemble",
}
_XGBOOST_KINDS = {"xgboost", "ml.xgboost", "xgb", "xgboost_tree"}
_LIGHTGBM_KINDS = {"lightgbm", "ml.lightgbm", "lgbm", "lightgbm_tree"}


def parse_tree(model_bytes, parameters):
    """解析一棵授权树并返回白名单字典。

    ``treeIndex`` 是从零开始的非负 Python ``int``，不能是 bool、浮点数或
    数字字符串。``features`` 是训练时的有序特征清单，优先用于把数值特征
    索引映射成授权名称。所有返回值均经过有限数值和 JSON 可编码性处理。
    """
    features, model_kind, tree_index = _validate_parameters(parameters)
    if not isinstance(model_bytes, (bytes, bytearray, memoryview)):
        raise ContractError("CONTRACT_INVALID", "model bytes are required")
    try:
        import joblib

        model = joblib.load(io.BytesIO(bytes(model_bytes)))
    except ContractError:
        raise
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", "trusted tree model could not be loaded") from exc

    try:
        kind, tree, tree_count = _select_tree(model, model_kind, tree_index)
        if kind == "SKLEARN_TREE":
            nodes, total_count = _from_sklearn(tree, features)
        elif kind == "XGBOOST":
            nodes, total_count = _from_xgboost(tree, features, tree_index)
        else:
            nodes, total_count = _from_lightgbm(tree, features, tree_index)
    except ContractError:
        raise
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", "trusted tree model could not be parsed") from exc

    _finish_children(nodes)
    truncated = total_count > len(nodes)
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "kind": kind,
        "treeIndex": tree_index,
        "treeCount": tree_count,
        "nodeCount": len(nodes),
        "totalNodeCount": total_count,
        "leafCount": sum(1 for node in nodes if node["isLeaf"]),
        "maxDepth": max((node["depth"] for node in nodes), default=None),
        "truncated": truncated,
        "truncatedNodeCount": max(total_count - len(nodes), 0),
        "nodes": nodes,
    }
    _check_json_size(report)
    return report


def _validate_parameters(parameters):
    if not isinstance(parameters, Mapping):
        raise ContractError("CONTRACT_INVALID", "tree parameters must be an object")
    features = parameters.get("features")
    if (not isinstance(features, list) or not features or len(set(features)) != len(features)
            or any(not isinstance(feature, str) or not feature for feature in features)):
        raise ContractError("CONTRACT_INVALID", "tree features are invalid")
    tree_index = parameters.get("treeIndex", 0)
    if (not isinstance(tree_index, int) or isinstance(tree_index, bool) or tree_index < 0):
        raise ContractError("CONTRACT_INVALID", "treeIndex must be a non-negative integer")
    model_kind = parameters.get("modelKind")
    if model_kind is not None and (not isinstance(model_kind, str) or not model_kind.strip()):
        raise ContractError("CONTRACT_INVALID", "modelKind is invalid")
    return features, _normalise_kind(model_kind), tree_index


def _normalise_kind(model_kind):
    if model_kind is None:
        return None
    value = model_kind.strip().lower()
    if value in _SKLEARN_KINDS:
        return "SKLEARN_TREE"
    if value in _XGBOOST_KINDS:
        return "XGBOOST"
    if value in _LIGHTGBM_KINDS:
        return "LIGHTGBM"
    raise ContractError("CONTRACT_INVALID", "unsupported modelKind")


def _select_tree(model, requested_kind, tree_index):
    has_sklearn_tree = hasattr(model, "tree_") and _looks_like_sklearn_tree(model.tree_)
    estimators = getattr(model, "estimators_", None)
    has_sklearn_ensemble = estimators is not None and _safe_len(estimators) > 0
    has_xgboost = callable(getattr(model, "get_booster", None))
    has_lightgbm = hasattr(model, "booster_") and callable(getattr(model.booster_, "dump_model", None))

    if requested_kind == "SKLEARN_TREE" or requested_kind is None and (has_sklearn_tree or has_sklearn_ensemble):
        if has_sklearn_tree:
            if tree_index != 0:
                raise ContractError("CONTRACT_INVALID", "treeIndex is outside the sklearn tree range")
            return "SKLEARN_TREE", model.tree_, 1
        if has_sklearn_ensemble:
            tree_count = _safe_len(estimators)
            if tree_index >= tree_count:
                raise ContractError("CONTRACT_INVALID", "treeIndex is outside the sklearn ensemble range")
            estimator = estimators[tree_index]
            if isinstance(estimator, Sequence) and not isinstance(estimator, (str, bytes)):
                if not estimator:
                    raise ContractError("CONTRACT_INVALID", "sklearn ensemble tree is empty")
                estimator = estimator[0]
            tree = getattr(estimator, "tree_", None)
            if not _looks_like_sklearn_tree(tree):
                raise ContractError("CONTRACT_INVALID", "sklearn ensemble tree is unsupported")
            return "SKLEARN_TREE", tree, tree_count
        if requested_kind == "SKLEARN_TREE":
            raise ContractError("CONTRACT_INVALID", "model is not a supported sklearn tree")

    if requested_kind == "XGBOOST" or requested_kind is None and has_xgboost:
        if not has_xgboost:
            raise ContractError("CONTRACT_INVALID", "model is not an XGBoost tree model")
        booster = model.get_booster()
        tree_count = _xgboost_tree_count(booster)
        if tree_count is not None and tree_index >= tree_count:
            raise ContractError("CONTRACT_INVALID", "treeIndex is outside the XGBoost tree range")
        return "XGBOOST", model, tree_count

    if requested_kind == "LIGHTGBM" or requested_kind is None and has_lightgbm:
        if not has_lightgbm:
            raise ContractError("CONTRACT_INVALID", "model is not a LightGBM tree model")
        trees = model.booster_.dump_model().get("tree_info", [])
        if not isinstance(trees, list) or tree_index >= len(trees):
            raise ContractError("CONTRACT_INVALID", "treeIndex is outside the LightGBM tree range")
        return "LIGHTGBM", model, len(trees)

    raise ContractError("CONTRACT_INVALID", "model kind does not match the joblib model")


def _safe_len(value):
    try:
        return len(value)
    except Exception:
        return 0


def _looks_like_sklearn_tree(tree):
    return (tree is not None and hasattr(tree, "children_left") and hasattr(tree, "children_right")
            and hasattr(tree, "feature") and hasattr(tree, "threshold"))


def _from_sklearn(tree, features):
    total_count = int(getattr(tree, "node_count", len(tree.children_left)))
    if total_count <= 0:
        raise ContractError("CONTRACT_INVALID", "sklearn tree is empty")
    nodes = []
    stack = [(0, 0)]
    while stack and len(nodes) < MAX_NODES:
        node_id, depth = stack.pop()
        left = _child_id(tree.children_left[node_id])
        right = _child_id(tree.children_right[node_id])
        is_leaf = left is None and right is None
        feature_index = _integer_or_none(tree.feature[node_id])
        entry = _base_node(node_id, depth, is_leaf)
        entry.update({
            "feature": "" if is_leaf else _feature_name(feature_index, features),
            "threshold": None if is_leaf else _number(tree.threshold[node_id]),
            "leftChild": left,
            "rightChild": right,
            "value": _json_value(tree.value[node_id]) if hasattr(tree, "value") else None,
            "samples": _integer_or_none(tree.n_node_samples[node_id])
                if hasattr(tree, "n_node_samples") else None,
            "splitType": "numerical" if not is_leaf else None,
            "comparison": "le" if not is_leaf else None,
            "missingChild": None,
            "missingDirection": None,
            "categories": None,
        })
        missing_left = getattr(tree, "missing_go_to_left", None)
        if not is_leaf and missing_left is not None:
            missing_left = bool(missing_left[node_id])
            entry["missingDirection"] = "left" if missing_left else "right"
            entry["missingChild"] = left if missing_left else right
        nodes.append(entry)
        if not is_leaf:
            # 压栈顺序固定为先左后右的深度优先遍历，输出顺序稳定且可复现。
            if right is not None:
                stack.append((right, depth + 1))
            if left is not None:
                stack.append((left, depth + 1))
    return nodes, total_count


def _from_xgboost(model, features, tree_index):
    try:
        frame = model.get_booster().trees_to_dataframe()
        rows = [row for _, row in frame.iterrows() if _same_tree(row.get("Tree"), tree_index)]
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", "XGBoost tree export is unavailable") from exc
    if not rows:
        raise ContractError("CONTRACT_INVALID", "XGBoost tree is empty")
    total_count = len(rows)
    selected = rows[:MAX_NODES]
    ids = {_text(row.get("ID")) for row in selected}
    nodes = []
    for row in selected:
        node_id = _text(row.get("ID"))
        feature_raw = row.get("Feature")
        # 类别分裂在部分 XGBoost 版本中 Split 为 NaN，不能据此判定为叶节点。
        is_leaf = str(feature_raw).strip() == "Leaf"
        category_values = _categories(row.get("Category"))
        if category_values is not None:
            is_leaf = False
        left = _optional_text(row.get("Yes"))
        right = _optional_text(row.get("No"))
        missing = _optional_text(row.get("Missing"))
        entry = _base_node(node_id, None, is_leaf)
        entry.update({
            "feature": "" if is_leaf else _xgb_feature_name(feature_raw, features),
            "threshold": None if is_leaf else _number(row.get("Split")),
            "leftChild": left if left in ids else None,
            "rightChild": right if right in ids else None,
            "value": (_number(row.get("Leaf")) if row.get("Leaf") is not None
                       else _number(row.get("Gain"))) if is_leaf else _number(row.get("Gain")),
            "samples": None,
            "splitType": None if is_leaf else ("categorical" if category_values is not None else "numerical"),
            "comparison": None if is_leaf else ("in" if category_values is not None else "le"),
            "missingChild": missing if missing in ids else None,
            "missingDirection": _branch_direction(missing, left, right),
            "categories": category_values,
            "cover": _number(row.get("Cover")),
        })
        nodes.append(entry)
    _assign_depths(nodes)
    return nodes, total_count


def _from_lightgbm(model, features, tree_index):
    try:
        trees = model.booster_.dump_model().get("tree_info", [])
        root = trees[tree_index].get("tree_structure")
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", "LightGBM tree export is unavailable") from exc
    if not isinstance(root, Mapping) or not root:
        raise ContractError("CONTRACT_INVALID", "LightGBM tree is empty")
    nodes = []
    total_count = 0
    stack = [(root, 0, 0)]
    while stack:
        node, depth, node_id = stack.pop()
        total_count += 1
        is_leaf = "leaf_value" in node
        left = None if is_leaf else node_id * 2 + 1
        right = None if is_leaf else node_id * 2 + 2
        if len(nodes) < MAX_NODES:
            decision_type = _optional_text(node.get("decision_type"))
            category_values = _lgb_categories(node.get("threshold"), decision_type)
            default_left = node.get("default_left")
            missing_direction = None
            missing_child = None
            if not is_leaf and isinstance(default_left, bool):
                missing_direction = "left" if default_left else "right"
                missing_child = left if default_left else right
            entry = _base_node(node_id, depth, is_leaf)
            entry.update({
                "feature": "" if is_leaf else _lgb_feature_name(node, features),
                "threshold": None if is_leaf else _lgb_threshold(node.get("threshold"), category_values),
                "leftChild": left,
                "rightChild": right,
                "value": _number(node.get("leaf_value")) if is_leaf else _number(node.get("split_gain")),
                "samples": _integer_or_none(node.get("leaf_count" if is_leaf else "internal_count")),
                "splitType": None if is_leaf else ("categorical" if category_values is not None else "numerical"),
                "comparison": None if is_leaf else _lgb_comparison(decision_type, category_values),
                "missingChild": missing_child,
                "missingDirection": missing_direction,
                "categories": category_values,
            })
            nodes.append(entry)
        if not is_leaf:
            # 与 sklearn 相同，先输出左分支，再输出右分支。
            right_node = node.get("right_child")
            left_node = node.get("left_child")
            if isinstance(right_node, Mapping):
                stack.append((right_node, depth + 1, right))
            if isinstance(left_node, Mapping):
                stack.append((left_node, depth + 1, left))
    # 由于节点 ID 是按二叉树位置生成的，截断时修正越界子引用。
    _finish_children(nodes)
    return nodes, total_count


def _base_node(node_id, depth, is_leaf):
    return {
        "nodeId": node_id,
        "feature": "",
        "threshold": None,
        "leftChild": None,
        "rightChild": None,
        "value": None,
        "samples": None,
        "depth": depth,
        "isLeaf": bool(is_leaf),
        "truncatedChildren": [],
    }


def _finish_children(nodes):
    present = {node["nodeId"] for node in nodes}
    for node in nodes:
        if node["isLeaf"]:
            node["leftChild"] = None
            node["rightChild"] = None
            continue
        original_children = {
            "left": node.get("leftChild"),
            "right": node.get("rightChild"),
        }
        for side in ("left", "right"):
            field = side + "Child"
            child = node.get(field)
            if child is not None and child not in present:
                node[field] = None
                node["truncatedChildren"].append(side)
        missing_child = node.get("missingChild")
        if missing_child is not None and missing_child not in present:
            node["missingChild"] = None
            node["missingDirection"] = None
            missing_side = next((side for side, child in original_children.items()
                                 if child == missing_child), "missing")
            if missing_side not in node["truncatedChildren"]:
                node["truncatedChildren"].append(missing_side)


def _assign_depths(nodes):
    by_id = {node["nodeId"]: node for node in nodes}
    roots = [node for node in nodes if node["nodeId"].endswith("-0")]
    if not roots:
        roots = nodes[:1]
    stack = [(node["nodeId"], 0) for node in reversed(roots)]
    visited = set()
    while stack:
        node_id, depth = stack.pop()
        if node_id in visited or node_id not in by_id:
            continue
        visited.add(node_id)
        by_id[node_id]["depth"] = depth
        for child in (by_id[node_id].get("rightChild"), by_id[node_id].get("leftChild")):
            if child in by_id:
                stack.append((child, depth + 1))


def _feature_name(index, features):
    if index is None or index < 0:
        return ""
    return features[index] if index < len(features) else "f%d" % index


def _xgb_feature_name(value, features):
    text = _optional_text(value)
    if text is None:
        return ""
    if text.startswith("f") and text[1:].isdigit():
        return _feature_name(int(text[1:]), features)
    return text if text in features else text


def _lgb_feature_name(node, features):
    index = _integer_or_none(node.get("split_feature"))
    if index is not None:
        return _feature_name(index, features)
    return _optional_text(node.get("split_feature_name")) or ""


def _same_tree(value, tree_index):
    try:
        return int(value) == tree_index
    except (TypeError, ValueError):
        return False


def _xgboost_tree_count(booster):
    try:
        frame = booster.trees_to_dataframe()
        values = {int(value) for value in frame["Tree"].tolist()}
        return len(values)
    except Exception:
        try:
            return int(booster.num_boosted_rounds())
        except Exception:
            return None


def _branch_direction(missing, left, right):
    if missing is None:
        return None
    if missing == left:
        return "left"
    if missing == right:
        return "right"
    return None


def _lgb_comparison(decision_type, categories):
    if categories is not None:
        return "in"
    if decision_type and "<=" in decision_type:
        return "le"
    if decision_type and "<" in decision_type:
        return "lt"
    return decision_type


def _lgb_categories(value, decision_type):
    if not decision_type or "==" not in decision_type:
        return None
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, str):
        return [_json_value(item) for item in value.split("||") if item != ""]
    return [_json_value(value)] if value is not None else []


def _lgb_threshold(value, categories):
    return categories if categories is not None else _number(value)


def _categories(value):
    if _is_missing_value(value):
        return None
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, str):
        return [_json_value(item) for item in value.replace("||", ",").split(",") if item.strip()]
    return [_json_value(value)]


def _is_missing_value(value):
    if value is None:
        return True
    try:
        return bool(math.isnan(float(value)))
    except (TypeError, ValueError):
        return isinstance(value, str) and value.strip().lower() in {"", "nan", "none"}


def _is_missing_number(value):
    return _is_missing_value(value)


def _optional_text(value):
    if _is_missing_value(value):
        return None
    return str(value)


def _text(value):
    text = _optional_text(value)
    return text if text is not None else ""


def _child_id(value):
    try:
        value = int(value)
    except (TypeError, ValueError):
        return None
    return None if value < 0 else value


def _integer_or_none(value):
    try:
        number = int(value)
        return number if float(value) == number else None
    except (TypeError, ValueError, OverflowError):
        return None


def _number(value):
    if _is_missing_value(value):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(number):
        return None
    return round(number, 6)


def _json_value(value):
    if hasattr(value, "tolist"):
        value = value.tolist()
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return _number(value)
    if isinstance(value, Mapping):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return [_json_value(item) for item in value]
    return str(value)


def _check_json_size(report):
    try:
        encoded = json.dumps(report, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise ContractError("CONTRACT_INVALID", "tree report contains non-JSON values") from exc
    if len(encoded) > MAX_REPORT_BYTES:
        raise ContractError("PAYLOAD_TOO_LARGE", "tree report exceeds 1 MiB")


__all__ = ["MAX_NODES", "MAX_REPORT_BYTES", "parse_tree"]
