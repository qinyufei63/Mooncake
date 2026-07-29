#!/usr/bin/env bash
set -Eeuo pipefail

# Full AArch64/UB acceptance for Mooncake PR #13 after the Layer 1 design was
# changed to consume a system-installed UbDiag RPM.

FORMAL_MOONCAKE_SHA="1f9a0f28ab11fae396b0d466d61fb740ee66e593"
LAYER0_UBDIAG_SHA="8df2c2844d402e2e4dcd5ceab2424e8d36c5f99f"
SYSTEM_UBDIAG_SHA="0d00321945740391da92e81f0f56c3c5187b2402"
SYSTEM_UBDIAG_VERSION="0.6.1"

PROJECT_BASE="${PROJECT_BASE:-/home/q00913006/project}"
MOONCAKE_ROOT="${PROJECT_BASE}/mooncake-pr13-system-rpm-verify"
LAYER0_UBDIAG_ROOT="${PROJECT_BASE}/ubdiag-layer0-8df2c284"
SYSTEM_UBDIAG_ROOT="${PROJECT_BASE}/ubdiag-system-rpm-0d003219"
SYSTEM_RPM_DIR="${PROJECT_BASE}/ubdiag-system-rpms-0d003219"
SYSTEM_RPM_ARCHIVE="${PROJECT_BASE}/ubdiag-system-rpms-0d003219.tar.gz"
RESULT_ROOT="${MOONCAKE_ROOT}/verify_results/system_rpm_20260729"
URMA_SOURCE="${URMA_SOURCE:-/opt/mooncake-offline-sources/urma}"
URMA_LIBRARY="${URMA_LIBRARY:-/usr/lib64/liburma.so}"
DEVICE_NAME="${DEVICE_NAME:-bonding_dev_0}"
BUILD_JOBS="${BUILD_JOBS:-64}"
MASTER_HOST="${MASTER_HOST:-141.61.84.245}"
CLIENT_HOST="${CLIENT_HOST:-141.61.84.247}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ASSET_REPO=""
LAYER0_BUNDLE="${SCRIPT_DIR}/../ubdiag_8df2c284/ubdiag-8df2c284.bundle"
SYSTEM_BUNDLE="${SCRIPT_DIR}/ubdiag-system-rpm-0d003219.bundle"
COMMAND="${1:-help}"
DOCKER_BIN=""
CONTAINER_NAME=""
NODE_ROLE=""

on_error()
{
    local rc=$?
    echo "VERIFY_FAILED command=${COMMAND} line=${BASH_LINENO[0]} rc=${rc}" >&2
    echo "SSH session remains active; inspect the log above." >&2
    exit "${rc}"
}
trap on_error ERR

fatal()
{
    echo "FATAL: $*" >&2
    return 1
}

detect_role()
{
    case "$(hostname -s)" in
        node1)
            NODE_ROLE="node1"
            CONTAINER_NAME="mooncake-ubdiag-pr13-node1"
            ;;
        node2)
            NODE_ROLE="node2"
            CONTAINER_NAME="mooncake-ubdiag-pr13-node2"
            ;;
        *)
            fatal "run this script only on node1 or node2"
            ;;
    esac
}

select_docker()
{
    local candidate
    /usr/bin/docker inspect "${CONTAINER_NAME}" >/dev/null
    /usr/bin/docker start "${CONTAINER_NAME}" >/dev/null || true

    for candidate in \
        "${PROJECT_BASE}/nsenter-docker-fixed/docker" \
        /usr/bin/docker; do
        [ -x "${candidate}" ] || continue
        if timeout 12 "${candidate}" exec "${CONTAINER_NAME}" /bin/true \
            >/dev/null 2>&1; then
            DOCKER_BIN="${candidate}"
            echo "Docker exec path: ${DOCKER_BIN}"
            return 0
        fi
    done
    fatal "Docker reports ${CONTAINER_NAME}, but docker exec is unusable"
}

inside()
{
    "${DOCKER_BIN}" exec "${CONTAINER_NAME}" "$@"
}

inside_clean_env()
{
    inside env \
        -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        -u ALL_PROXY -u all_proxy \
        NO_PROXY="${MASTER_HOST},${CLIENT_HOST},127.0.0.1,localhost" \
        no_proxy="${MASTER_HOST},${CLIENT_HOST},127.0.0.1,localhost" \
        "$@"
}

ensure_git_source()
{
    local bundle="$1"
    local source_dir="$2"
    local expected_sha="$3"

    [ -f "${bundle}" ] || fatal "missing offline bundle: ${bundle}"
    git bundle verify "${bundle}" >/dev/null

    if [ ! -e "${source_dir}" ]; then
        git clone "${bundle}" "${source_dir}"
    fi
    [ -d "${source_dir}/.git" ] ||
        fatal "${source_dir} exists but is not a Git repository"
    [ "$(git -C "${source_dir}" rev-parse HEAD)" = "${expected_sha}" ] ||
        fatal "${source_dir} is not at ${expected_sha}"
    git -C "${source_dir}" diff --quiet
    git -C "${source_dir}" diff --cached --quiet
}

