# Mooncake 从 UbDiag 迁移到 SpDiag 开发与 245/247 验证交接手册

本文用于指导开发人员完成 Mooncake 对 SpDiag 的源码 Mock、系统库集成、业务埋点改名，以及在 245/247 UB 环境中的编译和 Mooncake benchmark 验证。

文档基线：`LinQuickDev/Mooncake:supercache@bea2c4cf0cf6f2360671f2b5750dc094dd0a72ab`。

> 行号以该基线为准。完成迁移后行号可能变化，最终应以符号搜索、CMake 输出、ELF 动态依赖和运行结果为准。

## 1. 任务目标

UbDiag 已经改名为 SpDiag，改名后的源码将上传到：

```text
https://gitcode.com/openeuler/spdiag.git
```

Mooncake 需要继续保留原来的两层模型，但所有外部身份都迁移到 SpDiag：

| 层级 | 配置 | SpDiag 来源 | 结果 |
|---|---|---|---|
| L0 Mock | `MOONCAKE_ENABLE_SPDIAG=OFF` | FetchContent 拉取公开仓固定 SHA | 使用 SpDiag 头文件中的 `SPDIAG_DISABLE` 空实现，不链接运行库 |
| L1 System | `MOONCAKE_ENABLE_SPDIAG=ON` | 系统安装的 SpDiag RPM | 链接 `libspdiag.so`，使用 `spdiag` CLI 读取 Mooncake 埋点 |

最终验收不是“编译成功”四个字，而是：

1. 245 与 247 使用同一个 Mooncake 完整 SHA。
2. L0 拉取公开 SpDiag 仓的同一个完整 SHA。
3. L0 的 Mooncake ELF 不依赖 `libspdiag.so`，也不新增 SpDiag SHM。
4. L1 的 245/247 安装同一批 SpDiag RPM。
5. L1 的 Mooncake master、client 和 benchmark 都依赖并实际加载 `libspdiag.so`。
6. 245 启动 Mooncake master，247 启动 Mooncake client。
7. 247 使用 Mooncake 自己编译出的 `stress_cluster_bench` 完成 UB 写入和读取。
8. 写入 1000/1000 成功，读取 `failed=0`、查询数和吞吐非零。
9. SpDiag 能读取 Mooncake PerfPoint、P99、PerfLog，并导出非空 CSV。

## 2. 迁移不是只改仓库地址

SpDiag 已经改变整个公开身份：

```text
UbDiag                     -> SpDiag
ubdiag                     -> spdiag
UBDIAG_*                   -> SPDIAG_*
UbDiag::ubdiag_lib         -> SpDiag::spdiag_lib
UbDiag::PerfPoint          -> SpDiag::PerfPoint
UbDiag::PerfLevel          -> SpDiag::PerfLevel
include/ubdiag             -> include/spdiag
libubdiag.so               -> libspdiag.so
/usr/bin/ubdiag            -> /usr/bin/spdiag
/etc/ubdiag                -> /etc/spdiag
UbDiagConfig.cmake         -> SpDiagConfig.cmake
ubdiag_shm*                -> spdiag_shm*
```

如果只改 `GIT_REPOSITORY`，L0 会因为头文件和宏名变化而失败，L1 会因为 CMake package、target、CLI 和动态库名称变化而失败。

## 3. 开始开发前先固定两个 SHA

公开仓上传完成后先记录 SpDiag 的完整提交：

```bash
SPDIAG_SHA=$(git ls-remote \
  https://gitcode.com/openeuler/spdiag.git \
  refs/heads/master | awk '{print $1}')

test "${#SPDIAG_SHA}" -eq 40
echo "SPDIAG_SHA=${SPDIAG_SHA}"
```

Mooncake 修改完成后也要记录完整提交：

```bash
MOONCAKE_SHA=$(git rev-parse HEAD)
test "${#MOONCAKE_SHA}" -eq 40
test -z "$(git status --porcelain)"
echo "MOONCAKE_SHA=${MOONCAKE_SHA}"
```

`MOONCAKE_SPDIAG_GIT_TAG` 必须固定为公开仓的 40 位 SHA，不应直接填写浮动的 `master`。

## 4. SpDiag 公开仓前置检查

Mooncake 修改前，先确认公开仓确实是完成改名后的源码：

```bash
git clone https://gitcode.com/openeuler/spdiag.git spdiag-public-check
git -C spdiag-public-check checkout --detach "$SPDIAG_SHA"
test -f spdiag-public-check/include/spdiag/auto_perf.h
grep -q SPDIAG_DISABLE spdiag-public-check/include/spdiag/perf_point.h
grep -q 'project(SpDiag' spdiag-public-check/CMakeLists.txt
grep -q 'add_executable(spdiag' spdiag-public-check/src/cli/CMakeLists.txt
grep -q 'SpDiagConfig.cmake' spdiag-public-check/CMakeLists.txt
test -z "$(git -C spdiag-public-check status --porcelain)"
```

