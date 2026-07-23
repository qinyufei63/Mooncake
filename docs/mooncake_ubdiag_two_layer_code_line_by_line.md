# Mooncake UbDiag 两层分发代码逐行翻译

本文只做一件事：左边放代码原文，右边说明这一行具体做什么。

范围：

- `mooncake-common/FindUbDiag.cmake`：L1-L123 全文件逐行解释。
- 其他 5 个实现文件：逐行解释本次修改和紧邻的消费代码。
- 不展开用户指南、验证日志、架构图和风险分析。

## 1. `mooncake-common/FindUbDiag.cmake`

### L1-L30：文件说明和公共配置

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 1 | `# FindUbDiag.cmake v2 — 基于 UBDIAG_DISABLE 的两层集成` | 说明这是第二版 UbDiag 查找脚本，核心机制是 `UBDIAG_DISABLE` 两层集成。 |
| 2 | `#` | 注释空行，用来分隔说明。 |
| 3 | `# Layer 0 (默认): FetchContent 拉源码 + 定义 UBDIAG_DISABLE → constexpr 空函数` | 说明默认层只取源码头文件，并把 PerfPoint 编译成空函数。 |
| 4 | `# Layer 1 (可选): FetchContent 拉源码 + 编译 ubdiag 库 + CLI` | 说明启用层会真正编译 SDK 动态库和 CLI。 |
| 5 | `#` | 注释空行，用来分隔说明。 |
| 6 | `# Usage:` | 开始说明这个 CMake 文件怎么被其他模块调用。 |
| 7 | `#   include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)` | 示例：先加载这个统一集成脚本。 |
| 8 | `#   target_link_libraries(your_target PRIVATE UbDiag::ubdiag_lib)` | 示例：业务目标统一链接 `UbDiag::ubdiag_lib`。 |
| 9 | `#` | 注释空行，用来分隔说明。 |
| 10 | `# Options:` | 开始列出用户可传入的 CMake 参数。 |
| 11 | `#   -DMOONCAKE_ENABLE_UBDIAG=ON   编译真实 ubdiag (库 + CLI)` | 说明传 `ON` 会启用真实 UbDiag。 |
| 12 | `#   -DMOONCAKE_ENABLE_UBDIAG=OFF  (默认) 使用 UBDIAG_DISABLE 空函数` | 说明默认 `OFF` 会使用编译期空实现。 |
| 13 | `#   -DMOONCAKE_UBDIAG_GIT_TAG=<tag/branch/commit>  指定 ubdiag 版本` | 说明可以覆盖默认 UbDiag 版本。 |
| 14 | `#   -DMOONCAKE_UBDIAG_SOURCE_DIR=/path/to/ubdiag  离线模式指定本地源码` | 说明离线环境可以直接指定本地源码目录。 |
| 15 | `（空行）` | 分隔文件说明和正式逻辑。 |
| 16 | `if(TARGET UbDiag::ubdiag_lib)` | 检查统一 UbDiag 目标是否已经被前面的模块创建。 |
| 17 | `  return()` | 如果已经创建，就直接返回，防止重复拉源码或重复建目标。 |
| 18 | `endif()` | 结束“目标已存在”的判断。 |
| 19 | `（空行）` | 分隔幂等保护和配置项。 |
| 20 | `option(MOONCAKE_ENABLE_UBDIAG "编译 ubdiag 真实库(否则用 UBDIAG_DISABLE 空函数)" OFF)` | 定义主开关，默认值是 `OFF`。 |
| 21 | `set(MOONCAKE_UBDIAG_GIT_REPOSITORY` | 开始设置 UbDiag 源码仓地址。 |
| 22 | `    "https://github.com/LinQuickDev/ubdiag.git"` | 默认从 LinQuickDev 的 GitHub UbDiag 镜像拉取。 |
| 23 | `    CACHE STRING "ubdiag Git repository")` | 把仓地址存进 CMake cache，允许用户从命令行覆盖。 |
| 24 | `set(MOONCAKE_UBDIAG_GIT_TAG` | 开始设置 UbDiag 版本。 |
| 25 | `    "v0.5.1"` | 默认版本是 Git tag `v0.5.1`。 |
| 26 | `    CACHE STRING "ubdiag 版本(tag/branch/commit)")` | 把版本存进 cache，并允许填写 tag、分支或提交。 |
| 27 | `set(MOONCAKE_UBDIAG_SOURCE_DIR "" CACHE PATH "本地 ubdiag 源码目录(离线用,为空则 FetchContent)")` | 定义本地源码路径；为空时使用 FetchContent 下载。 |
| 28 | `（空行）` | 分隔配置项和 FetchContent 初始化。 |
| 29 | `include(FetchContent)` | 加载 CMake 自带的 FetchContent 模块。 |
| 30 | `（空行）` | 分隔公共配置和 Layer 0。 |

