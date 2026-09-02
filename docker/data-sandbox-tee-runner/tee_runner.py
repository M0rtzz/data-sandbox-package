#!/usr/bin/env python3
"""P5 trusted runtime wrapper.

It verifies a tee-contract/1.0 RS256 task, unwraps only task-bound keys,
authenticates AES-GCM inputs in memory, and invokes an existing runner command
with filtered plaintext paths.  It deliberately has no plaintext Base64 task
fallback and never emits keys or plaintext in logs.
"""
import base64, csv, hashlib, json, os, secrets, subprocess, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from tee_contract_runtime import ContractError, verify_task_jws

CONTRACT = "tee-contract/1.0"

def fail(code, message):
    print(json.dumps({"status":"FAILED", "errorCode":code, "message":message}), file=sys.stderr)
    raise SystemExit(1)

def b64url(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))

def read_json(path):
    with open(path, encoding="utf-8") as f: return json.load(f)

def verify_task(compact):
    try:
        h, p, s = compact.split(".")
        header, payload = json.loads(b64url(h)), json.loads(b64url(p))
    except Exception: fail("TASK_SIGNATURE_INVALID", "malformed JWS")
    if header.get("alg") != "RS256" or header.get("typ") != "JWS": fail("TASK_SIGNATURE_INVALID", "unsupported JWS header")
    key_path = os.environ.get("TEE_ISSUER_PUBLIC_KEY")
    if not key_path: fail("TASK_SIGNATURE_INVALID", "issuer trust key unavailable")
    try:
        key = serialization.load_pem_public_key(Path(key_path).read_bytes())
        key.verify(b64url(s), f"{h}.{p}".encode(), padding.PKCS1v15(), hashes.SHA256())
    except Exception: fail("TASK_SIGNATURE_INVALID", "signature verification failed")
    if payload.get("contractVersion") != CONTRACT: fail("CONTRACT_INVALID", "contract version mismatch")
    if payload.get("audience") != os.environ.get("TEE_AUDIENCE"): fail("TASK_SIGNATURE_INVALID", "audience mismatch")
    if payload.get("runtimeImageDigest") != os.environ.get("TEE_RUNTIME_IMAGE_DIGEST"): fail("TASK_SIGNATURE_INVALID", "runtime image mismatch")
    try:
        expires = datetime.fromisoformat(payload["expiresAt"].replace("Z", "+00:00"))
        if datetime.now(timezone.utc) > expires: fail("TASK_EXPIRED", "task expired")
    except KeyError: fail("CONTRACT_INVALID", "expiresAt missing")
    return payload

def consume_nonce(task):
    store = Path(os.environ.get("TEE_NONCE_STORE", "/tee/nonces"))
    store.mkdir(parents=True, exist_ok=True)
    path = store / hashlib.sha256((task.get("issuer", "") + "\0" + task.get("nonce", "")).encode()).hexdigest()
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    except FileExistsError: fail("TASK_REPLAYED", "task nonce already consumed")

def filter_columns(data, columns):
    try:
        rows = list(csv.DictReader(data.decode().splitlines()))
        header = list(rows[0].keys()) if rows else []
        if not columns or any(c not in header for c in columns): fail("POLICY_DENIED", "requested column is not available")
        out = []
        with tempfile.SpooledTemporaryFile(mode="w+", newline="", max_size=1024 * 1024) as f:
            w = csv.DictWriter(f, fieldnames=columns); w.writeheader(); w.writerows({c:r[c] for c in columns} for r in rows)
            f.seek(0); return f.read().encode()
    except SystemExit: raise
    except Exception: fail("DATA_INTEGRITY_FAILED", "CSV filtering failed")

