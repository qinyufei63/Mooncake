#!/usr/bin/env bash
set -euo pipefail

# Mooncake + UbDiag three-layer verification for 245.
# Defaults match the 245 UB setup. Override env vars for local WSL smoke:
#   PROJECT_DIR=/mnt/d/Code/Mooncake MASTER_HOST=127.0.0.1 CLIENT_HOST=127.0.0.1 \
#   PROTOCOL=tcp DEVICE_NAME= NUM_KEYS=16 READ_DURATION=3 USE_UB=OFF \
#   bash verify_3layers_245.sh --layers l1 --skip-rpm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-/home/q00913006/project/mooncake-qyf}"
RESULTS_DIR="${RESULTS_DIR:-${PROJECT_DIR}/verify_mooncake_ubdiag_$(date +%Y%m%d_%H%M%S)}"
LAYERS="${LAYERS:-l1,l2,l3}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_RPM="${SKIP_RPM:-0}"
RUN_BENCH="${RUN_BENCH:-1}"
RUN_RPM_UNPACK="${RUN_RPM_UNPACK:-1}"

MASTER_HOST="${MASTER_HOST:-141.61.84.245}"
CLIENT_HOST="${CLIENT_HOST:-141.61.84.245}"
PROTOCOL="${PROTOCOL:-ub}"
DEVICE_NAME="${DEVICE_NAME:-bonding_dev_0}"
USE_UB="${USE_UB:-ON}"

UBDIAG_SYSTEM_PREFIX="${UBDIAG_SYSTEM_PREFIX:-}"
UBDIAG_SYSTEM_BIN="${UBDIAG_SYSTEM_BIN:-ubdiag}"

usage() {
    cat <<EOF
Usage: bash $(basename "$0") [options]

Options:
  --project DIR        Mooncake source dir, default: ${PROJECT_DIR}
  --results DIR        Output dir, default: timestamped under project
  --layers LIST        Comma list: l1,l2,l3 (default: ${LAYERS})
  --skip-build         Reuse existing build dirs
  --skip-rpm           Do not build/unpack RPM
  --no-bench           Only configure/build/package; skip benchmark flow
  -h, --help           Show this help

Important:
  L2 is verified only from the customer machine system package path. This script
  never treats the Mooncake RPM as the Layer 2 UbDiag package.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT_DIR="$2"; shift 2 ;;
        --results) RESULTS_DIR="$2"; shift 2 ;;
        --layers) LAYERS="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-rpm) SKIP_RPM=1; shift ;;
        --no-bench) RUN_BENCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
mkdir -p "${RESULTS_DIR}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

run_logged() {
    local log_file="$1"; shift
    mkdir -p "$(dirname "${log_file}")"
    log "RUN: $*"
    "$@" >"${log_file}" 2>&1
}

