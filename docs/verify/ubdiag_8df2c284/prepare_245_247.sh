#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_MOONCAKE="37e0a1dc499f5e324a6cf450b387bad3fb883d3d"
EXPECTED_UBDIAG="8df2c2844d402e2e4dcd5ceab2424e8d36c5f99f"
EXPECTED_BUNDLE_SHA256="c0da33692ede766cad8a111df19aa8ed3810693e7f45e3f677f36db1d3beaaf4"
PROJECT_BASE="/home/q00913006/project"
MOONCAKE_ROOT="${PROJECT_BASE}/mooncake-pr13-verify"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UBDIAG_BUNDLE="${SCRIPT_DIR}/ubdiag-8df2c284.bundle"
UBDIAG_SOURCE="${PROJECT_BASE}/ubdiag-8df2c284"

case "$(hostname -s)" in
    node1)
        NODE_ROLE="node1"
        CONTAINER_NAME="mooncake-ubdiag-pr13-node1"
        BUILD_TARGETS=(mooncake_master)
        ROLE_BINARIES=(
            "mooncake-store/src/mooncake_master"
        )
        ;;
    node2)
        NODE_ROLE="node2"
        CONTAINER_NAME="mooncake-ubdiag-pr13-node2"
        BUILD_TARGETS=(mooncake_client stress_cluster_bench)
        ROLE_BINARIES=(
            "mooncake-store/src/mooncake_client"
            "mooncake-store/benchmarks/stress_cluster_bench"
        )
        ;;
    *)
        echo "FATAL: run this script only on node1 or node2" >&2
        exit 2
        ;;
esac

echo "=== ${NODE_ROLE}: verify offline inputs ==="
test -f "${UBDIAG_BUNDLE}" || {
    echo "FATAL: missing ${UBDIAG_BUNDLE}" >&2
    exit 3
}
echo "${EXPECTED_BUNDLE_SHA256}  ${UBDIAG_BUNDLE}" | sha256sum -c -

test -d "${MOONCAKE_ROOT}/.git" || {
    echo "FATAL: missing Mooncake repository: ${MOONCAKE_ROOT}" >&2
    exit 4
}
test "$(git -C "${MOONCAKE_ROOT}" rev-parse HEAD)" = "${EXPECTED_MOONCAKE}" || {
    echo "FATAL: Mooncake HEAD is not ${EXPECTED_MOONCAKE}" >&2
    exit 5
}

if [ ! -e "${UBDIAG_SOURCE}" ]; then
    git clone "${UBDIAG_BUNDLE}" "${UBDIAG_SOURCE}"
fi
test -d "${UBDIAG_SOURCE}/.git" || {
    echo "FATAL: ${UBDIAG_SOURCE} exists but is not a Git repository" >&2
    exit 6
}
test "$(git -C "${UBDIAG_SOURCE}" rev-parse HEAD)" = "${EXPECTED_UBDIAG}" || {
    echo "FATAL: UbDiag HEAD is not ${EXPECTED_UBDIAG}" >&2
    exit 7
}
git -C "${UBDIAG_SOURCE}" status --porcelain --untracked-files=all \
    > "${PROJECT_BASE}/ubdiag-8df2c284.status"
test ! -s "${PROJECT_BASE}/ubdiag-8df2c284.status" || {
    echo "FATAL: UbDiag source is not clean" >&2
    cat "${PROJECT_BASE}/ubdiag-8df2c284.status" >&2
    exit 8
}

docker inspect "${CONTAINER_NAME}" >/dev/null
docker start "${CONTAINER_NAME}" >/dev/null
docker exec "${CONTAINER_NAME}" test -d "${MOONCAKE_ROOT}"
docker exec "${CONTAINER_NAME}" test -d "${UBDIAG_SOURCE}"

