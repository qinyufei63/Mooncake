#!/usr/bin/env bash
# Prepare and validate the complete openEuler container environment used by
# Mooncake Store + UB/URMA + vendored UbDiag benchmark/RPM verification.
set -Eeuo pipefail

REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_NAME="${DEVICE_NAME:-bonding_dev_0}"
OFFLINE_BUNDLE_DIR="${OFFLINE_BUNDLE_DIR:-$(dirname "$REPO_DIR")/mooncake-ubdiag-offline-bundle}"
OFFLINE_SOURCE_DIR="${OFFLINE_SOURCE_DIR:-/opt/mooncake-offline-sources}"
OFFLINE_GO_CACHE_DIR="${OFFLINE_GO_CACHE_DIR:-/opt/mooncake-go-cache}"
ENV_FILE="/etc/profile.d/mooncake-ubdiag-v12.sh"

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fatal "请以 root 用户执行容器初始化"
[ -f /.dockerenv ] || fatal "当前终端不是 Docker 容器"
[ -d "$REPO_DIR/.git" ] || fatal "Mooncake 仓库不存在: $REPO_DIR"
[ -r "$OFFLINE_BUNDLE_DIR/manifest.env" ] || \
    fatal "离线依赖仓不存在: $OFFLINE_BUNDLE_DIR（请先在宿主机运行 prepare_mooncake_ubdiag_offline_bundle.sh）"
[ -r "$OFFLINE_BUNDLE_DIR/SHA256SUMS" ] || fatal "离线依赖仓缺少 SHA256SUMS"

# shellcheck disable=SC1091
source /etc/os-release
[ "${ID,,}" = "openeuler" ] || fatal "仅支持 openEuler，当前系统: ${ID:-unknown}"
# shellcheck disable=SC1090
source "$OFFLINE_BUNDLE_DIR/manifest.env"
[ "${MOONCAKE_OFFLINE_BUNDLE_VERSION:-}" = "2" ] || \
    fatal "不支持的离线依赖仓版本: ${MOONCAKE_OFFLINE_BUNDLE_VERSION:-missing}"
[ "${CONTAINER_RELEASEVER:-}" = "$VERSION_ID" ] || \
    fatal "离线仓与容器系统版本不一致: bundle=${CONTAINER_RELEASEVER:-missing} container=$VERSION_ID"
[ "${CONTAINER_OS_RELEASE_SHA256:-}" = "$(sha256sum /etc/os-release | awk '{print $1}')" ] || \
    fatal "离线仓不是按当前容器的 openEuler 版本制作"
[ "${CONTAINER_ARCH:-}" = "$(uname -m)" ] || \
    fatal "离线仓与容器架构不一致: bundle=${CONTAINER_ARCH:-missing} container=$(uname -m)"

echo "============================================================"
echo "  Mooncake UbDiag v1.2 容器依赖初始化"
echo "  repo: $REPO_DIR"
echo "  offline bundle: $OFFLINE_BUNDLE_DIR"
echo "  device: $DEVICE_NAME"
echo "============================================================"

# Verify the complete bundle before installing any payload. The only dnf call
# below consumes local RPM paths with every repository disabled.
(
    cd "$OFFLINE_BUNDLE_DIR"
    sha256sum -c SHA256SUMS
)
mapfile -t offline_rpms < <(
    find "$OFFLINE_BUNDLE_DIR/rpms" -maxdepth 1 -type f -name '*.rpm' | sort
)
[ "${#offline_rpms[@]}" -eq "${RPM_COUNT:-0}" ] || \
    fatal "离线 RPM 数量不匹配: manifest=${RPM_COUNT:-missing} actual=${#offline_rpms[@]}"
dnf --disablerepo='*' install -y "${offline_rpms[@]}"

case "$(uname -m)" in
    aarch64) expected_go_arch=arm64 ;;
    x86_64) expected_go_arch=amd64 ;;
    *) fatal "不支持的 Go 架构: $(uname -m)" ;;
esac
[ "$GO_TARBALL" = "go${GO_VERSION}.linux-${expected_go_arch}.tar.gz" ] || \
    fatal "Go 离线包名称异常: $GO_TARBALL"
[ -r "$OFFLINE_BUNDLE_DIR/$GO_TARBALL" ] || fatal "缺少 Go 离线包: $GO_TARBALL"
[ -r "$OFFLINE_BUNDLE_DIR/go-module-cache.tar.gz" ] || fatal "缺少 Go module cache"
[ -r "$OFFLINE_BUNDLE_DIR/ubdiag-source.tar.gz" ] || fatal "缺少 UbDiag 源码包"
[ -r "$OFFLINE_BUNDLE_DIR/umdk-source.tar.gz" ] || fatal "缺少 UMDK 源码包"

