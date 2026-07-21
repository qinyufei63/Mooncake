#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
MOONCAKE_CLIENT="${MOONCAKE_CLIENT:-${BUILD_DIR}/mooncake-store/src/mooncake_client}"

DEFAULT_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
MASTER_HOST="${MASTER_HOST:-${DEFAULT_HOST:-127.0.0.1}}"
MASTER_PORT="${MASTER_PORT:-50060}"
HTTP_METADATA_PORT="${HTTP_METADATA_PORT:-8020}"
METADATA_SERVER="${METADATA_SERVER:-http://${MASTER_HOST}:${HTTP_METADATA_PORT}/metadata}"
MASTER_SERVER_ADDRESS="${MASTER_SERVER_ADDRESS:-${MASTER_HOST}:${MASTER_PORT}}"
CLIENT_HOST="${CLIENT_HOST:-${MASTER_HOST}}"
CLIENT_PORT="${CLIENT_PORT:-8980}"
CLIENT_THREADS="${CLIENT_THREADS:-16}"
CLIENT_PROTOCOL="${CLIENT_PROTOCOL:-${PROTOCOL:-ub}}"
CLIENT_DEVICE_NAMES="${CLIENT_DEVICE_NAMES:-${DEVICE_NAME:-bonding_dev_0}}"
CLIENT_GLOBAL_SEGMENT_SIZE="${CLIENT_GLOBAL_SEGMENT_SIZE:-21474836480}"

export LD_LIBRARY_PATH="${BUILD_DIR}/_deps/ubdiag-build/src/sdk:${BUILD_DIR}/mooncake-store/src:${BUILD_DIR}/mooncake-transfer-engine/src:${BUILD_DIR}/mooncake-common:${BUILD_DIR}/mooncake-common/etcd:/usr/local/lib64:/usr/local/lib:/usr/lib64:${LD_LIBRARY_PATH:-}"
export MC_STORE_CLIENT_SETUP_RETRIES="${MC_STORE_CLIENT_SETUP_RETRIES:-3}"
export no_proxy="${no_proxy:-127.0.0.1,localhost,local,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12}"
export MC_STORE_CLIENT_METRIC_BANDWIDTH="${MC_STORE_CLIENT_METRIC_BANDWIDTH:-0}"
export MC_LOG_ENABLE="${MC_LOG_ENABLE:-on}"
export MC_LOG_LEVEL="${MC_LOG_LEVEL:-INFO}"
export MC_LOG_DIR="${MC_LOG_DIR:-${PROJECT_DIR}/logs/mooncake}"
export MC_LOG_DETAIL_ENABLE="${MC_LOG_DETAIL_ENABLE:-off}"
export MC_LOG_MAX_SIZE="${MC_LOG_MAX_SIZE:-100}"
export MC_LOG_BUFFER_SECS="${MC_LOG_BUFFER_SECS:-3}"
export MC_HIFREQ_LOG_SAMPLE_RATE="${MC_HIFREQ_LOG_SAMPLE_RATE:-0}"
export MC_TCP_BIND_ADDRESS="${MC_TCP_BIND_ADDRESS:-${CLIENT_HOST}}"
export MC_URMA_TRANS_MODE="${MC_URMA_TRANS_MODE:-RM}"

mkdir -p "${MC_LOG_DIR}"

if [ ! -x "${MOONCAKE_CLIENT}" ]; then
    echo "FATAL: mooncake_client not executable: ${MOONCAKE_CLIENT}" >&2
    exit 1
fi

args=(
    "--metadata_server=${METADATA_SERVER}"
    "--master_server_address=${MASTER_SERVER_ADDRESS}"
    "--host=${CLIENT_HOST}"
    "--global_segment_size=${CLIENT_GLOBAL_SEGMENT_SIZE}"
    "--threads=${CLIENT_THREADS}"
    "--protocol=${CLIENT_PROTOCOL}"
    "--port=${CLIENT_PORT}"
)
if [ -n "${CLIENT_DEVICE_NAMES}" ]; then
    args+=("--device_names=${CLIENT_DEVICE_NAMES}")
fi

echo "Starting mooncake_client: ${MOONCAKE_CLIENT}"
echo "  host=${CLIENT_HOST} port=${CLIENT_PORT} protocol=${CLIENT_PROTOCOL} metadata=${METADATA_SERVER}"
exec "${MOONCAKE_CLIENT}" "${args[@]}" ${EXTRA_CLIENT_ARGS:-}
