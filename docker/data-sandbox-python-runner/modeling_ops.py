#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Data Sandbox 建模算子函数库（智能建模与服务化闭环 / 可视化建模 DAG 节点执行）。

约定（与 python_runner 的执行契约完全一致）：
  python3 <script> --input <input.csv> --output <output.csv> --params <json> [--input-table <t>] [--jdbc-url <url>]

画布节点脚本 = 后端 CanvasOperatorRegistry 渲染的 `import modeling_ops as mops` + `mops.main()`，
算子代码从 params.op 分发（其余 params 为算子超参数，来自节点属性配置表单）。
每个算子：输入 CSV -> 输出 CSV（单一数据契约）；训练类算子（ml.*）额外在输出 CSV 末尾追加一行
  `MODELB64:,<base64(joblib)>`  标记行（不修改 python_runner，平台在取回结果时识别并剥离）。
两表算子（psi / feature_align）从沙箱 DB 快照（SANDBOX_DB_PATH，默认 /workspace/sandbox_data.db）
只读读取参考表（sqlite3 只读 URI），不依赖 runner 改动。

依赖：numpy/pandas 镜像预装；sklearn/scipy/joblib/xgboost/lightgbm 由 v2-ml 镜像预装
（这里均惰性导入，确保模块在旧镜像上 import 也不报错）。
"""
import argparse
import base64
import json
import math
import os
import re
import sys

import numpy as np
import pandas as pd

DB_PATH = os.environ.get("SANDBOX_DB_PATH", "/workspace/sandbox_data.db")
MODEL_MARKER = "MODELB64:"
PREPROC_MARKER = "PREPROC:"

# 常见类型转换 / 数值参数辅助 ----------------------------------------------------


def _num(params, key, default):
    v = params.get(key, default)
    if v is None or v == "":
        return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _int(params, key, default):
    v = params.get(key, default)
    if v is None or v == "":
        return default
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def _bool(params, key, default=True):
    v = params.get(key, default)
    if isinstance(v, str):
        return v.strip().lower() in ("true", "1", "yes", "on")
    return bool(v)


def _parse_hls(s):
    """解析 DNN 隐藏层，如 '(32,16)' / '32,16' / '32'。"""
    s = str(s).replace("(", "").replace(")", "").replace(" ", "")
    parts = [p for p in s.split(",") if p.strip()]
    return tuple(int(p) for p in parts) if parts else (32, 16)


def _cols(df, params, key="columns", default_all_numeric=True):
    """解析列选择：优先 params.columns/features，缺省取全部数值列（或全部列）。"""
    cols = params.get(key) or params.get("features") or []
    if not cols:
        if default_all_numeric:
            return list(df.select_dtypes(include=[np.number]).columns)
        return list(df.columns)
    return [c for c in cols if c in df.columns]


# 沙箱 DB 只读访问（两表算子） -----------------------------------------------------


def _table_name(t):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", t or ""):
        raise ValueError("非法表名: %r" % t)
    return t


def _db_path():
    return os.environ.get("SANDBOX_DB_PATH", DB_PATH)


def read_table(name, db_path=None):
    import sqlite3
    path = db_path or _db_path()
    conn = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
    try:
        return pd.read_sql_query('SELECT * FROM "%s"' % _table_name(name), conn)
    finally:
        conn.close()


# 输出（含 MODELB64 标记行） --------------------------------------------------------


def _b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def write_output(df, out_path, model_b64=None, preproc=None):
    """写出输出 CSV；训练算子追加 MODELB64 标记行，预处理算子追加 PREPROC(拟合参数) 标记行。"""
    df.to_csv(out_path, index=False, encoding="utf-8")
    if model_b64:
        with open(out_path, "a", encoding="utf-8") as f:
            f.write(MODEL_MARKER + "," + model_b64 + "\n")
    elif preproc:
        with open(out_path, "a", encoding="utf-8") as f:
            f.write(PREPROC_MARKER + "," + _b64(json.dumps(preproc)) + "\n")


# 数据预处理算子 --------------------------------------------------------------------


def fillna(df, params):
    """缺失值填充：mean/median/mode/zero/drop。"""
    method = params.get("method", "mean")
    cols = _cols(df, params, key="columns", default_all_numeric=False)
    if method == "drop":
        return (df.dropna(subset=cols) if cols else df.dropna()), None
    out = df.copy()
    fit = {"op": "fillna", "method": method, "values": {}}
    for c in cols:
        if method in ("mean", "median"):
            if pd.api.types.is_numeric_dtype(df[c]):
                val = getattr(out[c], method)()
                out[c] = out[c].fillna(val)
                fit["values"][c] = float(val)
        elif method == "mode":
            m = out[c].mode()
            val = m.iloc[0] if len(m) else 0
            out[c] = out[c].fillna(val)
            fit["values"][c] = float(val)
        elif method == "zero":
            out[c] = out[c].fillna(0)
            fit["values"][c] = 0
        else:
            raise ValueError("fillna: 未知 method=%s" % method)
    return out, fit


def outlier(df, params):
    """异常值剔除/截断：iqr / zscore，动作 clip（截断）或 remove（删除行）。"""
    method = params.get("method", "iqr")
    action = params.get("action", "clip")
    threshold = _num(params, "threshold", 3.0 if method == "zscore" else 1.5)
    cols = _cols(df, params, key="columns")
    out = df.copy()
    flags = pd.Series(False, index=df.index)
    fit = {"op": "outlier", "method": method, "action": action, "threshold": threshold, "bounds": {}}
    for c in cols:
        s = pd.to_numeric(out[c], errors="coerce")
        if method == "zscore":
            mu, sd = s.mean(), s.std()
            if not sd or sd == 0:
                continue
            lo, hi = mu - threshold * sd, mu + threshold * sd
        elif method == "iqr":
            q1, q3 = s.quantile(0.25), s.quantile(0.75)
            iqr = q3 - q1
            lo, hi = q1 - threshold * iqr, q3 + threshold * iqr
        else:
            raise ValueError("outlier: 未知 method=%s" % method)
        if action == "clip":
            out[c] = s.clip(lo, hi)
        else:  # remove
            flags = flags | s.lt(lo) | s.gt(hi)
        fit["bounds"][c] = {"lo": float(lo), "hi": float(hi)}
    if action == "remove":
        out = out[~flags]
    return out, fit


def unique(df, params):
    """唯一值过滤：删除常数列（仅一个唯一值）。"""
    keep = [c for c in df.columns if df[c].nunique(dropna=False) > 1]
    fit = {"op": "unique", "keep": list(df.columns), "drop": [c for c in df.columns if c not in keep]}
    return df[keep], fit


def _chi_merge_edges(col, target, max_bins):
    """卡方分箱（卡方合并法）：对数值列 + 二分类目标做有监督分箱，返回 bin 边界。"""
    d = pd.DataFrame({"v": pd.to_numeric(col, errors="coerce"),
                      "t": pd.to_numeric(target, errors="coerce")}).dropna().sort_values("v")
    if d["t"].nunique() < 2:
        raise ValueError("卡方分箱要求目标列含两个类别")
    g = d.groupby("v")["t"].agg(["sum", "count"])
    g["bad"] = g["count"] - g["sum"]
    gtot, btot = g["sum"].sum(), g["bad"].sum()
    vals = list(g.index)
    k = len(vals)
    if k < 2:
        raise ValueError("卡方分箱: 唯一值过少")
    bins = [[i] for i in range(k)]

    def _chi2(a, b):
        gg = sum(g["sum"].iloc[i] for i in a) + sum(g["sum"].iloc[i] for i in b) + 0.5
        gb = sum(g["bad"].iloc[i] for i in a) + sum(g["bad"].iloc[i] for i in b) + 0.5
        n = gg + gb
        eg = n * (gtot + 1.0) / (gtot + btot + 2.0)
        eb = n * (btot + 1.0) / (gtot + btot + 2.0)
        return (gg - eg) ** 2 / eg + (gb - eb) ** 2 / eb

    while len(bins) > max_bins:
        best_i, best_v = 0, None
        for i in range(len(bins) - 1):
            v = _chi2(bins[i], bins[i + 1])
            if best_v is None or v < best_v:
                best_v, best_i = v, i
        bins[best_i] = bins[best_i] + bins[best_i + 1]
        del bins[best_i + 1]
        if best_v >= 3.84:
            break  # 剩余相邻箱无显著差异（alpha=0.05, df=1）
    idx_map = {}
    for bi, grp in enumerate(bins):
        for j in grp:
            idx_map[j] = bi
    edges = []
    for j in range(k - 1):
        if idx_map[j] != idx_map[j + 1]:
            edges.append((vals[j] + vals[j + 1]) / 2.0)
    edges = sorted(set(edges))
    if not edges:
        raise ValueError("卡方分箱: 未产生分箱边界")
    return [float(vals[0])] + edges + [float(vals[-1])]


def binning(df, params):
    """特征分箱：quantile（等频）/ width（等宽）/ chi（卡方，需 target）。"""
    method = params.get("method", "quantile")
    bins = max(2, _int(params, "bins", 5))
    cols = _cols(df, params, key="columns")
    target = params.get("target") or params.get("label")
    out = df.copy()
    fit = {"op": "binning", "method": method, "edges": {}}
    for c in cols:
        s = pd.to_numeric(out[c], errors="coerce")
        if s.nunique() <= 1:
            continue
        edges = None
        try:
            if method == "quantile":
                out[c], edges = pd.qcut(out[c], q=min(bins, int(s.nunique())), duplicates="drop", retbins=True)
            elif method == "width":
                out[c], edges = pd.cut(out[c], bins=bins, include_lowest=True, retbins=True)
            elif method == "chi":
                if not target or target not in df.columns:
                    raise ValueError("卡方分箱需要配置 target 列")
                edges = _chi_merge_edges(out[c], out[target], bins)
                out[c] = pd.cut(out[c], bins=edges, include_lowest=True)
            else:
                raise ValueError("binning: 未知 method=%s" % method)
        except (ValueError, TypeError):
            try:
                out[c], edges = pd.cut(out[c], bins=min(bins, int(s.nunique())), include_lowest=True, retbins=True)
            except Exception:
                continue
        if edges is not None and len(edges) > 1:
            fit["edges"][c] = [float(e) for e in edges]
    return out, fit


def woe(df, params):
    """WOE 编码（有监督分箱后按好坏比取对数），原位替换目标列为 WOE 数值。"""
    target = params.get("target")
    if not target or target not in df.columns:
        raise ValueError("woe 需要配置 target 列")
    cols = _cols(df, params, key="columns")
    bins = max(2, _int(params, "bins", 5))
    out = df.copy()
    t = pd.to_numeric(out[target], errors="coerce")
    gtot = int((t == 1).sum())
    btot = int((t == 0).sum())
    if gtot == 0 or btot == 0:
        raise ValueError("woe 要求目标列含两类样本")
    for c in cols:
        s = pd.to_numeric(out[c], errors="coerce")
        try:
            binned = pd.qcut(s, q=min(bins, int(s.nunique())), duplicates="drop")
        except (ValueError, TypeError):
            binned = pd.cut(s, bins=bins, include_lowest=True)
        g = out[c].notna() & t.notna()
        grp = pd.DataFrame({"bin": binned[g], "t": t[g].astype(int)})
        stats = grp.groupby("bin", observed=True).agg(good=("t", "sum"), n=("t", "count"))
        stats["bad"] = stats["n"] - stats["good"]
        stats["p_good"] = (stats["good"] + 0.5) / (gtot + 1)
        stats["p_bad"] = (stats["bad"] + 0.5) / (btot + 1)
        stats["woe"] = np.log(stats["p_good"] / stats["p_bad"])
        out[c] = binned.map(stats["woe"]).astype(float)
    return out, None


def standardize(df, params):
    """标准化：zscore / minmax。"""
    method = params.get("method", "zscore")
    cols = _cols(df, params, key="columns")
    out = df.copy()
    fit = {"op": "standardize", "method": method, "scaler": {}}
    for c in cols:
        s = pd.to_numeric(out[c], errors="coerce")
        if method == "zscore":
            mu, sd = s.mean(), s.std()
            if sd and sd > 0:
                out[c] = (s - mu) / sd
                fit["scaler"][c] = {"mean": float(mu), "std": float(sd)}
        elif method == "minmax":
            mn, mx = s.min(), s.max()
            if mx > mn:
                out[c] = (s - mn) / (mx - mn)
                fit["scaler"][c] = {"min": float(mn), "max": float(mx)}
        else:
            raise ValueError("standardize: 未知 method=%s" % method)
    return out, fit


def derive(df, params):
    """特征派生/标签生成：expression 为按列 Series 的表达式（如 balance>1000、amount.astype(int)）。"""
    expr = params.get("expression")
    new_col = params.get("new_column") or params.get("target")
    if not expr:
        raise ValueError("derive 需要配置 expression")
    if not new_col:
        raise ValueError("derive 需要配置 new_column")
    ns = dict(df)
    ns.update({"np": np, "pd": pd})
    safe_builtins = {
        "float": float, "int": int, "str": str, "bool": bool, "abs": abs, "round": round,
        "min": min, "max": max, "len": len, "sum": sum, "True": True, "False": False, "None": None,
    }
    try:
        series = eval(expr, {"__builtins__": safe_builtins}, ns)  # noqa: S307 受限命名空间，仅列 Series 可用
    except Exception as exc:
        raise ValueError("derive 表达式错误: %s" % exc)
    series = pd.Series(series, index=df.index)
    cast = params.get("cast")
    if cast:
        series = series.astype(cast)
    out = df.copy()
    out[new_col] = series
    fit = {"op": "derive", "expression": expr, "new_column": new_col, "cast": params.get("cast")}
    return out, fit


def psi(df, params):
    """PSI（人群稳定性指数）：输入表 vs 参考表（同构资产表，DB 快照读取）。"""
    ref_table = params.get("compare_table") or params.get("reference_table")
    if not ref_table:
        raise ValueError("psi 需要配置 compare_table（参考表）")
    ref = read_table(ref_table, db_path=params.get("db_path"))
    cols = _cols(df, params, key="columns")
    rows = []
    for c in cols:
        if c not in ref.columns:
            continue
        a = pd.to_numeric(df[c], errors="coerce").dropna()
        b = pd.to_numeric(ref[c], errors="coerce").dropna()
        if len(a) < 2 or len(b) < 2:
            continue
        lo = min(float(a.min()), float(b.min()))
        hi = max(float(a.max()), float(b.max()))
        qs = np.unique(np.quantile(b.values, np.linspace(0, 1, 11)))
        edges = sorted(set([lo, hi] + [e for e in qs if lo < e < hi]))
        if len(edges) < 2:
            continue
        pa = pd.cut(a, bins=edges, include_lowest=True).value_counts(normalize=True)
        pb = pd.cut(b, bins=edges, include_lowest=True).value_counts(normalize=True)
        idx = sorted(set(pa.index) | set(pb.index), key=lambda iv: (iv.left, iv.right))
        val = 0.0
        for cat in idx:
            e = float(pb.get(cat, 0.0)) + 1e-6
            x = float(pa.get(cat, 0.0)) + 1e-6
            val += (x - e) * math.log(x / e)
        rows.append([c, round(val, 6)])
    out = pd.DataFrame(rows, columns=["column", "psi"])
    if out.empty:
        out = pd.DataFrame([["_none_", 0.0]], columns=["column", "psi"])
    return out, None


def feature_align(df, params):
    """特征对齐：比较输入表与参考表的列集合/类型/行数。"""
    ref_table = params.get("compare_table") or params.get("reference_table")
    if not ref_table:
        raise ValueError("feature_align 需要配置 compare_table（参考表）")
    ref = read_table(ref_table, db_path=params.get("db_path"))
    a_cols, b_cols = list(df.columns), list(ref.columns)
    common = [c for c in a_cols if c in b_cols]
    rows = []
    for c in common:
        rows.append([c, "common", str(df[c].dtype), str(ref[c].dtype), len(df), len(ref)])
    for c in a_cols:
        if c not in b_cols:
            rows.append([c, "missing_in_reference", str(df[c].dtype), "", len(df), len(ref)])
    for c in b_cols:
        if c not in a_cols:
            rows.append([c, "missing_in_input", "", str(ref[c].dtype), len(df), len(ref)])
    out = pd.DataFrame(rows, columns=["column", "alignment", "dtype_input",
                                      "dtype_reference", "rows_input", "rows_reference"])
    return out, None


def correlation(df, params):
    """相关系数：pearson / spearman，输出长表（列对, 值）。"""
    method = params.get("method", "pearson")
    if method not in ("pearson", "spearman"):
        raise ValueError("correlation: 未知 method=%s" % method)
    cm = df.select_dtypes(include=[np.number]).corr(method=method)
    rows = []
    cols = list(cm.columns)
    for i, a in enumerate(cols):
        for b in cols[i + 1:]:
            v = cm.loc[a, b]
            if pd.notna(v):
                rows.append([a, b, round(float(v), 6)])
    return pd.DataFrame(rows, columns=["column_a", "column_b", "value"]), None


# 机器学习训练算子 ------------------------------------------------------------------


def _joblib_dumps(model):
    """joblib.dumps（1.2+）；旧版降级为 BytesIO.dump。"""
    import joblib
    if hasattr(joblib, "dumps"):
        return joblib.dumps(model)
    from io import BytesIO
    buf = BytesIO()
    joblib.dump(model, buf)
    return buf.getvalue()


def _train_model(df, params, make, regression=False):
    features = _cols(df, params, key="features")
    label = params.get("label")
    if not label or label not in df.columns:
        raise ValueError("训练算子需要配置 label 列")
    if not features:
        raise ValueError("训练算子需要配置 features 特征列")
    X = df[features].apply(pd.to_numeric, errors="coerce").fillna(0)
    y = pd.to_numeric(df[label], errors="coerce")
    if regression:
        y = y.fillna(y.median())
        idx = y.notna()
        X, y = X[idx], y[idx]
    else:
        idx = y.notna()
        X, y = X[idx], y[idx].astype(int)
    if len(y) == 0:
        raise ValueError("标签列清洗后为空")
    model = make()
    model.fit(X, y)
    pred = model.predict(X)
    out = df.copy()
    out.loc[X.index, "pred"] = pred
    if not regression and hasattr(model, "predict_proba") and hasattr(model, "classes_"):
        try:
            if len(model.classes_) == 2:
                out.loc[X.index, "pred_prob"] = model.predict_proba(X)[:, 1]
        except Exception:
            pass
    b64 = base64.b64encode(_joblib_dumps(model)).decode("ascii")
    return out, b64


def _linear_regression(df, params):
    from sklearn.linear_model import LinearRegression
    return _train_model(df, params,
                        lambda: LinearRegression(fit_intercept=_bool(params, "fit_intercept", True)),
                        regression=True)


def _logistic_regression(df, params):
    from sklearn.linear_model import LogisticRegression
    C = _num(params, "C", 1.0)
    iters = _int(params, "max_iter", 1000)
    return _train_model(df, params,
                        lambda: LogisticRegression(C=C, max_iter=iters, solver="liblinear"),
                        regression=False)


def _knn(df, params):
    from sklearn.neighbors import KNeighborsClassifier
    k = _int(params, "n_neighbors", 5)
    return _train_model(df, params,
                        lambda: KNeighborsClassifier(n_neighbors=k, weights="distance"),
                        regression=False)


def _kmeans(df, params):
    from sklearn.cluster import KMeans
    k = _int(params, "n_clusters", 3)
    features = _cols(df, params, key="features")
    if not features:
        features = list(df.select_dtypes(include=[np.number]).columns)
    if not features:
        raise ValueError("kmeans 需要数值特征列")
    X = df[features].apply(pd.to_numeric, errors="coerce").fillna(0)
    km = KMeans(n_clusters=k, n_init=10, random_state=0,
                max_iter=_int(params, "max_iter", 300))
    km.fit(X)
    out = df.copy()
    out["cluster"] = km.predict(X).astype(int)
    b64 = base64.b64encode(_joblib_dumps(km)).decode("ascii")
    return out, b64


def _dnn(df, params):
    from sklearn.neural_network import MLPClassifier, MLPRegressor
    hls = _parse_hls(params.get("hidden_layer_sizes", "(32,16)"))
    iters = _int(params, "max_iter", 500)
    lr = _num(params, "learning_rate_init", 0.001)
    if params.get("task", "classification") == "regression":
        return _train_model(df, params,
                            lambda: MLPRegressor(hidden_layer_sizes=hls, max_iter=iters,
                                                 learning_rate_init=lr, random_state=0),
                            regression=True)
    return _train_model(df, params,
                        lambda: MLPClassifier(hidden_layer_sizes=hls, max_iter=iters,
                                              learning_rate_init=lr, random_state=0),
                        regression=False)


def _deep_learning(df, params):
    from deep_learning_models import TabularNeuralModel
    features = params.get("features")
    label = params.get("label")
    if not isinstance(features, list) or not features or len(set(features)) != len(features):
        raise ValueError("请选择不重复的数值特征列")
    if not label or label not in df.columns:
        raise ValueError("训练算子需要配置有效标签列")
    if any(c not in df.columns for c in features):
        raise ValueError("所选特征列不在输入数据中")
    if label in features or any(c in {"pred", "pred_prob", "prediction", "cluster"} for c in features):
        raise ValueError("特征列不能包含标签列或已有预测列")
    # 标识列需由使用者显式排除；不猜测列名，不自动选择全部数值列。
    if any(pd.to_numeric(df[c], errors="coerce").replace([np.inf, -np.inf], np.nan).notna().sum() == 0
           for c in features):
        raise ValueError("所选特征包含无有效数值的列")
    model = TabularNeuralModel(str(params["op"]).split(".")[-1],
                              task=params.get("task", "classification"),
                              epochs=params.get("epochs", 50),
                              learning_rate=params.get("learning_rate", 0.001))
    frame = df[features]
    model.fit(frame, df[label])
    output = df.copy()
    output["pred"] = model.predict(frame)
    if model.task == "classification":
        output["pred_prob"] = model.predict_proba(frame)[:, 1]
    return output, base64.b64encode(_joblib_dumps(model)).decode("ascii")


def _decision_tree(df, params):
    from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor
    md = params.get("max_depth")
    md = int(md) if md not in (None, "", "None") else None
    msl = _int(params, "min_samples_leaf", 1)
    if params.get("task", "classification") == "regression":
        return _train_model(df, params,
                            lambda: DecisionTreeRegressor(max_depth=md, min_samples_leaf=msl, random_state=0),
                            regression=True)
    return _train_model(df, params,
                        lambda: DecisionTreeClassifier(max_depth=md, min_samples_leaf=msl, random_state=0),
                        regression=False)


def _xgboost(df, params):
    import xgboost as xgb
    ne = _int(params, "n_estimators", 100)
    md = _int(params, "max_depth", 6)
    lr = _num(params, "learning_rate", 0.3)
    if params.get("task", "classification") == "regression":
        return _train_model(df, params,
                            lambda: xgb.XGBRegressor(n_estimators=ne, max_depth=md, learning_rate=lr,
                                                     n_jobs=1, random_state=0, verbosity=0),
                            regression=True)
    return _train_model(df, params,
                        lambda: xgb.XGBClassifier(n_estimators=ne, max_depth=md, learning_rate=lr,
                                                  n_jobs=1, random_state=0, verbosity=0),
                        regression=False)


def _lightgbm(df, params):
    import lightgbm as lgb
    ne = _int(params, "n_estimators", 100)
    nl = _int(params, "num_leaves", 31)
    lr = _num(params, "learning_rate", 0.1)
    if params.get("task", "classification") == "regression":
        return _train_model(df, params,
                            lambda: lgb.LGBMRegressor(n_estimators=ne, num_leaves=nl, learning_rate=lr,
                                                      n_jobs=1, random_state=0, verbose=-1),
                            regression=True)
    return _train_model(df, params,
                        lambda: lgb.LGBMClassifier(n_estimators=ne, num_leaves=nl, learning_rate=lr,
                                                   n_jobs=1, random_state=0, verbose=-1),
                        regression=False)


# 评估算子 --------------------------------------------------------------------------


def binary_classification(df, params):
    """二分类评估：accuracy/precision/recall/f1/auc + 混淆矩阵。"""
    from sklearn import metrics
    label = params.get("label")
    pred = params.get("pred") or "pred"
    prob = params.get("pred_prob") or "pred_prob"
    if not label or label not in df.columns:
        raise ValueError("binary_classification 需要 label 列")
    y = pd.to_numeric(df[label], errors="coerce")
    m = y.notna()
    y = y[m].astype(int)
    p = pd.to_numeric(df[pred], errors="coerce")[m]
    threshold = _num(params, "threshold", 0.5)
    yp = (p >= threshold).astype(int)
    probv = pd.to_numeric(df[prob], errors="coerce")[m] if prob in df.columns else p
    acc = metrics.accuracy_score(y, yp)
    prec = metrics.precision_score(y, yp, zero_division=0)
    rec = metrics.recall_score(y, yp, zero_division=0)
    f1 = metrics.f1_score(y, yp, zero_division=0)
    auc = 0.0
    try:
        if y.nunique() == 2 and probv.notna().all():
            auc = metrics.roc_auc_score(y, probv)
    except Exception:
        pass
    tn, fp, fn, tp = metrics.confusion_matrix(y, yp).ravel()
    out = pd.DataFrame([
        ["accuracy", round(acc, 6)],
        ["precision", round(prec, 6)],
        ["recall", round(rec, 6)],
        ["f1", round(f1, 6)],
        ["auc", round(auc, 6)],
        ["true_positive", int(tp)],
        ["true_negative", int(tn)],
        ["false_positive", int(fp)],
        ["false_negative", int(fn)],
        ["n", len(y)],
    ], columns=["metric", "value"])
    return out, None


def regression_evaluation(df, params):
    """回归评估：mae / rmse / r2。"""
    from sklearn import metrics
    label = params.get("label")
    pred = params.get("pred") or "pred"
    if not label or label not in df.columns:
        raise ValueError("regression_evaluation 需要 label 列")
    y = pd.to_numeric(df[label], errors="coerce")
    p = pd.to_numeric(df[pred], errors="coerce")
    m = y.notna() & p.notna()
    y, p = y[m], p[m]
    if len(y) < 2:
        raise ValueError("regression_evaluation 有效样本不足 2")
    out = pd.DataFrame([
        ["mae", round(metrics.mean_absolute_error(y, p), 6)],
        ["rmse", round(float(metrics.mean_squared_error(y, p) ** 0.5), 6)],
        ["r2", round(metrics.r2_score(y, p), 6)],
        ["n", len(y)],
    ], columns=["metric", "value"])
    return out, None


# 分发 -------------------------------------------------------------------------------

OPS = {
    "preprocessing.fillna": fillna,
    "preprocessing.outlier": outlier,
    "preprocessing.unique": unique,
    "preprocessing.binning": binning,
    "preprocessing.woe": woe,
    "preprocessing.standardize": standardize,
    "preprocessing.derive": derive,
    "preprocessing.psi": psi,
    "preprocessing.feature_align": feature_align,
    "stats.correlation": correlation,
    "ml.linear_regression": _linear_regression,
    "ml.logistic_regression": _logistic_regression,
    "ml.knn": _knn,
    "ml.kmeans": _kmeans,
    "ml.dnn": _dnn,
    "ml.cnn": _deep_learning,
    "ml.rnn": _deep_learning,
    "ml.lstm": _deep_learning,
    "ml.decision_tree": _decision_tree,
    "ml.xgboost": _xgboost,
    "ml.lightgbm": _lightgbm,
    "ml.binary_classification": binary_classification,
    "ml.regression_evaluation": regression_evaluation,
}

TRAIN_OPS = {"ml.linear_regression", "ml.logistic_regression", "ml.knn", "ml.kmeans",
             "ml.dnn", "ml.cnn", "ml.rnn", "ml.lstm", "ml.decision_tree", "ml.xgboost", "ml.lightgbm"}


def run(op, input_path, output_path, params, input_table="", jdbc_url=""):
    df = pd.read_csv(input_path, encoding="utf-8")
    if df.empty:
        raise ValueError("输入数据为空")
    fn = OPS.get(op)
    if fn is None:
        raise ValueError("未知算子: %s" % op)
    result, extra = fn(df, params)
    model_b64 = extra if isinstance(extra, str) else None
    preproc = extra if isinstance(extra, dict) else None
    write_output(result, output_path, model_b64, preproc)
    return len(result), model_b64 is not None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Data Sandbox Modeling Operator")
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--params", default="{}")
    ap.add_argument("--input-table", default="")
    ap.add_argument("--jdbc-url", default="")
    args = ap.parse_args(argv)
    params = json.loads(args.params or "{}")
    op = params.get("op") or params.get("component")
    if not op:
        raise ValueError("params.op 缺失")
    rows, has_model = run(op, args.input, args.output, params, args.input_table, args.jdbc_url)
    sys.stderr.write("[mops] op=%s rows=%d model_b64=%s\n" % (op, rows, has_model))


if __name__ == "__main__":
    main()
