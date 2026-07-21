#!/usr/bin/env bash
# Prepare and validate the complete openEuler container environment used by
# Mooncake Store + UB/URMA + vendored UbDiag benchmark/RPM verification.
set -Eeuo pipefail

REPO_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_NAME="${DEVICE_NAME:-bonding_dev_0}"
ENV_FILE="/etc/profile.d/mooncake-ubdiag-v12.sh"

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fatal "请以 root 用户执行容器初始化"
[ -f /.dockerenv ] || fatal "当前终端不是 Docker 容器"
[ -d "$REPO_DIR/.git" ] || fatal "Mooncake 仓库不存在: $REPO_DIR"

# shellcheck disable=SC1091
source /etc/os-release
[ "${ID,,}" = "openeuler" ] || fatal "仅支持 openEuler，当前系统: ${ID:-unknown}"

echo "============================================================"
echo "  Mooncake UbDiag v1.2 容器依赖初始化"
echo "  repo: $REPO_DIR"
echo "  device: $DEVICE_NAME"
echo "============================================================"

# Packages not covered by dependencies.sh but required by container operation,
# UB runtime validation, the benchmark verifier, or RPM packaging.
dnf makecache
dnf install -y \
    ca-certificates curl wget git \
    gcc gcc-c++ make cmake ninja-build \
    pkgconf-pkg-config \
    python3 python3-devel python3-pip \
    gflags-devel libzstd-devel zlib-devel \
    rpm rpm-build rpm-devel \
    file findutils which procps-ng iproute lsof strace \
    umdk-urma-lib umdk-urma-devel umdk-urma-tools

if [ ! -r /usr/include/asio.hpp ] && [ ! -r /usr/local/include/asio.hpp ]; then
    dnf install -y asio-devel
fi

# Use Mooncake's canonical dependency installer for the remaining C/C++
# libraries, submodules, yalantinglibs, and the required Go toolchain.
cd "$REPO_DIR"
export GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}"
export GOTOOLCHAIN=auto
bash dependencies.sh -y
export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
hash -r

# STORE_USE_ETCD and USE_ETCD build this Go module. Download its declared
# toolchain and modules during bootstrap rather than in the Mooncake build.
(cd mooncake-common/etcd && go mod download)

cat >"$ENV_FILE" <<'EOF'
export PATH="/usr/local/go/bin:/usr/local/bin:${PATH}"
export URMA_LIBRARY="/usr/lib64/liburma.so"
export LD_LIBRARY_PATH="/usr/lib64:/usr/local/lib64:/usr/local/lib:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="/usr/lib64:/usr/local/lib64:/usr/local/lib:${LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/share/pkgconfig:/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="/usr/local:/usr:${CMAKE_PREFIX_PATH:-}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export no_proxy="${no_proxy:-127.0.0.1,localhost,local,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12}"
EOF

# shellcheck disable=SC1090
source "$ENV_FILE"
ldconfig

echo ""
echo "[1/5] 检查构建和打包工具..."
required_commands=(
    bash git cmake gcc g++ make go python3 python3-config pkg-config
    rpmbuild file ldd readelf timeout sha256sum curl
)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || fatal "缺少命令: $command_name"
done
cmake --version | head -1
gcc --version | head -1
go version
python3 --version
rpmbuild --version

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
echo "  environment: $ENV_FILE"
echo "  URMA runtime: $URMA_REAL"
echo "  URMA providers: ${#providers[@]}"
echo "  UB device: $DEVICE_NAME"
echo "============================================================"
