# Mooncake UbDiag 集成重构方案 v1.0

> **基于**：atomgit liusiyu60/ubdiag master (d7e53c6) + GitHub LinQuickDev/Mooncake supercache (2300894)
> **日期**：2026-07-15
> **版本**：v1.0（初版，待 v1.1 校对 + v1.2 升级优化）
> **作者**：ZCode 与用户协作

---

## 一、现状分析

### 1.1 当前集成方式（你们分支 supercache_dev_extern&mock）

```
Mooncake
  ├── .gitmodules         ← extern/ubdiag 作为 git submodule
  │     url = atomgit.com/liusiyu60/ubdiag
  │     branch = fix/shm-probe-fastpath
  ├── extern/ubdiag/      ← submodule 检出的源码
  ├── mooncake-common/
  │     ├── FindUbDiag.cmake   ← 三层 fallback：submodule → system → mock
  │     └── ubdiag-mock/       ← header-only mock（空函数 PerfPoint）
  └── mooncake-store/src/CMakeLists.txt
        include(FindUbDiag.cmake)
        target_link_libraries(mooncake_store PRIVATE UbDiag::ubdiag_lib)
```

**三层 fallback 逻辑**（当前 FindUbDiag.cmake）：
1. **Layer 1（submodule）**：`extern/ubdiag` 存在 → `add_subdirectory` 编译
2. **Layer 2（system）**：`find_package(UbDiag QUIET)` 找系统安装
3. **Layer 3（mock）**：用 `mooncake-common/ubdiag-mock/auto_perf.h` 空函数

### 1.2 痛点

| 问题 | 影响 |
|------|------|
| **submodule 管理** | `git clone` 必须 `--recursive`，容易漏；submodule 指针漂移导致版本不一致 |
| **系统路径查找** | Layer 2 依赖 `/usr/local` 下预装 ubdiag，用户需要手动 `bash build.sh -i` 安装 ubdiag |
| **mock 头文件维护** | `mooncake-common/ubdiag-mock/auto_perf.h` 是手写的 mock，和真实 ubdiag 的 `auto_perf.h` 接口可能不同步 |
| **CLI 安装不自动化** | 用户拿到 mooncake 后，想打点还要单独去编译安装 ubdiag CLI |
| **三层逻辑复杂** | FindUbDiag.cmake 有 200+ 行的 fallback + RPM manifest + 选项处理，维护成本高 |

### 1.3 上游 Mooncake 的依赖管理方式

上游 `LinQuickDev/Mooncake supercache` 用 **git submodule** 管理 pybind11 和 yalantinglibs（`.gitmodules` 配置 + `extern/` 目录）。**没有用 FetchContent**。

---

## 二、重构目标

### 2.1 核心需求

> **ubdiag 不再作为 submodule，也不寻找系统路径。拉取 mooncake 时，用 CMake FetchContent 一并拉取 ubdiag 源码。编译时开关可选是否编译 ubdiag，默认 mock（空函数）。不 mock 则一起编译 ubdiag 并自动安装库 + 同版本 CLI。**

### 2.2 拆解为 5 个具体目标

| # | 目标 | 验收标准 |
|---|------|---------|
| G1 | 去掉 submodule | `.gitmodules` 不再有 ubdiag 条目；`extern/ubdiag` 删除 |
| G2 | 去掉系统路径查找 | FindUbDiag.cmake 不再调 `find_package(UbDiag QUIET)` |
| G3 | CMake FetchContent 拉取 | `cmake ..` 时自动从 atomgit 拉 ubdiag 源码到 build 目录 |
| G4 | 编译开关（默认 mock） | `-DMOONCAKE_ENABLE_UBDIAG=OFF`（默认）用 mock；`=ON` 编译真实 ubdiag |
| G5 | 自动安装库 + CLI | 启用 ubdiag 编译时，`cmake --install .` 自动安装 libubdiag + ubdiag CLI 到系统路径 |

---

## 三、架构设计

### 3.1 新的集成架构（两层：mock / vendored）

