# Mooncake UbDiag Verification Evidence

本目录保存 Mooncake 两层 UbDiag 集成的可复核验证产物。验证脚本本身不属于正式交付代码，本目录仅保留运行日志、符号检查结果和 UbDiag CSV 输出。

## Non-UB/TCP Validation (2026-07-22)

验证环境使用 openEuler 24.03 LTS-SP1，传输协议为 TCP，UbDiag 固定为 `v0.5.1`，对应提交 `705c6c37da45df2be4bc64c134dca0b7f30b2113`。

验证结果：

- Layer 0 DISABLE 的 master/client/write/read benchmark 全部通过，最终读取失败数为 0。
- Layer 0 的三个可执行文件均不链接 `libubdiag`，不包含 `UbDiag::` 实现或引用符号，也不创建 UbDiag SHM。
- Layer 1 vendored 从同一份源码构建 `libubdiag.so` 和 `ubdiag` CLI，master/client/write/read benchmark 全部通过，最终读取失败数为 0。
- `ubdiag show` 输出 31 条数据，`show --detail` 输出 192 条数据，P99/P999/P9999 列完整。
- `ubdiag show --perflog` 输出 1892 条单次探针记录。
- show、detail、perflog、rawtable、watch、history 六类 CSV 均包含有效数据。

主要产物：

| 内容 | 路径 |
| --- | --- |
| 完整验证日志 | [`nonub_full_validation_retry4.log`](nonub_20260722/nonub_full_validation_retry4.log) |
| Layer 0 benchmark 日志 | [`layer0_disable/`](nonub_20260722/nonub_full_retry4_20260722/layer0_disable/) |
| Layer 1 benchmark 日志 | [`layer1_vendored/`](nonub_20260722/nonub_full_retry4_20260722/layer1_vendored/) |
| Layer 0 二进制符号检查 | [`nonub_full_retry4_20260722/`](nonub_20260722/nonub_full_retry4_20260722/) |
| UbDiag CSV 输出 | [`csv/`](nonub_20260722/nonub_full_retry4_20260722/layer1_vendored/csv/) |

本次验证不覆盖 UB/URMA 硬件链路。UB/URMA 验证需要在具备对应硬件和运行时的环境中单独执行。