ensure_sources()
{
    ASSET_REPO="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
    if [ ! -e "${MOONCAKE_ROOT}" ]; then
        git -C "${ASSET_REPO}" worktree add --detach \
            "${MOONCAKE_ROOT}" "${FORMAL_MOONCAKE_SHA}"
    fi
    [ -d "${MOONCAKE_ROOT}/.git" ] ||
        [ -f "${MOONCAKE_ROOT}/.git" ] ||
        fatal "${MOONCAKE_ROOT} is not a Git worktree"
    [ "$(git -C "${MOONCAKE_ROOT}" rev-parse HEAD)" = \
        "${FORMAL_MOONCAKE_SHA}" ] ||
        fatal "Mooncake worktree is not at ${FORMAL_MOONCAKE_SHA}"
    git -C "${MOONCAKE_ROOT}" diff --quiet
    git -C "${MOONCAKE_ROOT}" diff --cached --quiet

    ensure_git_source "${LAYER0_BUNDLE}" "${LAYER0_UBDIAG_ROOT}" \
        "${LAYER0_UBDIAG_SHA}"
    ensure_git_source "${SYSTEM_BUNDLE}" "${SYSTEM_UBDIAG_ROOT}" \
        "${SYSTEM_UBDIAG_SHA}"
}

preflight_container()
{
    inside test -d "${MOONCAKE_ROOT}"
    inside test -d "${LAYER0_UBDIAG_ROOT}"
    inside test -d "${SYSTEM_UBDIAG_ROOT}"

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        test -f /.dockerenv
        test \"\$(uname -m)\" = aarch64
        test \"\$(ulimit -l)\" = unlimited
        for command_name in git cmake ninja gcc g++ python3 pkg-config \
            rpm rpmbuild rpm2cpio cpio file ldd readelf nm strings timeout \
            sha256sum curl ss awk sed grep find tar; do
            command -v \"\${command_name}\" >/dev/null
        done
        test -x /sbin/ldconfig
        test -f ${URMA_LIBRARY}
        test -f ${URMA_SOURCE}/CMakeLists.txt
        test -f /usr/local/include/msgpack.hpp ||
            test -f /usr/include/msgpack.hpp
        URMA_LOG_LEVEL=error urma_admin show --brief |
            grep -F '${DEVICE_NAME}' |
            grep -F ACTIVE
        find /usr/lib64/urma -maxdepth 1 -name 'liburma*.so*' -print |
            grep -q .
        if find /usr/lib64/urma -maxdepth 1 -name 'liburma*.so*' \
            -exec ldd -r {} \\; 2>&1 |
            grep -Eq 'not found|undefined symbol'; then
            echo 'URMA provider dependency failure' >&2
            exit 31
        fi
        echo CONTAINER_PREFLIGHT_PASS
    "
}

query_rpm_name()
{
    rpm -qp --qf '%{NAME}\n' "$1"
}

