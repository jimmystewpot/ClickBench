# StarRocks Version Benchmark Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an isolated StarRocks version benchmark and comparison subsystem (`starrocks-versions/`) in this fork, featuring version orchestration, automated result generation, an interactive side-by-side comparison web dashboard, and conflict-free upstream sync.

**Architecture:** An isolated sub-project within the fork (`starrocks-versions/`) containing its own version discovery (`list-versions.sh`), test runner (`run-version.sh`), aggregation engine (`generate-results.sh`), CLI diff tool (`compare.py`), and interactive frontend (`index.html`). This guarantees 100% clean upstream merges from `ClickHouse/ClickBench:main` while giving full autonomy to benchmark StarRocks versions 4.0, 4.1, 4.2, and future releases.

**Tech Stack:** Bash, Python 3, JavaScript (ES6), HTML/CSS, StarRocks FE/BE, GitHub Actions.

---

## Global Constraints
- Must NOT modify root `generate-results.sh`, `index.html`, or `data.generated.js` to ensure zero merge conflicts with upstream ClickBench.
- Must remain compatible with standard StarRocks ClickBench dataset queries (`queries.sql` / 43 hits queries).
- Must record cold-run (with internal caches disabled) and hot-run query iterations identical to ClickBench standards.
- Benchmark result schema must be backwards-compatible with ClickBench result format while capturing version metadata.

---

### Task 1: Version Discovery & Listing Utility

**Files:**
- Create: `starrocks-versions/list-versions.sh`
- Test: `starrocks-versions/tests/test_list_versions.sh`

**Interfaces:**
- Consumes: StarRocks release distribution index (`https://releases.starrocks.io/starrocks/`) and GitHub tags API.
- Produces: Formatted list of runnable StarRocks versions (version string, download URL, release date).

- [ ] **Step 1: Write test script for version listing**

```bash
#!/usr/bin/env bash
set -euo pipefail
# test_list_versions.sh: Verify list-versions outputs expected semantic versions
OUTPUT="$(./starrocks-versions/list-versions.sh --format=tsv | head -n 5)"
echo "$OUTPUT" | awk '{ if ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+/) print "PASS: " $1; else exit 1 }'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash starrocks-versions/tests/test_list_versions.sh`
Expected: FAIL (file does not exist)

- [ ] **Step 3: Implement `starrocks-versions/list-versions.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# list-versions.sh: Discover available StarRocks releases
FORMAT="${1:---format=tsv}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

curl -s "https://api.github.com/repos/StarRocks/starrocks/releases?per_page=100" | \
jq -r --arg arch "$ARCH" '
  .[] | 
  select(.prerelease == false and .draft == false) |
  .tag_name as $tag |
  ($tag | ltrimstr("v")) as $ver |
  select($ver | test("^[34]\\.[0-9]+\\.[0-9]+")) |
  {
    version: $ver,
    published_at: (.published_at | split("T")[0]),
    tarball: "https://releases.starrocks.io/starrocks/StarRocks-\($ver)-ubuntu-\($arch).tar.gz"
  } |
  "\([.version, .published_at, .tarball] | @tsv)"
' | sort -V -r
```

- [ ] **Step 4: Make script executable and run test**

Run: `chmod +x starrocks-versions/list-versions.sh starrocks-versions/tests/test_list_versions.sh && bash starrocks-versions/tests/test_list_versions.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add starrocks-versions/list-versions.sh starrocks-versions/tests/test_list_versions.sh
git commit -m "feat(starrocks-versions): add version discovery script and test"
```

---

### Task 2: Automated Single-Version Runner & Result Collector

**Files:**
- Create: `starrocks-versions/run-version.sh`
- Test: `starrocks-versions/tests/test_run_version_dry_run.sh`

**Interfaces:**
- Consumes: Target version string (e.g. `4.0.14`, `4.1.1`, `4.2.0`), machine type (default `c6a.4xlarge` or host detection).
- Produces: JSON result written to `starrocks-versions/results/<version>.json`.

- [ ] **Step 1: Write test for dry-run runner**

```bash
#!/usr/bin/env bash
set -euo pipefail
# test_run_version_dry_run.sh: Verify runner validates arguments and produces proper schema structure
./starrocks-versions/run-version.sh --dry-run 4.0.14 mock-machine > /tmp/mock_result.json
jq -e '.system == "StarRocks" and .version == "4.0.14" and .machine == "mock-machine"' /tmp/mock_result.json
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash starrocks-versions/tests/test_run_version_dry_run.sh`
Expected: FAIL

