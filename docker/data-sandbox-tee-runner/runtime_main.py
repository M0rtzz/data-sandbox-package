#!/usr/bin/env python3
"""Production P5 trusted runtime entry point for tee-contract/1.0."""
import base64
import csv
import hashlib
import json
import os
import secrets
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from tee_api_client import TeeApiClient
from tee_contract_runtime import (CONTRACT_VERSION, ContractError, decrypt_input,
                                  unwrap_key_envelope, verify_task_jws)
from tee_execution import execute


def main():
    started = now()
    compact = read_task_jws()
    task = verify_task_jws(compact, trusted_keys(), required("TEE_AUDIENCE"),
                           required("TEE_RUNTIME_IMAGE_DIGEST"))
    api = TeeApiClient()
    certificate_pem = Path(required("TEE_WORKLOAD_CERT")).read_bytes()
    private_pem = Path(required("TEE_WORKLOAD_PRIVATE_KEY")).read_bytes()
    cert_digest = hashlib.sha256(x509.load_pem_x509_certificate(certificate_pem)
                                 .public_bytes(serialization.Encoding.DER)).hexdigest()
    configured_kid = os.environ.get("TEE_WORKLOAD_KID")
    if configured_kid and configured_kid != cert_digest:
        reject("TASK_SIGNATURE_INVALID", "workload receipt kid does not match certificate")
    workload_kid = cert_digest
    release = api.release(task["requestId"], compact, read_optional("TEE_ATTESTATION_EVIDENCE"))
    if release.get("taskId") != task["taskId"]:
        reject("DATA_INTEGRITY_FAILED", "key release is not bound to task")
    runtime_mode = release.get("runtimeMode")
    attestation = release.get("attestationVerified") is True
    if runtime_mode not in ("SIMULATION", "HARDWARE") or (runtime_mode == "SIMULATION" and attestation):
        reject("CONTRACT_INVALID", "invalid runtime attestation result")
    envelopes = {(item.get("keyId"), version(item.get("keyVersion"), "keyVersion")): item
                 for item in release.get("keyEnvelopes", []) if isinstance(item, dict)}
    plaintext_inputs = []
    parameters = (task.get("program") or {}).get("parameters", {})
    declared_kinds = parameters.get("inputKinds")
    if task.get("operatorId") not in ("model.predict", "report.tree_structure") and declared_kinds is not None:
        reject("CONTRACT_INVALID", "typed inputs are reserved for model prediction")
    input_kinds = list(declared_kinds or ["DATA"] * len(task["inputs"]))
    if len(input_kinds) != len(task["inputs"]) or any(
            kind not in ("DATA", "MODEL") for kind in input_kinds):
        reject("CONTRACT_INVALID", "signed inputKinds do not match task inputs")
    try:
        for index, item in enumerate(task["inputs"]):
            envelope = envelopes.get((item["keyId"], item["keyVersion"]))
            if not envelope:
                reject("KEY_SERVICE_UNAVAILABLE", "input key was not released")
            encrypted = api.get_object(task["taskId"], item["objectId"])
            key = bytearray(unwrap_key_envelope(envelope, item, private_pem, cert_digest))
            try:
                plaintext = decrypt_input(encrypted, item, bytes(key))
                if len(plaintext) != item["plaintextBytes"]:
                    reject("DATA_INTEGRITY_FAILED", "plaintext size does not match signed task")
                if input_kinds[index] == "MODEL":
                    plaintext_inputs.append(bytearray(plaintext))
                else:
                    plaintext_inputs.append(bytearray(filter_columns(plaintext, task["columns"])))
                del plaintext
            finally:
                wipe(key)
        program_bytes = None
        if task["program"]["kind"] != "BUILTIN":
            program = api.get_program(task["taskId"], task["program"]["objectId"])
            if program.get("kind") != task["program"]["kind"] \
                    or program.get("sha256") != task["program"]["sha256"]:
                reject("DATA_INTEGRITY_FAILED", "program metadata does not match signed task")
            try:
                program_bytes = base64.b64decode(program["contentB64"], validate=True)
            except Exception:
                reject("DATA_INTEGRITY_FAILED", "program content is not valid Base64")
        tmpfs = Path(os.environ.get("TEE_TMPFS_ROOT", "/dev/shm"))
        if not tmpfs.is_dir():
            reject("CONTRACT_INVALID", "trusted tmpfs root is unavailable")
        with tempfile.TemporaryDirectory(prefix="tee-", dir=tmpfs) as workdir:
            outputs = execute(task, plaintext_inputs, program_bytes, workdir)
        contributors = release.get("contributors")
        receipt_outputs = []
        for index, output in enumerate(outputs):
            if output.kind == "REPORT":
                if output.report_kind not in task["outputPolicy"]["reportKinds"]:
                    reject("POLICY_DENIED", "report kind is not allowed by signed output policy")
                receipt_outputs.append({"kind": "REPORT", "reportKind": output.report_kind,
                                        "encrypted": False, "content": output.content})
                continue
            if not isinstance(contributors, list) or not contributors \
                    or any(not isinstance(value, str) or not value for value in contributors):
                reject("CONTRACT_INVALID", "key release did not supply verified contributors")
            result_id = result_id_for(task["taskId"], output.kind, index)
            key_result = api.output_key(task["requestId"] + ":output:" + str(index), compact,
                                        result_id, output.kind)
            key_envelope = key_result.get("keyEnvelope")
            key_binding = {"keyId": key_envelope.get("keyId"),
                           "keyVersion": version(key_envelope.get("keyVersion"), "keyVersion")}
            result_key = bytearray(unwrap_key_envelope(
                key_envelope, key_binding, private_pem, cert_digest))
            try:
                encrypted = encrypt_result(result_id, key_envelope, bytes(result_key), output.content)
            finally:
                wipe(result_key)
            stored = api.put_object(task["requestId"] + ":object:" + str(index), task["taskId"],
                                    result_id, output.kind, contributors, encrypted)
            receipt_outputs.append({"kind": output.kind, "resultId": result_id,
                                    "objectId": stored["objectId"], "encrypted": True,
                                    "keyId": encrypted["keyId"],
                                    "keyVersion": version(encrypted["keyVersion"], "keyVersion"),
                                    "ciphertextSha256": encrypted["ciphertextSha256"],
                                    "contributors": contributors,
                                    "exportState": stored.get("exportState", "PENDING_APPROVAL"),
                                    **({"artifactType": output.artifact_type}
                                       if output.artifact_type else {})})
        if task.get("contractVersion") == "tee-contract/2.0":
            api.authorize_report(task["taskId"])
        submit_receipt(api, task, private_pem, workload_kid, started, runtime_mode,
                       attestation, "SUCCEEDED", receipt_outputs, None)
        print(json.dumps({"status": "SUCCEEDED", "taskId": task["taskId"],
                          "runtimeMode": runtime_mode, "outputCount": len(receipt_outputs)}))
    except KeyboardInterrupt:
        submit_failure_receipt(api, task, private_pem, workload_kid, started,
                               runtime_mode, attestation, "CANCELLED", "CONTRACT_INVALID")
        raise ContractError("CONTRACT_INVALID", "trusted runtime was cancelled")
    except ContractError as failure:
        submit_failure_receipt(api, task, private_pem, workload_kid, started,
                               runtime_mode, attestation, "FAILED", failure.error_code)
        raise
    except Exception:
        submit_failure_receipt(api, task, private_pem, workload_kid, started,
                               runtime_mode, attestation, "FAILED", "CONTRACT_INVALID")
        raise
    finally:
        for value in plaintext_inputs:
            wipe(value)


