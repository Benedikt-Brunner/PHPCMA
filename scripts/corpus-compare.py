#!/usr/bin/env python3
"""Compare actual PHPCMA report JSON against a golden file.

Usage:
    python3 scripts/corpus-compare.py actual.json test/corpus/monolog.golden.json

Exit codes:
    0 — All checks passed
    1 — Regression detected
    2 — Usage error / file not found

Output format:
    ✓ classes: 3811 (baseline: 3811)
    ✓ resolution_rate: 31.4% (baseline: 31.4%)
    ✗ methods: 16200 < 16290 (REGRESSION: 90 methods lost)
    ✓ performance: 0.28s (baseline: 0.30s, limit: 0.60s)
"""
import json
import re
import sys
import os


def sanitize_json(raw: str) -> str:
    """Fix unescaped backslashes in JSON string values (PHP namespace separators)."""
    return re.sub(r'(?<!\\)\\(?![\\"/bfnrtu])', r'\\\\', raw)


def load_json(path: str) -> dict:
    with open(path) as f:
        raw = f.read()
    return json.loads(sanitize_json(raw))


def compare_count(name: str, actual: int, baseline: int, results: list) -> bool:
    """Symbol counts must not decrease (regression = parsing bug)."""
    if actual >= baseline:
        results.append(f"  ✓ {name}: {actual} (baseline: {baseline})")
        return True
    else:
        diff = baseline - actual
        results.append(f"  ✗ {name}: {actual} < {baseline} (REGRESSION: {diff} {name} lost)")
        return False


def compare_rate(name: str, actual: float, baseline: float, tolerance_pp: float, results: list) -> bool:
    """Resolution/pass rates must not decrease by more than tolerance (in percentage points).

    Values are already in percentage form (e.g., 10.8 means 10.8%).
    """
    if actual >= baseline - tolerance_pp:
        results.append(f"  ✓ {name}: {actual:.1f}% (baseline: {baseline:.1f}%)")
        return True
    else:
        drop = baseline - actual
        results.append(f"  ✗ {name}: {actual:.1f}% < {baseline:.1f}% (REGRESSION: {drop:.1f}pp drop)")
        return False


def compare_tolerance(name: str, actual: int, baseline: int, tolerance_pct: float, results: list) -> bool:
    """Values must be within tolerance percent of baseline."""
    if baseline == 0:
        results.append(f"  ✓ {name}: {actual} (baseline: 0)")
        return True
    low = int(baseline * (1 - tolerance_pct))
    high = int(baseline * (1 + tolerance_pct))
    if low <= actual <= high:
        results.append(f"  ✓ {name}: {actual} (baseline: {baseline}, range: {low}-{high})")
        return True
    else:
        results.append(f"  ✗ {name}: {actual} outside [{low}, {high}] (baseline: {baseline}, ±{tolerance_pct*100:.0f}%)")
        return False


def compare_performance(actual_s: float, baseline_s: float, multiplier: float, results: list) -> bool:
    """Wall clock must not exceed multiplier × baseline."""
    limit = baseline_s * multiplier
    if actual_s <= limit:
        results.append(f"  ✓ performance: {actual_s:.2f}s (baseline: {baseline_s:.2f}s, limit: {limit:.2f}s)")
        return True
    else:
        results.append(f"  ✗ performance: {actual_s:.2f}s > {limit:.2f}s (baseline: {baseline_s:.2f}s, {multiplier}x limit)")
        return False


def check_fields(actual: dict, baseline: dict, path: str, results: list) -> bool:
    """New fields OK (forward-compatible). Missing fields ERROR (backward-incompatible)."""
    ok = True
    for key in baseline:
        if key.startswith("_"):
            continue
        if key not in actual:
            results.append(f"  ✗ MISSING FIELD: {path}.{key} (backward-incompatible)")
            ok = False
    return ok


def main():
    if len(sys.argv) < 3:
        print("Usage: corpus-compare.py <actual.json> <golden.json> [--duration=N.Ns]")
        sys.exit(2)

    actual_path = sys.argv[1]
    golden_path = sys.argv[2]

    # Optional: pass actual duration via --duration flag
    actual_duration = None
    for arg in sys.argv[3:]:
        if arg.startswith("--duration="):
            actual_duration = float(arg.split("=", 1)[1])

    if not os.path.exists(actual_path):
        print(f"Error: actual file not found: {actual_path}")
        sys.exit(2)
    if not os.path.exists(golden_path):
        print(f"Error: golden file not found: {golden_path}")
        sys.exit(2)

    actual = load_json(actual_path)
    golden = load_json(golden_path)

    results = []
    all_ok = True

    print(f"Comparing: {actual_path} vs {golden_path}")
    print()

    # 1. Check top-level field presence
    if not check_fields(actual, golden, "root", results):
        all_ok = False

    # 2. Coverage symbol counts (must not decrease)
    a_cov = actual.get("coverage", {})
    g_cov = golden.get("coverage", {})

    for field in ["files", "symbols", "classes", "interfaces", "traits", "functions", "methods", "properties"]:
        if field in g_cov:
            if not compare_count(field, a_cov.get(field, 0), g_cov[field], results):
                all_ok = False

    # 3. Resolution rate (must not decrease by more than 0.5pp)
    if "resolution_rate" in g_cov:
        if not compare_rate("resolution_rate", a_cov.get("resolution_rate", 0), g_cov["resolution_rate"], 0.5, results):
            all_ok = False

    # 4. Type check counts (within 10% tolerance for violations)
    a_tc = actual.get("type_checks", {})
    g_tc = golden.get("type_checks", {})
    for check_name in g_tc:
        if not check_fields(a_tc.get(check_name, {}), g_tc[check_name], f"type_checks.{check_name}", results):
            all_ok = False
        # Pass counts should not decrease
        a_check = a_tc.get(check_name, {})
        g_check = g_tc[check_name]
        if "pass" in g_check and g_check["pass"] > 0:
            if not compare_count(f"{check_name}.pass", a_check.get("pass", 0), g_check["pass"], results):
                all_ok = False
        # Fail counts: tolerance of 10%
        if "fail" in g_check:
            if not compare_tolerance(f"{check_name}.fail", a_check.get("fail", 0), g_check["fail"], 0.10, results):
                all_ok = False

    # 5. Dead code counts (within 10% tolerance)
    a_dc = actual.get("dead_code", {})
    g_dc = golden.get("dead_code", {})
    for field in ["dead_classes", "dead_interfaces", "dead_traits", "dead_functions", "dead_methods", "dead_properties"]:
        if field in g_dc:
            if not compare_tolerance(field, a_dc.get(field, 0), g_dc[field], 0.10, results):
                all_ok = False

    # 6. Performance (wall clock must not exceed 2x baseline)
    g_meta = golden.get("_metadata", {})
    baseline_duration = g_meta.get("duration_seconds")
    if actual_duration is not None and baseline_duration is not None:
        if not compare_performance(actual_duration, baseline_duration, 2.0, results):
            all_ok = False

    # Print results
    print("Results:")
    for line in results:
        print(line)
    print()

    if all_ok:
        print("✓ All checks passed — no regressions detected")
        sys.exit(0)
    else:
        print("✗ REGRESSION DETECTED — see failures above")
        sys.exit(1)


if __name__ == "__main__":
    main()