### L31-L70：Layer 0 默认空实现

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 31 | `# ===== Layer 0: UBDIAG_DISABLE 模式(默认) =====` | 标记下面开始处理默认 Layer 0。 |
| 32 | `if(NOT MOONCAKE_ENABLE_UBDIAG)` | 当主开关没有打开时进入 Layer 0。 |
| 33 | `  # Populate the source tree only. The full FetchContent_Populate() form stays` | 注释：Layer 0 只准备源码树。 |
| 34 | `  # source-only without the deprecated single-argument call on newer CMake.` | 注释：使用完整参数形式，避免新版 CMake 的废弃接口问题。 |
| 35 | `  if(MOONCAKE_UBDIAG_SOURCE_DIR AND` | 先判断用户是否传了本地 UbDiag 源码目录。 |
| 36 | `     EXISTS "${MOONCAKE_UBDIAG_SOURCE_DIR}/CMakeLists.txt")` | 再确认该目录中确实存在 UbDiag 的顶层 `CMakeLists.txt`。 |
| 37 | `    set(ubdiag_SOURCE_DIR "${MOONCAKE_UBDIAG_SOURCE_DIR}")` | 本地源码有效时，把它设为后续统一使用的源码目录。 |
| 38 | `  else()` | 没有有效本地源码时，转入在线下载。 |
| 39 | `    FetchContent_Populate(ubdiag` | 只下载和展开名为 `ubdiag` 的源码，不把其工程加入构建。 |
| 40 | `      GIT_REPOSITORY ${MOONCAKE_UBDIAG_GIT_REPOSITORY}` | 使用前面配置的 Git 仓地址。 |
| 41 | `      GIT_TAG ${MOONCAKE_UBDIAG_GIT_TAG}` | 使用前面配置的 tag、分支或提交。 |
| 42 | `      SOURCE_DIR "${FETCHCONTENT_BASE_DIR}/ubdiag-src"` | 指定 UbDiag 源码展开目录。 |
| 43 | `      BINARY_DIR "${FETCHCONTENT_BASE_DIR}/ubdiag-build"` | 指定 UbDiag 构建目录；Layer 0 实际不会编译它。 |
| 44 | `      SUBBUILD_DIR "${FETCHCONTENT_BASE_DIR}/ubdiag-subbuild")` | 指定 FetchContent 下载辅助工程目录，并结束调用。 |
| 45 | `  endif()` | 结束本地源码和在线源码的选择。 |
| 46 | `（空行）` | 分隔源码获取和头文件校验。 |
| 47 | `  set(_MOONCAKE_UBDIAG_PERF_POINT_HEADER` | 开始保存 PerfPoint 头文件的完整路径。 |
| 48 | `      "${ubdiag_SOURCE_DIR}/include/ubdiag/perf_point.h")` | 指向所选 UbDiag 源码中的 `perf_point.h`。 |
| 49 | `  if(NOT EXISTS "${_MOONCAKE_UBDIAG_PERF_POINT_HEADER}")` | 检查该头文件是否真的存在。 |
| 50 | `    message(FATAL_ERROR` | 如果不存在，准备在 CMake 配置阶段直接报错。 |
| 51 | `      "UbDiag ${MOONCAKE_UBDIAG_GIT_TAG} is missing include/ubdiag/perf_point.h")` | 报错信息中打印版本和缺失文件。 |
| 52 | `  endif()` | 结束头文件存在性检查。 |
| 53 | `  file(STRINGS "${_MOONCAKE_UBDIAG_PERF_POINT_HEADER}"` | 从 `perf_point.h` 中按行读取匹配内容。 |
| 54 | `       _MOONCAKE_UBDIAG_DISABLE_LINES REGEX "UBDIAG_DISABLE")` | 查找 `UBDIAG_DISABLE`，并把匹配行保存到变量中。 |
| 55 | `  if(NOT _MOONCAKE_UBDIAG_DISABLE_LINES)` | 如果没有找到 `UBDIAG_DISABLE`，说明版本不支持空实现。 |
| 56 | `    message(FATAL_ERROR` | 准备直接终止 CMake 配置。 |
| 57 | `      "UbDiag ${MOONCAKE_UBDIAG_GIT_TAG} does not support UBDIAG_DISABLE. "` | 第一段错误信息说明当前版本不支持禁用宏。 |
| 58 | `      "Select an UbDiag release that contains the compile-time disabled PerfPoint implementation.")` | 第二段错误信息要求换成带编译期 PerfPoint 空实现的版本。 |
| 59 | `  endif()` | 结束 `UBDIAG_DISABLE` 能力检查。 |
| 60 | `（空行）` | 分隔能力检查和 mock target 创建。 |
| 61 | `  # Consumers inherit both the source include path and the compile-time switch.` | 注释：消费者将同时继承头文件路径和禁用宏。 |
| 62 | `  add_library(ubdiag_mock INTERFACE)` | 创建不产生二进制文件的接口库 `ubdiag_mock`。 |
| 63 | `  target_include_directories(ubdiag_mock INTERFACE ${ubdiag_SOURCE_DIR}/include)` | 把 UbDiag 公共头文件路径传播给所有消费者。 |
| 64 | `  target_compile_definitions(ubdiag_mock INTERFACE UBDIAG_DISABLE)` | 把 `UBDIAG_DISABLE` 编译宏传播给所有消费者。 |
| 65 | `  add_library(UbDiag::ubdiag_lib ALIAS ubdiag_mock)` | 让统一目标名在 Layer 0 下指向接口 mock。 |
| 66 | `（空行）` | 分隔 mock target 和结果发布。 |
| 67 | `  set(MOONCAKE_UBDIAG_ACTIVE_LAYER "mock" CACHE STRING "" FORCE)` | 把当前层记录成 `mock`，供 P2P 构建脚本读取。 |
| 68 | `  message(STATUS "UbDiag: UBDIAG_DISABLE(空函数,零依赖)")` | 在 CMake 日志中明确打印当前使用空实现。 |
| 69 | `  return()` | Layer 0 完成后立即返回，不再执行 Layer 1 代码。 |
| 70 | `endif()` | 结束 Layer 0 条件块。 |

