# Mooncake UbDiag 集成重构方案 v1.2（升级优化版）

> **核心原则**：ubdiag 侧改，Mooncake 侧尽量不侵入
> **基于**：atomgit liusiyu60/ubdiag master (d7e53c6) + GitHub LinQuickDev/Mooncake supercache (2300894)
> **v1.1 → v1.2 变化**：6 项 ubdiag 侧升级 + Mooncake 侧 FindUbDiag.cmake 最终版（~50行）
> **日期**：2026-07-15

---

## 一、v1.2 的核心理念

```
v1.1: Mooncake 用 100 行 FindUbDiag.cmake 绕过 ubdiag 的 CMake 缺陷
v1.2: ubdiag 修好自己的 CMake,Mooncake 只需 50 行 FindUbDiag.cmake
```

**所有改动尽量落在 ubdiag 侧**。Mooncake 侧只改 FindUbDiag.cmake（从 submodule 三层 → FetchContent 两层）+ p2p-store/build.sh 的 case 路径。其余 Mooncake 文件**零改动**。

---

## 二、ubdiag 侧升级（6 项，全部在 ubdiag 仓库改）

### 2.1 🔴 P0：`CMAKE_SOURCE_DIR` → `CMAKE_CURRENT_SOURCE_DIR`

**问题**：ubdiag 被其他项目 `add_subdirectory` 时，`CMAKE_SOURCE_DIR` 指向宿主根目录而非 ubdiag 目录，include 路径全部错位。Mooncake 侧需要 12 行 workaround 修复。

**改法**：ubdiag 全部 CMakeLists 里的 `CMAKE_SOURCE_DIR` 改为 `CMAKE_CURRENT_SOURCE_DIR`（子目录用）或保留 `PROJECT_SOURCE_DIR`（根目录用）。

**涉及文件**（ubdiag 仓库）：

| 文件 | 当前 | 改为 |
|------|------|------|
| `CMakeLists.txt`（根） | `CMAKE_SOURCE_DIR` | `PROJECT_SOURCE_DIR`（根目录等价，但被 add_subdirectory 后不漂移） |
| `src/sdk/CMakeLists.txt:50` | `${CMAKE_SOURCE_DIR}/include` | `${PROJECT_SOURCE_DIR}/include` |
| `src/manager/CMakeLists.txt` | 检查是否有 `CMAKE_SOURCE_DIR` | 同上 |
| `src/runtime/CMakeLists.txt` | 同上 | 同上 |
| `src/cli/CMakeLists.txt` | 同上 | 同上 |
| `src/runtime/ebpf/CMakeLists.txt` | `${CMAKE_SOURCE_DIR}/src/runtime/...` | `${CMAKE_CURRENT_SOURCE_DIR}/...`（子目录用 `CMAKE_CURRENT_SOURCE_DIR`） |

**Mooncake 侧收益**：FindUbDiag.cmake 删掉 include 路径修复（旧版 L124-135 共 12 行）。

### 2.2 🔴 P0：`BUILD_TESTS`/`BUILD_EXAMPLES` 加命名空间前缀

**问题**：ubdiag 的 `option(BUILD_TESTS ...)` 和 Mooncake 的 `option(BUILD_TESTS ...)` 同名冲突。Mooncake 想编自己的测试时，ubdiag 的 `add_subdirectory` 会读到 Mooncake 的 `BUILD_TESTS=ON`，编译 ubdiag 的测试（不需要）。旧版 FindUbDiag.cmake 有 50 行变量保存/恢复代码处理这个问题。

**改法**：

```cmake
# ubdiag 的 CMakeLists.txt
option(UBDIAG_BUILD_TESTS "Build UbDiag unit tests" OFF)      # 原 BUILD_TESTS
option(UBDIAG_BUILD_EXAMPLES "Build UbDiag examples" OFF)     # 原 BUILD_EXAMPLES

if(UBDIAG_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

if(UBDIAG_BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()
```

**同步改 build.sh**：
```bash
# build.sh 的选项映射
-t) case ... UBDIAG_BUILD_TESTS ...      # 原 BUILD_TESTS
-e) case ... UBDIAG_BUILD_EXAMPLES ...   # 原 BUILD_EXAMPLES
```

