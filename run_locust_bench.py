#!/usr/bin/env python3
"""Run locust benchmark (headless mode) through Llama Stack."""
import sys, os, time, json, statistics
os.environ["HOME"] = "/tmp"
sys.path.insert(0, "/tmp/pylib/lib/python3.11/site-packages")

import numpy as np

LLAMA_STACK_URL = "http://llama-stack:8321"
MODEL = "vllm-inference/Qwen/Qwen2.5-7B-Instruct"

LOCUSTFILE = "/tmp/locustfile_llama.py"

locust_code = '''
import time, json, os
os.environ["HOME"] = "/tmp"
import sys
sys.path.insert(0, "/tmp/pylib/lib/python3.11/site-packages")
from locust import HttpUser, task, between, events

MODEL = "vllm-inference/Qwen/Qwen2.5-7B-Instruct"

PROMPTS = [
    "Explain the concept of quantum entanglement in simple terms.",
    "Write a Python function that implements binary search on a sorted array.",
    "What are the key differences between TCP and UDP protocols?",
    "Describe the architecture of a transformer neural network.",
    "Explain how garbage collection works in Java vs Python.",
    "What is the CAP theorem in distributed systems?",
    "Write a brief history of the internet in 200 words.",
    "Explain the difference between supervised and unsupervised learning.",
    "What are the SOLID principles in software engineering?",
    "Describe how DNS resolution works step by step.",
]

class LlamaStackUser(HttpUser):
    wait_time = between(0.1, 0.5)

    @task
    def chat_completion(self):
        import random
        prompt = random.choice(PROMPTS)
        payload = {
            "model": MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 150,
            "temperature": 0.7,
        }
        with self.client.post(
            "/v1/chat/completions",
            json=payload,
            headers={"Content-Type": "application/json"},
            catch_response=True,
            name="/v1/chat/completions",
        ) as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"Status {response.status_code}")
'''

with open(LOCUSTFILE, "w") as f:
    f.write(locust_code)

print("Locust file written. Running headless locust test...")
print(f"  Target: {LLAMA_STACK_URL}")
print(f"  Model: {MODEL}")
print(f"  Users: 1->5->10->20->40 (stepping), 30s each step\n")

os.environ["PYTHONPATH"] = "/tmp/pylib/lib/python3.11/site-packages:" + os.environ.get("PYTHONPATH", "")
os.environ["PATH"] = "/tmp/pylib/bin:" + os.environ.get("PATH", "")

import subprocess

steps = [
    {"users": 1, "rate": 1, "duration": "30s"},
    {"users": 5, "rate": 5, "duration": "30s"},
    {"users": 10, "rate": 5, "duration": "30s"},
    {"users": 20, "rate": 5, "duration": "30s"},
    {"users": 40, "rate": 10, "duration": "30s"},
]

all_results = []

for i, step in enumerate(steps):
    csv_prefix = f"/tmp/locust-step-{i}"
    cmd = [
        sys.executable, "-m", "locust",
        "-f", LOCUSTFILE,
        "--host", LLAMA_STACK_URL,
        "--headless",
        "-u", str(step["users"]),
        "-r", str(step["rate"]),
        "-t", step["duration"],
        "--csv", csv_prefix,
        "--only-summary",
    ]
    print(f"--- Step {i + 1}: {step['users']} users, spawn-rate {step['rate']}, {step['duration']} ---")
    result = subprocess.run(cmd, capture_output=True, text=True, env=os.environ)

    print(result.stdout[-1500:] if len(result.stdout) > 1500 else result.stdout)
    if result.returncode != 0:
        print(f"STDERR: {result.stderr[-500:]}")

    stats_file = f"{csv_prefix}_stats.csv"
    if os.path.exists(stats_file):
        with open(stats_file) as f:
            content = f.read()
        print(content)
        all_results.append({"step": i + 1, "users": step["users"], "csv": content})

with open("/tmp/locust-all-results.json", "w") as f:
    json.dump(all_results, f, indent=2)

print(f"\nLocust results saved to /tmp/locust-all-results.json")
