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
UBDIAG_REPOSITORY="https://github.com/LinQuickDev/ubdiag.git"
UMDK_EXPECTED_TAG="v25.12.0.B081"
UMDK_EXPECTED_COMMIT="a4768b149b6040c11a1c42971addb768a4222b74"
UMDK_REPOSITORY="https://github.com/openeuler-mirror/umdk.git"
RPM_MIRROR_BASE="${RPM_MIRROR_BASE:-https://repo.huaweicloud.com/openeuler}"

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

without_proxy() {
    env -u http_proxy -u https_proxy -u ftp_proxy -u all_proxy \
        -u HTTP_PROXY -u HTTPS_PROXY -u FTP_PROXY -u ALL_PROXY "$@"
}

clone_fixed_source() {
    local name="$1"
    local repository="$2"
    local ref="$3"
    local destination="$4"
    echo "$name 本地源码不存在，宿主机从 $repository 拉取 $ref"
    rm -rf "$destination"
    mkdir -p "$(dirname "$destination")"
    without_proxy env GIT_TERMINAL_PROMPT=0 git \
        -c http.proxy= -c https.proxy= \
        -c advice.detachedHead=false clone \
        --branch "$ref" --depth 1 \
        --recurse-submodules --shallow-submodules \
        "$repository" "$destination" || \
        fatal "$name 固定版本拉取失败: $repository $ref"
}