### L71-L123：Layer 1 真实库和 CLI

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 71 | `（空行）` | 分隔 Layer 0 和 Layer 1。 |
| 72 | `# ===== Layer 1: 编译真实 ubdiag =====` | 标记下面开始处理真实 UbDiag。 |
| 73 | `if(MOONCAKE_UBDIAG_SOURCE_DIR AND EXISTS "${MOONCAKE_UBDIAG_SOURCE_DIR}/CMakeLists.txt")` | 判断是否存在可用的本地 UbDiag 源码。 |
| 74 | `  FetchContent_Declare(ubdiag SOURCE_DIR ${MOONCAKE_UBDIAG_SOURCE_DIR})` | 本地源码有效时，声明 FetchContent 直接使用这个目录。 |
| 75 | `else()` | 没有有效本地源码时改用 Git。 |
| 76 | `  FetchContent_Declare(ubdiag` | 开始声明在线 UbDiag 依赖。 |
| 77 | `    GIT_REPOSITORY ${MOONCAKE_UBDIAG_GIT_REPOSITORY}` | 使用配置好的 Git 仓地址。 |
| 78 | `    GIT_TAG ${MOONCAKE_UBDIAG_GIT_TAG})` | 使用配置好的版本，并结束依赖声明。 |
| 79 | `endif()` | 结束本地和在线来源选择。 |
| 80 | `（空行）` | 分隔源码声明和功能开关。 |
| 81 | `set(UBDIAG_BUILD_SHARED ON CACHE BOOL "" FORCE)` | 强制 UbDiag SDK 构建成共享库 `libubdiag.so`。 |
| 82 | `set(ENABLE_PERCENTILE ON CACHE BOOL "" FORCE)` | 强制开启 P99/P999/P9999 分位数统计。 |
| 83 | `set(ENABLE_PERFLOG ON CACHE BOOL "" FORCE)` | 强制编译 PerfLog 功能。 |
| 84 | `set(ENABLE_OB_MEMORY OFF CACHE BOOL "" FORCE)` | 关闭 OB 内存 eBPF 观测功能。 |
| 85 | `set(ENABLE_OB_CACHE OFF CACHE BOOL "" FORCE)` | 关闭 OB cache/perf_event 观测功能。 |
| 86 | `set(ENABLE_MEMPOINT OFF CACHE BOOL "" FORCE)` | 关闭 MemPoint 功能。 |
| 87 | `set(UBDIAG_ENABLE_CACHEPOINT OFF CACHE BOOL "" FORCE)` | 预设关闭 CachePoint；当前固定 UbDiag 版本没有读取这个变量。 |
| 88 | `（空行）` | 分隔功能开关和子工程加载。 |
| 89 | `function(_mooncake_make_ubdiag_available)` | 定义一个函数，用函数作用域隔离 UbDiag 的通用构建变量。 |
| 90 | `  # UbDiag still exposes generic BUILD_* options. Keep the overrides inside a` | 注释：UbDiag 使用了通用的 `BUILD_*` 变量。 |
| 91 | `  # function scope so Mooncake's own BUILD_EXAMPLES value is not changed.` | 注释：函数作用域可避免修改 Mooncake 自己的同名选项。 |
| 92 | `  set(BUILD_TESTS OFF)` | 在函数内部关闭 UbDiag 自身测试。 |
| 93 | `  set(BUILD_EXAMPLES OFF)` | 在函数内部关闭 UbDiag 自身示例。 |
| 94 | `  FetchContent_MakeAvailable(ubdiag)` | 获取 UbDiag 源码并执行其 CMake，创建真实库和 CLI targets。 |
| 95 | `  set(ubdiag_SOURCE_DIR "${ubdiag_SOURCE_DIR}" PARENT_SCOPE)` | 把函数内得到的源码目录传回外层作用域。 |
| 96 | `endfunction()` | 结束函数定义。 |
| 97 | `_mooncake_make_ubdiag_available()` | 调用函数，真正把 UbDiag 加入构建。 |
| 98 | `（空行）` | 分隔子工程加载和 target 校验。 |
| 99 | `if(NOT TARGET ubdiag_lib OR NOT TARGET ubdiag)` | 检查真实 SDK target 和 CLI target 是否都存在。 |
| 100 | `  message(FATAL_ERROR` | 任一 target 缺失时准备终止配置。 |
| 101 | `    "UbDiag ${MOONCAKE_UBDIAG_GIT_TAG} did not create both ubdiag_lib and CLI targets")` | 错误信息说明必须同时生成 SDK 和 CLI。 |
| 102 | `endif()` | 结束 target 完整性检查。 |
| 103 | `（空行）` | 分隔 target 校验和 include 修复。 |
| 104 | `# UbDiag master still uses CMAKE_SOURCE_DIR internally. When consumed by` | 注释：UbDiag 内部仍使用顶层工程源码目录变量。 |
| 105 | `# FetchContent that variable points at Mooncake, so add the real source paths` | 注释：被 Mooncake 嵌入后，该变量会错误指向 Mooncake 根目录。 |
| 106 | `# to every UbDiag target without modifying the mirrored upstream sources.` | 注释：Mooncake 通过补 include 路径修复，不修改 UbDiag 镜像源码。 |
| 107 | `foreach(_MOONCAKE_UBDIAG_LIB_TARGET` | 开始遍历可能需要修复 include 的 UbDiag targets。 |
| 108 | `        ubdiag_logger ubdiag_lib ubdiag_runtime_lib ubdiag_manager_lib` | 列出 logger、SDK、runtime 和 manager targets。 |
| 109 | `        ubdiag_bpf_loader)` | 再加入可选 eBPF loader target，并结束列表。 |
| 110 | `  if(TARGET ${_MOONCAKE_UBDIAG_LIB_TARGET})` | 只处理当前构建中确实存在的 target。 |
| 111 | `    target_include_directories(${_MOONCAKE_UBDIAG_LIB_TARGET} PUBLIC` | 给该 target 增加公共 include 路径。 |
| 112 | `      $<BUILD_INTERFACE:${ubdiag_SOURCE_DIR}/include>` | 在构建阶段加入 UbDiag 公共头文件目录。 |
| 113 | `      $<BUILD_INTERFACE:${ubdiag_SOURCE_DIR}/src>)` | 在构建阶段加入 UbDiag 内部源码头目录。 |
| 114 | `  endif()` | 结束 target 存在性判断。 |
| 115 | `endforeach()` | 结束所有 UbDiag 库 target 的遍历。 |
| 116 | `target_include_directories(ubdiag PRIVATE` | 单独给 CLI target 增加私有 include 路径。 |
| 117 | `  ${ubdiag_SOURCE_DIR}/include` | CLI 可以找到 UbDiag 公共头文件。 |
| 118 | `  ${ubdiag_SOURCE_DIR}/src` | CLI 可以找到 UbDiag 内部源码头文件。 |
| 119 | `  ${ubdiag_SOURCE_DIR}/src/cli)` | CLI 可以找到自身目录头文件，并结束调用。 |
| 120 | `（空行）` | 分隔 include 修复和统一出口。 |
| 121 | `add_library(UbDiag::ubdiag_lib ALIAS ubdiag_lib)` | 让统一目标名在 Layer 1 下指向真实 SDK target。 |
| 122 | `set(MOONCAKE_UBDIAG_ACTIVE_LAYER "vendored" CACHE STRING "" FORCE)` | 把当前层记录成 `vendored`，供 P2P 构建读取。 |
| 123 | `message(STATUS "UbDiag: FetchContent 编译 ${MOONCAKE_UBDIAG_GIT_TAG}(库+CLI)")` | 在 CMake 日志中打印真实库和 CLI 已按指定版本构建。 |

