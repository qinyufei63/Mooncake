#!/bin/bash
# ============================================================
# Mooncake UbDiag v1.2 集成验证脚本
# 验证: DISABLE 模式 + vendored 模式 + 版本校验 + 打点验证
# 用法: bash scripts/verify_ubdiag_v12.sh
# ============================================================
set -Eeuo pipefail

WORKSPACE=/home/q00913006/project
MOONCAKE_DIR=$WORKSPACE/mooncake-v12-verify
UBDIAG_VER_TAG="v0.5.1"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib64:/usr/lib64:${LD_LIBRARY_PATH:-}

echo "============================================================"
echo "  Mooncake UbDiag v1.2 集成验证"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ===== 0. 准备 =====
echo ""
echo "[0/8] 准备工作区..."
# 先回到 workspace 根目录(避免 rm -rf 删掉自己所在的目录)
cd $WORKSPACE
rm -rf $MOONCAKE_DIR
git clone -b supercache_dev_ubdiag \
    --depth=1 --recurse-submodules --shallow-submodules \
    https://github.com/qinyufei63/Mooncake.git "$MOONCAKE_DIR"
cd $MOONCAKE_DIR

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
echo "  配置的 ubdiag 版本:"
grep "MOONCAKE_UBDIAG_GIT_TAG" mooncake-common/FindUbDiag.cmake

# ===== 1. Layer 0: DISABLE 模式 =====
echo ""
echo "============================================================"
echo "[1/8] Layer 0: DISABLE 模式 cmake 配置"
echo "============================================================"
mkdir build_mock && cd build_mock
if ! cmake .. -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
     -DSTORE_USE_ETCD=ON -DUSE_ETCD=ON 2>&1 | tee cmake_mock.log; then
    echo "FATAL: DISABLE 模式 CMake 配置失败，停止验证"
    exit 1
fi
grep -iE "UbDiag|ubdiag|fetch|disable|error|fatal" cmake_mock.log || true

echo ""
echo "[1/8] 检查 FetchContent 拉取的 ubdiag 版本..."
if [ -d "_deps/ubdiag-src" ]; then
    cd _deps/ubdiag-src
    TAG=$(git describe --tags 2>/dev/null || echo "unknown")
    COMMIT=$(git log --oneline -1 2>/dev/null || echo "unknown")
    echo "  tag: $TAG"
    echo "  commit: $COMMIT"
    grep "versionString" include/ubdiag/version.h 2>/dev/null || echo "  (version.h 无 versionString)"

    if ! grep -q "UBDIAG_DISABLE" include/ubdiag/perf_point.h; then
        echo "FATAL: $TAG 的 perf_point.h 不包含 UBDIAG_DISABLE，无法验证 v1.2 DISABLE 层"
        echo "       当前文档依赖的空函数机制不在所选 tag 中，请先修正 UbDiag 版本基线"
        exit 2
    fi
    echo "  OK: $TAG 包含 UBDIAG_DISABLE 空函数机制"
    cd ../..
fi

echo ""
echo "============================================================"
echo "[2/8] Layer 0: DISABLE 模式编译"
echo "============================================================"
if ! cmake --build . --parallel "$BUILD_JOBS" --target mooncake_master \
     2>&1 | tee build_mock.log; then
    echo "FATAL: DISABLE 模式 mooncake_master 编译失败"
    exit 1
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
ubdiag stop 2>/dev/null || true
rm -f /dev/shm/ubdiag_shm_* 2>/dev/null || true

if [ -n "$MOCK_BIN" ]; then
    echo "[3/8] 运行 mooncake_master --help (DISABLE 模式,不应有 ubdiag 输出)..."
    OUTPUT=$($MOCK_BIN --help 2>&1 || true)
    if echo "$OUTPUT" | grep -qi "ubdiag\|PerfPoint\|shared memory"; then
        echo "  WARN: mooncake 输出中出现了 ubdiag 相关内容"
        echo "$OUTPUT" | grep -i "ubdiag\|perf\|shm" | head -5
    else
        echo "  OK: mooncake 运行无 ubdiag 输出 (PerfPoint 被编译器优化掉了)"
    fi

    # 确认 SHM 未被创建 (DISABLE 模式不应该创建 SHM)
    if ls /dev/shm/ubdiag_shm_* 2>/dev/null; then
        echo "  WARN: DISABLE 模式下 SHM 被创建了 (不应该)"
    else
        echo "  OK: DISABLE 模式下无 SHM 创建 (符合预期)"
    fi