```
                    Mooncake CMakeLists.txt
                           │
                    ┌──────┴──────┐
                    │ MOONCAKE_    │
                    │ ENABLE_UBDIAG│
                    └──────┬──────┘
                   ┌───────┴───────┐
                   │               │
              OFF (默认)         ON
                   │               │
          ┌────────┘        ┌──────┘
          │                 │
     include(mock)    FetchContent(ubdiag)
          │                 │
  ubdiag-mock/auto_perf.h   ↓
  (空函数,no-op)      add_subdirectory(ubdiag)
                         编译 libubdiag + ubdiag CLI
                         install 到 /usr/local
                            │
                   ┌────────┘
                   │
           UbDiag::ubdiag_lib
           (真实库,有 SHM 打点)
```

**简化为两层**（去掉原来的 Layer 2 系统路径查找）：
- **Layer 0（mock，默认）**：header-only 空函数，零依赖，开箱即编译
- **Layer 1（vendored，可选）**：FetchContent 拉源码 + add_subdirectory 编译

### 3.2 为什么用 FetchContent 而不是 submodule

| 维度 | git submodule | CMake FetchContent |
|------|:---:|:---:|
| `git clone --recursive` 依赖 | ❌ 必须 | ✅ 不需要 |
| 离线环境 | ❌ submodule 可能漏 | ✅ 可配 `FETCHCONTENT_SOURCE_DIR` 指定本地目录 |
| CMake 原生管理 | ❌ 外部 | ✅ CMake 内部 |
| 版本锁定 | ✅ git 指针 | ✅ `GIT_TAG` 锁 commit/tag |
| 自动下载 | ❌ 需手动 init | ✅ cmake 配置时自动 |
| 上游 Mooncake 惯例 | ✅ pybind11/yalantinglibs 用 submodule | — |

> **注意**：上游 Mooncake 用 submodule 管理 pybind11/yalantinglibs。ubdiag 用 FetchContent 是因为：(1) 我们要去掉 submodule；(2) FetchContent 更适合"可选依赖"（ubdiag 默认是 mock，不需要拉源码）。

### 3.3 文件改动清单

#### 新增文件

| 文件 | 用途 |
|------|------|
| `mooncake-common/FindUbDiag.cmake`（**重写**） | 新的两层逻辑：mock / FetchContent |

#### 删除文件

| 文件 | 原因 |
|------|------|
| `.gitmodules` 里的 `[submodule "extern/ubdiag"]` 条目 | 不再用 submodule |
| `extern/ubdiag/` 目录 | 不再用 submodule |
| `mooncake-common/ubdiag-mock/` 目录 | mock 逻辑合并到 FindUbDiag.cmake 内部生成 |

#### 修改文件

| 文件 | 改动 |
|------|------|
| `mooncake-store/src/CMakeLists.txt` | include FindUbDiag.cmake 的路径不变，但选项从 `MOONCAKE_UBDIAG_*` 简化为 `MOONCAKE_ENABLE_UBDIAG` |
| `mooncake-p2p-store/CMakeLists.txt` | 同上（如果 p2p-store 也用 ubdiag） |
| `mooncake-transfer-engine/src/CMakeLists.txt` | 同上（如果 transfer-engine 也用 ubdiag） |

#### 不变文件

| 文件 | 说明 |
|------|------|
| 用户代码里的 `#include "ubdiag/auto_perf.h"` | 接口不变，mock 和真实 ubdiag 都提供同名头文件 |
| 用户代码里的 `PerfPoint pt(PerfKey::XXX); pt.Start(); pt.End();` | 调用方式不变 |
| ubdiag 自己的 CMakeLists.txt / build.sh | 不改 ubdiag 侧的代码 |

---

## 四、FindUbDiag.cmake 重写方案

### 4.1 核心逻辑（伪代码）

