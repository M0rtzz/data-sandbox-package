#!/usr/bin/env python3
"""Offline checks against the public synthetic examples; no production key is used."""
import base64, hashlib, json, sys
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

e = json.loads(Path(sys.argv[1]).read_text())
def check(env, key):
    n,a,c,t=(base64.b64decode(env[x]) for x in ("nonceB64","aadB64","ciphertextB64","tagB64"))
    assert hashlib.sha256(n+a+c+t).hexdigest() == env["ciphertextSha256"]
    return AESGCM(base64.b64decode(key)).decrypt(n,c+t,a)
assert check(e["asset"], e["testMaterial"]["inputKeyB64"]) == e["testMaterial"]["plaintextUtf8"].encode()
assert check(e["outputEnvelope"], e["testMaterial"]["outputKeyB64"]) == e["testMaterial"]["outputPlaintextUtf8"].encode()
def verify(jws):
    h,p,s=jws.split(".")
    key=serialization.load_pem_public_key(e["testMaterial"]["trustedPublicKeyPem"].encode())
    key.verify(base64.urlsafe_b64decode(s+"="*(-len(s)%4)), (h+"."+p).encode(), padding.PKCS1v15(), hashes.SHA256())
verify(e["taskJws"])
print("CONTRACT_VECTOR_AES_GCM_AND_JWS=OK")
