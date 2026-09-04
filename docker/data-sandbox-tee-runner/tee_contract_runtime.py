#!/usr/bin/env python3
"""Strict, side-effect-free primitives for the B P5 trusted runtime.

This module deliberately has no platform credentials, network calls, or logging.
It is imported by the container entry point so that untrusted program execution
cannot bypass task, key-envelope, or encrypted-object validation.
"""
import base64
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

CONTRACT_VERSION = "tee-contract/1.0"
MAX_OBJECT_PLAINTEXT = 64 * 1024 * 1024
MAX_TASK_PLAINTEXT = 256 * 1024 * 1024
MAX_TASK_LIFETIME = timedelta(minutes=5)
CLOCK_SKEW = timedelta(seconds=30)
REPORT_KINDS = {"EVALUATION_METRICS", "FEATURE_IMPORTANCE", "TREE_STRUCTURE",
                "MODEL_API_PREDICTION"}
PROGRAM_KINDS = {"BUILTIN", "SQL", "PYTHON", "JAR"}
HEX256 = re.compile(r"^[0-9a-f]{64}$")


class ContractError(ValueError):
    """A contract rejection safe to map to the frozen errorCode."""

    def __init__(self, error_code, message):
        super().__init__(message)
        self.error_code = error_code


def _reject(code, message):
    raise ContractError(code, message)


def b64url_decode(value):
    if not isinstance(value, str) or not value:
        _reject("TASK_SIGNATURE_INVALID", "invalid Base64URL field")
    try:
        return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except Exception as exc:
        raise ContractError("TASK_SIGNATURE_INVALID", "invalid Base64URL field") from exc


def _b64(value, name):
    if not isinstance(value, str):
        _reject("CONTRACT_INVALID", "%s must be Base64 text" % name)
    try:
        return base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ContractError("CONTRACT_INVALID", "%s is not valid Base64" % name) from exc


def _text(value, name):
    if not isinstance(value, str) or not value.strip():
        _reject("CONTRACT_INVALID", "%s is required" % name)
    return value


def _positive_int(value, name):
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        _reject("CONTRACT_INVALID", "%s must be a positive integer" % name)
    return value


def _wire_version(value, name):
    """Accept the current Java adapter's decimal string while enforcing v1 semantics."""
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    return _positive_int(value, name)


def _instant(value, name):
    try:
        parsed = datetime.fromisoformat(_text(value, name).replace("Z", "+00:00"))
    except ValueError as exc:
        raise ContractError("CONTRACT_INVALID", "%s is not RFC3339" % name) from exc
    if parsed.tzinfo is None:
        _reject("CONTRACT_INVALID", "%s must include UTC offset" % name)
    return parsed.astimezone(timezone.utc)


def _sha256(value, name):
    if not isinstance(value, str) or not HEX256.fullmatch(value):
        _reject("CONTRACT_INVALID", "%s must be a lowercase SHA-256 hex digest" % name)
    return value


def verify_task_jws(compact, trusted_public_keys, audience, runtime_image_digest, now=None):
    """Verify an exact JWS signing input and all static TaskSpec invariants.

    ``trusted_public_keys`` is a ``kid -> PEM bytes/text`` map.  There is no
    single-key fallback: an unknown ``kid`` is a signature failure by contract.
    ``now`` is injectable solely for the published synthetic vector.
    """
    if not isinstance(compact, str) or compact.count(".") != 2:
        _reject("TASK_SIGNATURE_INVALID", "task is not JWS Compact")
    header_part, payload_part, signature_part = compact.split(".")
    try:
        header = json.loads(b64url_decode(header_part))
        payload = json.loads(b64url_decode(payload_part))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ContractError("TASK_SIGNATURE_INVALID", "JWS JSON cannot be parsed") from exc
    if header.get("alg") != "RS256" or header.get("typ") != "JWS":
        _reject("TASK_SIGNATURE_INVALID", "only RS256 JWS is accepted")
    kid = _text(header.get("kid"), "JWS kid")
    public_pem = trusted_public_keys.get(kid) if isinstance(trusted_public_keys, dict) else None
    if not public_pem:
        _reject("TASK_SIGNATURE_INVALID", "unknown signing key")
    try:
        public_key = serialization.load_pem_public_key(
            public_pem.encode("utf-8") if isinstance(public_pem, str) else public_pem)
        public_key.verify(b64url_decode(signature_part), (header_part + "." + payload_part).encode("ascii"),
                          padding.PKCS1v15(), hashes.SHA256())
    except ContractError:
        raise
    except Exception as exc:
        raise ContractError("TASK_SIGNATURE_INVALID", "JWS signature verification failed") from exc
    validate_task_spec(payload, audience, runtime_image_digest, now=now)
    return payload


