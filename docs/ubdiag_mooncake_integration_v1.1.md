# Mooncake UbDiag 集成重构方案 v1.1（校正版）

> **基于**：atomgit liusiyu60/ubdiag master (d7e53c6) + GitHub LinQuickDev/Mooncake supercache (2300894)
> **基线分支**：qinyufei63/Mooncake `supercache_dev_extern&mock` (d8537ab6)
> **v1.0 → v1.1 修正**：全量代码读取后修正了 6 处遗漏/误判
> **日期**：2026-07-15

---

## v1.0 → v1.1 修正记录

| # | v1.0 的判断 | v1.1 修正（基于全量代码读取） |
|---|------------|---------------------------|
| 1 | "删除 mooncake-common/ubdiag-mock/" | **保留**。mock 由 FindUbDiag.cmake 引用 `mooncake-common/ubdiag-mock` 目录，删了会断 Layer 3 fallback。改为保留目录但确保和真实 ubdiag 接口同步 |
| 2 | "mock 需要补 global_perf_t" | **不需要**。全量搜索 Mooncake 代码，`global_perf` 零命中，没有跨线程打点 |
| 3 | "只改 mooncake-store/src/CMakeLists.txt" | **5 个子模块都 include FindUbDiag.cmake**：mooncake-store/src、mooncake-integration、mooncake-transfer-engine/src、kunpeng_transport、mooncake-p2p-store（经 build.sh）。但 FindUbDiag.cmake 有 `if(TARGET UbDiag::ubdiag_lib) return()` 幂等保护，只需改 FindUbDiag.cmake 一处 |
| 4 | "p2p-store 不管" | **p2p-store/build.sh 依赖 `MOONCAKE_UBDIAG_ACTIVE_LAYER`** 变量决定链接路径。FetchContent 模式下路径从 `extern/ubdiag_build` 变成 `_deps/ubdiag-build`，必须适配 |
| 5 | "ubdiag install 规则自动生效" | **确认**：ubdiag CMakeLists 有 6 条 install 规则（L163-212），覆盖库/头文件/CLI/配置。add_subdirectory 后自动生效，无需 Mooncake 侧配置 |
| 6 | "perf_points.def 跟 ubdiag 走" | **不跟**。`mooncake_perf_points.def` 在 `mooncake-integration/store/` 下，是 Mooncake 自己的文件。每个 .cpp 通过 `#define UBDIAG_PERF_DEF_FILE "mooncake_perf_points.def"` 引用 |

---

## 一、现状全量分析（基于代码实读）

### 1.1 引用 ubdiag 的完整文件清单（15 个文件，5 个子模块）

| 子模块 | 文件 | 引用方式 | 改动需求 |
|--------|------|---------|:---:|
| **mooncake-store** | `include/master_perf.h` | `#include "ubdiag/auto_perf.h"` + `#define UBDIAG_PROGRAM_NAME` | 不改 |
| | `include/rpc_helper.h` | `UbDiag::PerfPoint` + `PerfLevel::SUB_SYSTEM` | 不改 |
| | `src/CMakeLists.txt:251` | `include(FindUbDiag.cmake)` + `target_link_libraries(... UbDiag::ubdiag_lib)` | 不改 |
| | `src/client_service.cpp` | 4 处 `PerfPoint` 打点 | 不改 |
| | `src/master_service.cpp` | 6 处打点 | 不改 |
| | `src/real_client.cpp` | 4 处打点 | 不改 |
| | `src/rpc_service.cpp` | 多处 `PerfKey::MASTER_RPC_*` | 不改 |
| **mooncake-integration** | `store/store_py.cpp` | 4 处打点 | 不改 |
| | `store/mooncake_perf_points.def` | 打点定义（~40 个 PerfKey） | 不改 |
| | `CMakeLists.txt:104` | `include(FindUbDiag.cmake)` | 不改 |
| **mooncake-transfer-engine** | `src/CMakeLists.txt:2` | `include(FindUbDiag.cmake)` + link | 不改 |
| | `src/transfer_metadata.cpp` | 2 处打点 | 不改 |
| **kunpeng_transport** | `CMakeLists.txt:34` | link `UbDiag::ubdiag_lib` | 不改 |
| | `urma/urma_endpoint.cpp` | 4 处打点 | 不改 |
| **mooncake-p2p-store** | `CMakeLists.txt:12` | 传 `${MOONCAKE_UBDIAG_ACTIVE_LAYER}` 给 build.sh | **需适配** |
| | `build.sh` | 根据 layer 选 `-lubdiag` 路径 | **需适配** |

