#!/bin/bash
# ============================================================
# Mooncake UbDiag v1.2 集成验证脚本
# 验证: DISABLE 模式 + vendored 模式 + 版本校验 + 打点验证
# 用法: bash scripts/verify_ubdiag_v12.sh
# ============================================================
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-$(pwd)}"
MOONCAKE_DIR=$WORKSPACE/mooncake-v12-verify
UBDIAG_EXPECTED_TAG="v0.5.1"
UBDIAG_EXPECTED_COMMIT="705c6c37da45df2be4bc64c134dca0b7f30b2113"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
REUSE_BUILD="${REUSE_BUILD:-0}"
VENDORED_UBDIAG_BIN=""
VENDORED_UBDIAG_LIB_DIR=""
DEFAULT_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
MASTER_HOST="${MASTER_HOST:-${DEFAULT_HOST:-127.0.0.1}}"
CLIENT_HOST="${CLIENT_HOST:-${MASTER_HOST}}"
PROTOCOL="${PROTOCOL:-ub}"
USE_UB="${USE_UB:-}"
if [ -z "$USE_UB" ]; then
    if [ "$PROTOCOL" = "ub" ]; then
        USE_UB=ON
    else
        USE_UB=OFF
    fi
fi
if [ "$PROTOCOL" = "ub" ] && [ "$USE_UB" != "ON" ]; then
    echo "FATAL: PROTOCOL=ub 要求 USE_UB=ON" >&2
    exit 1
fi
DEVICE_NAME="${DEVICE_NAME:-bonding_dev_0}"
NUM_KEYS="${NUM_KEYS:-1000}"
READ_DURATION="${READ_DURATION:-20}"
VERIFY_RESULTS_DIR="${VERIFY_RESULTS_DIR:-$WORKSPACE/verify_ubdiag_v12_$(date +%Y%m%d_%H%M%S)}"
MASTER_PID=""
CLIENT_PID=""
UBDIAG_ACTIVE_CORE=""

export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib64:/usr/lib64:${LD_LIBRARY_PATH:-}

run_vendored_ubdiag() {
    [ -x "$VENDORED_UBDIAG_BIN" ] || {
        echo "FATAL: vendored ubdiag CLI not executable: $VENDORED_UBDIAG_BIN" >&2
        return 1
    }
    env LD_LIBRARY_PATH="$VENDORED_UBDIAG_LIB_DIR:${LD_LIBRARY_PATH:-}" \
        "$VENDORED_UBDIAG_BIN" "$@"
}