def validate_task_spec(task, audience, runtime_image_digest, now=None):
    if not isinstance(task, dict) or task.get("contractVersion") != CONTRACT_VERSION:
        _reject("CONTRACT_INVALID", "contract version mismatch")
    for name in ("taskId", "requestId", "issuer", "audience", "sandboxId", "operatorId", "nonce"):
        _text(task.get(name), name)
    if task["audience"] != audience or task.get("runtimeImageDigest") != runtime_image_digest:
        _reject("TASK_SIGNATURE_INVALID", "task does not bind this runtime")
    issued_at, expires_at = _instant(task.get("issuedAt"), "issuedAt"), _instant(task.get("expiresAt"), "expiresAt")
    if expires_at <= issued_at or expires_at - issued_at > MAX_TASK_LIFETIME:
        _reject("CONTRACT_INVALID", "invalid task lifetime")
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if issued_at > current + CLOCK_SKEW or expires_at < current - CLOCK_SKEW:
        _reject("TASK_EXPIRED", "task is outside its valid time window")
    columns = task.get("columns")
    if not isinstance(columns, list) or not columns or any(not isinstance(item, str) or not item for item in columns):
        _reject("CONTRACT_INVALID", "columns must be a non-empty exact grant set")
    if len(set(columns)) != len(columns):
        _reject("CONTRACT_INVALID", "columns must not contain duplicates")
    _validate_inputs(task.get("inputs"))
    _validate_program(task.get("program"))
    _validate_output_policy(task.get("outputPolicy"))


def _validate_inputs(inputs):
    if not isinstance(inputs, list) or not inputs:
        _reject("CONTRACT_INVALID", "task inputs are required")
    total = 0
    for index, item in enumerate(inputs):
        if not isinstance(item, dict):
            _reject("CONTRACT_INVALID", "input %d is invalid" % index)
        for name in ("assetId", "keyId", "policyId", "objectId"):
            _text(item.get(name), "inputs[%d].%s" % (index, name))
        for name in ("assetVersion", "keyVersion", "policyVersion", "plaintextBytes"):
            _positive_int(item.get(name), "inputs[%d].%s" % (index, name))
        _sha256(item.get("ciphertextSha256"), "inputs[%d].ciphertextSha256" % index)
        if item["plaintextBytes"] > MAX_OBJECT_PLAINTEXT:
            _reject("PAYLOAD_TOO_LARGE", "input object exceeds 64 MiB")
        total += item["plaintextBytes"]
    if total > MAX_TASK_PLAINTEXT:
        _reject("PAYLOAD_TOO_LARGE", "total plaintext exceeds 256 MiB")


def _validate_program(program):
    if not isinstance(program, dict) or program.get("kind") not in PROGRAM_KINDS:
        _reject("CONTRACT_INVALID", "program kind is invalid")
    _sha256(program.get("sha256"), "program.sha256")
    builtin = program["kind"] == "BUILTIN"
    has_object = isinstance(program.get("objectId"), str) and bool(program["objectId"].strip())
    if builtin == has_object:
        _reject("CONTRACT_INVALID", "program object binding is invalid")
    if not isinstance(program.get("parameters"), dict):
        _reject("CONTRACT_INVALID", "program.parameters must be an object")


def _validate_output_policy(policy):
    if not isinstance(policy, dict) or policy.get("encryptData") is not True \
            or policy.get("encryptModel") is not True \
            or policy.get("exportRequiresAllContributors") is not True:
        _reject("CONTRACT_INVALID", "output encryption policy is invalid")
    kinds = policy.get("reportKinds")
    if not isinstance(kinds, list) or any(kind not in REPORT_KINDS for kind in kinds):
        _reject("CONTRACT_INVALID", "report kind is not in the whitelist")