[ "/usr/local/go" != "/usr/local" ] || fatal "Go 安装路径保护失败"
rm -rf /usr/local/go
tar -C /usr/local -xzf "$OFFLINE_BUNDLE_DIR/$GO_TARBALL"

[ "$OFFLINE_SOURCE_DIR" != "/" ] || fatal "OFFLINE_SOURCE_DIR 不能是根目录"
[ "$OFFLINE_GO_CACHE_DIR" != "/" ] || fatal "OFFLINE_GO_CACHE_DIR 不能是根目录"
rm -rf "$OFFLINE_SOURCE_DIR" "$OFFLINE_GO_CACHE_DIR"
mkdir -p "$OFFLINE_SOURCE_DIR/ubdiag" "$OFFLINE_SOURCE_DIR/urma" \
         "$OFFLINE_GO_CACHE_DIR/build"
tar --no-same-owner -C "$OFFLINE_SOURCE_DIR/ubdiag" \
    -xzf "$OFFLINE_BUNDLE_DIR/ubdiag-source.tar.gz"
tar --no-same-owner -C "$OFFLINE_SOURCE_DIR/urma" \
    -xzf "$OFFLINE_BUNDLE_DIR/umdk-source.tar.gz"
tar --no-same-owner -C "$OFFLINE_GO_CACHE_DIR" \
    -xzf "$OFFLINE_BUNDLE_DIR/go-module-cache.tar.gz"

[ "$(git -C "$OFFLINE_SOURCE_DIR/ubdiag" rev-parse HEAD)" = "$UBDIAG_COMMIT" ] || \
    fatal "解包后的 UbDiag commit 与 manifest 不一致"
[ "$(git -C "$OFFLINE_SOURCE_DIR/urma" rev-parse HEAD)" = "$UMDK_COMMIT" ] || \
    fatal "解包后的 UMDK commit 与 manifest 不一致"

SUBMODULE_STATUS="$(git -C "$REPO_DIR" submodule status --recursive)"
if [ -z "$SUBMODULE_STATUS" ] || grep -Eq '^[-+U]' <<<"$SUBMODULE_STATUS"; then
    echo "$SUBMODULE_STATUS" >&2
    fatal "Mooncake 子模块未完整初始化或不在记录版本；离线容器不会执行 git submodule update"
fi