预期公开接口为：

```text
头文件：include/spdiag/
Mock宏：SPDIAG_DISABLE
CMake包：SpDiag
CMake目标：SpDiag::spdiag_lib
CLI：spdiag
动态库：libspdiag.so
配置：/etc/spdiag/spdiag.conf
```

## 5. Mooncake 代码影响范围

当前基线共涉及 22 个文件：8 个构建/打包文件、12 个业务代码文件、2 个文档文件。

### 5.1 中央 CMake 解析器

`mooncake-common/FindUbDiag.cmake` 建议重命名为 `mooncake-common/FindSpDiag.cmake`。

关键位置：

| 基线行号 | 当前职责 | 迁移要求 |
|---|---|---|
| 8-20 | 开关、manifest、active layer | 改为 `MOONCAKE_ENABLE_SPDIAG` 和 `MOONCAKE_SPDIAG_*` |
| 23-54 | L0 FetchContent 和 Mock target | 改公开仓、完整 SHA、`SPDIAG_DISABLE`、`SpDiag::spdiag_lib` |
| 58-73 | L1 package 和共享库检查 | 改为 `find_package(SpDiag)` 和 `libspdiag.so` |
| 95-116 | 共享库位置和能力检查 | 检查 `SPDIAG_ENABLE_PERCENTILE/PERFLOG` |
| 118-131 | CLI 查找 | 查找 `spdiag` |
| 139-167 | CLI/动态库 RPM 身份比较 | 比较 SpDiag CLI 与 `libspdiag.so` |
| 169-184 | 配置、manifest 和状态输出 | 使用 `/etc/spdiag` 和 SpDiag 文案 |

应形成的核心逻辑：

```cmake
option(MOONCAKE_ENABLE_SPDIAG
       "Use the system-installed SpDiag shared library and CLI" OFF)

set(MOONCAKE_SPDIAG_GIT_REPOSITORY
    "https://gitcode.com/openeuler/spdiag.git")
set(MOONCAKE_SPDIAG_GIT_TAG "<40位公开仓SHA>")

target_compile_definitions(mooncake_spdiag_mock INTERFACE SPDIAG_DISABLE)
add_library(SpDiag::spdiag_lib ALIAS mooncake_spdiag_mock)
```

L1 应使用：

```cmake
find_package(SpDiag CONFIG QUIET)
TARGET SpDiag::spdiag_lib
SPDIAG_ENABLE_PERCENTILE
SPDIAG_ENABLE_PERFLOG
```

建议同时将生成文件改为：

```text
mooncake_spdiag.env
MOONCAKE_SPDIAG_LAYER
MOONCAKE_SPDIAG_SYSTEM_LIBRARY
MOONCAKE_SPDIAG_SYSTEM_CLI
MOONCAKE_SPDIAG_SYSTEM_CONFIG
MOONCAKE_SPDIAG_ACTIVE_LAYER
MOONCAKE_SPDIAG_LIBRARY_DIR
```

### 5.2 CMake 消费端

| 文件 | 基线位置 | 修改内容 |
|---|---:|---|
| `mooncake-integration/CMakeLists.txt` | 117-119 | 包含 `FindSpDiag.cmake`，链接 `SpDiag::spdiag_lib` |
| `mooncake-p2p-store/CMakeLists.txt` | 8 | 传递 `MOONCAKE_SPDIAG_ACTIVE_LAYER/LIBRARY_DIR` |
| `mooncake-store/src/CMakeLists.txt` | 313-381 | 所有目标改链 `SpDiag::spdiag_lib` |
| `mooncake-transfer-engine/src/CMakeLists.txt` | 2、64 | 包含新解析器并链接新 target |
| `mooncake-transfer-engine/src/transport/kunpeng_transport/CMakeLists.txt` | 34 | UB transport 链接新 target |

### 5.3 P2P 和 RPM

`mooncake-p2p-store/build.sh` 的 17、27-28、42-43 行附近：

```text
UBDIAG_LAYER   -> SPDIAG_LAYER
UBDIAG_LIB_DIR -> SPDIAG_LIB_DIR
-lubdiag       -> -lspdiag
```

`scripts/build_rpm.sh` 的 61-65、100-108、198-215、365 行附近需要改为读取 `mooncake_spdiag.env`，并在 L1 复制：

```text
/usr/bin/spdiag
/usr/lib64/libspdiag.so*
/etc/spdiag/spdiag.conf
```

L0 RPM 不能包含上述文件，L1 RPM 才包含。