## 2. `mooncake-transfer-engine/src/CMakeLists.txt`

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 1 | `file(GLOB ENGINE_SOURCES "*.cpp")` | 收集 Transfer Engine 当前目录中的 C++ 源文件。 |
| 2 | `include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)` | 加载两层分发入口，替代原来的系统 `find_package(UbDiag)`。 |
| 3 | `add_subdirectory(common)` | 继续加载 Transfer Engine 的 common 子目录。 |
| 4 | `add_subdirectory(transport)` | 继续加载 transport 子目录。 |
| 50 | `target_link_libraries(` | 开始声明 `transfer_engine` 的链接依赖。 |
| 51 | `  transfer_engine` | 指定要配置的目标是 `transfer_engine`。 |
| 52 | `  PUBLIC base` | 公开链接原有 `base` 库。 |
| 64 | `         UbDiag::ubdiag_lib)` | 链接统一 UbDiag 目标：Layer 0 传播空实现宏，Layer 1 链接真实库。 |

## 3. `mooncake-store/src/CMakeLists.txt`

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 253 | `# UbDiag instrumentation (FetchContent + UBDIAG_DISABLE 两层集成)` | 说明下面是新的 UbDiag 两层接入。 |
| 254 | `include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)` | 加载统一入口；如果 Transfer Engine 已加载过，会直接返回。 |
| 255 | `target_link_libraries(mooncake_store PRIVATE UbDiag::ubdiag_lib)` | 让 `mooncake_store` 使用当前层对应的 UbDiag 目标。 |
| 276 | `add_executable(mooncake_master master.cpp)` | 创建 Mooncake master 可执行文件。 |
| 289 | `target_link_libraries(` | 开始声明 master 的链接依赖。 |
| 290 | `  mooncake_master` | 指定目标是 `mooncake_master`。 |
| 299 | `          UbDiag::ubdiag_lib)` | 让 master 自身编译的打点代码也继承当前 UbDiag 层。 |
| 306 | `add_executable(mooncake_client real_client_main.cpp)` | 创建 Mooncake client 可执行文件。 |
| 308 | `target_link_libraries(mooncake_client PRIVATE mooncake_store transfer_engine` | client 链接 Store 和 Transfer Engine。 |
| 309 | `                                              asio_shared UbDiag::ubdiag_lib)` | client 再链接 ASIO 和统一 UbDiag 目标。 |