find_rpm_by_name()
{
    local wanted="$1"
    local candidate
    for candidate in "${SYSTEM_RPM_DIR}"/*.rpm; do
        [ -f "${candidate}" ] || continue
        if [ "$(query_rpm_name "${candidate}")" = "${wanted}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

build_system_ubdiag_rpm()
{
    [ "${NODE_ROLE}" = "node1" ] ||
        fatal "build-ubdiag-rpm must run on node1"
    ensure_sources
    select_docker
    preflight_container

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        cd '${SYSTEM_UBDIAG_ROOT}'
        cmake -E remove_directory output
        cmake -E remove_directory '${PROJECT_BASE}/ubdiag-rpmbuild-0d003219'
        RPM_TOPDIR='${PROJECT_BASE}/ubdiag-rpmbuild-0d003219' \
            bash build.sh package -p on -s on -m off -o off -k off
    "

    rm -rf "${SYSTEM_RPM_DIR}"
    mkdir -p "${SYSTEM_RPM_DIR}"
    find "${SYSTEM_UBDIAG_ROOT}/output" -maxdepth 1 -type f -name '*.rpm' \
        -exec cp -p {} "${SYSTEM_RPM_DIR}/" \;

    local base_rpm devel_rpm base_identity devel_identity
    base_rpm="$(find_rpm_by_name ubdiag)"
    devel_rpm="$(find_rpm_by_name ubdiag-devel)"
    base_identity="$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "${base_rpm}")"
    devel_identity="$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "${devel_rpm}")"
    [ "${base_identity}" = "${devel_identity}" ] ||
        fatal "UbDiag base/devel RPM identity mismatch"
    [ "$(rpm -qp --qf '%{VERSION}' "${base_rpm}")" = \
        "${SYSTEM_UBDIAG_VERSION}" ] ||
        fatal "unexpected UbDiag RPM version"

    (
        cd "${SYSTEM_RPM_DIR}"
        sha256sum ./*.rpm > SHA256SUMS
    )
    tar -C "${PROJECT_BASE}" -czf "${SYSTEM_RPM_ARCHIVE}" \
        "$(basename "${SYSTEM_RPM_DIR}")"
    sha256sum "${SYSTEM_RPM_ARCHIVE}" |
        tee "${SYSTEM_RPM_ARCHIVE}.sha256"

    echo "UBDIAG_RPM_BUILD_PASS identity=${base_identity}"
    echo "TRANSFER_TO_NODE2=${SYSTEM_RPM_ARCHIVE}"
}

prepare_rpm_directory()
{
    if [ ! -d "${SYSTEM_RPM_DIR}" ]; then
        [ -f "${SYSTEM_RPM_ARCHIVE}" ] ||
            fatal "missing ${SYSTEM_RPM_ARCHIVE}"
        tar -C "${PROJECT_BASE}" -xzf "${SYSTEM_RPM_ARCHIVE}"
    fi
    (
        cd "${SYSTEM_RPM_DIR}"
        sha256sum -c SHA256SUMS
    )
}

cleanup_runtime()
{
    inside bash -lc "
        pkill -TERM -x mooncake_master 2>/dev/null || true
        pkill -TERM -x mooncake_client 2>/dev/null || true
        pkill -TERM -x stress_cluster_bench 2>/dev/null || true
        sleep 2
        pkill -KILL -x mooncake_master 2>/dev/null || true
        pkill -KILL -x mooncake_client 2>/dev/null || true
        pkill -KILL -x stress_cluster_bench 2>/dev/null || true
        if [ -x /usr/bin/ubdiag ]; then
            /usr/bin/ubdiag stop >/dev/null 2>&1 || true
        fi
        rm -f /dev/shm/ubdiag_shm_default
    "
}

install_system_ubdiag()
{
    prepare_rpm_directory
    local base_rpm devel_rpm
    base_rpm="$(find_rpm_by_name ubdiag)"
    devel_rpm="$(find_rpm_by_name ubdiag-devel)"

    cleanup_runtime
    inside_clean_env rpm -Uvh --replacepkgs --oldpackage \
        "${base_rpm}" "${devel_rpm}"
    inside /sbin/ldconfig

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        /usr/bin/ubdiag --version | tee '${RESULT_ROOT}/ubdiag-version-${NODE_ROLE}.log'
        grep -q 'ubdiag version ${SYSTEM_UBDIAG_VERSION}' \
            '${RESULT_ROOT}/ubdiag-version-${NODE_ROLE}.log'
        grep -q 'build: 0d003219' \
            '${RESULT_ROOT}/ubdiag-version-${NODE_ROLE}.log'

        library=\$(readlink -f /usr/lib64/libubdiag.so)
        test -f \"\${library}\"
        library_record=\$(rpm -qf --qf '%{NAME}|%{VERSION}-%{RELEASE}.%{ARCH}' \
            \"\${library}\")
        cli_record=\$(rpm -qf --qf '%{NAME}|%{VERSION}-%{RELEASE}.%{ARCH}' \
            /usr/bin/ubdiag)
        test \"\${library_record#*|}\" = \"\${cli_record#*|}\"
        printf 'library=%s\ncli=%s\n' \"\${library_record}\" \"\${cli_record}\" |
            tee '${RESULT_ROOT}/ubdiag-rpm-identity-${NODE_ROLE}.log'

        ldd /usr/bin/ubdiag | tee '${RESULT_ROOT}/ubdiag-cli-ldd-${NODE_ROLE}.log'
        ! ldd /usr/bin/ubdiag | grep -q 'not found'
        ldd /usr/bin/ubdiag | grep -E \
            'libubdiag\\.so\\.0 => /usr/lib64/libubdiag\\.so\\.0'
        ! readelf -d /usr/bin/ubdiag |
            grep -Eq '\\((RPATH|RUNPATH)\\)'
        echo SYSTEM_UBDIAG_INSTALL_PASS
    "
}

configure_common()
{
    local build_dir="$1"
    shift
    inside_clean_env cmake -S "${MOONCAKE_ROOT}" -B "${build_dir}" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DWITH_STORE=ON \
        -DWITH_TE=ON \
        -DWITH_P2P_STORE=OFF \
        -DWITH_STORE_RUST=OFF \
        -DWITH_STORE_GO=OFF \
        -DWITH_EP=OFF \
        -DBUILD_BENCHMARK=ON \
        -DBUILD_UNIT_TESTS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DUSE_CUDA=OFF \
        -DUSE_REDIS=OFF \
        -DUSE_ETCD=OFF \
        -DSTORE_USE_ETCD=OFF \
        -DUSE_HTTP=ON \
        -DUSE_UB=ON \
        -DURMA_LIBRARY="${URMA_LIBRARY}" \
        -DFETCHCONTENT_SOURCE_DIR_URMA="${URMA_SOURCE}" \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        "$@"
}

build_targets()
{
    local build_dir="$1"
    inside_clean_env cmake --build "${build_dir}" --parallel "${BUILD_JOBS}" \
        --target mooncake_master mooncake_client stress_cluster_bench
}

verify_layer0()
{
    local build_dir="${MOONCAKE_ROOT}/build_mock"
    inside cmake -E remove_directory "${build_dir}"
    configure_common "${build_dir}" \
        -DMOONCAKE_ENABLE_UBDIAG=OFF \
        -DMOONCAKE_UBDIAG_SOURCE_DIR="${LAYER0_UBDIAG_ROOT}" \
        -DMOONCAKE_UBDIAG_GIT_TAG="${LAYER0_UBDIAG_SHA}" \
        -DMOONCAKE_UBDIAG_EXPECTED_COMMIT="${LAYER0_UBDIAG_SHA}"
    build_targets "${build_dir}"

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        grep -qx 'MOONCAKE_UBDIAG_LAYER=mock' \
            '${build_dir}/mooncake_ubdiag.env'
        grep -qx 'MOONCAKE_UBDIAG_RESOLVED_COMMIT=${LAYER0_UBDIAG_SHA}' \
            '${build_dir}/mooncake_ubdiag.env'
        grep -q -- '-DUBDIAG_DISABLE' '${build_dir}/compile_commands.json'
        for binary in \
            '${build_dir}/mooncake-store/src/mooncake_master' \
            '${build_dir}/mooncake-store/src/mooncake_client' \
            '${build_dir}/mooncake-store/benchmarks/stress_cluster_bench'; do
            test -x \"\${binary}\"
            ! readelf -d \"\${binary}\" 2>/dev/null |
                grep -q 'NEEDED.*libubdiag'
            ! ldd \"\${binary}\" 2>/dev/null | grep -q libubdiag
            ! strings \"\${binary}\" | grep -q 'libubdiag\\.so'
        done
        test -z \"\$(find '${build_dir}' -type f -name 'libubdiag.so*' -print -quit)\"
        echo LAYER0_BUILD_AND_BINARY_GATES_PASS
    "
}

verify_layer1()
{
    local build_dir="${MOONCAKE_ROOT}/build_system"
    inside cmake -E remove_directory "${build_dir}"
    configure_common "${build_dir}" \
        -DMOONCAKE_ENABLE_UBDIAG=ON \
        -DUbDiag_DIR=/usr/lib64/cmake/UbDiag
    build_targets "${build_dir}"

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        grep -qx 'MOONCAKE_UBDIAG_LAYER=system' \
            '${build_dir}/mooncake_ubdiag.env'
        grep -qx 'MOONCAKE_UBDIAG_SYSTEM_PREFIX=/usr' \
            '${build_dir}/mooncake_ubdiag.env'
        grep -qx 'MOONCAKE_UBDIAG_SYSTEM_CLI=/usr/bin/ubdiag' \
            '${build_dir}/mooncake_ubdiag.env'
        grep -q '^MOONCAKE_UBDIAG_SYSTEM_RPM_EVR_ARCH=${SYSTEM_UBDIAG_VERSION}-' \
            '${build_dir}/mooncake_ubdiag.env'
        for binary in \
            '${build_dir}/mooncake-store/src/mooncake_master' \
            '${build_dir}/mooncake-store/src/mooncake_client' \
            '${build_dir}/mooncake-store/benchmarks/stress_cluster_bench'; do
            test -x \"\${binary}\"
            readelf -d \"\${binary}\" |
                grep -q 'NEEDED.*libubdiag\\.so\\.0'
            ldd \"\${binary}\" |
                grep -E 'libubdiag\\.so\\.0 => /usr/lib64/libubdiag\\.so\\.0'
            ! ldd \"\${binary}\" | grep -q 'not found'
        done
        echo LAYER1_SYSTEM_BUILD_AND_LINK_GATES_PASS
    "
}

verify_mode_transition()
{
    local build_dir="${MOONCAKE_ROOT}/build_ubdiag_transition"
    inside cmake -E remove_directory "${build_dir}"

    configure_common "${build_dir}" \
        -DMOONCAKE_ENABLE_UBDIAG=OFF \
        -DMOONCAKE_UBDIAG_SOURCE_DIR="${LAYER0_UBDIAG_ROOT}" \
        -DMOONCAKE_UBDIAG_GIT_TAG="${LAYER0_UBDIAG_SHA}" \
        -DMOONCAKE_UBDIAG_EXPECTED_COMMIT="${LAYER0_UBDIAG_SHA}"
    inside grep -qx "MOONCAKE_UBDIAG_LAYER=mock" \
        "${build_dir}/mooncake_ubdiag.env"

    configure_common "${build_dir}" \
        -DMOONCAKE_ENABLE_UBDIAG=ON \
        -DUbDiag_DIR=/usr/lib64/cmake/UbDiag
    inside grep -qx "MOONCAKE_UBDIAG_LAYER=system" \
        "${build_dir}/mooncake_ubdiag.env"

    configure_common "${build_dir}" \
        -DMOONCAKE_ENABLE_UBDIAG=OFF \
        -DMOONCAKE_UBDIAG_SOURCE_DIR="${LAYER0_UBDIAG_ROOT}" \
        -DMOONCAKE_UBDIAG_GIT_TAG="${LAYER0_UBDIAG_SHA}" \
        -DMOONCAKE_UBDIAG_EXPECTED_COMMIT="${LAYER0_UBDIAG_SHA}"
    inside grep -qx "MOONCAKE_UBDIAG_LAYER=mock" \
        "${build_dir}/mooncake_ubdiag.env"
    echo "LAYER_SWITCH_OFF_ON_OFF_PASS"
}

prepare_node()
{
    ensure_sources
    mkdir -p "${RESULT_ROOT}"
    select_docker
    preflight_container
    install_system_ubdiag
    verify_layer0
    verify_layer1
    verify_mode_transition
    echo "PREP_${NODE_ROLE}_COMPLETE"
}

start_master()
{
    local layer="$1"
    local build_name master_port metadata_port metrics_port out_dir binary
    case "${layer}" in
        layer0)
            build_name="build_mock"
            master_port=25060
            metadata_port=28020
            metrics_port=29010
            ;;
        layer1)
            build_name="build_system"
            master_port=35060
            metadata_port=38020
            metrics_port=39010
            ;;
        *)
            fatal "unknown layer: ${layer}"
            ;;
    esac
    out_dir="${RESULT_ROOT}/${layer}_node1"
    binary="${MOONCAKE_ROOT}/${build_name}/mooncake-store/src/mooncake_master"

    cleanup_runtime
    inside mkdir -p "${out_dir}"
    if [ "${layer}" = "layer0" ]; then
        inside bash -lc "find /dev/shm -maxdepth 1 -name 'ubdiag_shm*' -print |
            sort > '${out_dir}/shm.before'"
    else
        inside_clean_env /usr/bin/ubdiag start --perflog
        inside_clean_env /usr/bin/ubdiag status |
            tee "${out_dir}/ubdiag-status.log"
    fi

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        nohup env \
            LD_LIBRARY_PATH='${MOONCAKE_ROOT}/${build_name}/mooncake-store/src:${MOONCAKE_ROOT}/${build_name}/mooncake-transfer-engine/src:${MOONCAKE_ROOT}/${build_name}/mooncake-common:/usr/lib64' \
            MC_LOG_ENABLE=on MC_LOG_LEVEL=INFO \
            '${binary}' \
            --global_file_segment_size=9223372036854775807 \
            --enable_http_metadata_server=true \
            --http_metadata_server_host=0.0.0.0 \
            --http_metadata_server_port=${metadata_port} \
            --default_kv_lease_ttl=300000 \
            --enable_offload=false \
            --port=${master_port} \
            --metrics_port=${metrics_port} \
            > '${out_dir}/master.log' 2>&1 &
        echo \$! > '${out_dir}/master.pid'
        sleep 8
        kill -0 \$(cat '${out_dir}/master.pid')
        ss -lnt | grep -q ':${master_port} '
        ss -lnt | grep -q ':${metadata_port} '
        ss -lnt | grep -q ':${metrics_port} '
        ! grep -Eqi 'segmentation fault|core dumped|fatal:' \
            '${out_dir}/master.log'
    "

    if [ "${layer}" = "layer1" ]; then
        inside_clean_env bash -lc "
            pid=\$(cat '${out_dir}/master.pid')
            grep -F '/usr/lib64/libubdiag.so.${SYSTEM_UBDIAG_VERSION}' \
                /proc/\${pid}/maps
        "
    fi
    echo "${layer^^}_MASTER_245_READY"
}

start_client_and_benchmark()
{
    local layer="$1"
    local build_name master_port metadata_port admin_port client_port out_dir
    local binary bench
    case "${layer}" in
        layer0)
            build_name="build_mock"
            master_port=25060
            metadata_port=28020
            admin_port=29010
            client_port=28980
            ;;
        layer1)
            build_name="build_system"
            master_port=35060
            metadata_port=38020
            admin_port=39010
            client_port=38980
            ;;
        *)
            fatal "unknown layer: ${layer}"
            ;;
    esac
    out_dir="${RESULT_ROOT}/${layer}_node2"
    binary="${MOONCAKE_ROOT}/${build_name}/mooncake-store/src/mooncake_client"
    bench="${MOONCAKE_ROOT}/${build_name}/mooncake-store/benchmarks/stress_cluster_bench"

    cleanup_runtime
    inside mkdir -p "${out_dir}/write" "${out_dir}/read"
    if [ "${layer}" = "layer0" ]; then
        inside bash -lc "find /dev/shm -maxdepth 1 -name 'ubdiag_shm*' -print |
            sort > '${out_dir}/shm.before'"
    else
        inside_clean_env /usr/bin/ubdiag start --perflog
        inside_clean_env /usr/bin/ubdiag status |
            tee "${out_dir}/ubdiag-status.log"
    fi

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        curl --noproxy '*' -sS -o /dev/null \
            -w '%{http_code}' \
            'http://${MASTER_HOST}:${metadata_port}/metadata' |
            grep -Eq '^(200|400|404)$'
        nohup env \
            LD_LIBRARY_PATH='${MOONCAKE_ROOT}/${build_name}/mooncake-store/src:${MOONCAKE_ROOT}/${build_name}/mooncake-transfer-engine/src:${MOONCAKE_ROOT}/${build_name}/mooncake-common:/usr/lib64' \
            MC_STORE_CLIENT_SETUP_RETRIES=3 \
            MC_TCP_BIND_ADDRESS='${CLIENT_HOST}' \
            MC_URMA_TRANS_MODE=RM \
            '${binary}' \
            --metadata_server='http://${MASTER_HOST}:${metadata_port}/metadata' \
            --master_server_address='${MASTER_HOST}:${master_port}' \
            --host='${CLIENT_HOST}' \
            --global_segment_size=8589934592 \
            --threads=16 \
            --protocol=ub \
            --port=${client_port} \
            --device_names='${DEVICE_NAME}' \
            > '${out_dir}/client.log' 2>&1 &
        echo \$! > '${out_dir}/client.pid'
        sleep 8
        kill -0 \$(cat '${out_dir}/client.pid')
        ss -lnt | grep -q ':${client_port} '
        ! grep -Eqi 'segmentation fault|core dumped|fatal:' \
            '${out_dir}/client.log'
    "

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        export LD_LIBRARY_PATH='${MOONCAKE_ROOT}/${build_name}/mooncake-store/src:${MOONCAKE_ROOT}/${build_name}/mooncake-transfer-engine/src:${MOONCAKE_ROOT}/${build_name}/mooncake-common:/usr/lib64'
        export MC_STORE_CLIENT_SETUP_RETRIES=3
        export MC_TCP_BIND_ADDRESS='${CLIENT_HOST}'
        export MC_URMA_TRANS_MODE=RM
        export MC_SLICE_SIZE=1048576
        export MC_WORKERS_PER_CTX=4
        export MC_MAX_WR=32

        timeout 600 '${bench}' \
            --metadata-server='http://${MASTER_HOST}:${metadata_port}/metadata' \
            --master-server='${MASTER_HOST}:${master_port}' \
            --local-hostname='${CLIENT_HOST}' \
            --master_admin_port=${admin_port} \
            --global-segment-size=0 \
            --local-buffer-size=536870912 \
            --scenario=segment_write \
            --num-keys=1000 \
            --protocol=ub \
            --verify=false \
            --num_threads=32 \
            --batch-size=32 \
            --device-name='${DEVICE_NAME}' \
            2>&1 | tee '${out_dir}/write/write.log'
        grep -q 'STATUS: PASSED' '${out_dir}/write/write.log'

        timeout 180 '${bench}' \
            --role=reader \
            --global-segment-size=0 \
            --local-buffer-size=1073741824 \
            --local-hostname='${CLIENT_HOST}' \
            --master-server='${MASTER_HOST}:${master_port}' \
            --master_admin_port=${admin_port} \
            --metadata-server='http://${MASTER_HOST}:${metadata_port}/metadata' \
            --scenario=segment_read \
            --num-keys=1000 \
            --protocol=ub \
            --verify=false \
            --num_threads=16 \
            --batch-size=16 \
            --duration=20 \
            --device-name='${DEVICE_NAME}' \
            2>&1 | tee '${out_dir}/read/read.log'
        grep -q 'STATUS: PASSED' '${out_dir}/read/read.log'
        grep -Eq 'failed: 0|failed=0' '${out_dir}/read/read.log'
        grep -q 'FINAL SUMMARY' '${out_dir}/read/read.log'
    "

    if [ "${layer}" = "layer0" ]; then
        inside bash -lc "
            find /dev/shm -maxdepth 1 -name 'ubdiag_shm*' -print |
                sort > '${out_dir}/shm.after'
            cmp '${out_dir}/shm.before' '${out_dir}/shm.after'
        "
        echo "LAYER0_MOCK_NO_SHM_CHANGE_PASS"
    else
        collect_cli "${out_dir}"
    fi

    inside bash -lc "
        kill \$(cat '${out_dir}/client.pid') 2>/dev/null || true
        sleep 2
    "
    echo "${layer^^}_UB_WRITE_READ_247_PASS"
}

require_csv()
{
    local directory="$1"
    local label="$2"
    inside bash -lc "
        set -Eeuo pipefail
        count=\$(find '${directory}' -type f -name '*.csv' -size +0c | wc -l)
        test \"\${count}\" -gt 0
        find '${directory}' -type f -name '*.csv' -size +0c -print |
            tee '${directory}/files.log'
        echo '${label}_CSV_PASS files='\${count}
    "
}

collect_cli()
{
    local out_dir="$1"
    local csv_root="${out_dir}/csv"
    inside mkdir -p \
        "${csv_root}/show" \
        "${csv_root}/detail" \
        "${csv_root}/perflog" \
        "${csv_root}/rawtable" \
        "${csv_root}/watch" \
        "${csv_root}/history"

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        /usr/bin/ubdiag show --csv '${csv_root}/show' |
            tee '${out_dir}/show.log'
        grep -q 'P99(ns)' '${out_dir}/show.log'
        grep -q 'P999(ns)' '${out_dir}/show.log'
        grep -q 'P9999(ns)' '${out_dir}/show.log'
        test \$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' \
            '${out_dir}/show.log') -gt 0

        /usr/bin/ubdiag show --detail --csv '${csv_root}/detail' |
            tee '${out_dir}/detail.log'
        test \$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' \
            '${out_dir}/detail.log') -gt 0
        core=\$(awk '/^[[:space:]]*[0-9]+[[:space:]]+/ {print \$2; exit}' \
            '${out_dir}/detail.log')
        test -n \"\${core}\"

        /usr/bin/ubdiag show --sort total:desc |
            tee '${out_dir}/sort.log'
        test \$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' \
            '${out_dir}/sort.log') -gt 0

        /usr/bin/ubdiag show --perflog --csv '${csv_root}/perflog' |
            tee '${out_dir}/perflog.log'
        test \$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]+' \
            '${out_dir}/perflog.log') -gt 0

        /usr/bin/ubdiag show --core \"\${core}\" \
            --csv '${csv_root}/rawtable' |
            tee '${out_dir}/rawtable.log'

        set +e
        timeout 6 /usr/bin/ubdiag watch --interval 1000 \
            --csv '${csv_root}/watch' > '${out_dir}/watch.log' 2>&1
        watch_rc=\$?
        set -e
        test \"\${watch_rc}\" -eq 124 || test \"\${watch_rc}\" -eq 0

        /usr/bin/ubdiag history --csv '${csv_root}/history' |
            tee '${out_dir}/history.log'

        ! grep -ERqi 'segmentation fault|core dumped|illegal instruction' \
            '${out_dir}' --include='*.log'
        echo LAYER1_CLI_TEXT_PASS
    "

    require_csv "${csv_root}/show" SHOW
    require_csv "${csv_root}/detail" DETAIL
    require_csv "${csv_root}/perflog" PERFLOG
    require_csv "${csv_root}/rawtable" RAWTABLE
    require_csv "${csv_root}/watch" WATCH
    require_csv "${csv_root}/history" HISTORY
    inside_clean_env /usr/bin/ubdiag stop
    echo "LAYER1_CLI_P99_PERFLOG_CSV_PASS"
}

collect_master()
{
    [ "${NODE_ROLE}" = "node1" ] ||
        fatal "layer1-master-collect must run on node1"
    local out_dir="${RESULT_ROOT}/layer1_node1"
    collect_cli "${out_dir}"
    inside bash -lc "
        kill \$(cat '${out_dir}/master.pid') 2>/dev/null || true
        sleep 2
    "
    echo "LAYER1_MASTER_CLI_245_PASS"
}

package_mooncake()
{
    [ "${NODE_ROLE}" = "node1" ] ||
        fatal "package must run on node1"
    local mock_out="${RESULT_ROOT}/rpm_mock"
    local system_out="${RESULT_ROOT}/rpm_system"
    inside cmake -E remove_directory "${mock_out}"
    inside cmake -E remove_directory "${system_out}"

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        cd '${MOONCAKE_ROOT}'
        bash scripts/build_rpm.sh build_mock '${mock_out}' aarch64 |
            tee '${RESULT_ROOT}/rpm-mock-build.log'
        bash scripts/build_rpm.sh build_system '${system_out}' aarch64 |
            tee '${RESULT_ROOT}/rpm-system-build.log'
    "

    inside_clean_env bash -lc "
        set -Eeuo pipefail
        mock_rpm=\$(find '${mock_out}' -maxdepth 1 -name '*.rpm' -print -quit)
        system_rpm=\$(find '${system_out}' -maxdepth 1 -name '*.rpm' -print -quit)
        test -f \"\${mock_rpm}\"
        test -f \"\${system_rpm}\"

        rpm -qlp \"\${mock_rpm}\" | tee '${RESULT_ROOT}/rpm-mock-files.log'
        ! rpm -qlp \"\${mock_rpm}\" |
            grep -Eq '^/usr/bin/ubdiag\$|^/usr/lib64/libubdiag\\.so'

        rpm -qlp \"\${system_rpm}\" | tee '${RESULT_ROOT}/rpm-system-files.log'
        rpm -qlp \"\${system_rpm}\" | grep -qx '/usr/bin/ubdiag'
        rpm -qlp \"\${system_rpm}\" |
            grep -Eq '^/usr/lib64/libubdiag\\.so'

        rm -rf '${RESULT_ROOT}/rpm-system-extract'
        mkdir -p '${RESULT_ROOT}/rpm-system-extract'
        cd '${RESULT_ROOT}/rpm-system-extract'
        rpm2cpio \"\${system_rpm}\" | cpio -idm --quiet
        test -x usr/bin/ubdiag
        test -f usr/lib64/libubdiag.so.${SYSTEM_UBDIAG_VERSION}
        ! readelf -d usr/bin/ubdiag | grep -Eq '\\((RPATH|RUNPATH)\\)'
        env LD_LIBRARY_PATH=\"\${PWD}/usr/lib64:/usr/lib64\" \
            ldd usr/bin/ubdiag |
            grep -F \"\${PWD}/usr/lib64/libubdiag.so.0\"
        cmp /usr/bin/ubdiag usr/bin/ubdiag
        cmp /usr/lib64/libubdiag.so.${SYSTEM_UBDIAG_VERSION} \
            usr/lib64/libubdiag.so.${SYSTEM_UBDIAG_VERSION}
        sha256sum \"\${mock_rpm}\" \"\${system_rpm}\" |
            tee '${RESULT_ROOT}/rpm-sha256.log'
        printf '%s\n' \"\${system_rpm}\" > '${RESULT_ROOT}/system-rpm-path.txt'
        echo MOONCAKE_RPM_CONTENT_AND_ISOLATED_INSTALL_PASS
    "

    normal_install_check
    echo "MOONCAKE_LAYER0_LAYER1_RPM_FULL_PASS"
}

normal_install_check()
{
    local test_container="mooncake-pr13-rpm-install-check-20260729"
    local image system_rpm
    image="$(/usr/bin/docker inspect --format '{{.Config.Image}}' \
        "${CONTAINER_NAME}")"
    system_rpm="$(inside cat "${RESULT_ROOT}/system-rpm-path.txt")"

    /usr/bin/docker rm -f "${test_container}" >/dev/null 2>&1 || true
    /usr/bin/docker run -d --name "${test_container}" \
        --entrypoint /usr/bin/sleep "${image}" infinity >/dev/null
    /usr/bin/docker cp "${system_rpm}" \
        "${test_container}:/tmp/mooncake-system.rpm" >/dev/null
    /usr/bin/docker exec "${test_container}" \
        rpm -Uvh /tmp/mooncake-system.rpm
    /usr/bin/docker exec "${test_container}" /sbin/ldconfig
    /usr/bin/docker exec "${test_container}" bash -lc "
        set -Eeuo pipefail
        test -x /usr/bin/mooncake_master
        test -x /usr/bin/mooncake_client
        test -x /usr/bin/ubdiag
        /usr/bin/ubdiag --version | grep -q \
            'ubdiag version ${SYSTEM_UBDIAG_VERSION}'
        ldd /usr/bin/mooncake_master |
            grep -E 'libubdiag\\.so\\.0 => /usr/lib64/libubdiag\\.so\\.0'
        ! ldd /usr/bin/mooncake_master | grep -q 'not found'
        echo NORMAL_RPM_INSTALL_PASS
    "
    /usr/bin/docker rm -f "${test_container}" >/dev/null
}

show_help()
{
    cat <<'EOF'
Usage: bash verify_245_247.sh <command>

Commands:
  build-ubdiag-rpm       node1 only: build the fixed system UbDiag RPM set
  prepare                both nodes: install RPM, build and gate Layer 0/1
  layer0-master          node1: start Layer 0 master
  layer0-client          node2: start client and run write/read benchmark
  layer1-master          node1: start UbDiag and Layer 1 master
  layer1-client          node2: run benchmark and full CLI/CSV validation
  layer1-master-collect  node1: collect master CLI/CSV and stop runtime
  package                node1: build, inspect, and install-check both RPMs
EOF
}

main()
{
    case "${COMMAND}" in
        help|-h|--help)
            show_help
            return 0
            ;;
    esac
    detect_role
    case "${COMMAND}" in
        build-ubdiag-rpm)
            build_system_ubdiag_rpm
            ;;
        prepare)
            prepare_node
            ;;
        layer0-master)
            [ "${NODE_ROLE}" = "node1" ||
                fatal "layer0-master must run on node1"
            select_docker
            start_master layer0
            ;;
        layer0-client)
            [ "${NODE_ROLE}" = "node2" ||
                fatal "layer0-client must run on node2"
            select_docker
            start_client_and_benchmark layer0
            ;;
        layer1-master)
            [ "${NODE_ROLE}" = "node1" ||
                fatal "layer1-master must run on node1"
            select_docker
            start_master layer1
            ;;
        layer1-client)
            [ "${NODE_ROLE}" = "node2" ||
                fatal "layer1-client must run on node2"
            select_docker
            start_client_and_benchmark layer1
            ;;
        layer1-master-collect)
            select_docker
            collect_master
            ;;
        package)
            select_docker
            package_mooncake
            ;;
        *)
            show_help >&2
            fatal "unknown command: ${COMMAND}"
            ;;
    esac
}

main
