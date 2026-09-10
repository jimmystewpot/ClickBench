#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${HERE}/list-versions.sh"

if [ ! -x "${SCRIPT}" ]; then
    echo "ERROR: ${SCRIPT} not found or not executable" >&2
    exit 1
fi

OUTPUT="$("${SCRIPT}" --format=tsv | head -n 5)"
if [ -z "${OUTPUT}" ]; then
    echo "ERROR: Output of list-versions.sh was empty" >&2
    exit 1
fi

echo "${OUTPUT}" | while IFS=$'\t' read -r ver rel_date tarball; do
    if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo "ERROR: Invalid version format: '${ver}'" >&2
        exit 1
    fi
    if [[ ! "${rel_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: Invalid date format: '${rel_date}'" >&2
        exit 1
    fi
    if [[ ! "${tarball}" =~ ^https:// ]]; then
        echo "ERROR: Invalid tarball URL: '${tarball}'" >&2
        exit 1
    fi
    echo "PASS: ${ver} (${rel_date}) -> ${tarball}"
done

echo "All checks in test_list_versions.sh passed."