## 4. `mooncake-integration/CMakeLists.txt`

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 104 | `if(WITH_STORE)` | 只有启用 Store 时才构建 Python store 扩展。 |
| 105 | `  pybind11_add_module(store ${SOURCES} ${CACHE_ALLOCATOR_SOURCES}` | 开始创建名为 `store` 的 Python 原生模块。 |
| 108 | `  set_target_properties(store PROPERTIES INSTALL_RPATH "$ORIGIN")` | 设置模块运行时优先从自身目录寻找动态库。 |
| 110 | `  include(${CMAKE_SOURCE_DIR}/mooncake-common/FindUbDiag.cmake)` | 加载两层分发入口，替代系统 `find_package`。 |
| 111 | `  target_include_directories(store PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/store)` | 保留 Python store 模块自己的头文件路径。 |
| 112 | `  target_link_libraries(store PRIVATE UbDiag::ubdiag_lib)` | 让 Python store 模块使用同一个 UbDiag 层。 |

## 5. `mooncake-p2p-store/CMakeLists.txt`

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 1 | `# Currently you have to manually execute makefile in the src subdirectory.` | 注释：P2P Store 仍通过源码子目录中的外部构建方式编译。 |
| 2 | `add_custom_target(build_p2p_store DEPENDS transfer_engine)` | 创建 P2P 构建目标，并要求先构建 Transfer Engine。 |
| 3 | `add_custom_command(` | 开始给 P2P 目标添加自定义命令。 |
| 4 | `    TARGET build_p2p_store` | 指定命令属于 `build_p2p_store`。 |
| 5 | `    COMMAND bash build.sh` | 执行 P2P 的 `build.sh`。 |
| 6 | `            ${CMAKE_CURRENT_BINARY_DIR}` | 第一个参数：P2P 当前构建输出目录。 |
| 7 | `            ${USE_ETCD}` | 第二个参数：是否启用 ETCD。 |
| 8 | `            ${USE_REDIS}` | 第三个参数：是否启用 Redis。 |
| 9 | `            ${USE_HTTP}` | 第四个参数：是否启用 HTTP。 |
| 10 | `            ${USE_ETCD_LEGACY}` | 第五个参数：是否使用旧 ETCD 接口。 |
| 11 | `            ${CMAKE_BINARY_DIR}` | 第六个参数：Mooncake 总构建目录。 |
| 12 | `            ${MOONCAKE_UBDIAG_ACTIVE_LAYER}` | 第七个参数：把 `mock` 或 `vendored` 传给 shell 脚本。 |
| 13 | `    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}` | 指定脚本从 P2P Store 源码目录运行。 |
| 14 | `)` | 结束自定义命令。 |
| 15 | `set_property(TARGET build_p2p_store PROPERTY EXCLUDE_FROM_ALL FALSE)` | 让 P2P 目标进入默认构建。 |