**Mooncake 侧收益**：FindUbDiag.cmake 删掉变量保存/恢复（旧版 L69-117 共 50 行）。

### 2.3 🔴 P0：打 tag

**改法**：在 atomgit 上给 ubdiag master (d7e53c6) 打 tag `v0.5.0`。

Mooncake 的 FetchContent 锁定到这个 tag：
```cmake
set(MOONCAKE_UBDIAG_GIT_TAG "v0.5.0" CACHE STRING "ubdiag 版本")
```

### 2.4 🟡 P1：install 规则条件化

**问题**：ubdiag 的 install 规则是全局的。被 `add_subdirectory` 后，Mooncake 的 `cmake --install .` 会强制安装 ubdiag 的所有东西。用户如果只想装 Mooncake 不想装 ubdiag，没办法。

**改法**：

```cmake
# ubdiag 的 CMakeLists.txt
option(UBDIAG_ENABLE_INSTALL "Enable install targets for UbDiag" ON)

if(UBDIAG_ENABLE_INSTALL)
    install(TARGETS ubdiag_lib ubdiag_logger
        EXPORT UbDiagTargets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
    install(DIRECTORY include/ubdiag
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
        FILES_MATCHING PATTERN "*.h"
    )
    install(EXPORT UbDiagTargets
        FILE UbDiagTargets.cmake
        NAMESPACE UbDiag::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UbDiag
    )
    install(TARGETS ubdiag
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    )
    # ... 其他 install 规则 ...
endif()
```

**Mooncake 侧用法**：
```cmake
# 默认:不安装 ubdiag(Mooncake 自己的 install 不带 ubdiag)
set(UBDIAG_ENABLE_INSTALL OFF CACHE BOOL "" FORCE)

# 如果 Mooncake 也想安装 ubdiag(库+CLI 到系统):
# set(UBDIAG_ENABLE_INSTALL ON CACHE BOOL "" FORCE)
```

### 2.5 🟡 P1：`UBDIAG_HAS_*` 特性检测宏

**问题**：Mooncake 裁剪了 OB 功能（`ENABLE_OB_MEMORY=OFF`），但消费方代码无法检测"这个 ubdiag 构建是否包含 OB"。

**改法**：ubdiag 的编译选项在 `target_compile_definitions` 时同步导出 `UBDIAG_HAS_*` 宏：

```cmake
# src/sdk/CMakeLists.txt
if(ENABLE_OB_MEMORY AND PLATFORM_LINUX)
    target_compile_definitions(ubdiag_lib PUBLIC UBDIAG_ENABLE_OB_MEMORY UBDIAG_HAS_OB_MEMORY)
endif()
if(ENABLE_OB_CACHE AND PLATFORM_LINUX)
    target_compile_definitions(ubdiag_lib PUBLIC UBDIAG_ENABLE_OB_CACHE UBDIAG_HAS_OB_CACHE)
endif()
if(ENABLE_MEMPOINT AND PLATFORM_LINUX)
    target_compile_definitions(ubdiag_lib PUBLIC UBDIAG_ENABLE_MEMPOINT UBDIAG_HAS_MEMPOINT)
endif()
```

**Mooncake 侧收益**（未来）：代码里可以 `#ifdef UBDIAG_HAS_OB_MEMORY` 做条件编译，而不是靠 CMake 变量传递。

### 2.6 🟢 P2：标准 `UbDiagConfig.cmake`

**问题**：ubdiag 安装了 `UbDiagTargets.cmake` 但没有标准的 `UbDiagConfig.cmake`，`find_package(UbDiag)` 无法标准工作。

**改法**：

新建 `cmake/UbDiagConfig.cmake.in`：
```cmake
@PACKAGE_INIT@
include("${CMAKE_CURRENT_LIST_DIR}/UbDiagTargets.cmake")
check_required_components(UbDiag)
```

在根 CMakeLists.txt 里：
```cmake
include(CMakePackageConfigHelpers)

configure_package_config_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/cmake/UbDiagConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/UbDiagConfig.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UbDiag
)

write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/UbDiagConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion
)

install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/UbDiagConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/UbDiagConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/UbDiag
)
```

**收益**：任何项目都能 `find_package(UbDiag 0.5 REQUIRED)`，包括 Mooncake 如果将来想回到 system 安装模式。