**结论**：15 个文件中**只有 2 个需要改**（p2p-store 的 CMakeLists + build.sh），其余 13 个完全不动。

### 1.2 现有三层 FindUbDiag.cmake 逻辑（239 行，已全部读完）

```
Layer 1 (submodule):  extern/ubdiag/CMakeLists.txt 存在？
  → add_subdirectory + 编译选项传递 + include 路径修复 + CLI 目标 + RPM manifest
  → return

Layer 2 (system):     find_package(UbDiag QUIET NO_DEFAULT_PATH)
  → 查找 /usr/lib64/cmake 等 + CLI 查找 + 配置查找 + RPM manifest
  → return

Layer 3 (mock):       add_library(ubdiag_mock INTERFACE)
  → target_include_directories(... mooncake-common/ubdiag-mock)
  → add_library(UbDiag::ubdiag_lib ALIAS ubdiag_mock)
  → RPM manifest("mock")
```

**关键变量**：
- `MOONCAKE_UBDIAG_ACTIVE_LAYER`：被 FindUbDiag.cmake 设置（"submodule"/"system"/"mock"），被 p2p-store/CMakeLists.txt 传给 build.sh
- `MOONCAKE_UBDIAG_RPM_MANIFEST`：RPM 打包用
- `MOONCAKE_UBDIAG_BUILD_CLI`：是否构建 CLI 目标

### 1.3 现有 .gitmodules

```
[submodule "extern/pybind11"]     ← Mooncake 原有，保留
[submodule "extern/yalantinglibs"] ← Mooncake 原有，保留
[submodule "extern/ubdiag"]        ← 我们的，要删除
  url = atomgit.com/liusiyu60/ubdiag
  branch = fix/shm-probe-fastpath
```

---

## 二、重构目标（v1.1 修正版）

### 2.1 架构变化

```
旧（三层 fallback）                    新（两层 + FetchContent）
┌─────────────────────┐               ┌──────────────────────┐
│ Layer 1: submodule   │               │ Layer 0: Mock(默认)   │
│  extern/ubdiag/      │    ──→       │  CMake 动态生成        │
│  add_subdirectory    │               │  mooncake-common/     │
├─────────────────────┤               │  ubdiag-mock/         │
│ Layer 2: system      │               ├──────────────────────┤
│  find_package(UbDiag)│               │ Layer 1: FetchContent │
├─────────────────────┤               │  -DMOONCAKE_ENABLE_   │
│ Layer 3: mock        │               │  UBDIAG=ON 时触发     │
│  ubdiag-mock/        │               │  拉源码+编译+安装     │
└─────────────────────┘               └──────────────────────┘
```

### 2.2 5 个具体目标

| # | 目标 | 验收标准 |
|---|------|---------|
| G1 | 去掉 submodule | `.gitmodules` 删除 ubdiag 条目；`extern/ubdiag/` 删除 |
| G2 | 去掉系统路径查找 | FindUbDiag.cmake 不再调 `find_package(UbDiag QUIET)` |
| G3 | FetchContent 拉取 | `cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON` 自动拉源码 |
| G4 | 默认 mock（开箱即编译） | `cmake ..`（不传选项）用 mock 编译通过 |
| G5 | 自动安装库 + CLI | `sudo cmake --install .` 安装 libubdiag.so + ubdiag CLI |
| G6 | **p2p-store 适配**（v1.1 新增） | p2p-store/build.sh 能正确识别 FetchContent 模式并链接 |

---

## 三、改动清单（精确到文件和行号）

