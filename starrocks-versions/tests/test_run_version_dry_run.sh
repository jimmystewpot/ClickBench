#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="${HERE}/run-version.sh"

if [ ! -x "${RUNNER}" ]; then
    echo "ERROR: ${RUNNER} not found or not executable" >&2
    exit 1
fi

TMP_OUTPUT="/tmp/mock_starrocks_run.json"
rm -f "${TMP_OUTPUT}"

"${RUNNER}" --dry-run 4.0.14 c6a.4xlarge > "${TMP_OUTPUT}"

jq -e '.system == "StarRocks"' "${TMP_OUTPUT}" > /dev/null
jq -e '.version == "4.0.14"' "${TMP_OUTPUT}" > /dev/null
jq -e '.machine == "c6a.4xlarge"' "${TMP_OUTPUT}" > /dev/null
jq -e '.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' "${TMP_OUTPUT}" > /dev/null
jq -e '.result | length == 43' "${TMP_OUTPUT}" > /dev/null
jq -e '.result[0] | length == 3' "${TMP_OUTPUT}" > /dev/null

rm -f "${TMP_OUTPUT}"
echo "PASS: run-version.sh dry-run produced valid ClickBench result JSON schema."
