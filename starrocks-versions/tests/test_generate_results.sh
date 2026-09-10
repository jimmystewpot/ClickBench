#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGGREGATOR="${HERE}/generate-results.sh"

if [ ! -x "${AGGREGATOR}" ]; then
    echo "ERROR: ${AGGREGATOR} not found or not executable" >&2
    exit 1
fi

# Ensure test fixtures exist
mkdir -p "${HERE}/results"
cat <<ENDJSON > "${HERE}/results/4.0.14.json"
{
  "system": "StarRocks",
  "version": "4.0.14",
  "date": "2026-09-07",
  "machine": "c6a.4xlarge",
  "cluster_size": 1,
  "load_time": 489,
  "data_size": 17944611636,
  "result": [[0.195, 0.051, 0.035], [0.556, 0.059, 0.064]]
}
ENDJSON

cat <<ENDJSON > "${HERE}/results/4.1.1.json"
{
  "system": "StarRocks",
  "version": "4.1.1",
  "date": "2026-09-08",
  "machine": "c6a.4xlarge",
  "cluster_size": 1,
  "load_time": 460,
  "data_size": 17800000000,
  "result": [[0.150, 0.040, 0.030], [0.450, 0.050, 0.052]]
}
ENDJSON

"${AGGREGATOR}"

if [ ! -f "${HERE}/data.generated.js" ]; then
    echo "ERROR: data.generated.js was not generated" >&2
    exit 1
fi

grep -q "const queries =" "${HERE}/data.generated.js"
grep -q "const data =" "${HERE}/data.generated.js"
grep -q "4.0.14" "${HERE}/data.generated.js"
grep -q "4.1.1" "${HERE}/data.generated.js"

echo "PASS: generate-results.sh successfully built valid data.generated.js with multiple StarRocks versions."