### 3.1 重写文件（1 个）

**`mooncake-common/FindUbDiag.cmake`**（239 行 → ~100 行）

```cmake
# FindUbDiag.cmake v2 — 两层集成：mock(默认) / FetchContent(可选)
#
# Usage:
#   include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)
#   target_link_libraries(your_target PRIVATE UbDiag::ubdiag_lib)
#
# Options:
#   -DMOONCAKE_ENABLE_UBDIAG=ON   启用真实 ubdiag(FetchContent 拉源码+编译+安装)
#   -DMOONCAKE_ENABLE_UBDIAG=OFF  (默认) 使用 mock 空函数

if(TARGET UbDiag::ubdiag_lib)
  return()
endif()

option(MOONCAKE_ENABLE_UBDIAG "编译 ubdiag 真实库(否则用 mock 空函数)" OFF)
option(MOONCAKE_UBDIAG_GIT_URL "ubdiag 仓库地址"
       "https://atomgit.com/liusiyu60/ubdiag.git")
set(MOONCAKE_UBDIAG_GIT_TAG "master" CACHE STRING "ubdiag 版本(tag/branch/commit)")

# 离线模式:指定本地 ubdiag 源码目录
set(MOONCAKE_UBDIAG_SOURCE_DIR "" CACHE PATH
    "本地 ubdiag 源码目录(离线用,为空则 FetchContent 从 git 拉)")

# ===== 函数:写 RPM manifest(保持 p2p-store/build.sh 兼容) =====
function(_mooncake_ubdiag_write_layer layer cli_path library_path config_path)
  set(_manifest "${CMAKE_BINARY_DIR}/mooncake_ubdiag_rpm.env")
  file(WRITE "${_manifest}" "MOONCAKE_UBDIAG_LAYER=${layer}\n")
  file(APPEND "${_manifest}" "MOONCAKE_UBDIAG_CLI_PATH=${cli_path}\n")
  file(APPEND "${_manifest}" "MOONCAKE_UBDIAG_LIBRARY_PATH=${library_path}\n")
  file(APPEND "${_manifest}" "MOONCAKE_UBDIAG_CONFIG_PATH=${config_path}\n")
  set(MOONCAKE_UBDIAG_RPM_MANIFEST "${_manifest}"
      CACHE FILEPATH "UbDiag RPM manifest" FORCE)
  set(MOONCAKE_UBDIAG_ACTIVE_LAYER "${layer}"
      CACHE STRING "Active UbDiag layer: vendored or mock" FORCE)
endfunction()

# ===== Layer 0: Mock(默认) =====
if(NOT MOONCAKE_ENABLE_UBDIAG)
  add_library(ubdiag_mock INTERFACE)
  target_include_directories(ubdiag_mock INTERFACE
      ${CMAKE_SOURCE_DIR}/mooncake-common/ubdiag-mock)
  add_library(UbDiag::ubdiag_lib ALIAS ubdiag_mock)
  _mooncake_ubdiag_write_layer("mock" "" "" "")
  message(STATUS "UbDiag: 使用 mock(空函数)。-DMOONCAKE_ENABLE_UBDIAG=ON 启用真实 ubdiag。")
  return()
endif()

# ===== Layer 1: FetchContent(可选,拉源码+编译) =====
include(FetchContent)

if(MOONCAKE_UBDIAG_SOURCE_DIR AND EXISTS "${MOONCAKE_UBDIAG_SOURCE_DIR}/CMakeLists.txt")
  # 离线:用本地源码
  FetchContent_Declare(ubdiag SOURCE_DIR ${MOONCAKE_UBDIAG_SOURCE_DIR})
else()
  # 在线:从 git 拉
  FetchContent_Declare(ubdiag
      GIT_REPOSITORY ${MOONCAKE_UBDIAG_GIT_URL}
      GIT_TAG ${MOONCAKE_UBDIAG_GIT_TAG})
endif()

# ubdiag 子项目的编译选项(只编 PerfPoint/P99/PerfLog,跳过 OB/eBPF 依赖)
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(UBDIAG_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(ENABLE_PERCENTILE ON CACHE BOOL "" FORCE)
set(ENABLE_PERFLOG ON CACHE BOOL "" FORCE)
# 裁剪:不需要 OB Memstat/Cachestat/MemPoint(需要 libbpf-devel/bpftool)
set(ENABLE_OB_MEMORY OFF CACHE BOOL "" FORCE)
set(ENABLE_OB_CACHE OFF CACHE BOOL "" FORCE)
set(ENABLE_MEMPOINT OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(ubdiag)

# 修复 include 路径(ubdiag 用 CMAKE_SOURCE_DIR,add_subdirectory 后指向 Mooncake 根)
if(TARGET ubdiag_lib)
  set(_ubdiag_src ${ubdiag_SOURCE_DIR})
  target_include_directories(ubdiag_lib PUBLIC
      $<BUILD_INTERFACE:${_ubdiag_src}/include>
      $<INSTALL_INTERFACE:include>)

  # CLI 目标
  if(TARGET ubdiag)
    add_custom_target(mooncake_ubdiag_cli ALL DEPENDS ubdiag)
  endif()

  add_library(UbDiag::ubdiag_lib ALIAS ubdiag_lib)
  _mooncake_ubdiag_write_layer(
      "vendored"
      "${ubdiag_BINARY_DIR}/src/cli/ubdiag"
      "${ubdiag_BINARY_DIR}/src/sdk/libubdiag.so"
      "${_ubdiag_src}/config/ubdiag.conf.example")
  message(STATUS "UbDiag: FetchContent 拉取并编译(CLI=已启用)")
endif()
```