cleanup() {
    if [ -n "$CLIENT_PID" ]; then
        kill "$CLIENT_PID" >/dev/null 2>&1 || true
        wait "$CLIENT_PID" >/dev/null 2>&1 || true
    fi
    if [ -n "$MASTER_PID" ]; then
        kill "$MASTER_PID" >/dev/null 2>&1 || true
        wait "$MASTER_PID" >/dev/null 2>&1 || true
    fi
    if [ -n "$VENDORED_UBDIAG_BIN" ] && [ -x "$VENDORED_UBDIAG_BIN" ]; then
        run_vendored_ubdiag stop >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

stop_mooncake_processes() {
    if [ -n "$CLIENT_PID" ]; then
        kill "$CLIENT_PID" >/dev/null 2>&1 || true
        wait "$CLIENT_PID" >/dev/null 2>&1 || true
        CLIENT_PID=""
    fi
    if [ -n "$MASTER_PID" ]; then
        kill "$MASTER_PID" >/dev/null 2>&1 || true
        wait "$MASTER_PID" >/dev/null 2>&1 || true
        MASTER_PID=""
    fi
}

run_benchmark_flow() {
    local label="$1"
    local build_dir="$2"
    local log_dir="$3"
    local common_env=(
        "PROJECT_DIR=$MOONCAKE_DIR"
        "BUILD_DIR=$build_dir"
        "MASTER_HOST=$MASTER_HOST"
        "CLIENT_HOST=$CLIENT_HOST"
        "LOCAL_HOSTNAME=$CLIENT_HOST"
        "PROTOCOL=$PROTOCOL"
        "DEVICE_NAME=$DEVICE_NAME"
        "NUM_KEYS=$NUM_KEYS"
        "READ_DURATION=$READ_DURATION"
        "BENCH_LOG_DIR=$log_dir"
    )

    mkdir -p "$log_dir"
    stop_mooncake_processes

    env "${common_env[@]}" bash "$MOONCAKE_DIR/run_mooncake_store_master.sh" \
        >"$log_dir/01_master.log" 2>&1 &
    MASTER_PID=$!
    sleep 4
    if ! kill -0 "$MASTER_PID" 2>/dev/null; then
        cat "$log_dir/01_master.log"
        echo "FATAL: $label mooncake_master 启动失败" >&2
        exit 1
    fi
    if grep -q "unknown command line flag" "$log_dir/01_master.log"; then
        cat "$log_dir/01_master.log"
        echo "FATAL: $label mooncake_master 使用了无效参数" >&2
        exit 1
    fi

    env "${common_env[@]}" bash "$MOONCAKE_DIR/run_mooncake_store_client.sh" \
        >"$log_dir/02_client.log" 2>&1 &
    CLIENT_PID=$!
    sleep 5
    if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
        cat "$log_dir/02_client.log"
        echo "FATAL: $label mooncake_client 启动失败" >&2
        exit 1
    fi

    if ! env "${common_env[@]}" bash "$MOONCAKE_DIR/write.sh" \
         >"$log_dir/03_write.log" 2>&1; then
        cat "$log_dir/03_write.log"
        echo "FATAL: $label write benchmark 命令失败" >&2
        exit 1
    fi
    grep -q "STATUS: PASSED" "$log_dir/03_write.log" || {
        cat "$log_dir/03_write.log"
        echo "FATAL: $label write benchmark 未通过" >&2
        exit 1
    }

    if ! env "${common_env[@]}" bash "$MOONCAKE_DIR/read.sh" \
         >"$log_dir/04_read.log" 2>&1; then
        cat "$log_dir/04_read.log"
        echo "FATAL: $label read benchmark 命令失败" >&2
        exit 1
    fi
    grep -q "STATUS: PASSED" "$log_dir/04_read.log" || {
        cat "$log_dir/04_read.log"
        echo "FATAL: $label read benchmark 未通过" >&2
        exit 1
    }

    stop_mooncake_processes
    echo "  OK: $label master/client/write/read benchmark 全部通过"
}

require_csv_data() {
    local dir="$1"
    local label="$2"
    local csv_file
    local found_csv=0
    while IFS= read -r csv_file; do
        found_csv=1
        if awk 'NF { rows++ } END { exit(rows < 2) }' "$csv_file"; then
            echo "  OK: $label CSV 包含数据: $csv_file"
            return 0
        fi
    done < <(find "$dir" -type f -name '*.csv' -print 2>/dev/null)
    if [ "$found_csv" -eq 0 ]; then
        echo "FATAL: $label 没有生成 CSV 文件" >&2
        exit 1
    else
        echo "FATAL: $label 的所有 CSV 都只有表头或为空" >&2
        exit 1
    fi
}

export_ubdiag_csv() {
    local out_dir="$1"
    mkdir -p "$out_dir"/{show,detail,rawtable,watch,history}

    run_vendored_ubdiag show --csv "$out_dir/show" >"$out_dir/show.log" 2>&1
    require_csv_data "$out_dir/show" "show"

    run_vendored_ubdiag show --detail --csv "$out_dir/detail" >"$out_dir/detail.log" 2>&1
    require_csv_data "$out_dir/detail" "show-detail"

    [ -n "$UBDIAG_ACTIVE_CORE" ] || {
        echo "FATAL: 无法确定包含打点数据的 CPU core" >&2
        exit 1
    }
    run_vendored_ubdiag show --core "$UBDIAG_ACTIVE_CORE" --csv "$out_dir/rawtable" \
        >"$out_dir/rawtable.log" 2>&1
    require_csv_data "$out_dir/rawtable" "show-core"

    set +e
    timeout 6 env LD_LIBRARY_PATH="$VENDORED_UBDIAG_LIB_DIR:${LD_LIBRARY_PATH:-}" \
        "$VENDORED_UBDIAG_BIN" watch --interval 1000 --csv "$out_dir/watch" \
        >"$out_dir/watch.log" 2>&1
    local watch_rc=$?
    set -e
    if [ "$watch_rc" -ne 0 ] && [ "$watch_rc" -ne 124 ]; then
        cat "$out_dir/watch.log"
        echo "FATAL: ubdiag watch CSV 执行失败，exit=$watch_rc" >&2
        exit 1
    fi
    require_csv_data "$out_dir/watch" "watch"

    run_vendored_ubdiag history --csv "$out_dir/history" >"$out_dir/history.log" 2>&1
    require_csv_data "$out_dir/history" "history"
}

echo "============================================================"
echo "  Mooncake UbDiag v1.2 集成验证"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  传输协议: PROTOCOL=$PROTOCOL USE_UB=$USE_UB DEVICE_NAME=$DEVICE_NAME"
echo "============================================================"

# ===== 0. 准备 =====
echo ""
echo "[0/8] 准备工作区..."
# 先回到 workspace 根目录(避免 rm -rf 删掉自己所在的目录)
cd "$WORKSPACE"
if [ "$REUSE_BUILD" = "1" ]; then
    [ -d "$MOONCAKE_DIR/.git" ] || {
        echo "FATAL: REUSE_BUILD=1 但现有验证目录不存在: $MOONCAKE_DIR" >&2
        exit 1
    }
    echo "  REUSE_BUILD=1: 复用现有源码和两层构建产物"
else
    rm -rf "$MOONCAKE_DIR"
    git clone -b supercache_dev_ubdiag \
        --depth=1 --recurse-submodules --shallow-submodules \
        https://github.com/qinyufei63/Mooncake.git "$MOONCAKE_DIR"
fi
cd "$MOONCAKE_DIR"
mkdir -p "$VERIFY_RESULTS_DIR"
echo "  验证结果目录: $VERIFY_RESULTS_DIR"

SUBMODULE_STATUS="$(git submodule status --recursive)"
if [ -z "$SUBMODULE_STATUS" ] || echo "$SUBMODULE_STATUS" | grep -Eq '^[-+U]'; then
    echo "FATAL: Mooncake 必需子模块未完整初始化"
    echo "$SUBMODULE_STATUS"
    exit 1
fi
echo "  OK: pybind11/yalantinglibs 子模块已初始化"

if [ ! -f mooncake-common/FindUbDiag.cmake ]; then
    echo "FATAL: FindUbDiag.cmake 不存在"
    exit 1
fi
echo "  OK: FindUbDiag.cmake 存在"
for helper in run_mooncake_store_master.sh run_mooncake_store_client.sh write.sh read.sh; do
    [ -f "$helper" ] || {
        echo "FATAL: benchmark helper 不存在: $helper" >&2
        exit 1
    }
done
echo "  OK: 4 个 benchmark helper 均存在"
echo "  配置的 ubdiag 仓库与版本:"
grep -A2 -E "MOONCAKE_UBDIAG_GIT_REPOSITORY|MOONCAKE_UBDIAG_GIT_TAG" \
    mooncake-common/FindUbDiag.cmake

# ===== 1. Layer 0: DISABLE 模式 =====
echo ""
echo "============================================================"
echo "[1/8] Layer 0: DISABLE 模式 cmake 配置"
echo "============================================================"
if [ "$REUSE_BUILD" = "1" ]; then
    [ -d build_mock ] || { echo "FATAL: build_mock 不存在" >&2; exit 1; }
    cd build_mock
    echo "  REUSE_BUILD=1: 复用构建目录，仅重新执行 DISABLE 模式 CMake 配置"
    if ! cmake .. -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
         -DSTORE_USE_ETCD=ON -DUSE_ETCD=ON -DUSE_UB="$USE_UB" \
         -DBUILD_BENCHMARK=ON -DBUILD_UNIT_TESTS=OFF \
         -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
         2>&1 | tee cmake_mock.log; then
        echo "FATAL: DISABLE 模式 CMake 重新配置失败" >&2
        exit 1
    fi
else
    mkdir build_mock && cd build_mock
    if ! cmake .. -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
         -DSTORE_USE_ETCD=ON -DUSE_ETCD=ON -DUSE_UB="$USE_UB" \
         -DBUILD_BENCHMARK=ON -DBUILD_UNIT_TESTS=OFF \
         -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
         2>&1 | tee cmake_mock.log; then
        echo "FATAL: DISABLE 模式 CMake 配置失败，停止验证"
        exit 1
    fi
fi
grep -iE "UbDiag|ubdiag|fetch|disable|error|fatal" cmake_mock.log 2>/dev/null || true
if [ "$USE_UB" = "ON" ] && ! grep -q '^USE_UB:BOOL=ON$' CMakeCache.txt; then
    echo "FATAL: DISABLE 构建没有启用 USE_UB" >&2
    exit 1
fi

echo ""
echo "[1/8] 检查 FetchContent 拉取的 ubdiag 版本..."
if [ -d "_deps/ubdiag-src" ]; then
    cd _deps/ubdiag-src
    if ! git show-ref --verify --quiet "refs/tags/$UBDIAG_EXPECTED_TAG"; then
        git fetch origin \
            "refs/tags/$UBDIAG_EXPECTED_TAG:refs/tags/$UBDIAG_EXPECTED_TAG"
    fi
    TAG=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    COMMIT=$(git log --oneline -1 2>/dev/null || echo "unknown")
    echo "  tag: $TAG"
    echo "  commit: $COMMIT"
    echo "  commit SHA: $COMMIT_FULL"
    grep -m1 "project(UbDiag VERSION" CMakeLists.txt 2>/dev/null || true
    grep "versionString" include/ubdiag/version.h 2>/dev/null || echo "  (version.h 无 versionString)"

    if [ "$COMMIT_FULL" != "$UBDIAG_EXPECTED_COMMIT" ]; then
        echo "FATAL: 期望 ubdiag $UBDIAG_EXPECTED_COMMIT,实际 $COMMIT_FULL"
        exit 2
    fi
    if [ "$TAG" != "$UBDIAG_EXPECTED_TAG" ]; then
        echo "FATAL: 期望 ubdiag tag $UBDIAG_EXPECTED_TAG,实际 $TAG" >&2
        exit 2
    fi
    echo "  OK: ubdiag commit 与 LinQuickDev/ubdiag master 镜像基线一致"

    if ! grep -q "UBDIAG_DISABLE" include/ubdiag/perf_point.h; then
        echo "FATAL: $TAG 的 perf_point.h 不包含 UBDIAG_DISABLE，无法验证 v1.2 DISABLE 层"
        echo "       当前文档依赖的空函数机制不在所选 tag 中，请先修正 UbDiag 版本基线"
        exit 2
    fi
    echo "  OK: $TAG 包含 UBDIAG_DISABLE 空函数机制"
    cd ../..
else
    echo "FATAL: DISABLE 模式没有找到 _deps/ubdiag-src" >&2
    exit 2
fi

echo ""
echo "============================================================"
echo "[2/8] Layer 0: DISABLE 模式编译"
echo "============================================================"
if [ "$REUSE_BUILD" = "1" ]; then
    echo "  REUSE_BUILD=1: 按新配置增量重编 DISABLE benchmark targets"
    if ! cmake --build . --parallel "$BUILD_JOBS" \
         --target mooncake_master mooncake_client stress_cluster_bench \
         2>&1 | tee build_mock_incremental.log; then
        echo "FATAL: DISABLE 模式增量编译失败" >&2
        exit 1
    fi
else
    if ! cmake --build . --parallel "$BUILD_JOBS" \
         --target mooncake_master mooncake_client stress_cluster_bench \
         2>&1 | tee build_mock.log; then
        echo "FATAL: DISABLE 模式 mooncake_master 编译失败"
        exit 1
    fi
fi
MOCK_BIN=mooncake-store/src/mooncake_master
if [ -f "$MOCK_BIN" ]; then
    echo "  OK: mooncake_master 编译成功 (DISABLE 模式)"
    file $MOCK_BIN | head -1
else
    echo "FATAL: mooncake_master 编译命令成功，但可执行文件不存在"
    exit 1
fi

echo ""
echo "============================================================"
echo "[3/8] Layer 0: DISABLE 模式 mock 验证"
echo "      确认 PerfPoint 是空函数,运行 mooncake 不产生 ubdiag 输出"
echo "============================================================"

# 确保 SHM 不存在 (DISABLE 模式不应该连 SHM)
rm -f /dev/shm/ubdiag_shm_* 2>/dev/null || true

if [ -n "$MOCK_BIN" ]; then
    echo "[3/8] 运行 mooncake_master --help (DISABLE 模式,不应有 ubdiag 输出)..."
    OUTPUT=$($MOCK_BIN --help 2>&1 || true)
    if echo "$OUTPUT" | grep -qi "ubdiag\|PerfPoint\|shared memory"; then
        echo "FATAL: DISABLE 模式 mooncake 输出中出现了 ubdiag 相关内容" >&2
        echo "$OUTPUT" | grep -i "ubdiag\|perf\|shm" | head -5
        exit 1
    else
        echo "  OK: mooncake 运行无 ubdiag 输出 (PerfPoint 被编译器优化掉了)"
    fi

    # 确认 SHM 未被创建 (DISABLE 模式不应该创建 SHM)
    if ls /dev/shm/ubdiag_shm_* 2>/dev/null; then
        echo "FATAL: DISABLE 模式下 SHM 被创建了" >&2
        exit 1
    else
        echo "  OK: DISABLE 模式下无 SHM 创建 (符合预期)"
    fi
else
    echo "FATAL: DISABLE 模式 mooncake_master 不存在" >&2
    exit 1
fi

# 确认 UBDIAG_DISABLE 生效:检查 mooncake_master 二进制是否引用 libubdiag
echo ""
echo "[3/8] 检查二进制是否链接 libubdiag (DISABLE 模式不应该链接)..."
if [ -n "$MOCK_BIN" ]; then
    if ldd $MOCK_BIN 2>/dev/null | grep -q "libubdiag"; then
        echo "FATAL: DISABLE 模式下链接了 libubdiag" >&2
        ldd $MOCK_BIN | grep libubdiag
        exit 1
    else
        echo "  OK: DISABLE 模式下未链接 libubdiag (constexpr 空函数,零依赖)"
    fi
fi

echo ""
echo "[3/8] Layer 0 运行 master/client/write/read benchmark..."
run_benchmark_flow \
    "Layer 0 DISABLE" \
    "$MOONCAKE_DIR/build_mock" \
    "$VERIFY_RESULTS_DIR/layer0_disable"
if ls /dev/shm/ubdiag_shm_* >/dev/null 2>&1; then
    echo "FATAL: Layer 0 benchmark 后出现 UbDiag SHM" >&2
    exit 1
fi

cd ..

# ===== 2. Layer 1: vendored 模式 =====
echo ""
echo "============================================================"
echo "[4/8] Layer 1: vendored 模式 cmake 配置"
echo "============================================================"
if [ "$REUSE_BUILD" = "1" ]; then
    [ -d build_vendored ] || { echo "FATAL: build_vendored 不存在" >&2; exit 1; }
    cd build_vendored
    echo "  REUSE_BUILD=1: 复用构建目录，仅重新执行 vendored 模式 CMake 配置"
    if ! cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON \
         -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
         -DSTORE_USE_ETCD=ON -DUSE_ETCD=ON -DUSE_UB="$USE_UB" \
         -DBUILD_BENCHMARK=ON -DBUILD_UNIT_TESTS=OFF \
         -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
         2>&1 | tee cmake_vendored.log; then
        echo "FATAL: vendored 模式 CMake 重新配置失败" >&2
        exit 1
    fi
else
    mkdir build_vendored && cd build_vendored
    if ! cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON \
         -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
         -DSTORE_USE_ETCD=ON -DUSE_ETCD=ON -DUSE_UB="$USE_UB" \
         -DBUILD_BENCHMARK=ON -DBUILD_UNIT_TESTS=OFF \
         -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
         2>&1 | tee cmake_vendored.log; then
        echo "FATAL: vendored 模式 CMake 配置失败，停止验证"
        exit 1
    fi
fi
grep -iE "UbDiag|ubdiag|fetch|vendored|error|fatal" cmake_vendored.log 2>/dev/null || true
if [ "$USE_UB" = "ON" ] && ! grep -q '^USE_UB:BOOL=ON$' CMakeCache.txt; then
    echo "FATAL: vendored 构建没有启用 USE_UB" >&2
    exit 1
fi

echo ""
echo "[4/8] 检查 FetchContent 拉取的 ubdiag 版本..."
if [ -d "_deps/ubdiag-src" ]; then
    cd _deps/ubdiag-src
    if ! git show-ref --verify --quiet "refs/tags/$UBDIAG_EXPECTED_TAG"; then
        git fetch origin \
            "refs/tags/$UBDIAG_EXPECTED_TAG:refs/tags/$UBDIAG_EXPECTED_TAG"
    fi
    TAG=$(git describe --tags --exact-match 2>/dev/null || echo "unknown")
    COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    COMMIT=$(git log --oneline -1 2>/dev/null || echo "unknown")
    echo "  tag: $TAG"
    echo "  commit: $COMMIT"
    echo "  commit SHA: $COMMIT_FULL"
    grep -m1 "project(UbDiag VERSION" CMakeLists.txt 2>/dev/null || true
    echo "  version.h:"
    grep "versionString\|versionMajor\|versionMinor\|versionPatch" include/ubdiag/version.h 2>/dev/null || echo "  (无 versionString)"
    cd ../..

    if [ "$COMMIT_FULL" = "$UBDIAG_EXPECTED_COMMIT" ]; then
        echo "  OK: commit 匹配 $UBDIAG_EXPECTED_COMMIT"
    else
        echo "FATAL: 期望 $UBDIAG_EXPECTED_COMMIT,实际 $COMMIT_FULL"
        exit 2
    fi
    if [ "$TAG" != "$UBDIAG_EXPECTED_TAG" ]; then
        echo "FATAL: 期望 ubdiag tag $UBDIAG_EXPECTED_TAG,实际 $TAG" >&2
        exit 2
    fi
else
    echo "FATAL: vendored 模式没有找到 _deps/ubdiag-src" >&2
    exit 2
fi

echo ""
echo "============================================================"
echo "[5/8] Layer 1: vendored 模式编译"
echo "============================================================"
if [ "$REUSE_BUILD" = "1" ]; then
    echo "  REUSE_BUILD=1: 按新配置增量重编 vendored benchmark targets"
    if ! cmake --build . --parallel "$BUILD_JOBS" \
         --target mooncake_master mooncake_client stress_cluster_bench ubdiag \
         2>&1 | tee build_vendored_incremental.log; then
        echo "FATAL: vendored 模式增量编译失败" >&2
        exit 1
    fi
else
    if ! cmake --build . --parallel "$BUILD_JOBS" \
         --target mooncake_master mooncake_client stress_cluster_bench ubdiag \
         2>&1 | tee build_vendored.log; then
        echo "FATAL: vendored 模式 mooncake_master/ubdiag 编译失败"
        exit 1
    fi
fi
VENDORED_BIN=mooncake-store/src/mooncake_master
if [ -f "$VENDORED_BIN" ]; then
    echo "  OK: mooncake_master 编译成功 (vendored 模式)"
    file $VENDORED_BIN | head -1
else
    echo "FATAL: mooncake_master 编译命令成功，但可执行文件不存在"
    exit 1
fi

echo ""
echo "[5/8] 检查 libubdiag + ubdiag CLI..."
VENDORED_UBDIAG_LIB_DIR="$(readlink -f _deps/ubdiag-build/src/sdk)"
VENDORED_UBDIAG_BIN="$(readlink -f _deps/ubdiag-build/src/cli/ubdiag)"
if ls "$VENDORED_UBDIAG_LIB_DIR"/libubdiag.* 2>/dev/null; then
    echo "  OK: libubdiag 编译成功"
    echo "  NOTE: libubdiag.so.0.5.0 中的 0.5.0 是 UbDiag project/ABI 版本，不是 Git tag"
else
    echo "FATAL: libubdiag 未找到"
    exit 1
fi
if [ -x "$VENDORED_UBDIAG_BIN" ]; then
    echo "  OK: ubdiag CLI 编译成功"
    echo "  CLI absolute path: $VENDORED_UBDIAG_BIN"
    echo "  SDK absolute path: $VENDORED_UBDIAG_LIB_DIR"
    sha256sum "$VENDORED_UBDIAG_BIN"
    run_vendored_ubdiag --help 2>&1 | head -3 || true
    echo "  CLI linked libubdiag:"
    CLI_LIBUBDIAG_PATH="$(
        env LD_LIBRARY_PATH="$VENDORED_UBDIAG_LIB_DIR:${LD_LIBRARY_PATH:-}" \
            ldd "$VENDORED_UBDIAG_BIN" | awk '/libubdiag/{print $3; exit}'
    )"
    echo "  $CLI_LIBUBDIAG_PATH"
    case "$CLI_LIBUBDIAG_PATH" in
        "$VENDORED_UBDIAG_LIB_DIR"/libubdiag.so*) ;;
        *)
            echo "FATAL: CLI 没有链接本次构建目录中的 libubdiag: $CLI_LIBUBDIAG_PATH" >&2
            exit 1
            ;;
    esac