- [ ] **Step 3: Implement `starrocks-versions/run-version.sh`**

Implement automated installation, configuration (disabling caches for cold runs), table creation, data loading, query timing across 3 iterations (1 cold, 2 hot), and emission of versioned result JSON. Supports `--dry-run` for fast CI verification.

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x starrocks-versions/run-version.sh starrocks-versions/tests/test_run_version_dry_run.sh && bash starrocks-versions/tests/test_run_version_dry_run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add starrocks-versions/run-version.sh starrocks-versions/tests/test_run_version_dry_run.sh
git commit -m "feat(starrocks-versions): add parameterized single-version benchmark runner"
```

---

### Task 3: CLI Version Comparison Tool (`compare.py`)

**Files:**
- Create: `starrocks-versions/compare.py`
- Test: `starrocks-versions/tests/test_compare.py`

**Interfaces:**
- Consumes: Two or more JSON result files (e.g. `results/4.0.14.json`, `results/4.1.1.json`).
- Produces: Terminal table with per-query cold/hot comparisons, percentage diffs, geometric mean speedups, and regression warnings.

- [ ] **Step 1: Write test for `compare.py`**

```python
import json
import subprocess
import sys

def test_compare_cli(tmp_path):
    v1 = {"system": "StarRocks", "version": "4.0", "result": [[1.0, 0.5, 0.5]]}
    v2 = {"system": "StarRocks", "version": "4.1", "result": [[0.5, 0.25, 0.25]]}
    f1 = tmp_path / "4.0.json"
    f2 = tmp_path / "4.1.json"
    f1.write_text(json.dumps(v1))
    f2.write_text(json.dumps(v2))
    
    out = subprocess.check_output([sys.executable, "starrocks-versions/compare.py", str(f1), str(f2)], text=True)
    assert "StarRocks 4.0" in out
    assert "StarRocks 4.1" in out
    assert "-50.0%" in out
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest starrocks-versions/tests/test_compare.py`
Expected: FAIL

- [ ] **Step 3: Implement `starrocks-versions/compare.py`**

```python
#!/usr/bin/env python3
import argparse
import json
import math
import sys

def load_result(path):
    with open(path) as f:
        data = json.load(f)
    return data

def main():
    parser = argparse.ArgumentParser(description="Compare StarRocks benchmark versions")
    parser.add_argument("baseline", help="Baseline result JSON (e.g., 4.0.json)")
    parser.add_argument("targets", nargs="+", help="Target result JSON(s) (e.g., 4.1.json 4.2.json)")
    args = parser.parse_args()

    base = load_result(args.baseline)
    base_v = base.get("version", "baseline")
    print(f"Baseline: {base.get('system', 'StarRocks')} {base_v} ({base.get('machine', '')})")

    for target_path in args.targets:
        tgt = load_result(target_path)
        tgt_v = tgt.get("version", target_path)
        print(f"\n--- Comparing {base_v} -> {tgt_v} ---")
        print(f"{'Query':<8} | {'Base Cold (s)':<14} | {'Target Cold (s)':<16} | {'Diff Cold':<12} | {'Diff Hot':<12}")
        print("-" * 72)
        
        base_res = base["result"]
        tgt_res = tgt["result"]
        ratios_cold = []
        ratios_hot = []

        for q_idx in range(min(len(base_res), len(tgt_res))):
            b_cold, b_hot = base_res[q_idx][0], min(base_res[q_idx][1:]) if len(base_res[q_idx]) > 1 else base_res[q_idx][0]
            t_cold, t_hot = tgt_res[q_idx][0], min(tgt_res[q_idx][1:]) if len(tgt_res[q_idx]) > 1 else tgt_res[q_idx][0]

            if b_cold and t_cold and b_cold > 0:
                diff_cold = ((t_cold - b_cold) / b_cold) * 100.0
                ratios_cold.append(t_cold / b_cold)
                diff_cold_str = f"{diff_cold:+.1f}%"
            else:
                diff_cold_str = "N/A"

            if b_hot and t_hot and b_hot > 0:
                diff_hot = ((t_hot - b_hot) / b_hot) * 100.0
                ratios_hot.append(t_hot / b_hot)
                diff_hot_str = f"{diff_hot:+.1f}%"
            else:
                diff_hot_str = "N/A"

            print(f"Q{q_idx:<7} | {b_cold:<14.3f} | {t_cold:<16.3f} | {diff_cold_str:<12} | {diff_hot_str:<12}")

        if ratios_cold:
            geomean_cold = math.exp(sum(math.log(r) for r in ratios_cold) / len(ratios_cold))
            print("-" * 72)
            print(f"Geometric mean cold speedup ratio: {geomean_cold:.3f}x ({'Faster' if geomean_cold < 1.0 else 'Slower'})")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest starrocks-versions/tests/test_compare.py`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add starrocks-versions/compare.py starrocks-versions/tests/test_compare.py
git commit -m "feat(starrocks-versions): add CLI comparison tool with geomean speedup"
```