def unwrap(envelope):
    if envelope.get("algorithm") != "RSA-OAEP-256": fail("CONTRACT_INVALID", "unsupported key envelope")
    private_path = os.environ.get("TEE_WORKLOAD_PRIVATE_KEY")
    if not private_path: fail("KEY_SERVICE_UNAVAILABLE", "workload key unavailable")
    try:
        key = serialization.load_pem_private_key(Path(private_path).read_bytes(), password=None)
        return key.decrypt(base64.b64decode(envelope["wrappedKeyB64"]), padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    except Exception: fail("DATA_INTEGRITY_FAILED", "key envelope cannot be opened")

def decrypt(obj, key):
    try:
        nonce, aad, ct, tag = (base64.b64decode(obj[x]) for x in ("nonceB64","aadB64","ciphertextB64","tagB64"))
        if len(nonce) != 12 or len(tag) != 16: fail("CONTRACT_INVALID", "invalid GCM parameters")
        digest = hashlib.sha256(nonce + aad + ct + tag).hexdigest()
        if digest != obj.get("ciphertextSha256"): fail("DATA_INTEGRITY_FAILED", "ciphertext digest mismatch")
        return AESGCM(key).decrypt(nonce, ct + tag, aad)
    except SystemExit: raise
    except Exception: fail("DATA_INTEGRITY_FAILED", "GCM authentication failed")

def encrypt_output(task, data, key):
    nonce = secrets.token_bytes(12)
    aad = json.dumps({"assetId": task["taskId"], "assetVersion": 1,
                      "keyId": "result", "keyVersion": 1}, separators=(",", ":")).encode()
    sealed = AESGCM(key).encrypt(nonce, data, aad)
    ciphertext, tag = sealed[:-16], sealed[-16:]
    digest = hashlib.sha256(nonce + aad + ciphertext + tag).hexdigest()
    return {"contractVersion": CONTRACT, "assetId": task["taskId"], "assetVersion": 1,
            "keyId": "result", "keyVersion": 1, "algorithm": "AES-256-GCM",
            "nonceB64": base64.b64encode(nonce).decode(), "aadB64": base64.b64encode(aad).decode(),
            "ciphertextB64": base64.b64encode(ciphertext).decode(), "tagB64": base64.b64encode(tag).decode(),
            "ciphertextSha256": digest}

def receipt_jws(receipt):
    private_path = os.environ.get("TEE_WORKLOAD_PRIVATE_KEY")
    kid = os.environ.get("TEE_WORKLOAD_KID")
    if not private_path or not kid: fail("KEY_SERVICE_UNAVAILABLE", "receipt signing key unavailable")
    header = base64.urlsafe_b64encode(json.dumps({"alg":"RS256","typ":"JWS","kid":kid}, separators=(",", ":")).encode()).rstrip(b"=")
    payload = base64.urlsafe_b64encode(json.dumps(receipt, separators=(",", ":")).encode()).rstrip(b"=")
    key = serialization.load_pem_private_key(Path(private_path).read_bytes(), password=None)
    sig = key.sign(header + b"." + payload, padding.PKCS1v15(), hashes.SHA256())
    return b".".join((header, payload, base64.urlsafe_b64encode(sig).rstrip(b"="))).decode()

def _trusted_task_keys():
    """Load only an explicit kid-to-public-key trust mapping.

    A single arbitrary issuer key is intentionally not accepted. For the
    migration period a one-key map is possible only when its kid is configured
    explicitly alongside the key path.
    """
    trust_dir = os.environ.get("TEE_ISSUER_TRUST_DIR")
    if trust_dir:
        directory = Path(trust_dir)
        keys = {item.stem: item.read_bytes() for item in directory.glob("*.pem") if item.is_file()}
        if keys:
            return keys
    key_path, kid = os.environ.get("TEE_ISSUER_PUBLIC_KEY"), os.environ.get("TEE_ISSUER_KID")
    if key_path and kid:
        return {kid: Path(key_path).read_bytes()}
    fail("TASK_SIGNATURE_INVALID", "issuer trust mapping unavailable")

def verify_task_contract(compact):
    try:
        return verify_task_jws(compact, _trusted_task_keys(),
                               os.environ.get("TEE_AUDIENCE"),
                               os.environ.get("TEE_RUNTIME_IMAGE_DIGEST"))
    except ContractError as exc:
        fail(exc.error_code, str(exc))

def main():
    task = verify_task_contract(Path(os.environ.get("TEE_TASK_JWS_FILE", "/etc/kuscia/tee_task_jws")).read_text().strip())
    consume_nonce(task)
    object_dir = Path(os.environ.get("TEE_OBJECT_DIR", "/tee/objects"))
    envelope_dir = Path(os.environ.get("TEE_KEY_ENVELOPE_DIR", "/tee/envelopes"))
    command = os.environ.get("TEE_EXEC_COMMAND")
    if not command: fail("CONTRACT_INVALID", "runner command missing")
    with tempfile.TemporaryDirectory(dir="/tmp") as work:
        paths = []
        for item in task.get("inputs", []):
            obj = read_json(object_dir / (item["objectId"] + ".json"))
            if obj.get("ciphertextSha256") != item.get("ciphertextSha256"): fail("DATA_INTEGRITY_FAILED", "task/object mismatch")
            envelope = read_json(envelope_dir / (item["keyId"] + "-" + str(item["keyVersion"]) + ".json"))
            plain = filter_columns(decrypt(obj, unwrap(envelope)), task.get("columns", []))
            path = Path(work) / (item["assetId"] + ".csv")
            path.write_bytes(plain); paths.append(str(path))
        env = {"PATH":os.environ.get("PATH", ""), "TEE_INPUTS":json.dumps(paths), "TEE_WORKDIR":work}
        result = subprocess.run(command, shell=True, cwd=work, env=env, capture_output=True, text=True, timeout=1800)
        if result.returncode: fail("CONTRACT_INVALID", "underlying runner failed")
        output = Path(work) / "output.csv"
        if not output.is_file(): fail("CONTRACT_INVALID", "runner did not produce output.csv")
        result_envelope_path = os.environ.get("TEE_RESULT_KEY_ENVELOPE")
        if not result_envelope_path: fail("KEY_SERVICE_UNAVAILABLE", "result key unavailable")
        envelope = read_json(result_envelope_path)
        encrypted = encrypt_output(task, output.read_bytes(), unwrap(envelope))
        Path(os.environ.get("TEE_RESULT_ENVELOPE", "/tmp/tee-result.json")).write_text(json.dumps(encrypted), encoding="utf-8")
        receipt = {"contractVersion": CONTRACT, "taskId":task["taskId"], "requestId":task["requestId"],
                   "status":"SUCCEEDED", "runtimeMode":os.environ.get("TEE_RUNTIME_MODE", "SIMULATION"),
                   "attestationVerified":False, "policyVersion":None, "keyReleaseCount":len(paths),
                   "outputs":[{"kind":"DATA", "resultId":task["taskId"], "encrypted":True,
                   "ciphertextSha256":encrypted["ciphertextSha256"]}], "startedAt":task["issuedAt"],
                   "finishedAt":datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), "errorCode":None}
        Path(os.environ.get("TEE_RECEIPT_JWS", "/tmp/tee-receipt.jws")).write_text(receipt_jws(receipt), encoding="utf-8")
        print(json.dumps({"status":"SUCCEEDED", "taskId":task["taskId"], "runtimeMode":os.environ.get("TEE_RUNTIME_MODE", "SIMULATION"), "result":encrypted["ciphertextSha256"]}))

if __name__ == "__main__": main()