### 5.4 Mooncake 业务埋点

| 文件 | 基线位置 | 相关命中数/职责 |
|---|---:|---|
| `mooncake-integration/store/store_py.cpp` | 26-28、478-2868 | Python Store 打点，11 处关键命中 |
| `mooncake-store/benchmarks/stress_cluster_bench.cpp` | 527 | Mooncake benchmark 执行 `ubdiag clear` |
| `mooncake-store/include/master_perf.h` | 4-10 | master 的自动 PerfPoint 定义入口 |
| `mooncake-store/include/rpc_helper.h` | 46-101 | RPC 可选 PerfPoint |
| `mooncake-store/src/client_service.cpp` | 47-2819 | client service 打点 |
| `mooncake-store/src/file_storage.cpp` | 22-1289 | 文件存储打点 |
| `mooncake-store/src/master_service.cpp` | 3474-9023 | master service 打点 |
| `mooncake-store/src/real_client.cpp` | 47-7342 | 客户端核心链路，53 处关键命中 |
| `mooncake-store/src/rpc_service.cpp` | 344-739 | master RPC 打点 |
| `mooncake-store/src/storage_backend.cpp` | 52-2102 | SSD/offload 打点 |
| `mooncake-transfer-engine/src/transfer_metadata.cpp` | 30-153 | UB handshake 元数据打点 |
| `mooncake-transfer-engine/src/transport/kunpeng_transport/urma/urma_endpoint.cpp` | 23-1390 | URMA endpoint 打点 |

统一替换：

```cpp
#define UBDIAG_PERF_DEF_FILE  -> #define SPDIAG_PERF_DEF_FILE
#define UBDIAG_PROGRAM_NAME   -> #define SPDIAG_PROGRAM_NAME
#include "ubdiag/auto_perf.h" -> #include "spdiag/auto_perf.h"
UbDiag::PerfPoint             -> SpDiag::PerfPoint
UbDiag::PerfLevel             -> SpDiag::PerfLevel
system("ubdiag clear")        -> system("spdiag clear")
```

`mooncake_perf_points.def` 是 Mooncake 自己的业务点定义，文件名和 PerfKey 枚举无需改名。

### 5.5 文档

```text
docs/ubdiag_integration_guide.md -> docs/spdiag_integration_guide.md
docs/yh/log-reference.md
```

文档应解释 L0 使用源码头文件，L1 使用系统 SpDiag RPM，不要再描述 LinQuick UbDiag。

## 6. 推荐开发顺序

```mermaid
flowchart LR
    A["确认公开 SpDiag SHA"] --> B["重写 FindSpDiag.cmake"]
    B --> C["更新五个 CMake 消费端"]
    C --> D["更新 P2P 与 RPM"]
    D --> E["批量替换业务埋点"]
    E --> F["人工复核 benchmark 和核心链路"]
    F --> G["旧名称扫描"]
    G --> H["本地 L0/L1 配置门禁"]
    H --> I["245/247 UB 验证"]
```

不要先机械替换整个仓库再修编译错误。中央 target 和公开接口先稳定，业务代码才能得到准确编译反馈。

## 7. 提交前静态门禁

### 7.1 旧名称扫描

```bash
git grep -n -E 'UbDiag|UBDIAG|ubdiag' -- \
  ':!CHANGELOG*' ':!docs/*migration*'
```

业务代码、CMake 和打包脚本中应无输出。历史迁移说明如果保留旧名称，应有明确原因。

### 7.2 新身份检查

```bash
grep -n 'gitcode.com/openeuler/spdiag' mooncake-common/FindSpDiag.cmake
grep -n SPDIAG_DISABLE mooncake-common/FindSpDiag.cmake
grep -R 'SpDiag::spdiag_lib' mooncake-* --include='CMakeLists.txt'
grep -R 'spdiag/auto_perf.h' mooncake-* --include='*.cpp' --include='*.h'
grep -n 'spdiag clear' mooncake-store/benchmarks/stress_cluster_bench.cpp
bash -n mooncake-p2p-store/build.sh
bash -n scripts/build_rpm.sh
git diff --check
```

### 7.3 评审重点

1. 公开仓地址是否为 `openeuler/spdiag`。
2. 是否固定 40 位 SHA。
3. L0 是否只消费头文件并传播 `SPDIAG_DISABLE`。
4. L1 是否只接受系统 SpDiag package、CLI 和共享库。
5. L1 是否仍检查 P99 与 PerfLog 编译能力。
6. CLI 和共享库是否仍要求来自同版本 RPM。
7. P2P 是否改为 `-lspdiag`。
8. Mooncake benchmark 是否执行 `spdiag clear`。
9. RPM 是否只在 L1 包含 SpDiag 产物。