else
    echo "  SKIP: mooncake_store 未编译,跳过 mock 运行验证"
fi

# 确认 UBDIAG_DISABLE 生效:检查 mooncake_master 二进制是否引用 libubdiag
echo ""
echo "[3/8] 检查二进制是否链接 libubdiag (DISABLE 模式不应该链接)..."
if [ -n "$MOCK_BIN" ]; then
    if ldd $MOCK_BIN 2>/dev/null | grep -q "libubdiag"; then
        echo "  WARN: DISABLE 模式下链接了 libubdiag (不应该)"
        ldd $MOCK_BIN | grep libubdiag
    else
        echo "  OK: DISABLE 模式下未链接 libubdiag (constexpr 空函数,零依赖)"
    fi
fi

cd ..

# ===== 2. Layer 1: vendored 模式 =====
echo ""
echo "============================================================"
echo "[4/8] Layer 1: vendored 模式 cmake 配置"
echo "============================================================"
mkdir build_vendored && cd build_vendored
if ! cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON \
     -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
     -DSTORE_USE_ETCD=ON -DUSE_ETCD=ON 2>&1 | tee cmake_vendored.log; then
    echo "FATAL: vendored 模式 CMake 配置失败，停止验证"
    exit 1
fi
grep -iE "UbDiag|ubdiag|fetch|vendored|error|fatal" cmake_vendored.log || true

echo ""
echo "[4/8] 检查 FetchContent 拉取的 ubdiag 版本..."
if [ -d "_deps/ubdiag-src" ]; then
    cd _deps/ubdiag-src
    TAG=$(git describe --tags 2>/dev/null || echo "unknown")
    COMMIT=$(git log --oneline -1 2>/dev/null || echo "unknown")
    echo "  tag: $TAG"
    echo "  commit: $COMMIT"
    echo "  version.h:"
    grep "versionString\|versionMajor\|versionMinor\|versionPatch" include/ubdiag/version.h 2>/dev/null || echo "  (无 versionString)"
    cd ../..

    if echo "$TAG" | grep -q "$UBDIAG_VER_TAG"; then
        echo "  OK: 版本匹配 $UBDIAG_VER_TAG"
    else
        echo "  WARN: 期望 $UBDIAG_VER_TAG,实际 $TAG"
    fi
fi

echo ""
echo "============================================================"
echo "[5/8] Layer 1: vendored 模式编译"
echo "============================================================"
if ! cmake --build . --parallel "$BUILD_JOBS" --target mooncake_master ubdiag \
     2>&1 | tee build_vendored.log; then
    echo "FATAL: vendored 模式 mooncake_master/ubdiag 编译失败"
    exit 1
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
if ls _deps/ubdiag-build/src/sdk/libubdiag.* 2>/dev/null; then
    echo "  OK: libubdiag 编译成功"
else
    echo "  WARN: libubdiag 未找到"
fi
if [ -f "_deps/ubdiag-build/src/cli/ubdiag" ]; then
    echo "  OK: ubdiag CLI 编译成功"
    _deps/ubdiag-build/src/cli/ubdiag --help 2>&1 | head -3 || true
else
    echo "  WARN: ubdiag CLI 未找到"
fi

echo ""
echo "[5/8] 检查 mooncake_master 是否链接了 libubdiag..."
if [ -n "$VENDORED_BIN" ]; then
    if ldd $VENDORED_BIN 2>/dev/null | grep -q "libubdiag"; then
        echo "  OK: vendored 模式下链接了 libubdiag"
        ldd $VENDORED_BIN | grep libubdiag
    else
        echo "  WARN: vendored 模式下未链接 libubdiag"
    fi
fi

echo ""
echo "[5/8] 安装 ubdiag 到系统..."
if [ -f "_deps/ubdiag-build/src/cli/ubdiag" ]; then
    sudo cp _deps/ubdiag-build/src/sdk/libubdiag.so /usr/lib64/ 2>/dev/null || true
    sudo cp _deps/ubdiag-build/src/cli/ubdiag /usr/local/bin/ 2>/dev/null || true
    sudo ldconfig 2>/dev/null || true
    echo "  OK: 安装完成"
    ubdiag status 2>&1 || true
fi

cd ..

