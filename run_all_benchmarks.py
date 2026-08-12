#!/usr/bin/env python3
"""Run multiple benchmarks through Llama Stack and report results."""
import sys, os, time, json, statistics, concurrent.futures
os.environ["HOME"] = "/tmp"
sys.path.insert(0, "/tmp/pylib/lib/python3.11/site-packages")

import openai
import numpy as np

LLAMA_STACK_URL = os.environ.get(
    "LLAMA_STACK_URL", "http://ogx-server-service:8321"
)
MODEL = os.environ.get("MODEL_ID", "simulator")

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


def timed_completion(client, prompt, max_tokens=150):
    start = time.time()
    try:
        resp = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=max_tokens,
            temperature=0.7,
        )
        elapsed = time.time() - start
        usage = resp.usage
        return {
            "elapsed_s": elapsed,
            "prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "total_tokens": usage.total_tokens,
            "ttft_s": None,
            "error": None,
        }
    except Exception as e:
        return {"elapsed_s": time.time() - start, "error": str(e)}


def timed_streaming_completion(client, prompt, max_tokens=150):
    start = time.time()
    ttft = None
    tokens = 0
    try:
        stream = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": prompt}],
            max_tokens=max_tokens,
            temperature=0.7,
            stream=True,
        )
        for chunk in stream:
            if chunk.choices and chunk.choices[0].delta.content:
                if ttft is None:
                    ttft = time.time() - start
                tokens += 1
        elapsed = time.time() - start
        return {
            "elapsed_s": elapsed,
            "ttft_s": ttft,
            "output_tokens": tokens,
            "error": None,
        }
    except Exception as e:
        return {"elapsed_s": time.time() - start, "error": str(e)}


def pct(data, p):
    if not data:
        return None
    return float(np.percentile(data, p))


