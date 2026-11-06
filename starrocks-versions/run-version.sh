#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

DRY_RUN=0
SUITE="native"
VERSION=""
MACHINE="$(uname -m)"

usage() {
    cat <<EOF
Usage: $0 [options] <version> [machine]

Options:
  --dry-run              Generate synthetic JSON output without starting cluster
  -s, --suite <name>     Benchmark suite: native, parquet, or all (default: native)
  -h, --help             Display this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -s|--suite)
            SUITE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            if [ -z "${VERSION}" ]; then
                VERSION="$1"
            else
                MACHINE="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "${VERSION}" ]; then
    echo "Error: version is required." >&2
    usage
fi

DATE_ISO="$(date -u +%Y-%m-%d)"
RESULTS_DIR="${HERE}/results"
mkdir -p "${RESULTS_DIR}"

generate_mock_json() {
    local out_ver="$1"
    local sys_suffix="$2"
    local results_array="["
    for q in $(seq 0 42); do
        local cold
        cold=$(awk -v q="$q" 'BEGIN { printf "%.3f", (0.05 + (q % 10) * 0.12) }')
        local hot1
        hot1=$(awk -v c="$cold" 'BEGIN { printf "%.3f", (c * 0.4) }')
        local hot2
        hot2=$(awk -v c="$cold" 'BEGIN { printf "%.3f", (c * 0.38) }')
        [ "$q" -gt 0 ] && results_array+=","
        results_array+="[${cold},${hot1},${hot2}]"
    done
    results_array+="]"

    cat <<ENDJSON
{
  "system": "StarRocks${sys_suffix}",
  "version": "${out_ver}",
  "date": "${DATE_ISO}",
  "machine": "${MACHINE}",
  "cluster_size": 1,
  "proprietary": "no",
  "hardware": "cpu",
  "tuned": "no",
  "tags": ["C++", "column-oriented", "MySQL compatible"],
  "load_time": 450,
  "data_size": 17800000000,
  "result": ${results_array}
}
ENDJSON
}

if [ "${DRY_RUN}" -eq 1 ]; then
    if [[ "${SUITE}" == "native" || "${SUITE}" == "all" ]]; then
        generate_mock_json "${VERSION}" "" | jq .
    fi
    if [[ "${SUITE}" == "parquet" || "${SUITE}" == "all" ]]; then
        generate_mock_json "${VERSION}-parquet" " (Parquet)" | jq .
    fi
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

# Port safety cleanup
kill_stale_starrocks() {
    echo "Checking for stale processes on StarRocks ports..." >&2
    for port in 9030 9050 8040 8030 8060; do
        local pids
        pids=$(fuser "${port}/tcp" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            echo "Port ${port} in use by PID(s): ${pids}. Terminating..." >&2
            kill -15 $pids 2>/dev/null || true
            sleep 2
            kill -9 $pids 2>/dev/null || true
        fi
    done
}

kill_stale_starrocks

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
echo "Starting StarRocks FE & BE..." >&2
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

run_queries() {
    local query_file="$1"
    local query_runner="$2"
    local results_array="["
    local q_idx=0
    while IFS= read -r query_sql || [ -n "$query_sql" ]; do
        [ -z "$query_sql" ] && continue
        local tries=()
        for try in 1 2 3; do
            if [ "$try" -eq 1 ]; then
                sync
                echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
            fi
            local time_taken
            time_taken=$(echo "$query_sql" | bash "${query_runner}" 2>&1 >/dev/null | tail -n1)
            tries+=("${time_taken}")
        done
        [ "$q_idx" -gt 0 ] && results_array+=","
        results_array+="[${tries[0]},${tries[1]},${tries[2]}]"
        q_idx=$((q_idx + 1))
    done < "${query_file}"
    results_array+="]"
    echo "${results_array}"
}

# Native Suite Execution
if [[ "${SUITE}" == "native" || "${SUITE}" == "all" ]]; then
    echo "Executing Native ClickBench Suite..." >&2
    mysql -h127.0.0.1 -P9030 -uroot < "${ROOT}/starrocks/create.sql"
    LOAD_START=$(date +%s)
    bash "${ROOT}/starrocks/load"
    LOAD_END=$(date +%s)
    LOAD_TIME=$((LOAD_END - LOAD_START))
    DATA_SIZE=$(bash "${ROOT}/starrocks/data-size")

    RESULTS_ARRAY=$(run_queries "${ROOT}/starrocks/queries.sql" "${ROOT}/starrocks/query")

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
    echo "Saved native result to ${JSON_FILE}" >&2
fi

# Parquet Suite Execution
if [[ "${SUITE}" == "parquet" || "${SUITE}" == "all" ]]; then
    echo "Executing Parquet ClickBench Suite..." >&2
    cd "${ROOT}/starrocks-parquet"
    LOAD_START=$(date +%s)
    bash "${ROOT}/starrocks-parquet/load"
    LOAD_END=$(date +%s)
    LOAD_TIME=$((LOAD_END - LOAD_START))
    DATA_SIZE=$(bash "${ROOT}/starrocks-parquet/data-size" 2>/dev/null || echo 0)

    RESULTS_ARRAY=$(run_queries "${ROOT}/starrocks-parquet/queries.sql" "${ROOT}/starrocks-parquet/query")

    JSON_FILE="${RESULTS_DIR}/${VERSION}-parquet.json"
    cat <<ENDJSON > "${JSON_FILE}"
{
  "system": "StarRocks (Parquet)",
  "version": "${VERSION}-parquet",
  "date": "${DATE_ISO}",
  "machine": "${MACHINE}",
  "cluster_size": 1,
  "proprietary": "no",
  "hardware": "cpu",
  "tuned": "no",
  "tags": ["C++", "column-oriented", "MySQL compatible", "Parquet"],
  "load_time": ${LOAD_TIME},
  "data_size": ${DATA_SIZE},
  "result": ${RESULTS_ARRAY}
}
ENDJSON
    echo "Saved parquet result to ${JSON_FILE}" >&2
fi

# Stop cluster
echo "Stopping StarRocks cluster..." >&2
"${STARROCKS_HOME}/be/bin/stop_be.sh" || true
"${STARROCKS_HOME}/fe/bin/stop_fe.sh" || true
kill_stale_starrocks
echo "Run complete." >&2
