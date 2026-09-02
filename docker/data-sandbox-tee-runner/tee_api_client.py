#!/usr/bin/env python3
"""mTLS client for the frozen tee-contract/1.0 runtime API.

The client deliberately does not fall back to User-Token, plain HTTP, or a
locally generated key.  Its payloads contain JWS/task metadata or ciphertext
only; plaintext and private-key bytes never leave the trusted runtime.
"""
import json
import os
import ssl
import urllib.error
import urllib.request
from pathlib import Path

from tee_contract_runtime import CONTRACT_VERSION, ContractError


class TeeApiClient:
    def __init__(self, base_url=None, ca_file=None, cert_file=None, key_file=None):
        self.base_url = (base_url or os.environ.get("TEE_API_BASE", "")).rstrip("/")
        ca_file = ca_file or os.environ.get("TEE_API_CA_FILE")
        # Transport identity authorizes the mTLS caller.  It is deliberately
        # separate from the workload identity used to receive keys and sign
        # receipts, so compromise of a platform client credential cannot open
        # a key envelope or forge an execution receipt.
        cert_file = cert_file or os.environ.get("TEE_API_CLIENT_CERT")
        key_file = key_file or os.environ.get("TEE_API_CLIENT_KEY")
        workload_cert = os.environ.get("TEE_WORKLOAD_CERT")
        if not self.base_url.startswith("https://") or not all(
                (ca_file, cert_file, key_file, workload_cert)):
            raise ContractError("KEY_SERVICE_UNAVAILABLE", "mTLS runtime API configuration is incomplete")
        context = ssl.create_default_context(cafile=ca_file)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=cert_file, keyfile=key_file)
        self.context = context
        self.recipient_cert_pem = Path(workload_cert).read_text(encoding="utf-8")

    def release(self, request_id, task_jws, attestation_evidence=None):
        return self._json("POST", "/runtime/release", {
            "contractVersion": CONTRACT_VERSION,
            "requestId": request_id,
            "taskJws": task_jws,
            "attestationEvidence": attestation_evidence,
            "recipientCertPem": self.recipient_cert_pem,
        })

    def output_key(self, request_id, task_jws, result_id, result_kind):
        return self._json("POST", "/runtime/output-key", {
            "contractVersion": CONTRACT_VERSION,
            "requestId": request_id,
            "taskJws": task_jws,
            "resultId": result_id,
            "resultKind": result_kind,
            "recipientCertPem": self.recipient_cert_pem,
        })

    def get_object(self, task_id, object_id):
        return self._json("GET", "/objects/" + _path_id(object_id),
                          headers={"X-TEE-Task-Id": _path_id(task_id)})

    def get_program(self, task_id, object_id):
        return self._json("GET", "/programs/" + _path_id(object_id),
                          headers={"X-TEE-Task-Id": _path_id(task_id)})

    def put_object(self, request_id, task_id, result_id, result_kind, contributors, encrypted_object):
        return self._json("POST", "/objects", {
            "contractVersion": CONTRACT_VERSION,
            "requestId": request_id,
            "taskId": task_id,
            "resultId": result_id,
            "resultKind": result_kind,
            "contributors": contributors,
            "encryptedObject": encrypted_object,
        })

    def receipt(self, task_id, request_id, receipt_jws):
        return self._json("POST", "/tasks/" + _path_id(task_id) + "/receipt", {
            "contractVersion": CONTRACT_VERSION,
            "requestId": request_id,
            "receiptJws": receipt_jws,
        })

    def _json(self, method, path, payload=None, headers=None):
        body = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(self.base_url + path, data=body, method=method)
        request.add_header("Accept", "application/json")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        if body is not None:
            request.add_header("Content-Type", "application/json; charset=utf-8")
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=15) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            return self._rejection(raw, "KEY_SERVICE_UNAVAILABLE")
        except (urllib.error.URLError, TimeoutError, ssl.SSLError) as exc:
            raise ContractError("KEY_SERVICE_UNAVAILABLE", "TEE API is unreachable") from exc
        try:
            wrapper = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            raise ContractError("KEY_SERVICE_UNAVAILABLE", "TEE API returned invalid JSON") from exc
        status, data = wrapper.get("status"), wrapper.get("data")
        if not isinstance(status, dict) or not isinstance(data, dict):
            raise ContractError("KEY_SERVICE_UNAVAILABLE", "TEE API response is not contract wrapped")
        if status.get("code") != 0:
            raise ContractError(data.get("errorCode", "KEY_SERVICE_UNAVAILABLE"), "TEE API rejected request")
        if data.get("contractVersion") != CONTRACT_VERSION:
            raise ContractError("CONTRACT_INVALID", "TEE API contract version mismatch")
        return data

    @staticmethod
    def _rejection(raw, default):
        try:
            wrapper = json.loads(raw.decode("utf-8"))
            data = wrapper.get("data") if isinstance(wrapper, dict) else None
            code = data.get("errorCode") if isinstance(data, dict) else None
        except Exception:
            code = None
        raise ContractError(code or default, "TEE API rejected request")


def _path_id(value):
    if not isinstance(value, str) or not value or "/" in value or ".." in value:
        raise ContractError("CONTRACT_INVALID", "invalid API object identifier")
    return value
