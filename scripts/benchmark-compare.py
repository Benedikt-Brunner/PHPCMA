#!/usr/bin/env python3
"""Compare current PHPCMA benchmark run against a baseline.

Usage:
    scripts/benchmark-compare.py --baseline tests/corpus/performance-baseline.json [--current run.json]
    scripts/benchmark-compare.py --baseline tests/corpus/performance-baseline.json --history perf-history/

If --current is omitted, reads JSON from stdin (pipe from benchmark.sh).
If --history is given, prints sparkline of historical runs.

Exit codes:
    0  No regression
    1  Regression detected
"""
import argparse
import json
import sys
import os
import glob


WALL_CLOCK_THRESHOLD = 2.0   # Flag if > 2x baseline
MEMORY_THRESHOLD = 1.5       # Flag if > 1.5x baseline

SPARK_CHARS = "▁▂▃▄▅▆▇█"


def sparkline(values: list[float]) -> str:
    if not values:
        return ""
    lo, hi = min(values), max(values)
    rng = hi - lo if hi != lo else 1.0
    return "".join(SPARK_CHARS[min(int((v - lo) / rng * (len(SPARK_CHARS) - 1)), len(SPARK_CHARS) - 1)] for v in values)


def load_json(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def load_history(directory: str) -> list[dict]:
    """Load all JSON files in a directory, sorted by date."""
    files = sorted(glob.glob(os.path.join(directory, "*.json")))
    history = []
    for f in files:
        try:
            history.append(load_json(f))
        except (json.JSONDecodeError, KeyError):
            continue
    return history


def compare(baseline: dict, current: dict) -> bool:
    """Compare current against baseline. Returns True if regression detected."""
    regression = False

    print("PHPCMA Performance Comparison")
    print("=" * 50)
    print(f"Baseline: {baseline.get('corpus', '?')} @ {baseline.get('commit', '?')} ({baseline.get('date', '?')})")
    print(f"Current:  {current.get('corpus', '?')} @ {current.get('commit', '?')} ({current.get('date', '?')})")
    print(f"Files:    {baseline.get('files', '?')} (baseline) / {current.get('files', '?')} (current)")
    print()

    # Wall clock
    base_wall = baseline["wall_clock_median_ms"]
    curr_wall = current["wall_clock_median_ms"]
    wall_ratio = curr_wall / base_wall if base_wall > 0 else 0
    wall_status = "🔴 REGRESSION" if wall_ratio > WALL_CLOCK_THRESHOLD else "🟢 OK"
    if wall_ratio > WALL_CLOCK_THRESHOLD:
        regression = True
    print(f"Wall clock:  {base_wall}ms → {curr_wall}ms ({wall_ratio:.2f}x) {wall_status}")
    print(f"  Threshold: {WALL_CLOCK_THRESHOLD}x")

    # CPU time
    base_cpu = baseline["cpu_time_median_ms"]
    curr_cpu = current["cpu_time_median_ms"]
    cpu_ratio = curr_cpu / base_cpu if base_cpu > 0 else 0
    print(f"CPU time:    {base_cpu}ms → {curr_cpu}ms ({cpu_ratio:.2f}x)")

    # Memory
    base_mem = baseline["peak_memory_mb"]
    curr_mem = current["peak_memory_mb"]
    mem_ratio = curr_mem / base_mem if base_mem > 0 else 0
    mem_status = "🔴 REGRESSION" if mem_ratio > MEMORY_THRESHOLD else "🟢 OK"
    if mem_ratio > MEMORY_THRESHOLD:
        regression = True
    print(f"Peak memory: {base_mem}MB → {curr_mem}MB ({mem_ratio:.2f}x) {mem_status}")
    print(f"  Threshold: {MEMORY_THRESHOLD}x")
    print()

    if regression:
        print("⚠️  PERFORMANCE REGRESSION DETECTED")
    else:
        print("✅ No regression")

    return regression


def print_history(history: list[dict]) -> None:
    """Print sparklines of historical performance data."""
    if not history:
        return

    print()
    print("Historical Performance")
    print("-" * 50)

    wall_vals = [h["wall_clock_median_ms"] for h in history]
    cpu_vals = [h["cpu_time_median_ms"] for h in history]
    mem_vals = [h["peak_memory_mb"] for h in history]

    print(f"Wall clock: {sparkline(wall_vals)}  {wall_vals[0]}ms → {wall_vals[-1]}ms")
    print(f"CPU time:   {sparkline(cpu_vals)}  {cpu_vals[0]}ms → {cpu_vals[-1]}ms")
    print(f"Peak mem:   {sparkline(mem_vals)}  {mem_vals[0]}MB → {mem_vals[-1]}MB")

    dates = [h.get("date", "?") for h in history]
    print(f"Dates:      {dates[0]} → {dates[-1]} ({len(history)} runs)")


def main():
    parser = argparse.ArgumentParser(description="Compare PHPCMA benchmark results against baseline")
    parser.add_argument("--baseline", required=True, help="Path to baseline JSON file")
    parser.add_argument("--current", help="Path to current run JSON (default: stdin)")
    parser.add_argument("--history", help="Directory of historical run JSON files for sparklines")
    args = parser.parse_args()

    baseline = load_json(args.baseline)

    if args.current:
        current = load_json(args.current)
    else:
        current = json.load(sys.stdin)

    regression = compare(baseline, current)

    if args.history and os.path.isdir(args.history):
        history = load_history(args.history)
        if history:
            print_history(history)

    sys.exit(1 if regression else 0)


if __name__ == "__main__":
    main()
