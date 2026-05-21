#!/usr/bin/env python3
"""Run Locust benchmark through Llama Stack at each concurrency level.

Uses the same concurrency levels and request counts as 06-load-test.py.
Each step runs until 800 requests complete (based on avg RPS from prior data),
with a minimum of 30s and a maximum of 600s per step.
"""
import sys, os, subprocess, json, time, csv, io
os.environ["HOME"] = "/tmp"
sys.path.insert(0, "/tmp/pylib/lib/python3.11/site-packages")

LLAMA_STACK_URL = "http://llama-stack:8321"
CONCURRENCY_LEVELS = [5, 10, 20, 40, 60, 80, 100, 150, 200, 300, 500, 1000]
TARGET_REQUESTS = 800


def estimate_duration(conc):
    """Conservative estimate of how long to run each step to get ~800 requests."""
    rps_estimate = {
        5: 2.3, 10: 4.1, 20: 6.9, 40: 10.7, 60: 13.1, 80: 15.7,
        100: 17.0, 150: 18.6, 200: 20.5, 300: 20.5, 500: 21.6, 1000: 22.9,
    }
    rps = rps_estimate.get(conc, 10)
    secs = int(TARGET_REQUESTS / rps) + 30
    return max(60, min(secs, 600))


def parse_locust_stats(csv_path):
    """Parse a locust _stats.csv and return the Aggregated row."""
    if not os.path.exists(csv_path):
        return None
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("Name") == "Aggregated":
                return row
    return None


def main():
    ts = time.strftime("%Y%m%d-%H%M%S")
    all_results = []
    env = os.environ.copy()
    env["PYTHONPATH"] = "/tmp/pylib/lib/python3.11/site-packages:" + env.get("PYTHONPATH", "")
    env["PATH"] = "/tmp/pylib/bin:" + env.get("PATH", "")

    print(f"Locust Full Benchmark — {len(CONCURRENCY_LEVELS)} levels x ~{TARGET_REQUESTS} reqs")
    print(f"Target: {LLAMA_STACK_URL} (Llama Stack)")
    print(f"Levels: {CONCURRENCY_LEVELS}\n")

    for conc in CONCURRENCY_LEVELS:
        duration = estimate_duration(conc)
        csv_prefix = f"/tmp/locust-full-{conc}u"

        print(f"{'=' * 60}")
        print(f"  LOCUST: {conc} users, {duration}s run time")
        print(f"{'=' * 60}")

        cmd = [
            sys.executable, "-m", "locust",
            "-f", "/tmp/locustfile_llama.py",
            "--host", LLAMA_STACK_URL,
            "--headless",
            "-u", str(conc),
            "-r", str(min(conc, 100)),
            "-t", f"{duration}s",
            "--csv", csv_prefix,
            "--only-summary",
        ]

        result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=duration + 60)
        stdout = result.stdout
        stderr = result.stderr

        for line in (stdout + stderr).splitlines():
            if "Aggregated" in line or "reqs" in line.lower() or "fail" in line.lower():
                print(f"  {line.strip()}")

        stats = parse_locust_stats(f"{csv_prefix}_stats.csv")
        if stats:
            all_results.append({
                "concurrency": conc,
                "duration_s": duration,
                "request_count": int(stats.get("Request Count", 0)),
                "failure_count": int(stats.get("Failure Count", 0)),
                "avg_ms": float(stats.get("Average Response Time", 0)),
                "min_ms": float(stats.get("Min Response Time", 0)),
                "max_ms": float(stats.get("Max Response Time", 0)),
                "median_ms": float(stats.get("Median Response Time", 0)),
                "rps": float(stats.get("Requests/s", 0)),
                "failures_per_s": float(stats.get("Failures/s", 0)),
                "p50_ms": float(stats.get("50%", 0)),
                "p66_ms": float(stats.get("66%", 0)),
                "p75_ms": float(stats.get("75%", 0)),
                "p80_ms": float(stats.get("80%", 0)),
                "p90_ms": float(stats.get("90%", 0)),
                "p95_ms": float(stats.get("95%", 0)),
                "p98_ms": float(stats.get("98%", 0)),
                "p99_ms": float(stats.get("99%", 0)),
            })
            print(f"  Reqs: {stats.get('Request Count')}, "
                  f"RPS: {stats.get('Requests/s')}, "
                  f"Avg: {stats.get('Average Response Time')}ms, "
                  f"p50: {stats.get('Median Response Time')}ms, "
                  f"Failures: {stats.get('Failure Count')}")
        else:
            print(f"  WARNING: No stats CSV found for {conc} users")
            if result.returncode != 0:
                print(f"  Exit code: {result.returncode}")
                print(f"  Stderr (last 500): {stderr[-500:]}")

        print()

    # Summary table
    print(f"\n{'=' * 100}")
    print(f"  LOCUST BENCHMARK RESULTS")
    print(f"  Target: {LLAMA_STACK_URL} (Llama Stack)")
    print(f"{'=' * 100}\n")

    hdr = (f"{'Conc':>5} {'Reqs':>6} {'RPS':>7} {'Avg(ms)':>8} {'p50(ms)':>8} "
           f"{'p95(ms)':>8} {'p99(ms)':>8} {'Min(ms)':>8} {'Max(ms)':>8} {'Err':>4}")
    print(hdr)
    print("-" * len(hdr))
    for r in all_results:
        print(f"{r['concurrency']:>5} {r['request_count']:>6} {r['rps']:>7.1f} "
              f"{r['avg_ms']:>8.0f} {r['p50_ms']:>8.0f} "
              f"{r['p95_ms']:>8.0f} {r['p99_ms']:>8.0f} "
              f"{r['min_ms']:>8.0f} {r['max_ms']:>8.0f} {r['failure_count']:>4}")

    outfile = f"/tmp/locust-full-bench-{ts}.json"
    with open(outfile, "w") as f:
        json.dump(all_results, f, indent=2)
    print(f"\nResults saved to {outfile}")


if __name__ == "__main__":
    main()