### 3.2 适配文件（2 个）

**`mooncake-p2p-store/build.sh`**（改 `case` 的路径）

```bash
# 旧:
case "$UBDIAG_LAYER" in
    submodule)
        UBDIAG_LIB_DIR="$BUILD_DIR/extern/ubdiag_build/src/sdk"
        EXT_LDFLAGS+=" -L$UBDIAG_LIB_DIR -lubdiag"
        ;;
    system)
        EXT_LDFLAGS+=" -lubdiag"
        ;;
    mock)
        echo "P2P Store: using UbDiag mock; skipping -lubdiag"
        ;;
    *)
        echo "Error: Unknown UbDiag layer: $UBDIAG_LAYER"
        ;;
esac

# 新:
case "$UBDIAG_LAYER" in
    vendored)
        UBDIAG_LIB_DIR="$BUILD_DIR/_deps/ubdiag-build/src/sdk"
        EXT_LDFLAGS+=" -L$UBDIAG_LIB_DIR -lubdiag"
        ;;
    mock)
        echo "P2P Store: using UbDiag mock; skipping -lubdiag"
        ;;
    *)
        echo "Error: Unknown UbDiag layer: $UBDIAG_LAYER"
        ;;
esac
```

> **变化**：`submodule`/`system` 两个 case 合并为 `vendored`（因为不再区分 submodule 和 system，都是 FetchContent 编译的）。路径从 `extern/ubdiag_build` 改为 `_deps/ubdiag-build`（FetchContent 的默认 build 目录）。

**`mooncake-p2p-store/CMakeLists.txt`**（不用改，它只是透传 `${MOONCAKE_UBDIAG_ACTIVE_LAYER}`，变量名没变）

### 3.3 删除项（2 个）

| 删除 | 原因 |
|------|------|
| `.gitmodules` 里的 `[submodule "extern/ubdiag"]` 条目 | 不再用 submodule |
| `extern/ubdiag/` 目录（git submodule） | 不再用 submodule |

### 3.4 不改的文件（13 个 + mock 目录）