contains_layer() {
    case ",${LAYERS}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

kill_mooncake() {
    pkill -f mooncake_master 2>/dev/null || true
    pkill -f mooncake_client 2>/dev/null || true
    pkill -f stress_cluster_bench 2>/dev/null || true
    sleep 2
}

restore_submodule() {
    if [ -n "${HIDDEN_UBDIAG_DIR:-}" ] && [ -d "${HIDDEN_UBDIAG_DIR}" ]; then
        rm -rf "${PROJECT_DIR}/extern/ubdiag"
        mv "${HIDDEN_UBDIAG_DIR}" "${PROJECT_DIR}/extern/ubdiag"
        HIDDEN_UBDIAG_DIR=""
    fi
}

hide_submodule() {
    restore_submodule
    if [ -d "${PROJECT_DIR}/extern/ubdiag" ]; then
        HIDDEN_UBDIAG_DIR="${PROJECT_DIR}/extern/ubdiag.hidden.$$"
        mv "${PROJECT_DIR}/extern/ubdiag" "${HIDDEN_UBDIAG_DIR}"
    fi
}

trap 'restore_submodule; kill_mooncake' EXIT

check_layer_hit() {
    local cmake_log="$1"
    local layer="$2"
    local expected="$3"
    if grep -q "UbDiag: ${expected}" "${cmake_log}"; then
        log "OK: ${layer} hit ${expected}"
    else
        grep 'UbDiag:' "${cmake_log}" || true
        die "${layer} did not hit expected UbDiag layer: ${expected}"
    fi
}

cmake_args_common() {
    local args=(
        -DWITH_STORE=ON
        -DWITH_P2P_STORE=OFF
        -DBUILD_UNIT_TESTS=OFF
        -DBUILD_EXAMPLES=OFF
        -DBUILD_TESTS=OFF
        -DBUILD_BENCHMARK=ON
        -DUSE_CUDA=OFF
        -DUSE_REDIS=OFF
        -DUSE_ETCD=OFF
        -DSTORE_USE_ETCD=OFF
        -DENABLE_PERFLOG=ON
        -DUSE_UB="${USE_UB}"
        -DMOONCAKE_UBDIAG_BUILD_CLI=ON
        -DMOONCAKE_UBDIAG_L1_SHARED=ON
        -DMOONCAKE_UBDIAG_PERFPOINT_ONLY=ON
    )
    printf '%s\n' "${args[@]}"
}

configure_and_build() {
    local layer="$1"
    local build_dir="$2"
    local log_dir="$3"
    shift 3

    mkdir -p "${log_dir}"
    if [ "${SKIP_BUILD}" != "1" ]; then
        rm -rf "${build_dir}"
        mkdir -p "${build_dir}"
        (
            cd "${build_dir}"
            cmake "${PROJECT_DIR}" $(cmake_args_common) "$@" >"${log_dir}/cmake.log" 2>&1
            cmake --build . -j"$(nproc)" >"${log_dir}/build.log" 2>&1
        )
    fi
    [ -x "${build_dir}/mooncake-store/benchmarks/stress_cluster_bench" ] || die "${layer}: stress_cluster_bench missing"
}

start_ubdiag() {
    local ubdiag_bin="$1"
    local log_dir="$2"
    [ -x "${ubdiag_bin}" ] || ubdiag_bin="$(command -v "${ubdiag_bin}" || true)"
    [ -n "${ubdiag_bin}" ] || die "ubdiag binary not found"

    export PATH="$(dirname "${ubdiag_bin}"):${PATH}"
    "${ubdiag_bin}" stop >"${log_dir}/ubdiag_stop.log" 2>&1 || true
    rm -f /dev/shm/ubdiag_shm_* 2>/dev/null || true
    "${ubdiag_bin}" start --perflog >"${log_dir}/ubdiag_start.log" 2>&1 || \
        "${ubdiag_bin}" start >>"${log_dir}/ubdiag_start.log" 2>&1
    echo "${ubdiag_bin}"
}

require_csv() {
    local dir="$1"
    local label="$2"
    local count
    count="$(find "${dir}" -type f -name '*.csv' 2>/dev/null | wc -l)"
    if [ "${count}" -eq 0 ]; then
        die "CSV export failed for ${label}: no csv files in ${dir}"
    fi
    log "CSV ${label}: ${count} file(s)"
}

export_ubdiag_csv() {
    local ubdiag_bin="$1"
    local out_dir="$2"
    mkdir -p "${out_dir}"/{show,detail,rawtable,history,watch}

    "${ubdiag_bin}" show --csv "${out_dir}/show" >"${out_dir}/show.log" 2>&1
    require_csv "${out_dir}/show" "show"

    "${ubdiag_bin}" show --detail --csv "${out_dir}/detail" >"${out_dir}/detail.log" 2>&1
    require_csv "${out_dir}/detail" "show-detail"

    "${ubdiag_bin}" show --core 0 --csv "${out_dir}/rawtable" >"${out_dir}/rawtable.log" 2>&1 || true
    require_csv "${out_dir}/rawtable" "show-core-rawtable"

    timeout 6s "${ubdiag_bin}" watch --interval 1000 --csv "${out_dir}/watch" >"${out_dir}/watch.log" 2>&1 || true
    require_csv "${out_dir}/watch" "watch"

    "${ubdiag_bin}" history --csv "${out_dir}/history" >"${out_dir}/history.log" 2>&1 || true
    require_csv "${out_dir}/history" "history"
}

run_benchmark_flow() {
    local label="$1"
    local build_dir="$2"
    local log_dir="$3"
    local ubdiag_bin="${4:-}"

    [ "${RUN_BENCH}" = "1" ] || return 0
    mkdir -p "${log_dir}"
    kill_mooncake

    local real_ubdiag=""
    if [ -n "${ubdiag_bin}" ]; then
        real_ubdiag="$(start_ubdiag "${ubdiag_bin}" "${log_dir}")"
    fi

    local common_env=(
        "PROJECT_DIR=${PROJECT_DIR}"
        "BUILD_DIR=${build_dir}"
        "MASTER_HOST=${MASTER_HOST}"
        "CLIENT_HOST=${CLIENT_HOST}"
        "LOCAL_HOSTNAME=${CLIENT_HOST}"
        "PROTOCOL=${PROTOCOL}"
        "DEVICE_NAME=${DEVICE_NAME}"
        "NUM_KEYS=${NUM_KEYS:-1000}"
        "READ_DURATION=${READ_DURATION:-20}"
        "BENCH_LOG_DIR=${log_dir}"
        "LD_LIBRARY_PATH=${build_dir}/mooncake-store/src:${build_dir}/mooncake-transfer-engine/src:${build_dir}/mooncake-common:${build_dir}/mooncake-common/etcd:${build_dir}/extern/ubdiag_build/src/sdk:/usr/local/lib64:/usr/local/lib:/usr/lib64:${LD_LIBRARY_PATH:-}"
    )

    env "${common_env[@]}" bash "${SCRIPT_DIR}/run_mooncake_store_master.sh" >"${log_dir}/01_master.log" 2>&1 &
    local master_pid=$!
    sleep 4
    kill -0 "${master_pid}" 2>/dev/null || die "${label}: master failed to start"

    env "${common_env[@]}" bash "${SCRIPT_DIR}/run_mooncake_store_client.sh" >"${log_dir}/02_client.log" 2>&1 &
    local client_pid=$!
    sleep 4
    kill -0 "${client_pid}" 2>/dev/null || die "${label}: client failed to start"

    env "${common_env[@]}" bash "${SCRIPT_DIR}/write.sh" >"${log_dir}/03_write.log" 2>&1
    env "${common_env[@]}" bash "${SCRIPT_DIR}/read.sh" >"${log_dir}/04_read.log" 2>&1

    if [ -n "${real_ubdiag}" ]; then
        export_ubdiag_csv "${real_ubdiag}" "${log_dir}/csv"
        "${real_ubdiag}" stop >"${log_dir}/ubdiag_stop_final.log" 2>&1 || true
    fi

    kill_mooncake
    {
        echo "label=${label}"
        grep -E 'STATUS|Throughput|Ops/sec|Total ops|P99' "${log_dir}/03_write.log" "${log_dir}/04_read.log" 2>/dev/null || true
        find "${log_dir}/csv" -type f -name '*.csv' 2>/dev/null | sort || true
    } >"${log_dir}/00_summary.txt"
}

verify_rpm_unpack() {
    local rpm_file="$1"
    local out_dir="$2"
    [ "${RUN_RPM_UNPACK}" = "1" ] || return 0
    command -v rpm2cpio >/dev/null || die "rpm2cpio not found"
    command -v cpio >/dev/null || die "cpio not found"

    rm -rf "${out_dir}"
    mkdir -p "${out_dir}/root"
    (
        cd "${out_dir}/root"
        rpm2cpio "${rpm_file}" | cpio -idmv >"${out_dir}/cpio.log" 2>&1
    )
    [ -x "${out_dir}/root/usr/bin/ubdiag" ] || die "RPM unpack: /usr/bin/ubdiag missing"
    compgen -G "${out_dir}/root/usr/lib64/libubdiag.so*" >/dev/null || die "RPM unpack: libubdiag.so missing"
    if [ -e "${out_dir}/root/usr/include/ubdiag" ] || [ -e "${out_dir}/root/usr/lib64/cmake/UbDiag" ]; then
        die "RPM unpack: found UbDiag dev/system-package metadata; L2 boundary violated"
    fi
    log "RPM unpack OK: runtime CLI/lib only"
}

build_rpm() {
    local build_dir="$1"
    local log_dir="$2"
    [ "${SKIP_RPM}" != "1" ] || return 0
    command -v rpmbuild >/dev/null || die "rpmbuild not found; install rpm-build on this machine"
    (
        cd "${PROJECT_DIR}"
        BUILD_DIR="${build_dir}" OUTPUT_DIR="${RESULTS_DIR}/rpm-output" TARGET_PLATFORM="$(uname -m)" \
            bash scripts/build_rpm.sh >"${log_dir}/rpm_build.log" 2>&1
    )
    local rpm_file
    rpm_file="$(find "${RESULTS_DIR}/rpm-output" -type f -name '*.rpm' | head -1)"
    [ -n "${rpm_file}" ] || die "RPM was not produced"
    echo "${rpm_file}" >"${log_dir}/rpm_path.txt"
    verify_rpm_unpack "${rpm_file}" "${log_dir}/rpm_unpacked"
}

log "Project: ${PROJECT_DIR}"
log "Results: ${RESULTS_DIR}"
log "Layers: ${LAYERS}"
log "Runtime: MASTER_HOST=${MASTER_HOST} CLIENT_HOST=${CLIENT_HOST} PROTOCOL=${PROTOCOL} USE_UB=${USE_UB}"

[ -d "${PROJECT_DIR}" ] || die "PROJECT_DIR not found: ${PROJECT_DIR}"
[ -f "${SCRIPT_DIR}/write.sh" ] || die "write.sh not found next to verify script"

cd "${PROJECT_DIR}"

if contains_layer l1; then
    log "===== L1 submodule ====="
    restore_submodule
    [ -f "${PROJECT_DIR}/extern/ubdiag/CMakeLists.txt" ] || die "L1 requires extern/ubdiag submodule"
    L1_BUILD="${PROJECT_DIR}/build_verify_l1"
    L1_LOG="${RESULTS_DIR}/l1_submodule"
    configure_and_build "l1" "${L1_BUILD}" "${L1_LOG}"
    check_layer_hit "${L1_LOG}/cmake.log" "l1" "using submodule"
    run_benchmark_flow "l1" "${L1_BUILD}" "${L1_LOG}" "${L1_BUILD}/extern/ubdiag_build/src/cli/ubdiag"
    build_rpm "${L1_BUILD}" "${L1_LOG}"
fi

if contains_layer l2; then
    log "===== L2 system package ====="
    L2_BUILD="${PROJECT_DIR}/build_verify_l2"
    L2_LOG="${RESULTS_DIR}/l2_system"
    hide_submodule
    l2_extra=()
    if [ -n "${UBDIAG_SYSTEM_PREFIX}" ]; then
        l2_extra+=("-DCMAKE_PREFIX_PATH=${UBDIAG_SYSTEM_PREFIX}")
    fi
    configure_and_build "l2" "${L2_BUILD}" "${L2_LOG}" "${l2_extra[@]}"
    check_layer_hit "${L2_LOG}/cmake.log" "l2" "using system package"
    run_benchmark_flow "l2" "${L2_BUILD}" "${L2_LOG}" "${UBDIAG_SYSTEM_BIN}"
    restore_submodule
fi

if contains_layer l3; then
    log "===== L3 mock fallback ====="
    L3_BUILD="${PROJECT_DIR}/build_verify_l3"
    L3_LOG="${RESULTS_DIR}/l3_mock"
    hide_submodule
    configure_and_build "l3" "${L3_BUILD}" "${L3_LOG}" -DMOONCAKE_UBDIAG_DISABLE_SYSTEM=ON
    check_layer_hit "${L3_LOG}/cmake.log" "l3" "using mock"
    run_benchmark_flow "l3" "${L3_BUILD}" "${L3_LOG}" ""
    restore_submodule
fi

log "===== SUMMARY ====="
for f in "${RESULTS_DIR}"/*/00_summary.txt; do
    [ -f "${f}" ] || continue
    echo "--- ${f} ---"
    cat "${f}"
done
log "Done. Full logs: ${RESULTS_DIR}"
