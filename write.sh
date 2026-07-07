#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"
BENCH="${BENCH:-${BUILD_DIR}/mooncake-store/benchmarks/stress_cluster_bench}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
BENCH_LOG_DIR="${BENCH_LOG_DIR:-${PROJECT_DIR}/benchmark_logs/${TIMESTAMP}}"

MASTER_HOST="${MASTER_HOST:-141.61.84.245}"
MASTER_PORT="${MASTER_PORT:-50060}"
HTTP_METADATA_PORT="${HTTP_METADATA_PORT:-8020}"
METADATA_SERVER="${METADATA_SERVER:-http://${MASTER_HOST}:${HTTP_METADATA_PORT}/metadata}"
MASTER_SERVER="${MASTER_SERVER:-${MASTER_HOST}:${MASTER_PORT}}"
MASTER_ADMIN_PORT="${MASTER_ADMIN_PORT:-9010}"
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-${CLIENT_HOST:-141.61.84.245}}"
PROTOCOL="${PROTOCOL:-ub}"
DEVICE_NAME="${DEVICE_NAME:-bonding_dev_0}"
NUM_KEYS="${NUM_KEYS:-1000}"
WRITE_THREADS="${WRITE_THREADS:-32}"
WRITE_BATCH_SIZE="${WRITE_BATCH_SIZE:-32}"
WRITE_LOCAL_BUFFER_SIZE="${WRITE_LOCAL_BUFFER_SIZE:-536870912}"
WRITE_GLOBAL_SEGMENT_SIZE="${WRITE_GLOBAL_SEGMENT_SIZE:-0}"
WRITE_TIMEOUT_SEC="${WRITE_TIMEOUT_SEC:-600}"
VERIFY="${VERIFY:-false}"

export LD_LIBRARY_PATH="${BUILD_DIR}/mooncake-store/src:${BUILD_DIR}/mooncake-transfer-engine/src:${BUILD_DIR}/mooncake-common:${BUILD_DIR}/mooncake-common/etcd:${BUILD_DIR}/extern/ubdiag_build/src/sdk:/usr/local/lib64:/usr/local/lib:/usr/lib64:${LD_LIBRARY_PATH:-}"
export MC_STORE_CLIENT_SETUP_RETRIES="${MC_STORE_CLIENT_SETUP_RETRIES:-3}"
export no_proxy="${no_proxy:-127.0.0.1,localhost,local,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,141.61.17.0/24,141.61.11.0/24,141.61.84.0/24}"
export MC_STORE_CLIENT_METRIC_BANDWIDTH="${MC_STORE_CLIENT_METRIC_BANDWIDTH:-0}"
export MC_TCP_BIND_ADDRESS="${MC_TCP_BIND_ADDRESS:-${LOCAL_HOSTNAME}}"
export MC_SLICE_SIZE="${MC_SLICE_SIZE:-1048576}"
export MC_WORKERS_PER_CTX="${MC_WORKERS_PER_CTX:-4}"
export MC_MAX_WR="${MC_MAX_WR:-32}"
export MC_URMA_TRANS_MODE="${MC_URMA_TRANS_MODE:-RM}"
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

stdout_log="${BENCH_LOG_DIR}/write_stdout.log"
stderr_log="${BENCH_LOG_DIR}/write_stderr.log"

args=(
    "--metadata-server=${METADATA_SERVER}"
    "--master-server=${MASTER_SERVER}"
    "--local-hostname=${LOCAL_HOSTNAME}"
    "--master_admin_port=${MASTER_ADMIN_PORT}"
    "--global-segment-size=${WRITE_GLOBAL_SEGMENT_SIZE}"
    "--local-buffer-size=${WRITE_LOCAL_BUFFER_SIZE}"
    "--scenario=segment_write"
    "--num-keys=${NUM_KEYS}"
    "--protocol=${PROTOCOL}"
    "--verify=${VERIFY}"
    "--num_threads=${WRITE_THREADS}"
    "--batch-size=${WRITE_BATCH_SIZE}"
)
if [ -n "${DEVICE_NAME}" ]; then
    args+=("--device-name=${DEVICE_NAME}")
fi

echo "============================================"
echo "  WRITE BENCHMARK START: $(date)"
echo "============================================"
echo "bench=${BENCH}"
echo "protocol=${PROTOCOL} local=${LOCAL_HOSTNAME} master=${MASTER_SERVER} keys=${NUM_KEYS}"

set +e
timeout "${WRITE_TIMEOUT_SEC}s" "${BENCH}" "${args[@]}" ${EXTRA_WRITE_ARGS:-} \
    > >(tee "${stdout_log}") \
    2> >(tee "${stderr_log}" >&2)
exit_code=$?
set -e

echo ""
echo "============================================"
echo "  WRITE BENCHMARK SUMMARY"
echo "============================================"
echo "  Exit code: ${exit_code}"
echo "  End time:  $(date)"
if [ "${exit_code}" -eq 124 ]; then
    echo "  STATUS: TIMEOUT after ${WRITE_TIMEOUT_SEC}s"
elif [ "${exit_code}" -ne 0 ]; then
    echo "  STATUS: FAILED"
else
    echo "  STATUS: PASSED"
fi

echo ""
echo "============================================"
echo "  KEY METRICS"
echo "============================================"
grep -E '(STATUS|succeeded|failed|complete|Written|All segments|Total ops|Throughput|Ops/sec|Wall time)' "${stdout_log}" "${stderr_log}" 2>/dev/null || echo "  (check logs for details)"

if grep -qi 'segfault\|SIGSEGV\|signal\|fatal\|corrupted\|double free' "${stderr_log}"; then
    echo ""
    echo "  CRITICAL ERRORS DETECTED IN STDERR"
    grep -i 'segfault\|SIGSEGV\|signal\|fatal\|corrupted\|double free' "${stderr_log}" || true
fi

echo ""
echo "logs: ${BENCH_LOG_DIR}"
echo "============================================"
exit "${exit_code}"
