#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
BENCH="${BENCH:-${BUILD_DIR}/mooncake-store/benchmarks/stress_cluster_bench}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
BENCH_LOG_DIR="${BENCH_LOG_DIR:-${PROJECT_DIR}/benchmark_logs/${TIMESTAMP}}"

DEFAULT_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
MASTER_HOST="${MASTER_HOST:-${DEFAULT_HOST:-127.0.0.1}}"
MASTER_PORT="${MASTER_PORT:-50060}"
HTTP_METADATA_PORT="${HTTP_METADATA_PORT:-8020}"
METADATA_SERVER="${METADATA_SERVER:-http://${MASTER_HOST}:${HTTP_METADATA_PORT}/metadata}"
MASTER_SERVER="${MASTER_SERVER:-${MASTER_HOST}:${MASTER_PORT}}"
MASTER_ADMIN_PORT="${MASTER_ADMIN_PORT:-9010}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-${CLIENT_HOST:-${MASTER_HOST}}}"
PROTOCOL="${PROTOCOL:-ub}"
if [ -z "${DEVICE_NAME+x}" ]; then
    if [ "$PROTOCOL" = "ub" ]; then
        DEVICE_NAME="bonding_dev_0"
    else
        DEVICE_NAME=""
    fi
fi
NUM_KEYS="${NUM_KEYS:-1000}"
READ_THREADS="${READ_THREADS:-16}"
READ_BATCH_SIZE="${READ_BATCH_SIZE:-16}"
READ_LOCAL_BUFFER_SIZE="${READ_LOCAL_BUFFER_SIZE:-1073741824}"
READ_GLOBAL_SEGMENT_SIZE="${READ_GLOBAL_SEGMENT_SIZE:-0}"
READ_DURATION="${READ_DURATION:-20}"
READ_TIMEOUT_SEC="${READ_TIMEOUT_SEC:-180}"
VERIFY="${VERIFY:-false}"

export LD_LIBRARY_PATH="${BUILD_DIR}/_deps/ubdiag-build/src/sdk:${BUILD_DIR}/mooncake-store/src:${BUILD_DIR}/mooncake-transfer-engine/src:${BUILD_DIR}/mooncake-common:${BUILD_DIR}/mooncake-common/etcd:/usr/lib64:/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"
export MC_STORE_CLIENT_SETUP_RETRIES="${MC_STORE_CLIENT_SETUP_RETRIES:-3}"
export MC_STORE_CLIENT_METRIC_BANDWIDTH="${MC_STORE_CLIENT_METRIC_BANDWIDTH:-1}"
export MC_TCP_BIND_ADDRESS="${MC_TCP_BIND_ADDRESS:-${LOCAL_HOSTNAME}}"
export no_proxy="${no_proxy:-127.0.0.1,localhost,local,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12}"
export MC_LOG_ENABLE="${MC_LOG_ENABLE:-on}"
export MC_LOG_LEVEL="${MC_LOG_LEVEL:-INFO}"
export MC_LOG_DIR="${MC_LOG_DIR:-${PROJECT_DIR}/logs/mooncake}"
export MC_LOG_DETAIL_ENABLE="${MC_LOG_DETAIL_ENABLE:-off}"
export MC_LOG_MAX_SIZE="${MC_LOG_MAX_SIZE:-100}"
export MC_LOG_BUFFER_SECS="${MC_LOG_BUFFER_SECS:-3}"
export MC_HIFREQ_LOG_SAMPLE_RATE="${MC_HIFREQ_LOG_SAMPLE_RATE:-0.1}"

mkdir -p "${BENCH_LOG_DIR}" "${MC_LOG_DIR}"

if [ ! -x "${BENCH}" ]; then
    echo "FATAL: stress_cluster_bench not executable: ${BENCH}" >&2
    exit 1
fi

stdout_log="${BENCH_LOG_DIR}/read_stdout.log"
stderr_log="${BENCH_LOG_DIR}/read_stderr.log"
args=(
    "--role=reader"
    "--global-segment-size=${READ_GLOBAL_SEGMENT_SIZE}"
    "--local-buffer-size=${READ_LOCAL_BUFFER_SIZE}"
    "--local-hostname=${LOCAL_HOSTNAME}"
    "--master-server=${MASTER_SERVER}"
    "--master_admin_port=${MASTER_ADMIN_PORT}"
    "--metadata-server=${METADATA_SERVER}"
    "--scenario=segment_read"
    "--num-keys=${NUM_KEYS}"
    "--protocol=${PROTOCOL}"
    "--verify=${VERIFY}"
    "--num_threads=${READ_THREADS}"
    "--batch-size=${READ_BATCH_SIZE}"
    "--duration=${READ_DURATION}"
)
if [ -n "${DEVICE_NAME}" ]; then
    args+=("--device-name=${DEVICE_NAME}")
fi

echo "READ BENCHMARK: bench=${BENCH} protocol=${PROTOCOL} host=${LOCAL_HOSTNAME} keys=${NUM_KEYS} duration=${READ_DURATION}s"
set +e
timeout "${READ_TIMEOUT_SEC}s" "${BENCH}" "${args[@]}" ${EXTRA_READ_ARGS:-} \
    > >(tee "${stdout_log}") 2> >(tee "${stderr_log}" >&2)
exit_code=$?
set -e

if [ "${exit_code}" -eq 124 ]; then
    echo "STATUS: TIMEOUT after ${READ_TIMEOUT_SEC}s"
elif [ "${exit_code}" -ne 0 ]; then
    echo "STATUS: FAILED"
else
    echo "STATUS: PASSED"
fi
grep -E '(Throughput|Ops/sec|Wall time|Total ops|P50|P99)' \
    "${stdout_log}" "${stderr_log}" 2>/dev/null | head -20 || true
exit "${exit_code}"
