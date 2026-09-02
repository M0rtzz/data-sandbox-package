#!/usr/bin/env python3
"""Offline P5 validation against the public synthetic vector only."""
import base64
import copy
import json
import sys
from datetime import datetime
from pathlib import Path

from tee_contract_runtime import (ContractError, decrypt_input, validate_object_for_input,
                                  validate_task_spec, verify_task_jws)


def rejects(action, code):
    try:
        action()
    except ContractError as exc:
        assert exc.error_code == code, (exc.error_code, code)
    else:
        raise AssertionError("expected rejection " + code)


examples = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = examples["taskPayload"]
test = examples["testMaterial"]
now = datetime.fromisoformat(test["verificationTime"].replace("Z", "+00:00"))
verified = verify_task_jws(examples["taskJws"], {test["trustedKid"]: test["trustedPublicKeyPem"]},
                           task["audience"], task["runtimeImageDigest"], now)
assert verified["taskId"] == task["taskId"]
assert decrypt_input(examples["asset"], task["inputs"][0], base64.b64decode(test["inputKeyB64"])) == \
       test["plaintextUtf8"].encode()

tampered = copy.deepcopy(examples["asset"])
tampered_ciphertext = base64.b64decode(tampered["ciphertextB64"])
tampered["ciphertextB64"] = base64.b64encode(bytes([tampered_ciphertext[0] ^ 1]) + tampered_ciphertext[1:]).decode()
rejects(lambda: validate_object_for_input(tampered, task["inputs"][0]), "DATA_INTEGRITY_FAILED")
rejects(lambda: verify_task_jws(examples["taskJws"], {}, task["audience"], task["runtimeImageDigest"], now),
        "TASK_SIGNATURE_INVALID")
short_lived = copy.deepcopy(task)
short_lived["expiresAt"] = short_lived["issuedAt"]
rejects(lambda: validate_task_spec(short_lived, short_lived["audience"],
                                   short_lived["runtimeImageDigest"], now), "CONTRACT_INVALID")
print("P5_CONTRACT_RUNTIME_VECTOR=OK")
