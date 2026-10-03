# Compatibility evidence

Target: macOS 14+ Apple Silicon. No Apple Silicon machine/OS combination has been verified yet.

The capability probe reads Mach CPU/memory and libproc process usage without AppKit, NSWorkspace, NSRunningApplication or a desktop-session dependency. It reports permissions and cost on the current caller; interactive execution does not prove system-domain/no-desktop behavior.

SMC opening status, HID service count and IOAccelerator presence are diagnostic capability signals. No temperature mapping or GPU statistics adapter has been verified. Temperature and GPU measurements are explicitly `unsupported` with null values. Thermal state is a separate raw system state, never converted to Celsius.

| Machine | Basic interfaces | Temperature/GPU | system/no-desktop | Support claim |
| --- | --- | --- | --- | --- |
| MacBookPro11,5 / macOS 15.7.9 / Intel | CPU, memory and partial process reads observed | SMC open failed in sandbox; no verified readings | Unverified | Development validation only |
| M1 8GB | Unverified | Unverified | Unverified | None |
| Pro/Max | Unverified | Unverified | Unverified | None |
| Latest base M series | Unverified | Unverified | Unverified | None |

## 软件适配进度（2026-10-03）

新增只读 AppleSMC readKeyInfo/readBytes、sp78/flt 解码、IOHID 温度事件和 IOAccelerator Device Utilization % 适配。传感器保留原始标识；不依据接口存在性或读数猜测 CPU/GPU 对应。最多展示 16 个候选传感器，未知格式/范围返回不可用；GPU 多适配器值采用可读设备的最大值，来源须注明。

协议参考为项目自身编写适配，不导入其他监测应用代码：[SMC 接口](https://github.com/exelban/stats/blob/master/SMC/smc.swift)、[HID 事件声明](https://github.com/exelban/stats/blob/master/Modules/Sensors/bridge.h)。目前 Intel 开发机完成编译与基础 CPU/内存/进程冒烟；M 系列温度和 GPU 对照仍未通过，能力表不填写虚假机型验证。