```cmake
# mooncake-common/FindUbDiag.cmake

option(MOONCAKE_ENABLE_UBDIAG "编译 ubdiag 真实库(否则用 mock 空函数)" OFF)
option(MOONCAKE_UBDIAG_GIT_URL "ubdiag 仓库地址" "https://atomgit.com/liusiyu60/ubdiag.git")
option(MOONCAKE_UBDIAG_GIT_TAG "ubdiag 版本(commit/tag/branch)" "master")

# 离线模式:用户可指定本地 ubdiag 源码目录
set(MOONCAKE_UBDIAG_SOURCE_DIR "" CACHE PATH "本地 ubdiag 源码目录(离线用,为空则 FetchContent)")

if(TARGET UbDiag::ubdiag_lib)
    return()  # 已经处理过,跳过
endif()

if(NOT MOONCAKE_ENABLE_UBDIAG)
    # ===== Layer 0: Mock(默认) =====
    # 在 build 目录生成 header-only mock
    message(STATUS "UbDiag: 使用 mock(空函数打点)。-DMOONCAKE_ENABLE_UBDIAG=ON 启用真实 ubdiag。")
    _generate_ubdiag_mock()  # 生成空函数 auto_perf.h
    return()
endif()

# ===== Layer 1: FetchContent 拉取并编译 =====
include(FetchContent)

if(MOONCAKE_UBDIAG_SOURCE_DIR AND EXISTS "${MOONCAKE_UBDIAG_SOURCE_DIR}/CMakeLists.txt")
    # 离线:用本地源码目录
    FetchContent_Declare(ubdiag SOURCE_DIR ${MOONCAKE_UBDIAG_SOURCE_DIR})
else()
    # 在线:从 git 拉
    FetchContent_Declare(ubdiag
        GIT_REPOSITORY ${MOONCAKE_UBDIAG_GIT_URL}
        GIT_TAG ${MOONCAKE_UBDIAG_GIT_TAG}
    )
endif()

# ubdiag 子项目的编译选项
set(UBDIAG_BUILD_SHARED ON CACHE BOOL "" FORCE)   # 编译为 .so
set(BUILD_TESTS OFF CACHE BOOL "" FORCE)            # 不编 ubdiag 的测试
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)         # 不编 ubdiag 的示例
set(ENABLE_PERCENTILE ON CACHE BOOL "" FORCE)       # 启用 P99
set(ENABLE_PERFLOG ON CACHE BOOL "" FORCE)          # 启用 PerfLog

FetchContent_MakeAvailable(ubdiag)

# UbDiag::ubdiag_lib target 已由 ubdiag 的 CMakeLists 定义
# 确保头文件路径可用
target_include_directories(ubdiag_lib INTERFACE
    ${ubdiag_SOURCE_DIR}/include
)
```

### 4.2 Mock 生成逻辑

mock 不再维护独立文件，而是在 CMake 配置时**动态生成**到 `${CMAKE_BINARY_DIR}/ubdiag_mock/` 目录，保证和真实 ubdiag 的接口严格一致：

```cmake
function(_generate_ubdiag_mock)
    set(MOCK_DIR ${CMAKE_BINARY_DIR}/ubdiag_mock/ubdiag)
    file(MAKE_DIRECTORY ${MOCK_DIR})

    # 生成 auto_perf.h(空函数版)
    # 接口和真实 auto_perf.h 完全一致:PerfKey 枚举 + PerfPoint 空类
    file(WRITE ${MOCK_DIR}/auto_perf.h "...空函数代码...")

    # 创建一个 INTERFACE library
    add_library(ubdiag_lib INTERFACE)
    target_include_directories(ubdiag_lib INTERFACE ${CMAKE_BINARY_DIR}/ubdiag_mock)
    target_alias(UbDiag::ubdiag_lib ALIAS ubdiag_lib)
endfunction()
```

### 4.3 CLI 安装

当 `MOONCAKE_ENABLE_UBDIAG=ON` 时，ubdiag 的 `add_subdirectory` 会编译 `ubdiag` CLI 目标（`src/cli/`）。Mooncake 的 `cmake --install .` 会自动安装 ubdiag 的 targets（通过 ubdiag CMakeLists 的 `install(TARGETS ubdiag ...)`）。