## 6. `mooncake-p2p-store/build.sh`

### 参数读取

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 16 | `if [ "$#" -ne 7 ]; then` | 要求脚本必须收到 7 个参数。 |
| 17 | `    echo "Usage: $0 TARGET_PATH USE_ETCD USE_REDIS USE_HTTP USE_ETCD_LEGACY BUILD_DIR UBDIAG_LAYER"` | 参数错误时打印完整用法。 |
| 18 | `    exit 1` | 参数数量不对就返回失败。 |
| 19 | `fi` | 结束参数数量检查。 |
| 20 | `（空行）` | 分隔参数校验和参数赋值。 |
| 21 | `TARGET=$1` | 保存 P2P 输出目录。 |
| 22 | `USE_ETCD=$2` | 保存 ETCD 开关。 |
| 23 | `USE_REDIS=$3` | 保存 Redis 开关。 |
| 24 | `USE_HTTP=$4` | 保存 HTTP 开关。 |
| 25 | `USE_ETCD_LEGACY=$5` | 保存旧 ETCD 开关。 |
| 26 | `BUILD_DIR=$6` | 保存 Mooncake 总构建目录。 |
| 27 | `UBDIAG_LAYER=$7` | 保存 CMake 传来的 UbDiag 层。 |

### 链接参数