| 文件/目录 | 为什么不改 |
|-----------|-----------|
| `mooncake-common/ubdiag-mock/` | FindUbDiag.cmake Layer 0 引用它，保留 |
| `mooncake-common/ubdiag-mock/ubdiag/auto_perf.h` | mock 头文件，接口和真实 ubdiag 对齐（已确认无 global_perf 需求） |
| `mooncake-store/include/master_perf.h` | `#include "ubdiag/auto_perf.h"` 接口不变 |
| `mooncake-store/include/rpc_helper.h` | `UbDiag::PerfPoint` 用法不变 |
| `mooncake-store/src/*.cpp`（4 个） | 插桩代码不变 |
| `mooncake-integration/store/*`（2 个） | 插桩代码 + def 文件不变 |
| `mooncake-transfer-engine/src/*`（2 个） | 插桩代码不变 |
| `kunpeng_transport/*`（2 个） | 插桩代码不变 |
| 5 个子模块的 CMakeLists.txt（不含 p2p-store） | `include(FindUbDiag.cmake)` + `target_link_libraries(... UbDiag::ubdiag_lib)` 不变 |

---

## 四、用户使用流程

### 4.1 默认（mock，零依赖）

```bash
git clone https://github.com/LinQuickDev/Mooncake.git   # 不需要 --recursive
cd Mooncake && mkdir build && cd build
cmake ..                           # 自动用 mock(空函数打点)
make -j$(nproc)                    # 正常编译,PerfPoint 是 no-op
```

### 4.2 启用真实 ubdiag

```bash
git clone https://github.com/LinQuickDev/Mooncake.git
cd Mooncake && mkdir build && cd build
cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON   # FetchContent 拉 ubdiag + 编译
make -j$(nproc)                         # Mooncake + ubdiag(含 CLI)
sudo cmake --install .                  # 安装 libubdiag.so + ubdiag CLI

ubdiag start
./mooncake_store ...
ubdiag show
ubdiag stop
```

### 4.3 离线环境

```bash
# 提前下载 ubdiag 源码
git clone https://atomgit.com/liusiyu60/ubdiag.git /path/to/ubdiag

# 编译 Mooncake 时指定本地路径
cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON \
         -DMOONCAKE_UBDIAG_SOURCE_DIR=/path/to/ubdiag
```

---

## 五、技术约束与风险（v1.1 修正）

### 5.1 CMake 变量冲突（已有解决方案）

ubdiag 的 CMakeLists 用 `BUILD_TESTS`/`BUILD_EXAMPLES` 和 Mooncake 同名。FindUbDiag.cmake 在 `FetchContent_MakeAvailable` 前用 `set(... CACHE ... FORCE)` 设置 ubdiag 的选项，**v1.0 的旧版有变量保存/恢复逻辑（L69-117）**。v1.1 的 FetchContent 模式下，`FORCE` 设置在子项目之前生效，子项目不会覆盖。但 **Mooncake 自己的 BUILD_TESTS/BUILD_EXAMPLES 需要在 FetchContent 之后恢复**。

**方案**：在 FindUbDiag.cmake 里保留变量保存/恢复逻辑（和旧版 L69-117 相同的模式）。

### 5.2 `CMAKE_SOURCE_DIR` 污染（已有解决方案）

ubdiag 的 CMakeLists 用 `CMAKE_SOURCE_DIR`（而不是 `CMAKE_CURRENT_SOURCE_DIR`）设置 include 路径。被 `add_subdirectory` 后 `CMAKE_SOURCE_DIR` 指向 Mooncake 根目录。

**方案**：FindUbDiag.cmake 在 `FetchContent_MakeAvailable` 后用 `target_include_directories` 显式修复（和旧版 L124-135 相同）。

### 5.3 p2p-store/build.sh 路径适配（v1.1 新增）

FetchContent 的 build 目录是 `${CMAKE_BINARY_DIR}/_deps/ubdiag-build/`，和旧 submodule 的 `${CMAKE_BINARY_DIR}/extern/ubdiag_build/` 不同。

**方案**：build.sh 的 case 改为 `vendored`（见 §3.2）。

### 5.4 install 冲突

ubdiag 的 `install(EXPORT UbDiagTargets FILE UbDiagConfig.cmake)` 和 Mooncake 的 package config 可能在同一 install 目录。