**关键**：ubdiag CMakeLists 已有 `install(TARGETS ubdiag ...)`（L202），不需要 Mooncake 侧额外配置。只要 `add_subdirectory` 了 ubdiag，它的 install 规则就会生效。

---

## 五、用户使用流程（重构后）

### 5.1 默认使用（mock，零依赖）

```bash
git clone https://github.com/LinQuickDev/Mooncake.git  # 不需要 --recursive
cd Mooncake
mkdir build && cd build
cmake ..                        # ubdiag 用 mock(空函数),零额外依赖
make -j$(nproc)                 # 正常编译,Mooncake 代码里的 PerfPoint 是 no-op
```

### 5.2 启用真实 ubdiag 打点

```bash
git clone https://github.com/LinQuickDev/Mooncake.git
cd Mooncake
mkdir build && cd build
cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON   # FetchContent 拉取 ubdiag 源码并编译
make -j$(nproc)                         # 编译 Mooncake + ubdiag(含 CLI)
sudo cmake --install .                  # 安装 libubdiag.so + ubdiag CLI 到 /usr/local

# 使用:
ubdiag start                            # 创建 SHM
./mooncake-store                        # Mooncake 进程自动打点
ubdiag show                             # 查看性能数据
```

### 5.3 离线环境（无网络）

```bash
# 方法1:指定本地 ubdiag 源码目录
cmake .. -DMOONCAKE_ENABLE_UBDIAG=ON \
         -DMOONCAKE_UBDIAG_SOURCE_DIR=/path/to/local/ubdiag

# 方法2:用 FetchContent 的缓存(首次联网后)
# CMake 默认缓存在 ~/.cache/FetchContent/ 或 build/_deps/
```

---

## 六、技术约束与风险

### 6.1 CMake 兼容性

- **FetchContent_MakeAvailable** 需要 CMake 3.14+。Mooncake 要求 3.16（`cmake_minimum_required(VERSION 3.16)`），**满足**。
- FetchContent 的 `GIT_TAG` 建议**锁定到 commit hash 或 tag**（不用 branch），避免拉到不稳定版本。v1.0 先用 `master`，v1.2 改为 tag。

### 6.2 目标名冲突

- ubdiag 的 CMakeLists 定义了 `ubdiag_lib`（SDK 库）和 `ubdiag`（CLI 可执行文件）。这些是全局目标名。
- Mooncake 如果也有同名目标，会冲突。**当前 Mooncake 没有同名目标**，无冲突。

### 6.3 编译选项传递

FetchContent 的 `add_subdirectory` 会继承父项目的 CMake 变量。需要在 `FetchContent_MakeAvailable` 之前用 `set(... CACHE ... FORCE)` 设置 ubdiag 的编译选项（BUILD_TESTS=OFF 等），避免编译 ubdiag 的测试和示例。

### 6.4 install 冲突

ubdiag 的 `install(EXPORT UbDiagTargets ...)` 和 Mooncake 的 install 规则在同一个 build 目录。CMake 允许多个 `install(EXPORT)` 共存，但 **CMake package config 文件可能冲突**。需要确认 ubdiag 的 `UbDiagConfig.cmake` install 路径不与 Mooncake 的冲突。

### 6.5 Mock 接口同步

当前 mock 的 `auto_perf.h` 缺少 `global_perf_t` / `global_perf` / `PerfPoint(key, global_perf, level)` 全局模式构造函数。如果 Mooncake 代码里用了全局 PerfPoint（跨线程打点），mock 编译会失败。**需要在 mock 里补齐 `global_perf_t` 的空实现**。

---

## 七、与现有代码的兼容性

### 7.1 用户代码（插桩点）不需要改

```cpp
// 现有的插桩代码,mock 和真实 ubdiag 下都能编译
#define UBDIAG_PROGRAM_NAME "mooncake"
#include "ubdiag/auto_perf.h"

void doWork() {
    PerfPoint pt(PerfKey::SOME_WORK);
    pt.Start();
    // ... 业务代码 ...
    pt.End(0);
}
```