## 8. 245/247 环境与角色

| 节点 | 地址 | 角色 |
|---|---|---|
| 245 | `141.61.84.245` | Mooncake master、metadata、metrics/admin |
| 247 | `141.61.84.247` | Mooncake client、Mooncake `stress_cluster_bench` |

已有容器通常为：

```text
245: mooncake-ubdiag-pr13-node1
247: mooncake-ubdiag-pr13-node2
```

进入环境后先判断当前位置：

```bash
if [ -f /.dockerenv ]; then echo IN_CONTAINER; else echo ON_HOST; fi
uname -m
ulimit -Sl
ulimit -Hl
urma_admin show
```

验证应在专用容器内执行。已经在容器里时不要再次执行 `docker exec`。

245 常用 URMA 源码路径：

```text
/opt/mooncake-offline-sources/urma
```

247 曾使用：

```text
/home/q00913006/project/mooncake-ubdiag-offline-bundle/source-downloads/urma
```

实际执行前必须检查：

```bash
test -f "$URMA_SRC/src/urma/lib/urma/CMakeLists.txt"
test -f "$MOONCAKE_SRC/extern/pybind11/CMakeLists.txt"
```

## 9. 两台机器共同准备

同事需要先把修改后的 Mooncake 分支拉到两台机器，并确保完整 SHA 相同：

```bash
export MOONCAKE_SRC=/home/q00913006/project/mooncake-spdiag-verify
export SPDIAG_REPO=https://gitcode.com/openeuler/spdiag.git
export SPDIAG_SHA=<公开仓40位SHA>
export MOONCAKE_SHA=<Mooncake修改分支40位SHA>

test "$(git -C "$MOONCAKE_SRC" rev-parse HEAD)" = "$MOONCAKE_SHA"
test -z "$(git -C "$MOONCAKE_SRC" status --porcelain)"
git ls-remote "$SPDIAG_REPO" refs/heads/master | grep -q "^${SPDIAG_SHA}"
```

禁止复用旧 `build_mock`、`build_system` 或旧 CMakeCache。迁移涉及 package 和 target 改名，旧缓存可能制造假成功。

## 10. L0 Mock 编译

245、247 分别设置自己的 `URMA_SRC`，然后执行：

```bash
cd "$MOONCAKE_SRC"
cmake -E remove_directory build_spdiag_l0

cmake -S . -B build_spdiag_l0 -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
  -DWITH_STORE_RUST=OFF -DWITH_STORE_GO=OFF -DWITH_EP=OFF \
  -DBUILD_BENCHMARK=ON -DBUILD_UNIT_TESTS=OFF \
  -DUSE_CUDA=OFF -DUSE_REDIS=OFF -DUSE_ETCD=OFF \
  -DSTORE_USE_ETCD=OFF -DUSE_HTTP=ON -DUSE_UB=ON \
  -DURMA_LIBRARY=/usr/lib64/liburma.so \
  -DFETCHCONTENT_SOURCE_DIR_URMA="$URMA_SRC" \
  -DMOONCAKE_ENABLE_SPDIAG=OFF \
  -DMOONCAKE_SPDIAG_GIT_REPOSITORY="$SPDIAG_REPO" \
  -DMOONCAKE_SPDIAG_GIT_TAG="$SPDIAG_SHA" \
  2>&1 | tee configure_spdiag_l0.log

cmake --build build_spdiag_l0 --parallel 64 \
  --target mooncake_master mooncake_client stress_cluster_bench \
  2>&1 | tee build_spdiag_l0.log
```

### 10.1 L0 源码与编译宏证据

```bash
git -C build_spdiag_l0/_deps/spdiag-src rev-parse HEAD
git -C build_spdiag_l0/_deps/spdiag-src status --porcelain
grep -m1 SPDIAG_DISABLE build_spdiag_l0/compile_commands.json
cat build_spdiag_l0/mooncake_spdiag.env
```

预期：

```text
HEAD 等于 SPDIAG_SHA
源码工作树无输出
编译命令含 -DSPDIAG_DISABLE
MOONCAKE_SPDIAG_LAYER=mock
```

### 10.2 L0 ELF 证据

```bash
ELFS=(
  build_spdiag_l0/mooncake-store/src/mooncake_master
  build_spdiag_l0/mooncake-store/src/mooncake_client
  build_spdiag_l0/mooncake-store/benchmarks/stress_cluster_bench
)

for elf in "${ELFS[@]}"; do
  echo "=== $elf ==="
  file "$elf"
  readelf -d "$elf" | grep NEEDED
  if readelf -d "$elf" | grep -Eq 'lib(sp|ub)diag'; then
    echo "FATAL: L0 contains diagnostic runtime dependency"
    exit 1
  fi
  echo "NO_DIAG_RUNTIME_DEPENDENCY"
done
```