**风险评估**：低。Mooncake 的 install 规则用 Mooncake 自己的 namespace（如果有），ubdiag 用 `UbDiag::` namespace。两者不冲突。但需要实际 `cmake --install .` 验证。

### 5.5 OB 功能裁剪（减少编译依赖）

Mooncake 只用 PerfPoint/P99/PerfLog，不需要 OB Memstat/Cachestat/MemPoint。FetchContent 时设置 `ENABLE_OB_MEMORY=OFF ENABLE_OB_CACHE=OFF ENABLE_MEMPOINT=OFF`，跳过 libbpf-devel/bpftool/systemtap-sdt-devel 依赖。

**好处**：用户不需要安装 eBPF 相关包就能编译 ubdiag。

### 5.6 FetchContent 缓存

CMake 3.16 的 FetchContent 默认缓存在 `${CMAKE_BINARY_DIR}/_deps/`。首次配置时联网拉取，之后增量构建不重复拉。

**离线优化**：`FETCHCONTENT_FULLY_DISCONNECTED=ON` + `MOONCAKE_UBDIAG_SOURCE_DIR` 指定本地目录。

---

## 六、兼容性确认

### 6.1 插桩代码兼容性（零改动）

所有 `.cpp` 里的打点代码**完全不变**：
- `#include "ubdiag/auto_perf.h"` —— mock 和真实 ubdiag 都提供同名头
- `PerfPoint pt(PerfKey::XXX, PerfLevel::MODULE); pt.Start(); ... pt.End(0);` —— 接口完全一致
- `#define UBDIAG_PERF_DEF_FILE "mooncake_perf_points.def"` —— def 文件不动

### 6.2 CMake target 兼容性

`UbDiag::ubdiag_lib` target 名**不变**。mock 模式下是 INTERFACE 库别名，FetchContent 模式下是编译出来的真实库的别名。下游 `target_link_libraries(... UbDiag::ubdiag_lib)` 不需要改。

### 6.3 `MOONCAKE_UBDIAG_ACTIVE_LAYER` 兼容性

变量名**不变**，值从 `"submodule"`/`"system"`/`"mock"` 变为 `"vendored"`/`"mock"`。p2p-store/build.sh 适配后正常工作。

---

## 七、实施计划

### Phase 1（v1.1 → 实施）

| 步骤 | 文件 | 操作 |
|------|------|------|
| 1 | `.gitmodules` | 删除 `[submodule "extern/ubdiag"]` 条目 |
| 2 | `extern/ubdiag` | `git rm`（从 git 跟踪中移除） |
| 3 | `mooncake-common/FindUbDiag.cmake` | 重写为两层逻辑（~100 行） |
| 4 | `mooncake-p2p-store/build.sh` | 改 case 路径 |
| 5 | — | 本地验证 mock 模式编译 |
| 6 | — | 本地验证 `-DMOONCAKE_ENABLE_UBDIAG=ON` 编译+安装 |

### Phase 2（v1.2 升级优化，后续）

- `GIT_TAG` 锁定到 tag
- 变量保存/恢复逻辑精细化
- RPM 打包 manifest 完整化
- 离线缓存优化
- CMake package config 冲突实测

---

## 八、待讨论

1. **`GIT_TAG` 锁定**：v1.1 先用 master。是否需要先在 atomgit 打 tag（如 `v0.5.0`）？
2. **ubdiag 的 `CMAKE_SOURCE_DIR` 问题**：这是 ubdiag 自己的 bug（应该用 `CMAKE_CURRENT_SOURCE_DIR`）。v1.2 是否考虑修 ubdiag 侧？
3. **OB 裁剪**：默认 `ENABLE_OB_*=OFF`，但用户如果想在 Mooncake 进程上看 memstat/cachestat 怎么办？是否提供 `MOONCAKE_UBDIAG_FULL=ON` 选项？
4. **install prefix 一致性**：Mooncake 和 ubdiag 的 `CMAKE_INSTALL_PREFIX` 是否一致？
5. **网络依赖**：atomgit 在某些环境访问慢，是否提供 GitHub mirror？