def run_benchmark(name, func, num_requests, concurrency, client):
    print(f"\n{'=' * 60}")
    print(f"  BENCHMARK: {name}")
    print(f"  Requests: {num_requests}, Concurrency: {concurrency}")
    print(f"{'=' * 60}")

    results = []
    start = time.time()

    if concurrency == 1:
        for i in range(num_requests):
            prompt = PROMPTS[i % len(PROMPTS)]
            r = func(client, prompt)
            results.append(r)
            if (i + 1) % 10 == 0:
                print(f"  {i + 1}/{num_requests} done")
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            futures = []
            for i in range(num_requests):
                prompt = PROMPTS[i % len(PROMPTS)]
                futures.append(pool.submit(func, client, prompt))
            progress_step = max(num_requests // 10, 1)
            for i, f in enumerate(concurrent.futures.as_completed(futures)):
                results.append(f.result())
                if (i + 1) % progress_step == 0:
                    print(f"  {i + 1}/{num_requests} done")

    total_time = time.time() - start

    errors = [r for r in results if r.get("error")]
    good = [r for r in results if not r.get("error")]
    latencies = [r["elapsed_s"] for r in good]

    report = {
        "benchmark": name,
        "num_requests": num_requests,
        "concurrency": concurrency,
        "total_time_s": round(total_time, 2),
        "throughput_rps": round(num_requests / total_time, 3),
        "errors": len(errors),
        "latency_p50_s": round(pct(latencies, 50), 3) if latencies else None,
        "latency_p95_s": round(pct(latencies, 95), 3) if latencies else None,
        "latency_p99_s": round(pct(latencies, 99), 3) if latencies else None,
        "latency_avg_s": round(statistics.mean(latencies), 3) if latencies else None,
        "latency_min_s": round(min(latencies), 3) if latencies else None,
        "latency_max_s": round(max(latencies), 3) if latencies else None,
    }

    if any(r.get("ttft_s") for r in good):
        ttfts = [r["ttft_s"] for r in good if r.get("ttft_s")]
        report["ttft_p50_s"] = round(pct(ttfts, 50), 4)
        report["ttft_p95_s"] = round(pct(ttfts, 95), 4)

    if any(r.get("prompt_tokens") for r in good):
        total_prompt = sum(r.get("prompt_tokens", 0) for r in good)
        total_comp = sum(r.get("completion_tokens", 0) for r in good)
        report["total_prompt_tokens"] = total_prompt
        report["total_completion_tokens"] = total_comp
        report["input_tok_per_s"] = round(total_prompt / total_time, 1)
        report["output_tok_per_s"] = round(total_comp / total_time, 1)

    if any(r.get("output_tokens") for r in good):
        total_out = sum(r.get("output_tokens", 0) for r in good)
        report["total_output_tokens_streaming"] = total_out
        report["output_tok_per_s_streaming"] = round(total_out / total_time, 1)

    return report


def print_report(reports):
    print(f"\n{'=' * 100}")
    print(f"  COMPREHENSIVE BENCHMARK RESULTS")
    print(f"  Model: {MODEL}")
    print(f"  Endpoint: {LLAMA_STACK_URL} (Llama Stack)")
    print(f"{'=' * 100}\n")

    hdr = f"{'Benchmark':<35} {'Conc':>4} {'Reqs':>5} {'RPS':>7} {'p50(s)':>7} {'p95(s)':>7} {'p99(s)':>7} {'Avg(s)':>7} {'Err':>4}"
    print(hdr)
    print("-" * len(hdr))
    for r in reports:
        p50 = r.get("latency_p50_s", "N/A")
        p95 = r.get("latency_p95_s", "N/A")
        p99 = r.get("latency_p99_s", "N/A")
        avg = r.get("latency_avg_s", "N/A")
        print(
            f"{r['benchmark']:<35} {r['concurrency']:>4} {r['num_requests']:>5} "
            f"{r['throughput_rps']:>7.3f} {p50!s:>7} {p95!s:>7} {p99!s:>7} {avg!s:>7} {r['errors']:>4}"
        )

    print(f"\n{'Token Throughput':<35} {'In tok/s':>10} {'Out tok/s':>10} {'TTFT p50':>10} {'TTFT p95':>10}")
    print("-" * 75)
    for r in reports:
        in_t = r.get("input_tok_per_s", r.get("output_tok_per_s_streaming", "N/A"))
        out_t = r.get("output_tok_per_s", r.get("output_tok_per_s_streaming", "N/A"))
        ttft50 = r.get("ttft_p50_s", "N/A")
        ttft95 = r.get("ttft_p95_s", "N/A")
        print(f"{r['benchmark']:<35} {in_t!s:>10} {out_t!s:>10} {ttft50!s:>10} {ttft95!s:>10}")


CONCURRENCY_LEVELS = [5, 10, 20, 40, 60, 80, 100, 150, 200, 300, 500, 1000]
REQUESTS_PER_LEVEL = 800


def main():
    client = openai.OpenAI(base_url=f"{LLAMA_STACK_URL}/v1", api_key="unused")

    print("Warming up (3 requests)...")
    for i in range(3):
        timed_completion(client, "Hello, respond briefly.", max_tokens=20)
    print("Warm-up done.\n")
    print(f"Concurrency levels: {CONCURRENCY_LEVELS}")
    print(f"Requests per level: {REQUESTS_PER_LEVEL}")
    print(f"Total requests: {len(CONCURRENCY_LEVELS) * REQUESTS_PER_LEVEL * 2} "
          f"({len(CONCURRENCY_LEVELS)} levels x {REQUESTS_PER_LEVEL} reqs x 2 modes)\n")

    reports = []

    for conc in CONCURRENCY_LEVELS:
        reports.append(
            run_benchmark(
                f"OpenAI SDK: Conc={conc} (non-stream)",
                timed_completion, REQUESTS_PER_LEVEL, conc, client,
            )
        )
        reports.append(
            run_benchmark(
                f"OpenAI SDK: Conc={conc} (streaming)",
                timed_streaming_completion, REQUESTS_PER_LEVEL, conc, client,
            )
        )

    print_report(reports)

    ts = time.strftime("%Y%m%d-%H%M%S")
    outfile = f"/tmp/openai-sdk-bench-{ts}.json"
    with open(outfile, "w") as f:
        json.dump(reports, f, indent=2)
    print(f"\nResults saved to {outfile}")


if __name__ == "__main__":
    main()