这里的成功证据是机器打开 ELF 后没有发现 `libspdiag` 或 `libubdiag`，不是单独打印一个人为 PASS 标志。

## 11. Mooncake benchmark 的定义

本任务中的 benchmark 专指 Mooncake 仓库构建出的：

```text
$BUILD/mooncake-store/benchmarks/stress_cluster_bench
```

它驱动真实 Mooncake master/client、metadata 和 UB transport 数据链路。SpDiag demo、SpDiag benchmark 或只运行 `spdiag show` 都不能替代它。

固定参数：

```text
protocol=ub
device=bonding_dev_0
value_size=4 MiB
num_keys=1000
write_threads=32
write_batch=32
read_threads=16
read_batch=16
read_duration=20s
MC_URMA_ACTIVE_PORT=0
```

## 12. L0 运行时验证

L0 使用以下端口：

```text
master RPC=45060
metadata HTTP=48020
metrics/admin=49010
client=48980
```

### 12.1 245 启动 L0 master

```bash
cd "$MOONCAKE_SRC"
export BUILD="$MOONCAKE_SRC/build_spdiag_l0"
export OUT="$MOONCAKE_SRC/verify_results/spdiag_l0_245"
mkdir -p "$OUT"
find /dev/shm -maxdepth 1 -name 'spdiag_shm*' -printf '%f\n' | sort > "$OUT/shm.before"

nohup env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  LD_LIBRARY_PATH="$BUILD/mooncake-store/src:$BUILD/mooncake-transfer-engine/src:$BUILD/mooncake-common:/usr/lib64" \
  "$BUILD/mooncake-store/src/mooncake_master" \
  --global_file_segment_size=9223372036854775807 \
  --enable_http_metadata_server=true \
  --http_metadata_server_host=0.0.0.0 \
  --http_metadata_server_port=48020 \
  --default_kv_lease_ttl=300000 \
  --enable_offload=false --port=45060 --metrics_port=49010 \
  > "$OUT/master.log" 2>&1 &

echo $! > "$OUT/master.pid"
sleep 8
kill -0 "$(cat "$OUT/master.pid")"
ss -lnt | grep -E ':45060|:48020|:49010'
curl --noproxy '*' -sS -o /dev/null -w 'METADATA_HTTP=%{http_code}\n' \
  http://127.0.0.1:48020/metadata
```

HTTP 返回 400 或 404 表示服务可达但请求缺少 key；`000` 才是未连接。

### 12.2 247 启动 L0 client

```bash
cd "$MOONCAKE_SRC"
export BUILD="$MOONCAKE_SRC/build_spdiag_l0"
export OUT="$MOONCAKE_SRC/verify_results/spdiag_l0_247"
mkdir -p "$OUT"
find /dev/shm -maxdepth 1 -name 'spdiag_shm*' -printf '%f\n' | sort > "$OUT/shm.before"

nohup env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  MC_URMA_ACTIVE_PORT=0 \
  NO_PROXY=141.61.84.245,141.61.84.247,127.0.0.1,localhost \
  LD_LIBRARY_PATH="$BUILD/mooncake-store/src:$BUILD/mooncake-transfer-engine/src:$BUILD/mooncake-common:/usr/lib64" \
  "$BUILD/mooncake-store/src/mooncake_client" \
  --metadata_server=http://141.61.84.245:48020/metadata \
  --master_server_address=141.61.84.245:45060 \
  --host=141.61.84.247 --global_segment_size=8589934592 \
  --threads=16 --protocol=ub --port=48980 \
  --device_names=bonding_dev_0 \
  > "$OUT/client.log" 2>&1 &

echo $! > "$OUT/client.pid"
sleep 8
kill -0 "$(cat "$OUT/client.pid")"
ss -lnt | grep ':48980'
grep -E 'Using active port|manually specified port' "$OUT/client.log"
```

### 12.3 247 运行 Mooncake L0 写入 benchmark

```bash
BENCH="$BUILD/mooncake-store/benchmarks/stress_cluster_bench"
MC_URMA_ACTIVE_PORT=0 "$BENCH" \
  --scenario=segment_write --role=writer \
  --metadata-server=http://141.61.84.245:48020/metadata \
  --master-server=141.61.84.245:45060 --master_admin_port=49010 \
  --local-hostname=141.61.84.247 \
  --protocol=ub --device-name=bonding_dev_0 \
  --global-segment-size=0 --local-buffer-size=536870912 \
  --value-size=4194304 --num-keys=1000 \
  --num_threads=32 --batch-size=32 --verify=false \
  2>&1 | tee "$OUT/write.log"

grep -E '1000 succeeded, 0 failed|All segments write complete' "$OUT/write.log"
```

