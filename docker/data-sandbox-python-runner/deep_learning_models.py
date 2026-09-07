"""表格轻量网络：固定特征顺序、CPU 训练和可移植权重；一行始终对应一个样本。"""
import math

import numpy as np
import pandas as pd


def _network(kind, feature_count):
    import torch.nn as nn

    class Network(nn.Module):
        def __init__(self):
            super().__init__()
            if kind == "cnn":
                self.encoder = nn.Conv1d(1, 16, min(3, feature_count))
                self.output = nn.Linear(16, 1)
            else:
                recurrent = nn.RNN if kind == "rnn" else nn.LSTM
                self.encoder = recurrent(1, 32, batch_first=True)
                self.output = nn.Linear(32, 1)

        def forward(self, value):
            if kind == "cnn":
                encoded = self.encoder(value.unsqueeze(1)).relu().mean(dim=2)
            else:
                sequence, _ = self.encoder(value.unsqueeze(2))
                encoded = sequence[:, -1, :]
            return self.output(encoded).squeeze(1)

    return Network()


class TabularNeuralModel:
    """兼容平台模型接口，joblib 仅保存参数数组和预处理状态，不保存动态网络类。"""

    def __init__(self, kind, task="classification", epochs=50, learning_rate=0.001):
        if kind not in ("cnn", "rnn", "lstm"):
            raise ValueError("网络类型必须为 CNN、RNN 或 LSTM")
        if task not in ("classification", "regression"):
            raise ValueError("任务类型必须为二分类或回归")
        if isinstance(epochs, bool):
            raise ValueError("训练轮数必须为 1 至 500 的整数")
        try:
            count, rate = float(epochs), float(learning_rate)
        except (ValueError, TypeError):
            raise ValueError("训练轮数和学习率必须为有效数值") from None
        if not math.isfinite(count) or not count.is_integer() or not 1 <= count <= 500:
            raise ValueError("训练轮数必须为 1 至 500 的整数")
        if not math.isfinite(rate) or not 0 < rate <= 0.1:
            raise ValueError("学习率必须大于 0 且不超过 0.1")
        self.kind, self.task = kind, task
        self.epochs, self.learning_rate = int(count), rate
        self.format_version = 1

    def _values(self, frame):
        if not isinstance(frame, pd.DataFrame):
            frame = pd.DataFrame(frame, columns=self.feature_names_in_)
        missing = [name for name in self.feature_names_in_ if name not in frame.columns]
        if missing:
            raise ValueError("预测输入缺少模型所需特征列")
        if frame.columns.duplicated().any():
            raise ValueError("输入包含重复列名")
        values = frame[list(self.feature_names_in_)].apply(pd.to_numeric, errors="coerce")
        return values.replace([np.inf, -np.inf], np.nan).fillna(0).to_numpy(dtype=np.float64)

    def fit(self, frame, target):
        import torch

        torch.set_num_threads(1)
        torch.manual_seed(0)
        if not isinstance(frame, pd.DataFrame) or not 1 <= frame.shape[1] <= 256:
            raise ValueError("请选择 1 至 256 个数值特征")
        if not 2 <= len(frame) <= 100000:
            raise ValueError("轻量网络支持 2 至 100000 个样本")
        self.feature_names_in_ = np.asarray(frame.columns, dtype=object)
        self.n_features_in_ = len(self.feature_names_in_)
        values = self._values(frame)
        labels = np.asarray(pd.to_numeric(pd.Series(np.asarray(target)), errors="coerce"), dtype=np.float64)
        if len(labels) != len(values) or not np.isfinite(labels).all():
            raise ValueError("标签必须为完整、有限的数值，不能包含缺失值")
        if self.task == "classification":
            if set(np.unique(labels)) != {0.0, 1.0}:
                raise ValueError("二分类标签必须同时包含 0 和 1")
            self.classes_ = np.asarray([0, 1])
        self.mean_ = values.mean(axis=0)
        self.scale_ = values.std(axis=0)
        self.scale_[self.scale_ < 1e-12] = 1.0
        self.target_mean_ = float(labels.mean()) if self.task == "regression" else 0.0
        self.target_scale_ = max(float(labels.std()), 1e-12) if self.task == "regression" else 1.0
        features = ((values - self.mean_) / self.scale_).astype(np.float32)
        normalized = ((labels - self.target_mean_) / self.target_scale_).astype(np.float32)
        if not np.isfinite(features).all() or not np.isfinite(normalized).all():
            raise ValueError("数据数值范围超出轻量网络支持范围")
        x, y = torch.from_numpy(features), torch.from_numpy(normalized)
        network = _network(self.kind, self.n_features_in_)
        optimizer = torch.optim.Adam(network.parameters(), lr=self.learning_rate)
        loss_function = torch.nn.BCEWithLogitsLoss() if self.task == "classification" else torch.nn.MSELoss()
        network.train()
        for _ in range(self.epochs):
            order = torch.randperm(len(x))
            for indices in order.split(32):
                optimizer.zero_grad()
                loss = loss_function(network(x[indices]), y[indices])
                if not torch.isfinite(loss):
                    raise ValueError("训练损失无效，请检查数据和学习率")
                loss.backward()
                torch.nn.utils.clip_grad_norm_(network.parameters(), 5.0)
                optimizer.step()
        self.state_dict_ = {name: value.detach().cpu().numpy().copy()
                            for name, value in network.state_dict().items()}
        self.training_samples_ = len(x)
        return self

    def _scores(self, frame):
        import torch

        if not hasattr(self, "state_dict_"):
            raise ValueError("模型尚未训练")
        torch.set_num_threads(1)
        values = ((self._values(frame) - self.mean_) / self.scale_).astype(np.float32)
        if not np.isfinite(values).all():
            raise ValueError("预测数据数值范围无效")
        network = _network(self.kind, self.n_features_in_)
        network.load_state_dict({name: torch.from_numpy(value) for name, value in self.state_dict_.items()})
        network.eval()
        with torch.no_grad():
            chunks = [network(batch).numpy() for batch in torch.from_numpy(values).split(1024)]
        scores = np.concatenate(chunks) if chunks else np.empty(0, dtype=np.float32)
        if not np.isfinite(scores).all():
            raise ValueError("模型预测出现无效数值")
        return scores

    def predict(self, frame):
        scores = self._scores(frame)
        if self.task == "classification":
            return (scores >= 0).astype(int)
        return scores * self.target_scale_ + self.target_mean_

    def predict_proba(self, frame):
        if self.task != "classification":
            raise ValueError("回归模型不提供分类概率")
        positive = 1.0 / (1.0 + np.exp(-np.clip(self._scores(frame), -80, 80)))
        return np.column_stack((1.0 - positive, positive))
