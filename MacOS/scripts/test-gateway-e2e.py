#!/usr/bin/env python3
"""E2E: transform ~/.codex/auth.json into Melon Tools' gateway account format,
boot CLIProxyAPI against it, and verify the credential loads + models enumerate.
Prints no secrets."""
import atexit
import base64
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.request
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "build", "cliproxyapi")
# Real tokens are written here for the smoke test: keep the directory private
# and remove it even when the script fails.
TEST_DIR = tempfile.mkdtemp(prefix="melon-gw-e2e-")
CONFIG = f"{TEST_DIR}/config.yaml"
AUTHS = f"{TEST_DIR}/auths"
PORT = 18402
KEY = "melon-e2e-key"

os.umask(0o077)
os.makedirs(AUTHS, mode=0o700, exist_ok=True)
atexit.register(lambda: shutil.rmtree(TEST_DIR, ignore_errors=True))

with open(os.path.expanduser("~/.codex/auth.json")) as f:
    auth = json.load(f)
tokens = auth.get("tokens") or {}

def jwt_claims(tok):
    try:
        payload = tok.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}

claims = jwt_claims(tokens.get("id_token", ""))
auth_claims = claims.get("https://api.openai.com/auth", {})

# Mirror the Swift syncAccounts() output exactly.
account = {
    "id_token": tokens.get("id_token", ""),
    "access_token": tokens.get("access_token", ""),
    "refresh_token": tokens.get("refresh_token", ""),
    "account_id": tokens.get("account_id", "") or auth_claims.get("account_id", ""),
    "last_refresh": auth.get("last_refresh", ""),
    "email": claims.get("email", ""),
    "type": "codex",
    "expired": "",
    "plan_type": auth_claims.get("chatgpt_plan_type", "free"),
}
# token_expiry hint from access token
exp = jwt_claims(tokens.get("access_token", "")).get("exp")
if exp:
    account["expired"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp))

auth_path = f"{AUTHS}/codex-e2e-account.json"
with open(auth_path, "w") as f:
    json.dump(account, f, indent=2)
os.chmod(auth_path, 0o600)
print("account file written: email=%s plan=%s account_id_present=%s" % (
    account["email"] or "(none)", account["plan_type"], bool(account["account_id"])))

with open(CONFIG, "w") as f:
    os.chmod(CONFIG, 0o600)
    f.write(f"""# Melon Tools E2E test config
config-version: 8

server:
  host: "127.0.0.1"
  port: {PORT}

access:
  api-keys:
    - "{KEY}"

oauth:
  auth-dir: "{AUTHS}"
""")

proc = subprocess.Popen([BIN, "-config", CONFIG], stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True)
time.sleep(5)

def get(path, headers=None):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

status, body = get("/v1/models", {"Authorization": f"Bearer {KEY}"})
print("GET /v1/models ->", status)
try:
    data = json.loads(body)
    models = [m.get("id") for m in data.get("data", [])]
    print("models returned:", len(models))
    for m in models[:8]:
        print("  -", m)
except Exception as e:
    print("body parse failed:", e)

proc.terminate()
try:
    out, _ = proc.communicate(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    out, _ = proc.communicate()

print("---- client load lines ----")
for line in out.splitlines():
    if "client load complete" in line or "Codex keys" in line or "error" in line.lower():
        print(line[-220:])