### 12.4 247 运行 Mooncake L0 读取 benchmark

```bash
MC_URMA_ACTIVE_PORT=0 "$BENCH" \
  --scenario=segment_read --role=reader \
  --metadata-server=http://141.61.84.245:48020/metadata \
  --master-server=141.61.84.245:45060 --master_admin_port=49010 \
  --local-hostname=141.61.84.247 \
  --protocol=ub --device-name=bonding_dev_0 \
  --global-segment-size=0 --local-buffer-size=1073741824 \
  --value-size=4194304 --num-keys=1000 \
  --num_threads=16 --batch-size=16 --duration=20 --verify=false \
  2>&1 | tee "$OUT/read.log"

grep -E 'FINAL SUMMARY|Total queries|Throughput|P50|P99' "$OUT/read.log"
grep -Eq 'Total queries:[[:space:]]+[1-9][0-9]* \(failed: 0\)' "$OUT/read.log"
```

### 12.5 L0 SHM 与错误门禁

245、247分别执行：

```bash
find /dev/shm -maxdepth 1 -name 'spdiag_shm*' -printf '%f\n' | sort > "$OUT/shm.after"
cmp "$OUT/shm.before" "$OUT/shm.after"
! grep -Eqi 'segmentation fault|core dumped|Failed to setup|No available RNIC' "$OUT"/*.log
```

`cmp` 无输出且退出码为 0，证明 Mooncake L0 没有创建或删除 SpDiag SHM。

## 13. 准备 L1 SpDiag RPM

L1 不从 Mooncake 内部编译真实 SpDiag。应先从公开仓同一 SHA 构建 SpDiag RPM，并在 245/247 安装同一批 runtime 和 devel RPM。

完整功能出包命令：

```bash
git clone https://gitcode.com/openeuler/spdiag.git spdiag-rpm-source
git -C spdiag-rpm-source checkout --detach "$SPDIAG_SHA"
cd spdiag-rpm-source
bash build.sh package -p on -s on -m on -o on -k on
```

Mooncake 联合验证强制依赖 P99 和 PerfLog。MemPoint、OB Memory、OB Cache 可以包含在 RPM 中，但它们属于 SpDiag 自身功能，不是 Mooncake benchmark 的通过条件。

在两台容器安装同一批包：

```bash
RUNTIME_RPM=$(find . -maxdepth 1 -type f \
  -name 'spdiag-[0-9]*.aarch64.rpm' -print -quit)
DEVEL_RPM=$(find . -maxdepth 1 -type f \
  -name 'spdiag-devel-*.aarch64.rpm' -print -quit)

test -n "$RUNTIME_RPM"
test -n "$DEVEL_RPM"
rpm -qp "$RUNTIME_RPM" "$DEVEL_RPM"
rpm -Uvh --test --replacepkgs "$RUNTIME_RPM" "$DEVEL_RPM"
rpm -Uvh --replacepkgs "$RUNTIME_RPM" "$DEVEL_RPM"
/sbin/ldconfig

rpm -q spdiag spdiag-devel
spdiag --version
rpm -qf /usr/bin/spdiag
rpm -qf "$(readlink -f /usr/lib64/libspdiag.so)"
test -f /usr/lib64/cmake/SpDiag/SpDiagConfig.cmake
ldd /usr/bin/spdiag | grep '/usr/lib64/libspdiag.so'
```

上述规则只选择名称紧跟数字版本的 runtime RPM 和 `spdiag-devel` RPM，不会选择 debuginfo、debugsource、static 或 src RPM。仍应以 `rpm -qp` 输出作为安装前的机器证据。

## 14. L1 编译

245、247分别执行：

```bash
cd "$MOONCAKE_SRC"
cmake -E remove_directory build_spdiag_l1

cmake -S . -B build_spdiag_l1 -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DWITH_STORE=ON -DWITH_TE=ON -DWITH_P2P_STORE=OFF \
  -DWITH_STORE_RUST=OFF -DWITH_STORE_GO=OFF -DWITH_EP=OFF \
  -DBUILD_BENCHMARK=ON -DBUILD_UNIT_TESTS=OFF \
  -DUSE_CUDA=OFF -DUSE_REDIS=OFF -DUSE_ETCD=OFF \
  -DSTORE_USE_ETCD=OFF -DUSE_HTTP=ON -DUSE_UB=ON \
  -DURMA_LIBRARY=/usr/lib64/liburma.so \
  -DFETCHCONTENT_SOURCE_DIR_URMA="$URMA_SRC" \
  -DMOONCAKE_ENABLE_SPDIAG=ON \
  2>&1 | tee configure_spdiag_l1.log

cmake --build build_spdiag_l1 --parallel 64 \
  --target mooncake_master mooncake_client stress_cluster_bench \
  2>&1 | tee build_spdiag_l1.log
```

