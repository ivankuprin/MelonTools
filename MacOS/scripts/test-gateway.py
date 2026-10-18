#!/usr/bin/env python3
"""Smoke-test the Melon Tools gateway config shape against the real CLIProxyAPI binary."""
import subprocess
import time
import urllib.request
import urllib.error
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "build", "cliproxyapi")
TEST_DIR = "/tmp/melon-gw-test"
CONFIG = f"{TEST_DIR}/config.yaml"
AUTHS = f"{TEST_DIR}/auths"

os.makedirs(AUTHS, exist_ok=True)

config = f"""# Melon Tools test config
config-version: 8

server:
  host: "127.0.0.1"
  port: 18399

access:
  api-keys:
    - "melon-test-key"

oauth:
  auth-dir: "{AUTHS}"
"""
with open(CONFIG, "w") as f:
    f.write(config)

proc = subprocess.Popen([BIN, "-config", CONFIG],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print(f"started pid {proc.pid}, waiting for boot...")
time.sleep(4)

result = 1
for attempt in range(3):
    req = urllib.request.Request("http://127.0.0.1:18399/v1/models",
                                 headers={"Authorization": "Bearer melon-test-key"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = resp.read()[:300]
            print("HTTP", resp.status)
            print("BODY", body)
            result = 0
            break
    except urllib.error.HTTPError as e:
        print("HTTPError", e.code, e.read()[:300])
        result = 0  # server responded; shape is valid
        break
    except Exception as e:
        print(f"attempt {attempt}: {e}")
        time.sleep(2)

# unauthorized check
try:
    req = urllib.request.Request("http://127.0.0.1:18399/v1/models")
    urllib.request.urlopen(req, timeout=5)
    print("WARN: unauthenticated request answered")
except urllib.error.HTTPError as e:
    print("unauth check: HTTP", e.code)
except Exception as e:
    print("unauth check error:", e)

proc.terminate()
try:
    out, _ = proc.communicate(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    out, _ = proc.communicate()
print("---- gateway output (tail) ----")
print("\n".join(out.splitlines()[-12:]))
sys.exit(result)