def submit_failure_receipt(api, task, private_pem, kid, started, runtime_mode,
                           attestation, status, error_code):
    try:
        submit_receipt(api, task, private_pem, kid, started, runtime_mode,
                       attestation, status, [], error_code)
    except Exception:
        # Never replace the original execution failure or expose response/key details.
        pass


def submit_receipt(api, task, private_pem, kid, started, runtime_mode,
                   attestation, status, outputs, error_code):
    versions = {item["policyVersion"] for item in task["inputs"]}
    receipt = {"contractVersion": task["contractVersion"], "taskId": task["taskId"],
               "requestId": task["requestId"], "status": status,
               "runtimeMode": runtime_mode, "attestationVerified": attestation,
               "policyVersion": next(iter(versions)) if len(versions) == 1 else None,
               "keyReleaseCount": len(task["inputs"]), "outputs": outputs,
               "startedAt": started, "finishedAt": now(), "errorCode": error_code}
    signed = sign_receipt(receipt, private_pem, kid)
    api.receipt(task["taskId"], task["requestId"] + ":receipt", signed)


def read_task_jws():
    path = Path(os.environ.get("TEE_TASK_CONFIG", "/etc/kuscia/tee-conf.json"))
    raw = path.read_text(encoding="utf-8").strip()
    if raw.count(".") == 2 and not raw.startswith("{"):
        return raw
    config = json.loads(raw)
    if isinstance(config.get("tee_task_jws"), str):
        return config["tee_task_jws"]
    nested = config.get("task_input_config")
    if isinstance(nested, str):
        nested = json.loads(nested)
    if isinstance(nested, dict) and isinstance(nested.get("tee_task_jws"), str):
        return nested["tee_task_jws"]
    reject("CONTRACT_INVALID", "tee_task_jws is missing from Kuscia config")