cat >"$ENV_FILE" <<EOF
export PATH="/usr/local/go/bin:/usr/local/bin:\${PATH}"
export URMA_LIBRARY="/usr/lib64/liburma.so"
export LD_LIBRARY_PATH="/usr/lib64:/usr/local/lib64:/usr/local/lib:\${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="/usr/lib64:/usr/local/lib64:/usr/local/lib:\${LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/share/pkgconfig:/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="/usr/local:/usr:\${CMAKE_PREFIX_PATH:-}"
export MOONCAKE_OFFLINE=1
export MOONCAKE_UBDIAG_SOURCE_DIR="$OFFLINE_SOURCE_DIR/ubdiag"
export FETCHCONTENT_SOURCE_DIR_URMA="$OFFLINE_SOURCE_DIR/urma"
export FETCHCONTENT_FULLY_DISCONNECTED=ON
export GOPROXY=off
export GOSUMDB=off
export GOTOOLCHAIN=local
export GOMODCACHE="$OFFLINE_GO_CACHE_DIR/pkg/mod"
export GOCACHE="$OFFLINE_GO_CACHE_DIR/build"
EOF

# shellcheck disable=SC1090
source "$ENV_FILE"
hash -r
ldconfig

cd "$REPO_DIR"
rm -rf /tmp/mooncake-ylt-build
cmake -S extern/yalantinglibs -B /tmp/mooncake-ylt-build \
    -DBUILD_EXAMPLES=OFF -DBUILD_BENCHMARK=OFF -DBUILD_UNIT_TESTS=OFF
cmake --build /tmp/mooncake-ylt-build --parallel "$(nproc)"
cmake --install /tmp/mooncake-ylt-build
ldconfig

echo ""
echo "[1/5] 检查构建和打包工具..."
required_commands=(
    bash git cmake gcc g++ make go python3 python3-config pkg-config
    dnf rpm rpmbuild file ldd readelf timeout sha256sum curl
)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || fatal "缺少命令: $command_name"
done
cmake --version | head -1
gcc --version | head -1
go version
python3 --version
rpmbuild --version
[ "$(go env GOVERSION)" = "go$GO_VERSION" ] || \
    fatal "Go 版本不匹配: expected=go$GO_VERSION actual=$(go env GOVERSION)"
[ "$(go env GOPROXY)" = "off" ] || fatal "Go 仍可能联网: GOPROXY=$(go env GOPROXY)"
[ "$(go env GOTOOLCHAIN)" = "local" ] || \
    fatal "Go 仍可能下载工具链: GOTOOLCHAIN=$(go env GOTOOLCHAIN)"
(cd "$REPO_DIR/mooncake-common/etcd" && go mod verify && go list -mod=readonly all >/dev/null)
echo "  OK: Go 工具链和 etcd module cache 已通过完全离线检查"

echo ""
echo "[2/5] 检查 Mooncake 必需头文件和 CMake package..."
required_headers=(
    /usr/include/gflags/gflags.h
    /usr/include/glog/logging.h
    /usr/include/yaml-cpp/yaml.h
    /usr/include/infiniband/verbs.h
    /usr/include/numa.h
    /usr/include/curl/curl.h
    /usr/include/liburing.h
    /usr/include/xxhash.h
    /usr/include/zstd.h
    /usr/include/zlib.h
    /usr/include/ub/umdk/urma/urma_api.h
)
for header in "${required_headers[@]}"; do
    [ -r "$header" ] || fatal "缺少头文件: $header"
done
[ -r /usr/include/asio.hpp ] || [ -r /usr/local/include/asio.hpp ] || \
    fatal "缺少 ASIO 头文件 asio.hpp"
[ -r /usr/include/jsoncpp/json/json.h ] || [ -r /usr/include/json/json.h ] || \
    fatal "缺少 JsonCpp 头文件 json.h"
[ -r "$MOONCAKE_UBDIAG_SOURCE_DIR/include/ubdiag/perf_point.h" ] || \
    fatal "离线 UbDiag 源码不完整: $MOONCAKE_UBDIAG_SOURCE_DIR"
[ -r "$FETCHCONTENT_SOURCE_DIR_URMA/CMakeLists.txt" ] || \
    fatal "离线 UMDK 源码不完整: $FETCHCONTENT_SOURCE_DIR_URMA"
[ "$(git -C "$MOONCAKE_UBDIAG_SOURCE_DIR" rev-parse HEAD)" = "$UBDIAG_COMMIT" ] || \
    fatal "离线 UbDiag 源码版本漂移"
[ "$(git -C "$FETCHCONTENT_SOURCE_DIR_URMA" rev-parse HEAD)" = "$UMDK_COMMIT" ] || \
    fatal "离线 UMDK 源码版本漂移"
cmake_search_roots=()
for search_root in /usr/local/lib /usr/local/lib64 /usr/lib /usr/lib64; do
    [ -d "$search_root" ] && cmake_search_roots+=("$search_root")
done
find "${cmake_search_roots[@]}" -type f \
    \( -name 'yalantinglibsConfig.cmake' -o -name 'yalantinglibs-config.cmake' \) \
    -print -quit | grep -q . || fatal "未找到 yalantinglibs CMake package"

rm -rf /tmp/mooncake-cmake-dependency-probe
mkdir -p /tmp/mooncake-cmake-dependency-probe
cat >/tmp/mooncake-cmake-dependency-probe/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(mooncake_dependency_probe LANGUAGES C CXX)
list(APPEND CMAKE_MODULE_PATH "$ENV{MOONCAKE_PROBE_REPO}/mooncake-common")
include("$ENV{MOONCAKE_PROBE_REPO}/mooncake-common/FindJsonCpp.cmake")
include("$ENV{MOONCAKE_PROBE_REPO}/mooncake-common/FindGLOG.cmake")
find_package(yaml-cpp REQUIRED)
find_package(gflags REQUIRED)
find_package(CURL REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter Development)
find_package(yalantinglibs CONFIG REQUIRED)
foreach(required_lib zstd xxhash ibverbs numa uring)
    string(TOUPPER "${required_lib}" required_lib_upper)
    find_library(${required_lib_upper}_LIBRARY NAMES ${required_lib})
    if(NOT ${required_lib_upper}_LIBRARY)
        message(FATAL_ERROR "Missing library: ${required_lib}")
    endif()
endforeach()
EOF
MOONCAKE_PROBE_REPO="$REPO_DIR" cmake \
    -S /tmp/mooncake-cmake-dependency-probe \
    -B /tmp/mooncake-cmake-dependency-probe/build \
    -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH"

cat >/tmp/mooncake-cxx20-probe.cpp <<'EOF'
#include <asio.hpp>
#include <Python.h>
#include <gflags/gflags.h>
#include <glog/logging.h>
#include <yaml-cpp/yaml.h>
#include <infiniband/verbs.h>
#include <ub/umdk/urma/urma_api.h>
int main() { return 0; }
EOF
g++ -std=c++20 $(python3-config --includes) \
    -c /tmp/mooncake-cxx20-probe.cpp -o /tmp/mooncake-cxx20-probe.o

echo ""
echo "[3/5] 检查动态库..."
required_libraries=(
    liburma.so libibverbs.so libnuma.so libyaml-cpp.so libgflags.so
    libglog.so libjsoncpp.so libcurl.so liburing.so libxxhash.so
    libzstd.so
)
ldconfig_output="$(ldconfig -p)"
for library in "${required_libraries[@]}"; do
    grep -q "$library" <<<"$ldconfig_output" || fatal "ldconfig 未找到: $library"
done

echo ""
echo "[4/5] 检查 URMA runtime、provider 和实际初始化..."
[ -e "$URMA_LIBRARY" ] || fatal "URMA library 不存在: $URMA_LIBRARY"
URMA_REAL="$(readlink -f "$URMA_LIBRARY")"
URMA_DIR="$(dirname "$URMA_REAL")"
PROVIDER_DIR="$URMA_DIR/urma"
[ -d "$PROVIDER_DIR" ] || fatal "URMA provider 目录不存在: $PROVIDER_DIR"
mapfile -t providers < <(
    find "$PROVIDER_DIR" -maxdepth 1 \
        \( -type f -o -type l \) -name 'liburma*.so*' -print | sort
)
[ "${#providers[@]}" -gt 0 ] || fatal "URMA provider 目录为空: $PROVIDER_DIR"
for provider in "${providers[@]}"; do
    [ -r "$provider" ] && [ -x "$provider" ] || fatal "provider 权限异常: $provider"
    provider_deps="$(ldd -r "$provider" 2>&1 || true)"
    if grep -qE 'not found|undefined symbol' <<<"$provider_deps"; then
        echo "$provider_deps" >&2
        fatal "provider 动态依赖异常: $provider"
    fi
done

cat >/tmp/mooncake_urma_init_probe.c <<'EOF'
#include <stdio.h>
#include <urma_api.h>

int main(void) {
    urma_init_attr_t attr = {0};
    urma_status_t ret = urma_init(&attr);
    printf("urma_init ret=%d\n", ret);
    if (ret != URMA_SUCCESS && ret != URMA_EEXIST) {
        return 1;
    }
    if (ret == URMA_SUCCESS) {
        (void)urma_uninit();
    }
    return 0;
}
EOF
gcc -I/usr/include/ub/umdk/urma /tmp/mooncake_urma_init_probe.c \
    -L"$URMA_DIR" -Wl,-rpath,"$URMA_DIR" -lurma \
    -o /tmp/mooncake_urma_init_probe
URMA_LOG_LEVEL=debug /tmp/mooncake_urma_init_probe

echo ""
echo "[5/5] 检查 UB 设备和 benchmark 指定设备..."
[ -d /sys/class/ubcore ] || fatal "容器看不到 /sys/class/ubcore"
urma_admin show --brief | tee /tmp/mooncake_urma_devices.log
grep -q "$DEVICE_NAME" /tmp/mooncake_urma_devices.log || {
    echo "可见设备如下:" >&2
    cat /tmp/mooncake_urma_devices.log >&2
    fatal "未找到 benchmark 设备: $DEVICE_NAME"
}
[ "$(ulimit -l)" = "unlimited" ] || fatal "memlock 不是 unlimited: $(ulimit -l)"

echo ""
echo "============================================================"
echo "  PASS: Mooncake UbDiag 容器依赖、环境变量和 URMA 均已就绪"
echo "  network mode: fully offline"
echo "  environment: $ENV_FILE"
echo "  UbDiag source: $MOONCAKE_UBDIAG_SOURCE_DIR ($UBDIAG_COMMIT)"
echo "  UMDK source: $FETCHCONTENT_SOURCE_DIR_URMA ($UMDK_COMMIT)"
echo "  URMA runtime: $URMA_REAL"
echo "  URMA providers: ${#providers[@]}"
echo "  UB device: $DEVICE_NAME"
echo "============================================================"
