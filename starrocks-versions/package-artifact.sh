#!/usr/bin/env bash
set -euo pipefail

# package-artifact.sh: Build and package custom StarRocks release artifacts
# for ClickBench benchmarking across different branches and compiler flags.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKBENCH_ROOT="$(cd "${HERE}/.." && pwd)"

# Default options
BRANCH="perf/arm64-aggregate-rc"
VERSION_TAG=""
CFLAGS=""
REPO_DIR="/home/jalamb/go/src/github.com/jimmystewpot/starrocks"
OUTPUT_DIR=""
USE_DOCKER=0
DOCKER_IMAGE="starrocks/dev-env-ubuntu:main-20261029"
DRY_RUN=0
CLEAN=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -v, --version-tag <name>   Version tag label (e.g. main-baseline, main-custom-default, main-custom-lse) [Required]
  -b, --branch <ref>         Git branch/ref to checkout and build (default: perf/arm64-aggregate-rc)
  -c, --cflags <flags>       Extra C/C++ compiler flags (e.g. -march=armv8-a+crc+lse, -mcpu=neoverse-v2)
  -r, --repo-dir <path>      Path to StarRocks source tree (default: ${REPO_DIR})
  -o, --output-dir <path>    Output directory for packaged artifact (default: \${HERE}/work/\${VERSION_TAG})
      --use-docker           Run compilation inside StarRocks dev-env docker container
      --docker-image <img    Docker image for build (default: ${DOCKER_IMAGE})
      --clean                Perform git clean / clean build before compiling
  -d, --dry-run              Simulate build, create test artifact tarball, and print commands
  -h, --help                 Display this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version-tag)
            VERSION_TAG="$2"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -c|--cflags)
            CFLAGS="$2"
            shift 2
            ;;
        -r|--repo-dir)
            REPO_DIR="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --use-docker)
            USE_DOCKER=1
            shift
            ;;
        --docker-image)
            DOCKER_IMAGE="$2"
            shift 2
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "${VERSION_TAG}" ]]; then
    echo "Error: --version-tag is required." >&2
    usage
fi

# Detect architecture matching StarRocks release artifact naming
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

SR_PKG="StarRocks-${VERSION_TAG}-ubuntu-${ARCH}"
TARBALL_NAME="${SR_PKG}.tar.gz"

if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="${HERE}/work/${VERSION_TAG}"
fi
mkdir -p "${OUTPUT_DIR}"

TARGET_TARBALL="${OUTPUT_DIR}/${TARBALL_NAME}"

echo "=========================================================="
echo "StarRocks Artifact Packaging"
echo "  Version Tag : ${VERSION_TAG}"
echo "  Branch      : ${BRANCH}"
echo "  Arch        : ${ARCH}"
echo "  Extra CFLAGS: ${CFLAGS:-'(default)'}"
echo "  Repo Dir    : ${REPO_DIR}"
echo "  Output File : ${TARGET_TARBALL}"
echo "  Mode        : $([[ ${DRY_RUN} -eq 1 ]] && echo 'DRY-RUN' || echo 'LIVE BUILD')"
echo "=========================================================="

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "[DRY-RUN] Simulating package creation for ${VERSION_TAG}..."
    MOCK_DIR=$(mktemp -d "/tmp/sr_mock_XXXXXX")
    trap 'rm -rf "${MOCK_DIR}"' EXIT

    MOCK_PKG="${MOCK_DIR}/${SR_PKG}"
    mkdir -p "${MOCK_PKG}/fe/bin" "${MOCK_PKG}/fe/conf" "${MOCK_PKG}/fe/lib"
    mkdir -p "${MOCK_PKG}/be/bin" "${MOCK_PKG}/be/conf" "${MOCK_PKG}/be/lib"

    # Stub scripts & configuration
    cat << 'EOF' > "${MOCK_PKG}/fe/bin/start_fe.sh"
#!/usr/bin/env bash
echo "Starting mock FE..."
exit 0
EOF
    cat << 'EOF' > "${MOCK_PKG}/be/bin/start_be.sh"