else
    echo "FATAL: ubdiag CLI 未找到"
    exit 1
fi

echo ""
echo "[5/8] 检查 mooncake_master 是否链接了 libubdiag..."
if [ -n "$VENDORED_BIN" ]; then
    MOONCAKE_LIBUBDIAG_PATH="$(ldd "$VENDORED_BIN" 2>/dev/null | awk '/libubdiag/{print $3; exit}')"
    echo "  $MOONCAKE_LIBUBDIAG_PATH"
    case "$MOONCAKE_LIBUBDIAG_PATH" in
        "$VENDORED_UBDIAG_LIB_DIR"/libubdiag.so*)
            echo "  OK: mooncake_master 链接本次构建目录中的 libubdiag"
            ;;
        *)
            echo "FATAL: mooncake_master 没有链接本次构建目录中的 libubdiag" >&2
            exit 1
            ;;
    esac
fi

echo ""
echo "[5/8] 锁定本次构建树中的 ubdiag，不安装、不调用系统 ubdiag..."
run_vendored_ubdiag status 2>&1 || true

cd ..

# ===== 3. 版本校验汇总 =====
echo ""
echo "============================================================"
echo "[6/8] 版本校验汇总"
echo "============================================================"
echo "  期望 ubdiag tag: $UBDIAG_EXPECTED_TAG"
echo "  期望 ubdiag commit: $UBDIAG_EXPECTED_COMMIT"
echo "  DISABLE 模式拉取:"
(cd build_mock/_deps/ubdiag-src 2>/dev/null && git rev-parse HEAD 2>/dev/null) || echo "    (源码目录不存在)"
echo "  vendored 模式拉取:"
(cd build_vendored/_deps/ubdiag-src 2>/dev/null && git rev-parse HEAD 2>/dev/null) || echo "    (源码目录不存在)"
MOCK_FETCHED_COMMIT="$(git -C build_mock/_deps/ubdiag-src rev-parse HEAD 2>/dev/null || true)"
VENDORED_FETCHED_COMMIT="$(git -C build_vendored/_deps/ubdiag-src rev-parse HEAD 2>/dev/null || true)"
if [ "$MOCK_FETCHED_COMMIT" != "$UBDIAG_EXPECTED_COMMIT" ] || \
   [ "$VENDORED_FETCHED_COMMIT" != "$UBDIAG_EXPECTED_COMMIT" ]; then
    echo "FATAL: 两层 UbDiag commit 未同时命中期望基线" >&2
    exit 2
