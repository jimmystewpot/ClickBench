#!/usr/bin/env python3
"""Compare StarRocks benchmark results across versions."""

import argparse
import json
import math
import sys
from pathlib import Path

def load_result(path_str):
    path = Path(path_str)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path_str}")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def get_best_hot(tries):
    if not tries:
        return None
    if len(tries) == 1:
        return tries[0]
    valid_hot = [t for t in tries[1:] if t is not None]
    return min(valid_hot) if valid_hot else None

def compute_diff(base_val, target_val):
    if base_val is None or target_val is None or base_val <= 0:
        return None, "N/A"
    pct = ((target_val - base_val) / base_val) * 100.0
    return pct, f"{pct:+.1f}%"

def main():
    parser = argparse.ArgumentParser(description="Compare StarRocks ClickBench versions")
    parser.add_argument("baseline", help="Baseline result JSON (e.g. 4.0.14.json)")
    parser.add_argument("targets", nargs="+", help="Target result JSON(s) to compare against baseline")
    parser.add_argument("--markdown", action="store_true", help="Output in Markdown table format")
    parser.add_argument("--json", action="store_true", help="Output summary in JSON format")

    args = parser.parse_args()

    try:
        base_data = load_result(args.baseline)
    except Exception as e:
        print(f"Error loading baseline: {e}", file=sys.stderr)
        sys.exit(1)

    base_sys = base_data.get("system", "StarRocks")
    base_ver = base_data.get("version", "baseline")
    base_mach = base_data.get("machine", "")
    base_results = base_data.get("result", [])

    all_comparisons = []

    for target_path in args.targets:
        try:
            target_data = load_result(target_path)
        except Exception as e:
            print(f"Error loading target {target_path}: {e}", file=sys.stderr)
            continue

        tgt_sys = target_data.get("system", "StarRocks")
        tgt_ver = target_data.get("version", target_path)
        tgt_mach = target_data.get("machine", "")
        tgt_results = target_data.get("result", [])

        query_diffs = []
        ratios_cold = []
        ratios_hot = []
        regressions_cold = 0
        improvements_cold = 0

        num_queries = min(len(base_results), len(tgt_results))
        for q_idx in range(num_queries):
            b_tries = base_results[q_idx]
            t_tries = tgt_results[q_idx]

            b_cold = b_tries[0] if b_tries else None
            t_cold = t_tries[0] if t_tries else None
            b_hot = get_best_hot(b_tries)
            t_hot = get_best_hot(t_tries)

            diff_cold_val, diff_cold_str = compute_diff(b_cold, t_cold)
            diff_hot_val, diff_hot_str = compute_diff(b_hot, t_hot)

            if diff_cold_val is not None:
                ratios_cold.append(t_cold / b_cold)
                if diff_cold_val > 10.0:
                    regressions_cold += 1
                elif diff_cold_val < -10.0:
                    improvements_cold += 1

            if diff_hot_val is not None:
                ratios_hot.append(t_hot / b_hot)

            query_diffs.append({
                "query": f"Q{q_idx}",
                "base_cold": b_cold,
                "target_cold": t_cold,
                "diff_cold": diff_cold_str,
                "base_hot": b_hot,
                "target_hot": t_hot,
                "diff_hot": diff_hot_str,
            })

        geomean_cold = (math.exp(sum(math.log(r) for r in ratios_cold) / len(ratios_cold))) if ratios_cold else None
        geomean_hot = (math.exp(sum(math.log(r) for r in ratios_hot) / len(ratios_hot))) if ratios_hot else None

        comp_summary = {
            "baseline": f"{base_sys} {base_ver} ({base_mach})",
            "target": f"{tgt_sys} {tgt_ver} ({tgt_mach})",
            "queries_compared": num_queries,
            "geomean_cold_ratio": geomean_cold,
            "geomean_hot_ratio": geomean_hot,
            "regressions_cold_gt_10pct": regressions_cold,
            "improvements_cold_gt_10pct": improvements_cold,
            "query_diffs": query_diffs
        }
        all_comparisons.append(comp_summary)

        if args.json:
            continue

        if args.markdown:
            print(f"### {base_sys} Version Comparison: `{base_ver}` -> `{tgt_ver}`\n")
            print(f"- **Baseline:** {base_sys} {base_ver} (`{base_mach}`)")
            print(f"- **Target:** {tgt_sys} {tgt_ver} (`{tgt_mach}`)")
            if geomean_cold:
                status = "Faster" if geomean_cold < 1.0 else "Slower"
                print(f"- **Geometric mean cold speedup ratio:** {geomean_cold:.3f}x ({status})")
            print(f"- **Regressions (>+10% cold):** {regressions_cold}")
            print(f"- **Improvements (<-10% cold):** {improvements_cold}\n")

            print("| Query | Base Cold (s) | Target Cold (s) | Cold Diff | Base Hot (s) | Target Hot (s) | Hot Diff |")
            print("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |")
            for q in query_diffs:
                b_c = f"{q['base_cold']:.3f}" if q['base_cold'] is not None else "N/A"
                t_c = f"{q['target_cold']:.3f}" if q['target_cold'] is not None else "N/A"
                b_h = f"{q['base_hot']:.3f}" if q['base_hot'] is not None else "N/A"
                t_h = f"{q['target_hot']:.3f}" if q['target_hot'] is not None else "N/A"
                print(f"| {q['query']} | {b_c} | {t_c} | {q['diff_cold']} | {b_h} | {t_h} | {q['diff_hot']} |")
            print()
        else:
            print(f"\n==========================================================================")
            print(f"  StarRocks Version Comparison: {base_sys} {base_ver} -> {tgt_sys} {tgt_ver}")
            print(f"==========================================================================")
            print(f"Baseline: {base_sys} {base_ver} ({base_mach})")
            print(f"Target:   {tgt_sys} {tgt_ver} ({tgt_mach})\n")
            print(f"{'Query':<8} | {'Base Cold':<12} | {'Target Cold':<12} | {'Diff Cold':<11} | {'Base Hot':<11} | {'Target Hot':<11} | {'Diff Hot':<11}")
            print("-" * 88)
            for q in query_diffs:
                b_c = f"{q['base_cold']:.3f}s" if q['base_cold'] is not None else "N/A"
                t_c = f"{q['target_cold']:.3f}s" if q['target_cold'] is not None else "N/A"
                b_h = f"{q['base_hot']:.3f}s" if q['base_hot'] is not None else "N/A"
                t_h = f"{q['target_hot']:.3f}s" if q['target_hot'] is not None else "N/A"
                print(f"{q['query']:<8} | {b_c:<12} | {t_c:<12} | {q['diff_cold']:<11} | {b_h:<11} | {t_h:<11} | {q['diff_hot']:<11}")
            print("-" * 88)
            if geomean_cold:
                speedup_cold_str = "Faster" if geomean_cold < 1.0 else "Slower"
                print(f"Geometric mean cold query ratio: {geomean_cold:.3f}x ({speedup_cold_str})")
            if geomean_hot:
                speedup_hot_str = "Faster" if geomean_hot < 1.0 else "Slower"
                print(f"Geometric mean hot query ratio:  {geomean_hot:.3f}x ({speedup_hot_str})")
            print(f"Regressions (>+10% cold slowdown): {regressions_cold}")
            print(f"Improvements (<-10% cold speedup):  {improvements_cold}\n")

    if args.json:
        print(json.dumps(all_comparisons, indent=2))

if __name__ == "__main__":
    main()
