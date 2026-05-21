import sys, os, random, time
os.environ["HOME"] = "/tmp"
sys.path.insert(0, "/tmp/pylib/lib/python3.11/site-packages")
from locust import HttpUser, task, between

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
    wait_time = between(0, 0)

    @task
    def chat_completion(self):
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