fi
echo "  OK: 两层均命中精确 commit"

# ===== 4. 打点验证 =====
echo ""
echo "============================================================"
echo "[7/8] 打点验证 (vendored 模式)"
echo "============================================================"

if [ -z "$VENDORED_BIN" ] || [ ! -f "build_vendored/$VENDORED_BIN" ]; then
    echo "FATAL: vendored mooncake_master 不存在，不能执行打点验证" >&2
    exit 1
fi

echo "[7/8] 使用本次构建的 ubdiag 启动采集..."
echo "  $VENDORED_UBDIAG_BIN"
run_vendored_ubdiag stop 2>/dev/null || true
rm -f /dev/shm/ubdiag_shm_* 2>/dev/null || true
run_vendored_ubdiag start --perflog
sleep 1
run_vendored_ubdiag status

echo ""
echo "[7/8] Layer 1 运行 master/client/write/read benchmark..."
run_benchmark_flow \
    "Layer 1 vendored" \
    "$MOONCAKE_DIR/build_vendored" \
    "$VERIFY_RESULTS_DIR/layer1_vendored"

echo ""
echo "[7/8] ubdiag show (汇总)..."
UBDIAG_SHOW_LOG="$MOONCAKE_DIR/build_vendored/ubdiag_show.log"
if ! run_vendored_ubdiag show >"$UBDIAG_SHOW_LOG" 2>&1; then
    cat "$UBDIAG_SHOW_LOG"
    echo "FATAL: ubdiag show 执行失败" >&2
    exit 1
