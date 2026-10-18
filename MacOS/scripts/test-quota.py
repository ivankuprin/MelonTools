#!/usr/bin/env python3
"""Validate the quota endpoint + headers used by CodexService.fetchQuota().
Prints no secrets."""
import base64
import json
import os
import urllib.request
import urllib.error

with open(os.path.expanduser("~/.codex/auth.json")) as f:
    auth = json.load(f)
tokens = auth.get("tokens") or {}
access = tokens.get("access_token", "")
account_id = tokens.get("account_id", "")

def jwt_claims(tok):
    try:
        payload = tok.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}

account_id = account_id or jwt_claims(tokens.get("id_token", "")).get("https://api.openai.com/auth", {}).get("account_id", "")

UA = "Codex Desktop (macOS; arm64)"   # same string the Swift app sends

req = urllib.request.Request("https://chatgpt.com/backend-api/wham/usage")
req.add_header("Authorization", f"Bearer {access}")
req.add_header("User-Agent", UA)
req.add_header("originator", "Codex Desktop")
if account_id:
    req.add_header("ChatGPT-Account-Id", account_id)

try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print("HTTP", r.status)
        body = json.loads(r.read())
except urllib.error.HTTPError as e:
    print("HTTPError", e.code)
    try:
        print("body:", e.read()[:300])
    except Exception:
        pass
    raise SystemExit(1)

print("plan_type:", body.get("plan_type"))
rl = body.get("rate_limit") or {}
for name in ("primary_window", "secondary_window"):
    w = rl.get(name)
    if w is None:
        print(f"{name}: (absent)")
        continue
    print(f"{name}: used_percent={w.get('used_percent')} window_s={w.get('limit_window_seconds')} reset_after_s={w.get('reset_after_seconds')} reset_at={w.get('reset_at')}")
credits = body.get("rate_limit_reset_credits") or {}
print("reset credits available:", credits.get("available_count"))
print("ALL_KEYS:", sorted(body.keys()))