---

## 三、ubdiag 侧改动汇总

| 文件 | 改动 | 优先级 |
|------|------|:---:|
| `CMakeLists.txt`（根） | `CMAKE_SOURCE_DIR`→`PROJECT_SOURCE_DIR`；`BUILD_TESTS`→`UBDIAG_BUILD_TESTS`；`BUILD_EXAMPLES`→`UBDIAG_BUILD_EXAMPLES`；install 条件化；加 Config.cmake 生成 | P0+P1 |
| `src/sdk/CMakeLists.txt` | `${CMAKE_SOURCE_DIR}`→`${PROJECT_SOURCE_DIR}`；加 `UBDIAG_HAS_*` 宏导出 | P0+P1 |
| `src/manager/CMakeLists.txt` | `CMAKE_SOURCE_DIR`→`CMAKE_CURRENT_SOURCE_DIR`（子目录） | P0 |
| `src/runtime/CMakeLists.txt` | 同上 | P0 |
| `src/runtime/ebpf/CMakeLists.txt` | 同上 | P0 |
| `src/cli/CMakeLists.txt` | 同上 | P0 |
| `build.sh` | `-t`→`UBDIAG_BUILD_TESTS`；`-e`→`UBDIAG_BUILD_EXAMPLES` | P0 |
| `cmake/UbDiagConfig.cmake.in` | **新建** | P2 |
| atomgit tag | 打 `v0.5.0` | P0 |

**估计改动量**：ubdiag 侧 ~8 个文件，主要是查找替换 + 少量新增。

---

## 四、Mooncake 侧最终版 FindUbDiag.cmake（~50 行）

ubdiag 的 6 项升级完成后，Mooncake 的 FindUbDiag.cmake 可以简化到：

```cmake
# mooncake-common/FindUbDiag.cmake v2 — 两层集成
#
# Usage:
#   include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)
#   target_link_libraries(your_target PRIVATE UbDiag::ubdiag_lib)

if(TARGET UbDiag::ubdiag_lib)
  return()
endif()

option(MOONCAKE_ENABLE_UBDIAG "编译 ubdiag 真实库(否则用 mock)" OFF)
set(MOONCAKE_UBDIAG_GIT_TAG "v0.5.0" CACHE STRING "ubdiag 版本")
set(MOONCAKE_UBDIAG_SOURCE_DIR "" CACHE PATH "本地 ubdiag 源码(离线用)")

# ===== Layer 0: Mock(默认) =====
if(NOT MOONCAKE_ENABLE_UBDIAG)
  add_library(ubdiag_mock INTERFACE)
  target_include_directories(ubdiag_mock INTERFACE
      ${CMAKE_SOURCE_DIR}/mooncake-common/ubdiag-mock)
  add_library(UbDiag::ubdiag_lib ALIAS ubdiag_mock)
  set(MOONCAKE_UBDIAG_ACTIVE_LAYER "mock" CACHE STRING "" FORCE)
  message(STATUS "UbDiag: mock(空函数)")
  return()
endif()

# ===== Layer 1: FetchContent =====
include(FetchContent)

if(MOONCAKE_UBDIAG_SOURCE_DIR AND EXISTS "${MOONCAKE_UBDIAG_SOURCE_DIR}/CMakeLists.txt")
  FetchContent_Declare(ubdiag SOURCE_DIR ${MOONCAKE_UBDIAG_SOURCE_DIR})
else()
  FetchContent_Declare(ubdiag
      GIT_REPOSITORY https://atomgit.com/liusiyu60/ubdiag.git
      GIT_TAG ${MOONCAKE_UBDIAG_GIT_TAG})
endif()

# ubdiag 编译选项(不需要 Mooncake 做 workaround,ubdiag 自己已修好)
set(UBDIAG_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(UBDIAG_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(UBDIAG_BUILD_SHARED ON CACHE BOOL "" FORCE)
set(ENABLE_PERCENTILE ON CACHE BOOL "" FORCE)
set(ENABLE_PERFLOG ON CACHE BOOL "" FORCE)
set(ENABLE_OB_MEMORY OFF CACHE BOOL "" FORCE)
set(ENABLE_OB_CACHE OFF CACHE BOOL "" FORCE)
set(ENABLE_MEMPOINT OFF CACHE BOOL "" FORCE)
set(UBDIAG_ENABLE_INSTALL ON CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(ubdiag)

if(TARGET ubdiag_lib)
  add_library(UbDiag::ubdiag_lib ALIAS ubdiag_lib)
  set(MOONCAKE_UBDIAG_ACTIVE_LAYER "vendored" CACHE STRING "" FORCE)
  message(STATUS "UbDiag: FetchContent ${MOONCAKE_UBDIAG_GIT_TAG}")
endif()
```

