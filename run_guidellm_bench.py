#!/usr/bin/env python3
"""Run guidellm benchmark through Llama Stack."""
import sys, os, subprocess, json
os.environ["HOME"] = "/tmp"
sys.path.insert(0, "/tmp/pylib/lib/python3.11/site-packages")
os.environ["PATH"] = "/tmp/pylib/bin:" + os.environ.get("PATH", "")

LLAMA_STACK_URL = "http://llama-stack:8321"
MODEL = "vllm-inference/Qwen/Qwen2.5-7B-Instruct"

cmd = [
    "/tmp/pylib/bin/guidellm",
    "--target", f"{LLAMA_STACK_URL}/v1",
    "--model", MODEL,
    "--data", "prompt_tokens=128,generated_tokens=128",
    "--rate", "1,2,5,10,20",
    "--max-seconds", "30",
    "--output-path", "/tmp/guidellm-results.json",
]

print(f"Running: {' '.join(cmd)}")
result = subprocess.run(cmd, capture_output=False, text=True, env=os.environ)
print(f"\nguidellm exit code: {result.returncode}")

if os.path.exists("/tmp/guidellm-results.json"):
    with open("/tmp/guidellm-results.json") as f:
        data = json.load(f)
    print(json.dumps(data, indent=2, default=str)[:5000])