fi
head -40 "$UBDIAG_SHOW_LOG"
UBDIAG_DATA_ROWS="$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' "$UBDIAG_SHOW_LOG" || true)"
if [ "$UBDIAG_DATA_ROWS" -eq 0 ]; then
    echo "FATAL: ubdiag show 没有任何数据行，不能判定打点验证通过" >&2
    exit 1
fi
echo "  OK: ubdiag show 捕获到 $UBDIAG_DATA_ROWS 条数据"

echo ""
echo "[7/8] ubdiag show --detail (按核)..."
UBDIAG_DETAIL_LOG="$MOONCAKE_DIR/build_vendored/ubdiag_show_detail.log"
run_vendored_ubdiag show --detail >"$UBDIAG_DETAIL_LOG" 2>&1
head -30 "$UBDIAG_DETAIL_LOG"
UBDIAG_DETAIL_ROWS="$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' "$UBDIAG_DETAIL_LOG" || true)"
if [ "$UBDIAG_DETAIL_ROWS" -eq 0 ]; then
    echo "FATAL: ubdiag show --detail 没有任何数据行" >&2
    exit 1
fi
UBDIAG_ACTIVE_CORE="$(
    awk '/^[[:space:]]*[0-9]+[[:space:]]+/ { print $2; exit }' "$UBDIAG_DETAIL_LOG"
)"
if ! [[ "$UBDIAG_ACTIVE_CORE" =~ ^[0-9]+$ ]]; then
    echo "FATAL: 无法从 detail 输出解析有效 CPU core: $UBDIAG_ACTIVE_CORE" >&2
    exit 1