### 14.1 L1 配置与 ELF 门禁

```bash
cat build_spdiag_l1/mooncake_spdiag.env
grep -E 'SpDiag: Layer 1|libspdiag|spdiag' configure_spdiag_l1.log

ELFS=(
  build_spdiag_l1/mooncake-store/src/mooncake_master
  build_spdiag_l1/mooncake-store/src/mooncake_client
  build_spdiag_l1/mooncake-store/benchmarks/stress_cluster_bench
)

for elf in "${ELFS[@]}"; do
  echo "=== $elf ==="
  readelf -d "$elf" | grep 'NEEDED.*libspdiag.so.0'
  ldd "$elf" | grep 'libspdiag.so.0 => /usr/lib64/libspdiag.so.0'
  ! readelf -d "$elf" | grep -E 'libubdiag|ubdiag-build'
done
```

三个 Mooncake ELF 都需要检查，因为 master、client 和 benchmark 是三条不同的最终链接路径。

## 15. L1 运行时验证

L1 使用另一组端口，避免误连尚未退出的 L0 进程：

```text
master RPC=55060
metadata HTTP=58020
metrics/admin=59010
client=58980
```

245、247在专用验证容器内分别执行：

```bash
spdiag stop >/dev/null 2>&1 || true
spdiag start --perflog
spdiag status
test -e /dev/shm/spdiag_shm_default
```

随后按第 12 章相同方式启动 master、client 和 Mooncake benchmark，只替换：

```text
BUILD=build_spdiag_l1
45060 -> 55060
48020 -> 58020
49010 -> 59010
48980 -> 58980
输出目录 spdiag_l0_* -> spdiag_l1_*
```

不要让 245 使用 L1 master、247却使用 L0 client，也不要混用端口。

### 15.1 运行进程实际加载证据

245：

```bash
readlink -f /proc/$(cat "$OUT/master.pid")/exe
grep '/usr/lib64/libspdiag.so' /proc/$(cat "$OUT/master.pid")/maps
```

247：

```bash
readlink -f /proc/$(cat "$OUT/client.pid")/exe
grep '/usr/lib64/libspdiag.so' /proc/$(cat "$OUT/client.pid")/maps
```

这比单看 `ldd` 更强：`ldd` 证明未来会加载什么，`/proc/PID/maps` 证明运行中的进程实际加载了什么。

## 16. Mooncake benchmark 后的 SpDiag 数据证据

245 和 247 都要执行，分别证明 master 侧和 client/benchmark 侧打点：

```bash
export CSV_ROOT="$OUT/csv"
mkdir -p "$CSV_ROOT"/{show,detail,perflog,history,watch}

spdiag show | tee "$OUT/spdiag_show.log"
spdiag show --detail | tee "$OUT/spdiag_detail.log"
spdiag show --perflog | tee "$OUT/spdiag_perflog.log"

spdiag show --csv "$CSV_ROOT/show"
spdiag show --detail --csv "$CSV_ROOT/detail"
spdiag show --perflog --csv "$CSV_ROOT/perflog"
spdiag history --csv "$CSV_ROOT/history"

set +e
timeout 6 spdiag watch --interval 1000 --csv "$CSV_ROOT/watch"
WATCH_RC=$?
set -e
test "$WATCH_RC" -eq 0 -o "$WATCH_RC" -eq 124

find "$CSV_ROOT" -type f -name '*.csv' -size +0 -print
```

文本输出至少应出现：

```text
mooncake_master 或 mooncake_store
Ticks/Good/Bad/Total
P99/P999/P9999
PerfLog 数据或对应非空 CSV
```

CSV 仅仅“存在”不够，必须是非空文件，并包含 Mooncake 的 program、module 或 point 数据行。

## 17. L0/L1 benchmark 对照

必须保存两层相同参数下的结果：

| 指标 | L0 | L1 |
|---|---:|---:|
| 写入成功数 | 1000 | 1000 |
| 写入失败数 | 0 | 0 |
| 读取查询数 | >0 | >0 |
| 读取失败数 | 0 | 0 |
| Throughput | >0 | >0 |
| P50/P99 | 记录 | 记录 |
| SpDiag SHM | 无变化 | 存在 |
| ELF `libspdiag` | 无 | 有 |

L0 与 L1 吞吐不要求完全相等。集成验收关注功能正确、零失败和无异常明显退化；性能结论需要重复多轮并控制环境噪声后再下。

## 18. 常见失败及判断

### 18.1 L0 仍找到 `ubdiag/auto_perf.h`