configure_layer()
{
    local layer="$1"
    local enabled="$2"
    local build_dir="${MOONCAKE_ROOT}/build_${layer}"

    echo "=== ${NODE_ROLE}: configure ${layer} ==="
    docker exec "${CONTAINER_NAME}" cmake \
        -S "${MOONCAKE_ROOT}" \
        -B "${build_dir}" \
        -DMOONCAKE_ENABLE_UBDIAG="${enabled}" \
        -DMOONCAKE_UBDIAG_SOURCE_DIR="${UBDIAG_SOURCE}" \
        -DMOONCAKE_UBDIAG_GIT_TAG="${EXPECTED_UBDIAG}" \
        -DMOONCAKE_UBDIAG_EXPECTED_COMMIT="${EXPECTED_UBDIAG}"

    docker exec "${CONTAINER_NAME}" grep -qx \
        "MOONCAKE_UBDIAG_RESOLVED_COMMIT:STRING=${EXPECTED_UBDIAG}" \
        "${build_dir}/CMakeCache.txt"
    docker exec "${CONTAINER_NAME}" grep -qx \
        "MOONCAKE_UBDIAG_RESOLVED_COMMIT=${EXPECTED_UBDIAG}" \
        "${build_dir}/mooncake_ubdiag_rpm.env"

    echo "=== ${NODE_ROLE}: build ${layer} (${BUILD_TARGETS[*]}) ==="
    docker exec "${CONTAINER_NAME}" cmake \
        --build "${build_dir}" \
        --parallel 64 \
        --target "${BUILD_TARGETS[@]}"
}

configure_layer "mock" "OFF"

echo "=== ${NODE_ROLE}: Layer 0 binary gates ==="
for relative_binary in "${ROLE_BINARIES[@]}"; do
    binary="${MOONCAKE_ROOT}/build_mock/${relative_binary}"
    docker exec "${CONTAINER_NAME}" test -x "${binary}"
    if docker exec "${CONTAINER_NAME}" ldd "${binary}" | grep -q "libubdiag"; then
        echo "FATAL: Layer 0 binary links libubdiag: ${binary}" >&2
        exit 9
    fi
    if docker exec "${CONTAINER_NAME}" nm -C --undefined-only "${binary}" |
        grep -Eq "UbDiag::(PerfPoint|PerfManager)::"; then
        echo "FATAL: Layer 0 binary has concrete UbDiag references: ${binary}" >&2
        exit 10
    fi
done
echo "LAYER0_${NODE_ROLE}_PASS"

configure_layer "vendored" "ON"

echo "=== ${NODE_ROLE}: Layer 1 build and provenance gates ==="
docker exec "${CONTAINER_NAME}" cmake \
    --build "${MOONCAKE_ROOT}/build_vendored" \
    --parallel 64 \
    --target ubdiag

docker exec "${CONTAINER_NAME}" grep -qx \
    "${EXPECTED_UBDIAG}" \
    "${MOONCAKE_ROOT}/build_vendored/_deps/ubdiag-build/mooncake-source-commit.txt"
docker exec "${CONTAINER_NAME}" grep -qx "UBDIAG_BUILD_SHARED:BOOL=ON" \
    "${MOONCAKE_ROOT}/build_vendored/CMakeCache.txt"
docker exec "${CONTAINER_NAME}" grep -qx "ENABLE_PERCENTILE:BOOL=ON" \
    "${MOONCAKE_ROOT}/build_vendored/CMakeCache.txt"
docker exec "${CONTAINER_NAME}" grep -qx "ENABLE_PERFLOG:BOOL=ON" \
    "${MOONCAKE_ROOT}/build_vendored/CMakeCache.txt"

UBDIAG_LIB_DIR="${MOONCAKE_ROOT}/build_vendored/_deps/ubdiag-build/src/sdk"
UBDIAG_CLI="${MOONCAKE_ROOT}/build_vendored/_deps/ubdiag-build/src/cli/ubdiag"
docker exec "${CONTAINER_NAME}" test -x "${UBDIAG_CLI}"
docker exec "${CONTAINER_NAME}" env \
    LD_LIBRARY_PATH="${UBDIAG_LIB_DIR}:/usr/lib64" \
    "${UBDIAG_CLI}" --version |
    tee "${PROJECT_BASE}/ubdiag-8df2c284-${NODE_ROLE}.version"
grep -q "ubdiag version 0.6.0" \
    "${PROJECT_BASE}/ubdiag-8df2c284-${NODE_ROLE}.version"
grep -q "build: 8df2c284" \
    "${PROJECT_BASE}/ubdiag-8df2c284-${NODE_ROLE}.version"

for relative_binary in "${ROLE_BINARIES[@]}"; do
    binary="${MOONCAKE_ROOT}/build_vendored/${relative_binary}"
    docker exec "${CONTAINER_NAME}" env \
        LD_LIBRARY_PATH="${UBDIAG_LIB_DIR}:/usr/lib64" \
        ldd "${binary}" |
        grep "libubdiag" |
        grep -F "${UBDIAG_LIB_DIR}"
done

echo "LAYER1_${NODE_ROLE}_PASS"
echo "PREP_${NODE_ROLE}_COMPLETE"