def trusted_keys():
    directory = Path(required("TEE_ISSUER_TRUST_DIR"))
    keys = {path.stem: path.read_bytes() for path in directory.glob("*.pem") if path.is_file()}
    if not keys:
        reject("TASK_SIGNATURE_INVALID", "issuer trust mapping is empty")
    return keys


def filter_columns(content, columns):
    try:
        text = content.decode("utf-8")
        reader = csv.DictReader(text.splitlines())
        if not reader.fieldnames or any(column not in reader.fieldnames for column in columns):
            reject("POLICY_DENIED", "requested column is unavailable")
        import io
        stream = io.StringIO(newline="")
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        for row in reader:
            writer.writerow({column: row[column] for column in columns})
        return stream.getvalue().encode("utf-8")
    except ContractError:
        raise
    except Exception as exc:
        raise ContractError("DATA_INTEGRITY_FAILED", "CSV filtering failed") from exc


def encrypt_result(result_id, envelope, key, content):
    key_id = envelope.get("keyId")
    key_version = version(envelope.get("keyVersion"), "keyVersion")
    aad = json.dumps({"assetId": result_id, "assetVersion": 1, "keyId": key_id,
                      "keyVersion": key_version}, separators=(",", ":")).encode()
    nonce = secrets.token_bytes(12)
    sealed = AESGCM(key).encrypt(nonce, content, aad)
    ciphertext, tag = sealed[:-16], sealed[-16:]
    return {"contractVersion": CONTRACT_VERSION, "assetId": result_id, "assetVersion": 1,
            "keyId": key_id, "keyVersion": key_version, "algorithm": "AES-256-GCM",
            "nonceB64": base64.b64encode(nonce).decode(), "aadB64": base64.b64encode(aad).decode(),
            "ciphertextB64": base64.b64encode(ciphertext).decode(),
            "tagB64": base64.b64encode(tag).decode(),
            "ciphertextSha256": hashlib.sha256(nonce + aad + ciphertext + tag).hexdigest()}


def sign_receipt(receipt, private_pem, kid):
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=")
    header = encode(json.dumps({"alg": "RS256", "typ": "JWS", "kid": kid},
                               separators=(",", ":")).encode())
    payload = encode(json.dumps(receipt, separators=(",", ":")).encode())
    key = serialization.load_pem_private_key(private_pem, password=None)
    signature = key.sign(header + b"." + payload, padding.PKCS1v15(), hashes.SHA256())
    return b".".join((header, payload, encode(signature))).decode()


def result_id_for(task_id, kind, index):
    digest = hashlib.sha256((task_id + "\0" + kind + "\0" + str(index)).encode()).hexdigest()[:24]
    return "result-" + digest


def required(name):
    value = os.environ.get(name)
    if not value:
        reject("CONTRACT_INVALID", name + " is required")
    return value


def version(value, name):
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        reject("CONTRACT_INVALID", name + " must be a positive integer")
    return value


def read_optional(name):
    path = os.environ.get(name)
    return Path(path).read_text(encoding="utf-8") if path else None


def wipe(value):
    for index in range(len(value)):
        value[index] = 0


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def reject(code, message):
    raise ContractError(code, message)


if __name__ == "__main__":
    try:
        main()
    except ContractError as failure:
        print(json.dumps({"status": "FAILED", "errorCode": failure.error_code,
                          "message": str(failure)}), file=sys.stderr)
        raise SystemExit(1)
    except Exception:
        print(json.dumps({"status": "FAILED", "errorCode": "CONTRACT_INVALID",
                          "message": "trusted runtime failed"}), file=sys.stderr)
        raise SystemExit(1)