mock 下：`PerfPoint` 是空类，`Start/End` 是空函数，零开销。
真实 ubdiag 下：完整的 SHM 打点链路。

### 7.2 需要改的 CMakeLists 文件

| 文件 | 当前 | 改后 |
|------|------|------|
| `mooncake-common/FindUbDiag.cmake` | 200+ 行三层 fallback | ~60 行两层逻辑(mock/FetchContent) |
| `mooncake-store/src/CMakeLists.txt:251` | `include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)` | 不变 |
| `mooncake-store/src/CMakeLists.txt:252` | `target_link_libraries(mooncake_store PRIVATE UbDiag::ubdiag_lib)` | 不变 |

**关键**：`UbDiag::ubdiag_lib` target 名不变，下游 CMakeLists 不需要改。

### 7.3 perf_point.def（Mooncake 自定义的打点定义）

Mooncake 在 `mooncake-store/include/perf_point.def`（或类似路径）定义自己的 PerfKey。这个文件**不需要改**——mock 和真实 ubdiag 都会 `#include UBDIAG_PERF_DEF_FILE` 展开它。

---

## 八、实施计划（粗略）

### Phase 1（v1.0 → v1.1 校对）

- [ ] 重写 `FindUbDiag.cmake`（两层逻辑）
- [ ] 生成 mock `auto_perf.h`（含 `global_perf_t` 空实现）
- [ ] 删除 `.gitmodules` 里的 ubdiag 条目
- [ ] 删除 `extern/ubdiag/`
- [ ] 删除 `mooncake-common/ubdiag-mock/`（逻辑合并到 FindUbDiag.cmake）
- [ ] 本地验证：mock 模式编译通过
- [ ] 本地验证：`-DMOONCAKE_ENABLE_UBDIAG=ON` 拉取 + 编译通过
- [ ] 本地验证：`cmake --install .` 安装 libubdiag + ubdiag CLI

### Phase 2（v1.1 → v1.2 升级优化）

- [ ] `GIT_TAG` 从 master 改为 tag（版本锁定）
- [ ] ubdiag 的编译选项精细化（只编译 PerfPoint/P99/PerfLog，不编 OB/Memstat）
- [ ] RPM 打包集成（`MOONCAKE_UBDIAG_RPM_MANIFEST` 等）
- [ ] 离线缓存优化

---

## 九、待讨论的开放问题

1. **ubdiag 版本锁定**：v1.0 先用 master 分支。是否需要先打一个 tag（如 `v0.5.0-mooncake`）让 Mooncake 锁定？

2. **CLI 安装路径**：ubdiag CLI 默认装到 `/usr/local/bin/ubdiag`。Mooncake 的 install prefix 是否和 ubdiag 一致？如果 Mooncake 用自定义 prefix（如 `CMAKE_INSTALL_PREFIX=/opt/mooncake`），ubdiag 也会装到 `/opt/mooncake/bin/`，需要确认是否合理。

3. **OB 功能裁剪**：Mooncake 只需要 PerfPoint/P99/PerfLog，不需要 OB Memstat/Cachestat/MemPoint。FetchContent 时是否设置 `ENABLE_OB_MEMORY=OFF ENABLE_OB_CACHE=OFF` 来跳过 eBPF 编译依赖？这可以减少编译依赖（不需要 libbpf-devel/bpftool）。

4. **mock 的 global_perf 支持**：当前 mock 缺 `global_perf_t`。Mooncake 代码里有没有用跨线程 PerfPoint？如果有，mock 需要补。

5. **CMake package config 冲突**：ubdiag 的 `install(EXPORT UbDiagTargets FILE UbDiagConfig.cmake)` 和 Mooncake 的 package config 是否在同一目录冲突？需要实际测试。

6. **FetchContent 网络依赖**：atomgit 在某些网络环境下可能访问慢。是否提供 mirror 或 fallback URL？