说明 Mooncake 业务代码没有完成身份迁移，或者 FetchContent 拉到的不是改名后的 SpDiag SHA。

### 18.2 L0 ELF 出现 `libspdiag.so`

说明 mock target 没有被使用，或者某个 CMake 消费端直接链接了系统 SpDiag。

### 18.3 L1 `find_package(SpDiag)` 失败

检查：

```bash
rpm -q spdiag-devel
find /usr/lib64/cmake/SpDiag -maxdepth 1 -type f -print
grep -R 'SpDiag::spdiag_lib' /usr/lib64/cmake/SpDiag
```

### 18.4 L1 找到库但找不到 CLI

系统缺少 runtime RPM，或者 CLI 不在与库相同 prefix 的 `bin` 目录。

### 18.5 CLI 与动态库 RPM 身份不一致

不要绕过 Mooncake 的门禁。卸载混装版本，重新安装同一批 SpDiag runtime/devel RPM。

### 18.6 `No available RNIC`

先检查：

```bash
urma_admin show
echo "$MC_URMA_ACTIVE_PORT"
grep -E 'Using active port|manually specified port|Failed to open device' "$OUT/client.log"
```

245/247 当前验证惯例为 `bonding_dev_0` 和 `MC_URMA_ACTIVE_PORT=0`。

### 18.7 metadata 返回 400

对不带 key 的探活请求，400 可以表示 HTTP 服务已经监听。连接失败通常显示 `000` 或 curl 报无法连接。

### 18.8 `build: unknown`

从不包含 `.git` 的源码 tar 构建时可能出现。版本来源应由公开仓完整 SHA、源码包 SHA256 和 RPM EVR 共同记录，不能因此把正常源码包误判为缺代码。

### 18.9 旧 CMakeCache 导致仍显示 UbDiag

删除独立构建目录后重新配置，不要原地复用改名前的 build 目录。

## 19. 不应混淆的验证边界

Mooncake 联合验证负责证明：

```text
Mooncake PerfPoint
P99/P999/P9999
PerfLog
CSV
Mooncake master/client
Mooncake stress_cluster_bench
UB真实写读
```

SpDiag 的 MemPoint、Memstat、Cachestat 是 SpDiag 自身功能。它们可以包含在完整 RPM 中，但不能拿 SpDiag demo 的通过结果替代 Mooncake benchmark，也不应把 Mooncake benchmark 描述成 SpDiag 全功能验证。

## 20. 最终清理

每层验证完成后，只停止本次记录 PID 的进程：

```bash
kill -TERM "$(cat "$OUT/client.pid")" 2>/dev/null || true
kill -TERM "$(cat "$OUT/master.pid")" 2>/dev/null || true
```

L1 数据收集完成后：

```bash
spdiag stop
```

不要使用宽泛的 `killall` 删除其他人的进程，不要删除验证前已经存在且不属于本次任务的 SHM 或目录。

## 21. 最终验收报告模板

```text
Mooncake SHA: <40位SHA>
SpDiag public SHA: <40位SHA>
SpDiag RPM EVR: <VERSION-RELEASE.ARCH>

245: aarch64 / bonding_dev_0 ACTIVE / master
247: aarch64 / bonding_dev_0 ACTIVE / client + Mooncake stress_cluster_bench

L0:
- FetchContent SpDiag SHA matched
- SPDIAG_DISABLE present in real compile command
- master/client/stress_cluster_bench built
- all three ELF have no libspdiag/libubdiag dependency
- UB write 1000 succeeded, 0 failed
- UB read total queries > 0, failed 0, throughput > 0
- SpDiag SHM before/after unchanged

L1:
- same SpDiag runtime/devel RPM installed on both nodes
- SpDiagConfig.cmake and SpDiag::spdiag_lib found
- master/client/stress_cluster_bench link system libspdiag.so
- running master/client maps contain /usr/lib64/libspdiag.so
- UB write 1000 succeeded, 0 failed
- UB read total queries > 0, failed 0, throughput > 0
- Mooncake PerfPoint/P99/PerfLog visible
- summary/detail/perflog/history/watch CSV files non-empty

Conclusion: Mooncake -> SpDiag two-layer migration PASS/FAIL
Failed gate: <如失败，填写第一个真实失败点>
Evidence directories: <245路径> / <247路径>
```

## 22. 一句话交接说明

本次迁移不是简单替换依赖仓库，而是将 Mooncake 的源码 Mock、CMake package、链接目标、业务 PerfPoint、CLI、动态库、配置和 RPM 交付全部迁移到 SpDiag 身份，并通过 245 master、247 client 和 Mooncake `stress_cluster_bench` 的两层真实 UB 写读证明迁移有效。