| 行 | 代码原文 | 这一行做什么 |
|---:|---|---|
| 35 | `EXT_LDFLAGS="-L$BUILD_DIR/mooncake-transfer-engine/src"` | 加入 Transfer Engine 库目录。 |
| 36 | `EXT_LDFLAGS+=" -L$BUILD_DIR/mooncake-transfer-engine/src/common/base"` | 加入 base 库目录。 |
| 37 | `EXT_LDFLAGS+=" -L$BUILD_DIR/mooncake-common"` | 加入 Mooncake Common 构建目录。 |
| 38 | `EXT_LDFLAGS+=" -L$BUILD_DIR/mooncake-common/src"` | 加入 Mooncake Common 源码对应构建目录。 |
| 39 | `EXT_LDFLAGS+=" -ltransfer_engine -lbase -lasio -lstdc++ -lnuma -lglog -libverbs -lmlx5 -ljsoncpp -lmooncake_common -lm"` | 加入原有基础链接库；这里不再无条件写 `-lubdiag`。 |
| 40 | `（空行）` | 分隔基础库和 UbDiag 分支。 |
| 41 | `# ubdiag 链接: vendored 模式链接真实库, mock 模式跳过(空函数无库)` | 注释：只有真实层需要链接 UbDiag。 |
| 42 | `case "$UBDIAG_LAYER" in` | 根据当前 UbDiag 层选择链接参数。 |
| 43 | `    vendored)` | 开始处理真实 UbDiag 层。 |
| 44 | `        UBDIAG_LIB_DIR="$BUILD_DIR/_deps/ubdiag-build/src/sdk"` | 指向 FetchContent 构建出的 SDK 目录。 |
| 45 | `        EXT_LDFLAGS+=" -L$UBDIAG_LIB_DIR -lubdiag"` | 把真实 UbDiag 库目录和 `-lubdiag` 加入链接参数。 |
| 46 | `        ;;` | 结束 `vendored` 分支。 |
| 47 | `    mock)` | 开始处理默认空实现层。 |
| 48 | `        echo "P2P Store: ubdiag DISABLE 模式,跳过 -lubdiag"` | 打印日志，说明 mock 层不链接 UbDiag 库。 |
| 49 | `        ;;` | 结束 `mock` 分支。 |
| 50 | `    *)` | 处理既不是 `mock` 也不是 `vendored` 的异常值。 |
| 51 | `        echo "P2P Store: 未知 ubdiag layer: $UBDIAG_LAYER,跳过 -lubdiag"` | 打印未知层告警，并跳过 UbDiag 链接。 |
| 52 | `        ;;` | 结束未知层分支。 |
| 53 | `esac` | 结束整个层选择。 |

## 7. 最终理解

只需要记住两点：

1. 所有 C++/Python 目标都写 `UbDiag::ubdiag_lib`；这个名字在 Layer 0 指向接口空实现，在 Layer 1 指向真实 `libubdiag.so`。
2. P2P Store 使用 Go 外链参数，不能直接继承 CMake target，所以单独接收 `mock/vendored` 并决定是否增加 `-lubdiag`。