verify_tag_if_present() {
    local name="$1"
    local source_dir="$2"
    local tag="$3"
    local expected_commit="$4"
    if git -C "$source_dir" show-ref --verify --quiet "refs/tags/$tag"; then
        [ "$(git -C "$source_dir" rev-parse "$tag^{commit}")" = "$expected_commit" ] || \
            fatal "$name tag $tag 未指向期望提交 $expected_commit"
    else
        echo "$name 本地源码缺少 tag ref $tag；commit 已核验，将在容器源码副本中补回"
    fi
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
        if without_proxy curl --proxy "" -fL --retry 3 \
             --connect-timeout 20 --max-time 300 "$url" -o "$output"; then
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
       "$BUNDLE_DIR/dnf-root" "$BUNDLE_DIR/source-downloads"
rm -f "$BUNDLE_DIR"/go*.linux-*.tar.gz \
      "$BUNDLE_DIR"/go-module-cache.tar.gz \
      "$BUNDLE_DIR"/ubdiag-source.tar.gz \
      "$BUNDLE_DIR"/umdk-source.tar.gz \
      "$BUNDLE_DIR"/manifest.env "$BUNDLE_DIR"/SHA256SUMS

docker cp "$CONTAINER_NAME:/etc/yum.repos.d/." "$BUNDLE_DIR/repos/"
RPM_MIRROR_BASE="${RPM_MIRROR_BASE%/}"
mapfile -t repo_files < <(find "$BUNDLE_DIR/repos" -maxdepth 1 -type f -name '*.repo' | sort)
[ "${#repo_files[@]}" -gt 0 ] || fatal "目标容器没有可用的 DNF repo 文件"
for repo_file in "${repo_files[@]}"; do
    sed -i -E \
        -e '/^[[:space:]]*(metalink|mirrorlist)[[:space:]]*=/d' \
        -e "s#https?://repo\\.openeuler\\.org#${RPM_MIRROR_BASE}#g" \
        "$repo_file"
done
grep -RqsE '^[[:space:]]*baseurl[[:space:]]*=' "$BUNDLE_DIR/repos" || \
    fatal "镜像转换后没有可用的 baseurl"
if grep -RqsE '^[[:space:]]*(metalink|mirrorlist)[[:space:]]*=' "$BUNDLE_DIR/repos"; then
    fatal "repo 文件仍包含 metalink/mirrorlist，拒绝进入长时间重试"
fi
echo "RPM mirror: $RPM_MIRROR_BASE"
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
    if ! UBDIAG_SOURCE="$(first_git_source \
        "$REPO_DIR/build_vendored/_deps/ubdiag-src" \
        "$REPO_DIR/build_mock/_deps/ubdiag-src")"; then
        UBDIAG_SOURCE="$BUNDLE_DIR/source-downloads/ubdiag"
        clone_fixed_source "UbDiag" "$UBDIAG_REPOSITORY" \
            "$UBDIAG_EXPECTED_TAG" "$UBDIAG_SOURCE"
    fi
fi
UMDK_SOURCE="${OFFLINE_UMDK_SOURCE_DIR:-}"
if [ -z "$UMDK_SOURCE" ]; then
    if ! UMDK_SOURCE="$(first_git_source \
        "$REPO_DIR/build_vendored/_deps/urma-src" \
        "$REPO_DIR/build_mock/_deps/urma-src")"; then
        UMDK_SOURCE="$BUNDLE_DIR/source-downloads/urma"
        clone_fixed_source "UMDK" "$UMDK_REPOSITORY" \
            "$UMDK_EXPECTED_TAG" "$UMDK_SOURCE"
    fi
fi

assert_clean_source "UbDiag" "$UBDIAG_SOURCE"
assert_clean_source "UMDK" "$UMDK_SOURCE"
UBDIAG_COMMIT="$(git -C "$UBDIAG_SOURCE" rev-parse HEAD)"
[ "$UBDIAG_COMMIT" = "$UBDIAG_EXPECTED_COMMIT" ] || \
    fatal "UbDiag commit 不匹配: expected=$UBDIAG_EXPECTED_COMMIT actual=$UBDIAG_COMMIT"
verify_tag_if_present "UbDiag" "$UBDIAG_SOURCE" \
    "$UBDIAG_EXPECTED_TAG" "$UBDIAG_EXPECTED_COMMIT"
UMDK_COMMIT="$(git -C "$UMDK_SOURCE" rev-parse HEAD)"
[ "$UMDK_COMMIT" = "$UMDK_EXPECTED_COMMIT" ] || \
    fatal "UMDK commit 不匹配: expected=$UMDK_EXPECTED_COMMIT actual=$UMDK_COMMIT"
verify_tag_if_present "UMDK" "$UMDK_SOURCE" \
    "$UMDK_EXPECTED_TAG" "$UMDK_EXPECTED_COMMIT"

git -C "$REPO_DIR" submodule status --recursive >"$BUNDLE_DIR/submodules.txt"
if grep -Eq '^[-+U]' "$BUNDLE_DIR/submodules.txt"; then
    cat "$BUNDLE_DIR/submodules.txt" >&2
    fatal "Mooncake 子模块未完整初始化或不在记录版本"
fi

if ! dnf install --help 2>/dev/null | grep -q -- '--downloadonly'; then
    without_proxy dnf --setopt=proxy= --setopt='*.proxy=' \
        --setopt=timeout=20 --setopt=retries=1 \
        install -y dnf-plugins-core
fi
mapfile -t packages < <(
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$PACKAGE_FILE"
)
[ "${#packages[@]}" -gt 0 ] || fatal "RPM manifest 为空"

echo "Downloading ${#packages[@]} package/group roots and all dependencies..."
mkdir -p "$BUNDLE_DIR/dnf-root"
REPO_PROBE_URL="${RPM_MIRROR_BASE}/openEuler-24.03-LTS-SP3/OS/${CONTAINER_ARCH}/repodata/repomd.xml"
without_proxy curl --proxy "" -fL --retry 1 --connect-timeout 10 \
    --max-time 20 --range 0-0 -o /dev/null "$REPO_PROBE_URL" || \
    fatal "宿主机无法直连 openEuler SP3 镜像: $REPO_PROBE_URL"

DNF_RESOLVE_ARGS=(
    --installroot="$BUNDLE_DIR/dnf-root"
    --releasever="$CONTAINER_RELEASEVER"
    --setopt="reposdir=$BUNDLE_DIR/repos"
    --setopt=gpgcheck=0
    --setopt=localpkg_gpgcheck=0
    --setopt=proxy=
    --setopt='*.proxy='
    --setopt=timeout=20
    --setopt=retries=1
)
without_proxy dnf "${DNF_RESOLVE_ARGS[@]}" makecache --refresh \
    2>&1 | tee "$BUNDLE_DIR/logs/dnf-makecache.log"
without_proxy dnf "${DNF_RESOLVE_ARGS[@]}" \
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
without_proxy env \
    GOMODCACHE="$BUNDLE_DIR/go-cache/pkg/mod" \
    GOCACHE="$BUNDLE_DIR/go-build" \
    GOTOOLCHAIN=local \
    GOPROXY="${GOPROXY:-https://goproxy.cn,https://goproxy.io,direct}" \
    "$BUNDLE_DIR/go-toolchain/go/bin/go" \
    -C "$REPO_DIR/mooncake-common/etcd" mod download all
without_proxy env \
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
       "$BUNDLE_DIR/go-build" "$BUNDLE_DIR/dnf-root" \
       "$BUNDLE_DIR/source-downloads"

echo "============================================================"
echo "PASS: Mooncake UbDiag 离线依赖仓制作完成"
echo "bundle: $BUNDLE_DIR"
cat "$BUNDLE_DIR/manifest.env"
echo "============================================================"