fi
echo "  OK: 选择有数据的 core $UBDIAG_ACTIVE_CORE 验证 raw table CSV"

echo ""
echo "[7/8] ubdiag show --sort total:desc..."
UBDIAG_SORT_LOG="$MOONCAKE_DIR/build_vendored/ubdiag_show_sort.log"
run_vendored_ubdiag show --sort total:desc >"$UBDIAG_SORT_LOG" 2>&1
head -20 "$UBDIAG_SORT_LOG"
UBDIAG_SORT_ROWS="$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' "$UBDIAG_SORT_LOG" || true)"
if [ "$UBDIAG_SORT_ROWS" -eq 0 ]; then
    echo "FATAL: ubdiag show --sort 没有任何数据行" >&2
    exit 1
fi

echo ""
echo "[7/8] 导出 UbDiag CSV..."
export_ubdiag_csv "$VERIFY_RESULTS_DIR/layer1_vendored/csv"

echo ""
echo "[7/8] ubdiag stop..."
run_vendored_ubdiag stop

# ===== 5. 汇总 =====
echo ""
echo "============================================================"
echo "[8/8] 验证完成"
echo "============================================================"
echo ""
echo "Layer 0 DISABLE 模式:"
MOCK_CMAKE_COUNT="$(grep -c 'UbDiag' build_mock/cmake_mock.log 2>/dev/null || true)"
echo "  cmake 配置: $MOCK_CMAKE_COUNT 条 ubdiag 日志"
echo "  mooncake 编译: $([ -n "$MOCK_BIN" ] && [ -f "build_mock/$MOCK_BIN" ] && echo "成功" || echo "失败/跳过")"
MOCK_LINK_COUNT="$(ldd "build_mock/$MOCK_BIN" 2>/dev/null | grep -c libubdiag || true)"
echo "  libubdiag 链接: $MOCK_LINK_COUNT (应该为 0)"
echo "  SHM 创建: $(ls /dev/shm/ubdiag_shm_* 2>/dev/null | wc -l) (应该为 0)"
echo ""
echo "Layer 1 vendored 模式:"
VENDORED_CMAKE_COUNT="$(grep -c 'UbDiag' build_vendored/cmake_vendored.log 2>/dev/null || true)"
echo "  cmake 配置: $VENDORED_CMAKE_COUNT 条 ubdiag 日志"
echo "  mooncake 编译: $([ -n "$VENDORED_BIN" ] && echo "成功" || echo "失败/跳过")"
echo "  libubdiag 编译: $(ls build_vendored/_deps/ubdiag-build/src/sdk/libubdiag.* 2>/dev/null | wc -l) 个文件"
echo "  ubdiag CLI 编译: $([ -f build_vendored/_deps/ubdiag-build/src/cli/ubdiag ] && echo "成功" || echo "未找到")"
VENDORED_LINK_COUNT="$(ldd "build_vendored/$VENDORED_BIN" 2>/dev/null | grep -c libubdiag || true)"
echo "  libubdiag 链接: $VENDORED_LINK_COUNT (应该 >0)"
echo "  ubdiag 汇总数据行: $UBDIAG_DATA_ROWS"
echo "  ubdiag 按核数据行: $UBDIAG_DETAIL_ROWS"
CSV_COUNT="$(find "$VERIFY_RESULTS_DIR/layer1_vendored/csv" -type f -name '*.csv' | wc -l)"
echo "  CSV 文件数: $CSV_COUNT"
echo ""
echo "版本校验:"
echo "  期望 tag: $UBDIAG_EXPECTED_TAG"
echo "  实际 tag: $(cd build_vendored/_deps/ubdiag-src 2>/dev/null && git describe --tags --exact-match 2>/dev/null || echo "unknown")"
echo "  期望 commit: $UBDIAG_EXPECTED_COMMIT"
echo "  实际 commit: $(cd build_vendored/_deps/ubdiag-src 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo "unknown")"
echo ""
echo "日志:"
echo "  DISABLE cmake:  $MOONCAKE_DIR/build_mock/cmake_mock.log"
echo "  vendored cmake: $MOONCAKE_DIR/build_vendored/cmake_vendored.log"
echo "  benchmark/CSV:  $VERIFY_RESULTS_DIR"