---

### Task 4: Web Results Aggregator & Interactive Comparison Dashboard

**Files:**
- Create: `starrocks-versions/generate-results.sh`
- Create: `starrocks-versions/index.html`
- Test: `starrocks-versions/tests/test_generate_results.sh`

**Interfaces:**
- Consumes: All `starrocks-versions/results/*.json` files.
- Produces: `starrocks-versions/data.generated.js` and renders `starrocks-versions/index.html`.

- [ ] **Step 1: Write test for `generate-results.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# test_generate_results.sh: Verify data.generated.js is generated with array of versions
./starrocks-versions/generate-results.sh
grep -q "const data = \[" starrocks-versions/data.generated.js
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash starrocks-versions/tests/test_generate_results.sh`
Expected: FAIL

- [ ] **Step 3: Implement `generate-results.sh` and `index.html`**

1. Build `starrocks-versions/generate-results.sh`:
   Extracts version, date, machine, load_time, data_size, and query results from all `starrocks-versions/results/*.json` into `data.generated.js`.
2. Build `starrocks-versions/index.html`:
   - Interactive version toggles (e.g. `[ ] 4.0.14`, `[ ] 4.1.1`, `[ ] 4.2.0`).
   - Metric selectors (Cold run, Hot run, Ingestion time, Storage size).
   - Speedup bar charts with relative indices.
   - Per-query side-by-side comparison table with color-coded diffs.

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x starrocks-versions/generate-results.sh && bash starrocks-versions/tests/test_generate_results.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add starrocks-versions/generate-results.sh starrocks-versions/index.html starrocks-versions/tests/test_generate_results.sh
git commit -m "feat(starrocks-versions): add web aggregator and interactive dashboard"
```

---

### Task 5: Automated Upstream Sync Workflow

**Files:**
- Create: `.github/workflows/sync-upstream.yml`

**Interfaces:**
- Consumes: `https://github.com/ClickHouse/ClickBench.git` `main` branch.
- Produces: Clean merged `main` branch on fork with updated upstream results.

- [ ] **Step 1: Create workflow `.github/workflows/sync-upstream.yml`**

```yaml
name: Sync Upstream ClickBench

on:
  schedule:
    - cron: '0 3 * * 1' # Weekly on Mondays at 03:00 UTC
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout fork
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Configure Git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Fetch and Merge Upstream
        run: |
          git remote add upstream https://github.com/ClickHouse/ClickBench.git || true
          git fetch upstream main
          git merge upstream/main --no-edit -m "chore: sync upstream ClickBench results"
          git push origin main
```

- [ ] **Step 2: Validate yaml syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-upstream.yml'))"`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/sync-upstream.yml
git commit -m "ci: add automated upstream sync workflow"
```

---

## Verification Plan

### Automated Tests
1. `./starrocks-versions/tests/test_list_versions.sh` - Verifies live discovery of StarRocks releases from official channels.
2. `./starrocks-versions/tests/test_run_version_dry_run.sh` - Verifies runner argument parsing, directory layout, and JSON schema emission.
3. `pytest starrocks-versions/tests/test_compare.py` - Verifies CLI regression detection and geomean calculation.
4. `./starrocks-versions/tests/test_generate_results.sh` - Verifies generation of `data.generated.js` for the dashboard.

### Manual Verification
1. Inspect `starrocks-versions/index.html` in a web browser using sample benchmark outputs (e.g. comparing 4.0.14 against simulated 4.1.1/4.2.0).
2. Test a dry-run upstream sync: `git fetch https://github.com/ClickHouse/ClickBench.git main && git merge --no-commit --no-ff FETCH_HEAD` to prove zero conflicts.