**对比 v1.1（100 行）→ v1.2（50 行）**：

| 删掉的代码 | 为什么能删 | 行数 |
|-----------|-----------|:---:|
| 变量保存/恢复（BUILD_TESTS/BUILD_EXAMPLES） | ubdiag 改名为 UBDIAG_BUILD_TESTS，不再冲突 | -50 |
| include 路径修复 | ubdiag 改用 PROJECT_SOURCE_DIR，不需要 workaround | -12 |
| RPM manifest 函数 | 简化为直接 set 变量（如果 p2p-store 还需要） | -20 |
| CLI 查找逻辑 | ubdiag 的 install 自动装 CLI，不需要 Mooncake 查找 | -15 |
| system package 查找（Layer 2） | 整个删除 | -40 |

---

## 五、Mooncake 侧改动汇总（最小侵入）

| 文件 | 改动 | 行数变化 |
|------|------|---------|
| `mooncake-common/FindUbDiag.cmake` | 重写（239行→50行） | -189 |
| `mooncake-p2p-store/build.sh` | case 路径适配（3行） | ±3 |
| `.gitmodules` | 删 ubdiag 条目 | -3 |
| `extern/ubdiag/` | git rm | — |
| **其余 13 个文件** | **零改动** | 0 |

**Mooncake 总改动**：4 个文件，净减 ~190 行。

---

## 六、实施顺序

### Step 1：ubdiag 侧升级（在 atomgit ubdiag 仓库做）

```
1. CMAKE_SOURCE_DIR → PROJECT_SOURCE_DIR / CMAKE_CURRENT_SOURCE_DIR（全部 CMakeLists）
2. BUILD_TESTS → UBDIAG_BUILD_TESTS；BUILD_EXAMPLES → UBDIAG_BUILD_EXAMPLES（CMakeLists + build.sh）
3. install 规则加 UBDIAG_ENABLE_INSTALL 条件
4. 加 UBDIAG_HAS_* 特性宏导出
5. 新建 cmake/UbDiagConfig.cmake.in
6. 打 tag v0.5.0
```

### Step 2：Mooncake 侧适配（在 qinyufei63/Mooncake 做）

```
1. 删 .gitmodules 的 ubdiag 条目 + extern/ubdiag/
2. 重写 FindUbDiag.cmake（v1.2 版，50 行）
3. 改 p2p-store/build.sh 的 case 路径
4. 验证：mock 模式编译通过
5. 验证：-DMOONCAKE_ENABLE_UBDIAG=ON 编译+安装通过
```

---

## 七、版本演进路线

```
v1.0（初版）          → 方向确定（submodule→FetchContent、三层→两层）
v1.1（校正版）        → 全量代码读取，修正 6 处遗漏
v1.2（升级优化版）    → ubdiag 侧 6 项升级 + Mooncake 50 行最终版
                      → 原则：ubdiag 改，Mooncake 不侵入
v1.3（实施版）        → 按本文档 Step 1 + Step 2 执行
```

---

## 八、待确认

1. **tag 名**：用 `v0.5.0` 还是自定义（如 `v0.5.0-mooncake`）？
2. **ubdiag 侧改动审批**：6 项改动在 ubdiag 仓库做，需要走 PR 流程吗？（atomgit liusiyu60/ubdiag）
3. **CI 验证**：ubdiag 改完 CMake 后，自己的 `bash build.sh` 是否仍然编译通过？（向后兼容）
4. **build.sh 的 `-t`/`-e` 选项**：改名为 UBDIAG_BUILD_TESTS 后，用户的 `-t on` 命令是否仍有效？（需要在 build.sh 里做映射）
