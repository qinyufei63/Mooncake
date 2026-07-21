#!/usr/bin/env bash
# Run on the networked host. Resolve the target container's RPM dependencies
# and stage every non-RPM input needed by the fully offline container.
set -Eeuo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTAINER_NAME="${CONTAINER_NAME:-mooncake-ubdiag-v12-node2}"
BUNDLE_DIR="${BUNDLE_DIR:-$(dirname "$REPO_DIR")/mooncake-ubdiag-offline-bundle}"
PACKAGE_FILE="$REPO_DIR/scripts/mooncake_ubdiag_container_packages.txt"
GO_VERSION="${GO_VERSION:-1.25.10}"
UBDIAG_EXPECTED_TAG="v0.5.1"
UBDIAG_EXPECTED_COMMIT="705c6c37da45df2be4bc64c134dca0b7f30b2113"
UMDK_EXPECTED_TAG="v25.12.0.B081"

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

first_git_source() {
    local candidate
    for candidate in "$@"; do
        if [ -d "$candidate/.git" ] && [ -f "$candidate/CMakeLists.txt" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

assert_clean_source() {
    local name="$1"
    local source_dir="$2"
    local dirty
    dirty="$(git -C "$source_dir" status --porcelain --untracked-files=all)"
    if [ -n "$dirty" ]; then
        echo "$dirty" >&2
        fatal "$name 源码目录存在改动，拒绝把非基线内容写入离线仓: $source_dir"
    fi
}

download_go() {
    local output="$1"
    shift
    local url
    for url in "$@"; do
        echo "Downloading Go from $url"
        if curl -fL --retry 3 --connect-timeout 20 "$url" -o "$output"; then
            return 0
        fi
    done
    return 1
}

[ "$(id -u)" -eq 0 ] || fatal "请在宿主机以 root 执行"
[ ! -f /.dockerenv ] || fatal "离线依赖仓必须在可联网宿主机制作"
[ -d "$REPO_DIR/.git" ] || fatal "Mooncake 仓库不存在: $REPO_DIR"
[ -r "$PACKAGE_FILE" ] || fatal "RPM manifest 不存在: $PACKAGE_FILE"
docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || fatal "容器不存在: $CONTAINER_NAME"
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" = "true" ] || \
    fatal "容器未运行，无法读取目标系统信息: $CONTAINER_NAME"

BUNDLE_REAL="$(readlink -m "$BUNDLE_DIR")"
[ "$BUNDLE_REAL" != "/" ] || fatal "BUNDLE_DIR 不能是根目录"
[ "$BUNDLE_REAL" != "$(readlink -m "$REPO_DIR")" ] || fatal "BUNDLE_DIR 不能覆盖 Mooncake 仓库"
BUNDLE_DIR="$BUNDLE_REAL"

mkdir -p "$BUNDLE_DIR"/{repos,rpms,logs,go-cache,go-build}
rm -rf "$BUNDLE_DIR/repos"/* "$BUNDLE_DIR/rpms"/* \
       "$BUNDLE_DIR/go-cache"/* "$BUNDLE_DIR/go-build"/* \
       "$BUNDLE_DIR/dnf-root"
rm -f "$BUNDLE_DIR"/go*.linux-*.tar.gz \
      "$BUNDLE_DIR"/go-module-cache.tar.gz \
      "$BUNDLE_DIR"/ubdiag-source.tar.gz \
      "$BUNDLE_DIR"/umdk-source.tar.gz \
      "$BUNDLE_DIR"/manifest.env "$BUNDLE_DIR"/SHA256SUMS

docker cp "$CONTAINER_NAME:/etc/yum.repos.d/." "$BUNDLE_DIR/repos/"
CONTAINER_RELEASEVER="$(
    docker exec "$CONTAINER_NAME" sh -c '. /etc/os-release; printf %s "$VERSION_ID"'
)"
CONTAINER_OS_RELEASE_SHA256="$(
    docker exec "$CONTAINER_NAME" sha256sum /etc/os-release | awk '{print $1}'
)"
CONTAINER_ARCH="$(docker exec "$CONTAINER_NAME" uname -m)"
HOST_ARCH="$(uname -m)"
[ "$CONTAINER_ARCH" = "$HOST_ARCH" ] || \
    fatal "宿主机/容器架构不一致: host=$HOST_ARCH container=$CONTAINER_ARCH"

UBDIAG_SOURCE="${OFFLINE_UBDIAG_SOURCE_DIR:-}"
if [ -z "$UBDIAG_SOURCE" ]; then
    UBDIAG_SOURCE="$(first_git_source \
        "$REPO_DIR/build_vendored/_deps/ubdiag-src" \
        "$REPO_DIR/build_mock/_deps/ubdiag-src")" || \
        fatal "找不到已拉取的 UbDiag 源码，请先确认 build_vendored/build_mock 的 _deps"
fi
UMDK_SOURCE="${OFFLINE_UMDK_SOURCE_DIR:-}"
if [ -z "$UMDK_SOURCE" ]; then
    UMDK_SOURCE="$(first_git_source \
        "$REPO_DIR/build_vendored/_deps/urma-src" \
        "$REPO_DIR/build_mock/_deps/urma-src")" || \
        fatal "找不到已拉取的 UMDK 源码，请先确认 build_vendored/build_mock 的 _deps"
fi

assert_clean_source "UbDiag" "$UBDIAG_SOURCE"
assert_clean_source "UMDK" "$UMDK_SOURCE"
UBDIAG_COMMIT="$(git -C "$UBDIAG_SOURCE" rev-parse HEAD)"
[ "$UBDIAG_COMMIT" = "$UBDIAG_EXPECTED_COMMIT" ] || \
    fatal "UbDiag commit 不匹配: expected=$UBDIAG_EXPECTED_COMMIT actual=$UBDIAG_COMMIT"
[ "$(git -C "$UBDIAG_SOURCE" describe --tags --exact-match 2>/dev/null || true)" = "$UBDIAG_EXPECTED_TAG" ] || \
    fatal "UbDiag HEAD 未命中 tag $UBDIAG_EXPECTED_TAG"
UMDK_COMMIT="$(git -C "$UMDK_SOURCE" rev-parse HEAD)"
[ "$(git -C "$UMDK_SOURCE" rev-parse "$UMDK_EXPECTED_TAG^{commit}" 2>/dev/null || true)" = "$UMDK_COMMIT" ] || \
    fatal "UMDK HEAD 未命中 tag $UMDK_EXPECTED_TAG"

git -C "$REPO_DIR" submodule status --recursive >"$BUNDLE_DIR/submodules.txt"
if grep -Eq '^[-+U]' "$BUNDLE_DIR/submodules.txt"; then
    cat "$BUNDLE_DIR/submodules.txt" >&2
    fatal "Mooncake 子模块未完整初始化或不在记录版本"
fi

if ! dnf install --help 2>/dev/null | grep -q -- '--downloadonly'; then
    dnf install -y dnf-plugins-core
fi
mapfile -t packages < <(
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$PACKAGE_FILE"
)
[ "${#packages[@]}" -gt 0 ] || fatal "RPM manifest 为空"

echo "Downloading ${#packages[@]} package/group roots and all dependencies..."
mkdir -p "$BUNDLE_DIR/dnf-root"
dnf --installroot="$BUNDLE_DIR/dnf-root" \
    --releasever="$CONTAINER_RELEASEVER" \
    --setopt="reposdir=$BUNDLE_DIR/repos" \
    --setopt=gpgcheck=0 \
    --setopt=localpkg_gpgcheck=0 \
    install -y --downloadonly --downloaddir="$BUNDLE_DIR/rpms" \
    "${packages[@]}" \
    2>&1 | tee "$BUNDLE_DIR/logs/dnf-download.log"

mapfile -t rpm_files < <(find "$BUNDLE_DIR/rpms" -maxdepth 1 -type f -name '*.rpm' | sort)
[ "${#rpm_files[@]}" -gt 0 ] || fatal "没有下载到 RPM"
for rpm_file in "${rpm_files[@]}"; do
    rpm_arch="$(rpm -qp --qf '%{ARCH}' "$rpm_file")"
    [ "$rpm_arch" = "noarch" ] || [ "$rpm_arch" = "$CONTAINER_ARCH" ] || \
        fatal "RPM 架构与容器不一致: $rpm_file ($rpm_arch)"
done

case "$CONTAINER_ARCH" in
    aarch64) GO_ARCH=arm64 ;;
    x86_64) GO_ARCH=amd64 ;;
    *) fatal "不支持的 Go 架构: $CONTAINER_ARCH" ;;
esac
GO_TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
download_go "$BUNDLE_DIR/$GO_TARBALL" \
    "https://go.dev/dl/$GO_TARBALL" \
    "https://golang.google.cn/dl/$GO_TARBALL" \
    "https://mirrors.aliyun.com/golang/$GO_TARBALL" || \
    fatal "Go $GO_VERSION 下载失败"

rm -rf "$BUNDLE_DIR/go-toolchain"
mkdir -p "$BUNDLE_DIR/go-toolchain"
tar -C "$BUNDLE_DIR/go-toolchain" -xzf "$BUNDLE_DIR/$GO_TARBALL"
GOMODCACHE="$BUNDLE_DIR/go-cache/pkg/mod" \
GOCACHE="$BUNDLE_DIR/go-build" \
GOTOOLCHAIN=local \
GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}" \
    "$BUNDLE_DIR/go-toolchain/go/bin/go" \
    -C "$REPO_DIR/mooncake-common/etcd" mod download all
GOMODCACHE="$BUNDLE_DIR/go-cache/pkg/mod" \
GOCACHE="$BUNDLE_DIR/go-build" \
GOTOOLCHAIN=local \
GOPROXY=off \
    "$BUNDLE_DIR/go-toolchain/go/bin/go" \
    -C "$REPO_DIR/mooncake-common/etcd" mod verify
tar --owner=0 --group=0 --numeric-owner \
    -C "$BUNDLE_DIR/go-cache" -czf "$BUNDLE_DIR/go-module-cache.tar.gz" pkg

tar --owner=0 --group=0 --numeric-owner \
    -C "$UBDIAG_SOURCE" -czf "$BUNDLE_DIR/ubdiag-source.tar.gz" .
tar --owner=0 --group=0 --numeric-owner \
    -C "$UMDK_SOURCE" -czf "$BUNDLE_DIR/umdk-source.tar.gz" .

cat >"$BUNDLE_DIR/manifest.env" <<EOF
MOONCAKE_OFFLINE_BUNDLE_VERSION=2
CONTAINER_RELEASEVER=$CONTAINER_RELEASEVER
CONTAINER_OS_RELEASE_SHA256=$CONTAINER_OS_RELEASE_SHA256
CONTAINER_ARCH=$CONTAINER_ARCH
GO_VERSION=$GO_VERSION
GO_TARBALL=$GO_TARBALL
UBDIAG_TAG=$UBDIAG_EXPECTED_TAG
UBDIAG_COMMIT=$UBDIAG_COMMIT
UMDK_TAG=$UMDK_EXPECTED_TAG
UMDK_COMMIT=$UMDK_COMMIT
RPM_COUNT=${#rpm_files[@]}
EOF

(
    cd "$BUNDLE_DIR"
    sha256sum "$GO_TARBALL" go-module-cache.tar.gz \
        ubdiag-source.tar.gz umdk-source.tar.gz rpms/*.rpm >SHA256SUMS
)

rm -rf "$BUNDLE_DIR/go-toolchain" "$BUNDLE_DIR/go-cache" \
       "$BUNDLE_DIR/go-build" "$BUNDLE_DIR/dnf-root"

echo "============================================================"
echo "PASS: Mooncake UbDiag 离线依赖仓制作完成"
echo "bundle: $BUNDLE_DIR"
cat "$BUNDLE_DIR/manifest.env"
echo "============================================================"
