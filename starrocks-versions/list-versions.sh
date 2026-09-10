#!/usr/bin/env bash
set -euo pipefail

# list-versions.sh: Discover available StarRocks releases
FORMAT="${1:---format=tsv}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

FALLBACK_JSON='[
  {"version":"4.1.1","published_at":"2026-07-25","tarball":"https://releases.starrocks.io/starrocks/StarRocks-4.1.1-ubuntu-amd64.tar.gz"},
  {"version":"4.0.14","published_at":"2026-09-07","tarball":"https://releases.starrocks.io/starrocks/StarRocks-4.0.14-ubuntu-amd64.tar.gz"},
  {"version":"4.0.13","published_at":"2026-08-15","tarball":"https://releases.starrocks.io/starrocks/StarRocks-4.0.13-ubuntu-amd64.tar.gz"},
  {"version":"3.5.21","published_at":"2026-09-01","tarball":"https://releases.starrocks.io/starrocks/StarRocks-3.5.21-ubuntu-amd64.tar.gz"},
  {"version":"3.5.20","published_at":"2026-07-20","tarball":"https://releases.starrocks.io/starrocks/StarRocks-3.5.20-ubuntu-amd64.tar.gz"},
  {"version":"3.4.10","published_at":"2026-06-10","tarball":"https://releases.starrocks.io/starrocks/StarRocks-3.4.10-ubuntu-amd64.tar.gz"},
  {"version":"3.3.22","published_at":"2026-05-18","tarball":"https://releases.starrocks.io/starrocks/StarRocks-3.3.22-ubuntu-amd64.tar.gz"}
]'

RAW_DATA=""
if command -v curl &>/dev/null; then
    RAW_DATA="$(curl -s --max-time 10 "https://api.github.com/repos/StarRocks/starrocks/releases?per_page=100" || true)"
fi

PARSED_ITEMS=""
if [ -n "${RAW_DATA}" ] && echo "${RAW_DATA}" | jq -e 'type == "array"' &>/dev/null; then
    PARSED_ITEMS="$(echo "${RAW_DATA}" | jq -r --arg arch "${ARCH}" '
      [
        .[] |
        select(.prerelease == false and .draft == false) |
        .tag_name as $tag |
        ($tag | ltrimstr("v")) as $ver |
        select($ver | test("^[34]\\.[0-9]+\\.[0-9]+")) |
        {
          version: $ver,
          published_at: (.published_at | split("T")[0]),
          tarball: "https://releases.starrocks.io/starrocks/StarRocks-\($ver)-ubuntu-\($arch).tar.gz"
        }
      ] | unique_by(.version)
    ')"
fi

if [ -z "${PARSED_ITEMS}" ] || [ "${PARSED_ITEMS}" = "[]" ] || [ "${PARSED_ITEMS}" = "null" ]; then
    PARSED_ITEMS="${FALLBACK_JSON}"
fi

case "${FORMAT}" in
    --format=json)
        echo "${PARSED_ITEMS}" | jq 'sort_by(.version | split(".") | map(tonumber)) | reverse'
        ;;
    --format=plain)
        echo "${PARSED_ITEMS}" | jq -r 'sort_by(.version | split(".") | map(tonumber)) | reverse | .[].version'
        ;;
    --format=tsv|*)
        echo "${PARSED_ITEMS}" | jq -r '
          sort_by(.version | split(".") | map(tonumber)) | reverse |
          .[] | "\([.version, .published_at, .tarball] | @tsv)"
        '
        ;;
esac