def validate_object_for_input(envelope, task_input):
    """Validate metadata/AAD/hash before AES-GCM authentication and decryption."""
    if not isinstance(envelope, dict) or envelope.get("contractVersion") != CONTRACT_VERSION:
        _reject("CONTRACT_INVALID", "encrypted object contract version mismatch")
    for name in ("assetId", "keyId"):
        if envelope.get(name) != task_input.get(name):
            _reject("DATA_INTEGRITY_FAILED", "encrypted object is not bound to task input")
    for name in ("assetVersion", "keyVersion"):
        if _wire_version(envelope.get(name), name) != task_input.get(name):
            _reject("DATA_INTEGRITY_FAILED", "encrypted object version is not bound to task input")
    if envelope.get("algorithm") != "AES-256-GCM":
        _reject("CONTRACT_INVALID", "encrypted object algorithm is invalid")
    nonce, aad, ciphertext, tag = (_b64(envelope.get(name), name) for name in
                                   ("nonceB64", "aadB64", "ciphertextB64", "tagB64"))
    if len(nonce) != 12 or len(tag) != 16:
        _reject("CONTRACT_INVALID", "AES-GCM nonce or tag length is invalid")
    digest = hashlib.sha256(nonce + aad + ciphertext + tag).hexdigest()
    if digest != _sha256(envelope.get("ciphertextSha256"), "ciphertextSha256") \
            or digest != task_input.get("ciphertextSha256"):
        _reject("DATA_INTEGRITY_FAILED", "ciphertext digest mismatch")
    try:
        aad_binding = json.loads(aad.decode("utf-8"))
    except Exception as exc:
        raise ContractError("DATA_INTEGRITY_FAILED", "AAD is not a bound JSON object") from exc
    current_fields = {"assetId", "assetVersion", "keyId", "keyVersion"}
    legacy_fields = current_fields | {"contractVersion"}
    fields = set(aad_binding) if isinstance(aad_binding, dict) else set()
    if fields != current_fields and not (fields == legacy_fields
            and aad_binding.get("contractVersion") == CONTRACT_VERSION):
        _reject("DATA_INTEGRITY_FAILED", "AAD field set is not contract bound")
    for name in ("assetId", "keyId"):
        if aad_binding.get(name) != task_input.get(name):
            _reject("DATA_INTEGRITY_FAILED", "AAD binding mismatch")
    for name in ("assetVersion", "keyVersion"):
        if _wire_version(aad_binding.get(name), "AAD " + name) != task_input.get(name):
            _reject("DATA_INTEGRITY_FAILED", "AAD version binding mismatch")
    return nonce, aad, ciphertext, tag


def decrypt_input(envelope, task_input, key):
    nonce, aad, ciphertext, tag = validate_object_for_input(envelope, task_input)
    if not isinstance(key, bytes) or len(key) != 32:
        _reject("DATA_INTEGRITY_FAILED", "input key must be 32 bytes")
    try:
        return AESGCM(key).decrypt(nonce, ciphertext + tag, aad)
    except Exception as exc:
        raise ContractError("DATA_INTEGRITY_FAILED", "AES-GCM authentication failed") from exc


def unwrap_key_envelope(envelope, task_input, private_key_pem, workload_cert_sha256):
    if not isinstance(envelope, dict) or envelope.get("algorithm") != "RSA-OAEP-256":
        _reject("CONTRACT_INVALID", "key envelope algorithm is invalid")
    if envelope.get("keyId") != task_input.get("keyId") \
            or _wire_version(envelope.get("keyVersion"), "keyVersion") != task_input.get("keyVersion"):
        _reject("DATA_INTEGRITY_FAILED", "key envelope is not bound to task input")
    if envelope.get("recipientCertSha256") != workload_cert_sha256:
        _reject("TASK_SIGNATURE_INVALID", "key envelope recipient mismatch")
    try:
        private_key = serialization.load_pem_private_key(private_key_pem, password=None)
        key = private_key.decrypt(_b64(envelope.get("wrappedKeyB64"), "wrappedKeyB64"),
            padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    except ContractError:
        raise
    except Exception as exc:
        raise ContractError("DATA_INTEGRITY_FAILED", "RSA-OAEP key unwrap failed") from exc
    if len(key) != 32:
        _reject("DATA_INTEGRITY_FAILED", "unwrapped data key must be 32 bytes")
    return key
