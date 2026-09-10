#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

VERSION="${1:-}"
MACHINE="${2:-$(uname -m)}"

if [ -z "${VERSION}" ]; then
    echo "Usage: $0 [--dry-run] <version> [machine]" >&2
    exit 1
fi

DATE_ISO="$(date -u +%Y-%m-%d)"
RESULTS_DIR="${HERE}/results"
mkdir -p "${RESULTS_DIR}"

if [ "${DRY_RUN}" -eq 1 ]; then
    # Generate synthetically valid ClickBench result JSON for testing/verification
    RESULTS_ARRAY="["
    for q in $(seq 0 42); do
        cold=$(awk -v q="$q" 'BEGIN { printf "%.3f", (0.05 + (q % 10) * 0.12) }')
        hot1=$(awk -v c="$cold" 'BEGIN { printf "%.3f", (c * 0.4) }')
        hot2=$(awk -v c="$cold" 'BEGIN { printf "%.3f", (c * 0.38) }')
        [ "$q" -gt 0 ] && RESULTS_ARRAY+=","
        RESULTS_ARRAY+="[${cold},${hot1},${hot2}]"
    done
    RESULTS_ARRAY+="]"

    JSON_OUTPUT=$(cat <<ENDJSON
{
  "system": "StarRocks",
  "version": "${VERSION}",
  "date": "${DATE_ISO}",
  "machine": "${MACHINE}",
  "cluster_size": 1,
  "proprietary": "no",
  "hardware": "cpu",
  "tuned": "no",
  "tags": ["C++", "column-oriented", "MySQL compatible"],
  "load_time": 450,
  "data_size": 17800000000,
  "result": ${RESULTS_ARRAY}
}
ENDJSON
)
    echo "${JSON_OUTPUT}" | jq .
    exit 0
fi

# Live execution path
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

SR_PKG="StarRocks-${VERSION}-ubuntu-${ARCH}"
WORK_DIR="${HERE}/work/${VERSION}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

if [ ! -d "${SR_PKG}" ]; then
    TARBALL="${SR_PKG}.tar.gz"
    if [ ! -f "${TARBALL}" ]; then
        echo "Downloading ${TARBALL}..." >&2
        curl -fSL "https://releases.starrocks.io/starrocks/${TARBALL}" -o "${TARBALL}"
    fi
    tar -zxf "${TARBALL}"
    mkdir -p "${SR_PKG}/meta" "${SR_PKG}/storage"
    printf "\nmeta_dir = %s/%s/meta\n" "$PWD" "$SR_PKG" >> "${SR_PKG}/fe/conf/fe.conf"
    printf "\nstorage_root_path = %s/%s/storage\n" "$PWD" "$SR_PKG" >> "${SR_PKG}/be/conf/be.conf"
    printf "\ndisable_storage_page_cache = true\n" >> "${SR_PKG}/be/conf/be.conf"
    printf "\ndatacache_enable = false\n" >> "${SR_PKG}/be/conf/be.conf"
    printf "\npriority_networks = 127.0.0.1/32\n" >> "${SR_PKG}/fe/conf/fe.conf"
    printf "\npriority_networks = 127.0.0.1/32\n" >> "${SR_PKG}/be/conf/be.conf"
fi

export STARROCKS_HOME="$PWD/${SR_PKG}"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-${ARCH}"
export PATH="${JAVA_HOME}/bin:${PATH}"

backend_alive() {
    mysql -h127.0.0.1 -P9030 -uroot -B -N -e 'SHOW BACKENDS' 2>/dev/null \
        | awk -F'\t' 'tolower($9)=="true" { found=1 } END { exit !found }'
}

# Start cluster
"${STARROCKS_HOME}/fe/bin/start_fe.sh" --daemon
"${STARROCKS_HOME}/be/bin/start_be.sh" --daemon

for _ in $(seq 1 60); do
    mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 5
done

mysql -h127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM DROP BACKEND '127.0.0.1:9050'" 2>/dev/null || true
mysql -h127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '127.0.0.1:9050'" 2>/dev/null || true

for _ in $(seq 1 60); do
    backend_alive && break
    sleep 5
done

if ! backend_alive; then
    echo "StarRocks BE failed to start" >&2
    exit 1
fi

# Run create and load
mysql -h127.0.0.1 -P9030 -uroot < "${ROOT}/starrocks/create.sql"
LOAD_START=$(date +%s)
bash "${ROOT}/starrocks/load"
LOAD_END=$(date +%s)
LOAD_TIME=$((LOAD_END - LOAD_START))

DATA_SIZE=$(bash "${ROOT}/starrocks/data-size")

# Execute queries
RESULTS_ARRAY="["
Q_IDX=0
while IFS= read -r query_sql || [ -n "$query_sql" ]; do
    [ -z "$query_sql" ] && continue
    TRIES=()
    for try in 1 2 3; do
        if [ "$try" -eq 1 ]; then
            # Drop OS page cache if root
            sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
        fi
        TIME_TAKEN=$(echo "$query_sql" | bash "${ROOT}/starrocks/query" 2>&1 >/dev/null | tail -n1)
        TRIES+=("${TIME_TAKEN}")
    done
    [ "$Q_IDX" -gt 0 ] && RESULTS_ARRAY+=","
    RESULTS_ARRAY+="[${TRIES[0]},${TRIES[1]},${TRIES[2]}]"
    Q_IDX=$((Q_IDX + 1))
done < "${ROOT}/starrocks/queries.sql"
RESULTS_ARRAY+="]"

# Stop cluster
"${STARROCKS_HOME}/be/bin/stop_be.sh" || true
"${STARROCKS_HOME}/fe/bin/stop_fe.sh" || true

JSON_FILE="${RESULTS_DIR}/${VERSION}.json"
cat <<ENDJSON > "${JSON_FILE}"
{
  "system": "StarRocks",
  "version": "${VERSION}",
  "date": "${DATE_ISO}",
  "machine": "${MACHINE}",
  "cluster_size": 1,
  "proprietary": "no",
  "hardware": "cpu",
  "tuned": "no",
  "tags": ["C++", "column-oriented", "MySQL compatible"],
  "load_time": ${LOAD_TIME},
  "data_size": ${DATA_SIZE},
  "result": ${RESULTS_ARRAY}
}
ENDJSON

echo "Saved result to ${JSON_FILE}" >&2
cat "${JSON_FILE}"