#!/usr/bin/env bash
echo "Starting mock BE..."
exit 0
EOF
    chmod +x "${MOCK_PKG}/fe/bin/start_fe.sh" "${MOCK_PKG}/be/bin/start_be.sh"

    touch "${MOCK_PKG}/fe/conf/fe.conf"
    touch "${MOCK_PKG}/be/conf/be.conf"
    echo "mock_fe_jar" > "${MOCK_PKG}/fe/lib/starrocks-fe.jar"
    echo "mock_be_binary" > "${MOCK_PKG}/be/lib/starrocks_be"

    # Create synthetic tarball
    tar -czf "${TARGET_TARBALL}" -C "${MOCK_DIR}" "${SR_PKG}"
    sha256sum "${TARGET_TARBALL}" > "${TARGET_TARBALL}.sha256"

    echo "[DRY-RUN] Created mock artifact at: ${TARGET_TARBALL}"
    echo "[DRY-RUN] SHA256: $(cat "${TARGET_TARBALL}.sha256")"
    echo "[DRY-RUN] Build command that would run:"
    if [[ "${USE_DOCKER}" -eq 1 ]]; then
        echo "  docker run --rm -v ${REPO_DIR}:/starrocks ${DOCKER_IMAGE} /bin/bash -c 'cd /starrocks && ./build.sh --be --fe'"
    else
        echo "  cd ${REPO_DIR} && git checkout ${BRANCH} && ./build.sh --be --fe"
    fi
    exit 0
fi

# Live build execution
if [[ ! -d "${REPO_DIR}/.git" ]]; then
    echo "Error: ${REPO_DIR} is not a valid git repository." >&2
    exit 1
fi

cd "${REPO_DIR}"
echo "Checking out branch ${BRANCH}..."
git checkout "${BRANCH}"

if [[ "${CLEAN}" -eq 1 ]]; then
    echo "Cleaning build tree..."
    rm -rf output/
fi

# Export build flags
if [[ -n "${CFLAGS}" ]]; then
    export STARROCKS_CXX_COMMON_FLAGS="${STARROCKS_CXX_COMMON_FLAGS:-} ${CFLAGS}"
    export CFLAGS="${CFLAGS:-} ${CFLAGS}"
    export CXXFLAGS="${CXXFLAGS:-} ${CFLAGS}"
    export EXTRA_CXX_FLAGS="${EXTRA_CXX_FLAGS:-} ${CFLAGS}"
    echo "Exported CFLAGS/CXXFLAGS: ${CFLAGS}"
fi

echo "Starting StarRocks build..."
if [[ "${USE_DOCKER}" -eq 1 ]]; then
    echo "Running build inside docker container: ${DOCKER_IMAGE}..."
    docker run --rm \
        -v "${REPO_DIR}:/starrocks" \
        -w "/starrocks" \
        -e STARROCKS_CXX_COMMON_FLAGS="${STARROCKS_CXX_COMMON_FLAGS:-}" \
        -e EXTRA_CXX_FLAGS="${EXTRA_CXX_FLAGS:-}" \
        "${DOCKER_IMAGE}" \
        ./build.sh --be --fe
else
    ./build.sh --be --fe
fi

if [[ ! -d "output/fe" ]] || [[ ! -d "output/be" ]]; then
    echo "Error: Build did not produce output/fe and output/be directories." >&2
    exit 1
fi

STAGE_DIR=$(mktemp -d "/tmp/sr_stage_XXXXXX")
trap 'rm -rf "${STAGE_DIR}"' EXIT

STAGE_PKG="${STAGE_DIR}/${SR_PKG}"
mkdir -p "${STAGE_PKG}"
cp -r output/fe "${STAGE_PKG}/"
cp -r output/be "${STAGE_PKG}/"

echo "Packaging tarball into ${TARGET_TARBALL}..."
tar -czf "${TARGET_TARBALL}" -C "${STAGE_DIR}" "${SR_PKG}"
sha256sum "${TARGET_TARBALL}" > "${TARGET_TARBALL}.sha256"

echo "Artifact successfully packaged:"
ls -lh "${TARGET_TARBALL}"
echo "SHA256: $(cat "${TARGET_TARBALL}.sha256")"
EOF