# ===== 3. 版本校验汇总 =====
echo ""
echo "============================================================"
echo "[6/8] 版本校验汇总"
echo "============================================================"
echo "  期望 ubdiag tag: $UBDIAG_VER_TAG"
echo "  DISABLE 模式拉取:"
(cd build_mock/_deps/ubdiag-src 2>/dev/null && git describe --tags 2>/dev/null) || echo "    (未拉取)"
echo "  vendored 模式拉取:"
(cd build_vendored/_deps/ubdiag-src 2>/dev/null && git describe --tags 2>/dev/null) || echo "    (未拉取)"

# ===== 4. 打点验证 =====
echo ""
echo "============================================================"
echo "[7/8] 打点验证 (vendored 模式)"
echo "============================================================"

if [ -z "$VENDORED_BIN" ] || [ ! -f "build_vendored/$VENDORED_BIN" ]; then
    echo "  SKIP: mooncake_store 未编译,跳过打点验证"
    echo "        (可能缺少 etcd/liburma 依赖)"
    echo ""
    echo "============================================================"
    echo "[8/8] 验证完成 (部分跳过)"
    echo "============================================================"
    echo "日志:"
    echo "  DISABLE cmake:  $MOONCAKE_DIR/build_mock/cmake_mock.log"
    echo "  vendored cmake: $MOONCAKE_DIR/build_vendored/cmake_vendored.log"
    exit 0
fi

FULL_BIN="$MOONCAKE_DIR/build_vendored/$VENDORED_BIN"

if ! command -v ubdiag >/dev/null 2>&1; then
    echo "  SKIP: ubdiag CLI 未安装"
    exit 0
fi

echo "[7/8] 启动 ubdiag..."
ubdiag stop 2>/dev/null || true
rm -f /dev/shm/ubdiag_shm_* 2>/dev/null || true
ubdiag start
sleep 1
ubdiag status

echo ""
echo "[7/8] 运行 mooncake_master (5秒)..."
timeout 5 $FULL_BIN --metadata_server=127.0.0.1:2379 --mode=dummy 2>&1 | tail -20 || true

echo ""
echo "[7/8] ubdiag show (汇总)..."
ubdiag show 2>&1 | head -40

echo ""
echo "[7/8] ubdiag show --detail (按核)..."
ubdiag show --detail 2>&1 | head -30

echo ""
echo "[7/8] ubdiag show --sort total:desc..."
ubdiag show --sort total:desc 2>&1 | head -20

echo ""
echo "[7/8] ubdiag stop..."
ubdiag stop

# ===== 5. 汇总 =====
echo ""
echo "============================================================"
echo "[8/8] 验证完成"
echo "============================================================"
echo ""
echo "Layer 0 DISABLE 模式:"
echo "  cmake 配置: $(grep -c 'UbDiag' build_mock/cmake_mock.log 2>/dev/null || echo 0) 条 ubdiag 日志"
echo "  mooncake 编译: $([ -n "$MOCK_BIN" ] && [ -f "build_mock/$MOCK_BIN" ] && echo "成功" || echo "失败/跳过")"
echo "  libubdiag 链接: $(ldd build_mock/$MOCK_BIN 2>/dev/null | grep -c libubdiag || echo 0) (应该为 0)"
echo "  SHM 创建: $(ls /dev/shm/ubdiag_shm_* 2>/dev/null | wc -l) (应该为 0)"
echo ""
echo "Layer 1 vendored 模式:"
echo "  cmake 配置: $(grep -c 'UbDiag' build_vendored/cmake_vendored.log 2>/dev/null || echo 0) 条 ubdiag 日志"
echo "  mooncake 编译: $([ -n "$VENDORED_BIN" ] && echo "成功" || echo "失败/跳过")"
echo "  libubdiag 编译: $(ls build_vendored/_deps/ubdiag-build/src/sdk/libubdiag.* 2>/dev/null | wc -l) 个文件"
echo "  ubdiag CLI 编译: $([ -f build_vendored/_deps/ubdiag-build/src/cli/ubdiag ] && echo "成功" || echo "未找到")"
echo "  libubdiag 链接: $(ldd build_vendored/$VENDORED_BIN 2>/dev/null | grep -c libubdiag || echo 0) (应该 >0)"
echo ""
echo "版本校验:"
echo "  期望: $UBDIAG_VER_TAG"
echo "  实际: $(cd build_vendored/_deps/ubdiag-src 2>/dev/null && git describe --tags 2>/dev/null || echo "unknown")"
echo ""
echo "日志:"
echo "  DISABLE cmake:  $MOONCAKE_DIR/build_mock/cmake_mock.log"
echo "  vendored cmake: $MOONCAKE_DIR/build_vendored/cmake_vendored.log"
