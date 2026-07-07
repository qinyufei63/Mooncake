#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
MOONCAKE_MASTER="${MOONCAKE_MASTER:-${BUILD_DIR}/mooncake-store/src/mooncake_master}"

MASTER_HOST="${MASTER_HOST:-141.61.84.245}"
MASTER_PORT="${MASTER_PORT:-50060}"
HTTP_METADATA_HOST="${HTTP_METADATA_HOST:-${MASTER_HOST}}"
HTTP_METADATA_PORT="${HTTP_METADATA_PORT:-8020}"
METRICS_PORT="${METRICS_PORT:-9010}"
GLOBAL_FILE_SEGMENT_SIZE="${GLOBAL_FILE_SEGMENT_SIZE:-9223372036854775807}"
DEFAULT_KV_LEASE_TTL="${DEFAULT_KV_LEASE_TTL:-300000}"
ENABLE_OFFLOAD="${ENABLE_OFFLOAD:-false}"

export LD_LIBRARY_PATH="${BUILD_DIR}/mooncake-store/src:${BUILD_DIR}/mooncake-transfer-engine/src:${BUILD_DIR}/mooncake-common:${BUILD_DIR}/mooncake-common/etcd:${BUILD_DIR}/extern/ubdiag_build/src/sdk:/usr/local/lib64:/usr/local/lib:/usr/lib64:${LD_LIBRARY_PATH:-}"
export MC_LOG_ENABLE="${MC_LOG_ENABLE:-on}"
export MC_LOG_LEVEL="${MC_LOG_LEVEL:-INFO}"
export MC_LOG_DIR="${MC_LOG_DIR:-${PROJECT_DIR}/logs/mooncake}"
export MC_LOG_DETAIL_ENABLE="${MC_LOG_DETAIL_ENABLE:-off}"
export MC_LOG_MAX_SIZE="${MC_LOG_MAX_SIZE:-100}"
export MC_LOG_BUFFER_SECS="${MC_LOG_BUFFER_SECS:-3}"
export MC_HIFREQ_LOG_SAMPLE_RATE="${MC_HIFREQ_LOG_SAMPLE_RATE:-0.1}"

mkdir -p "${MC_LOG_DIR}"

if [ ! -x "${MOONCAKE_MASTER}" ]; then
    echo "FATAL: mooncake_master not executable: ${MOONCAKE_MASTER}" >&2
    exit 1
fi

args=(
    "--global_file_segment_size=${GLOBAL_FILE_SEGMENT_SIZE}"
    "--enable_http_metadata_server=true"
    "--http_metadata_server_host=${HTTP_METADATA_HOST}"
    "--http_metadata_server_port=${HTTP_METADATA_PORT}"
    "--default_kv_lease_ttl=${DEFAULT_KV_LEASE_TTL}"
    "--enable_offload=${ENABLE_OFFLOAD}"
    "--port=${MASTER_PORT}"
    "--metrics_port=${METRICS_PORT}"
)

echo "Starting mooncake_master: ${MOONCAKE_MASTER}"
echo "  host=${HTTP_METADATA_HOST} master_port=${MASTER_PORT} metadata_port=${HTTP_METADATA_PORT} metrics_port=${METRICS_PORT}"
exec "${MOONCAKE_MASTER}" "${args[@]}" ${EXTRA_MASTER_ARGS:-}
