# Research: 能力与技术选择

研究日期：2026-09-30。以下区分官方接口、项目实现证据和本设计推断，均不是本机实测结果。

## R1 原生采集与资源口径

**Decision**: Mach + libproc；CPU/速率使用累计计数差分，内存主用 physical footprint。
**Rationale**: Apple 开源声明提供进程 rusage 与 CPU 时间、resident/footprint、磁盘字节字段；获取失败必须检查返回码。公开头文件不保证任意调用者都能读取所有 PID。
**Alternatives considered**: 周期调用 top/ps、遍历 task_for_pid；前者有启动/解析成本，后者权限与侵入性不符合默认方案。
来源：[libproc.h](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)、[resource.h](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/resource.h)、[host_statistics64](https://developer.apple.com/documentation/kernel/1502863-host_statistics64)。

## R2 温度与热状态

**Decision**: 温度采用按机型验证的只读适配器；thermalState 单独显示。
**Rationale**: Apple thermalState 给出系统热状态；Stats 的实现使用 SMC/HID 和机型传感器映射。M1/M2 甚至存在相同 key 对应不同核心的情况，因此推断“通用温度 API 能覆盖全部 M 系列”不成立。
**Alternatives considered**: 常驻 powermetrics、只显示热状态；前者需要评估权限与成本，后者不能满足摄氏度需求。
来源：[Apple thermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property)、[Stats 传感器实现](https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift)、[传感器映射](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)、[M2 映射问题](https://github.com/exelban/stats/issues/1012)。仅学习接口；复用代码前检查许可证。

## R3 GPU 与网络归属

**Decision**: 首版保证系统网络吞吐与应用 CPU/内存；GPU 总体为能力适配，逐应用 GPU/网络放后续实验。
**Rationale**: metalps 提供 Apple Silicon 进程 GPU 活动的实际实现，但驱动属性不是跨所有系统的稳定契约；活动时间也不等同于 GPU 算力份额。活动监视器能显示网络流量并不能证明存在等价的通用公开 API。
**Alternatives considered**: GPU 活动估算、持久 nettop 子进程；可用于未来可选模块，须评估代理/VPN/短命进程归属及新增开销。禁止从 CPU 占比推算 GPU 或网络流量。
来源：[metalps 原始项目](https://github.com/LoganBarnett/metalps)、[Apple 网络活动说明](https://support.apple.com/guide/activity-monitor/view-network-activity-actmntr1006/mac)。本地研究另核验 `man nettop` 的进程汇总与持续输出选项，尚未运行采集验证。

## R4 Swift 与 HTTP/TLS

**Decision**: Swift单服务、SwiftNIO HTTP/1.1 + NIOSSL、React + TypeScript + Vite静态网页（用户指定）。
**Rationale**: 官方 NIO 提供事件循环和 HTTP/1.1，NIOSSL 提供 TLS；不自写 HTTP 解析器。Swift 可直接接入 Apple 框架。本方案更低占用的预期来自单服务、共享采集与按需传输，需测量验证。
**Alternatives considered**: Rust + axum 合理但需额外 macOS 桥接；NWListener 只解决连接监听，仍要可靠 HTTP 实现；Electron 引入常驻浏览器运行时；常驻 Node 服务对本场景无必要。
来源：[SwiftNIO](https://github.com/apple/swift-nio)、[NIOSSL](https://github.com/apple/swift-nio-ssl)、[NWListener](https://developer.apple.com/documentation/network/nwlistener)。

## R5 采样、电源与运行方式

**Decision**: 一套持续共享调度，默认系统1秒/应用4秒、温度10秒/GPU5秒，允许leeway；隐藏页只断流，不改变采样。用户明确选定LaunchDaemon：免费安装器请求管理员授权，注册system任务，通过UserName绑定普通业务身份；采用系统数据目录和专用TLS文件，避免依赖登录会话，见 [launchdaemon.md](launchdaemon.md)。
**Rationale**: Apple Dispatch 允许合并定时器唤醒；计划中的节省幅度需实测，不能由 API 能力推导具体 CPU 数字。
**Alternatives considered**: 每客户端启动采集循环、无界历史、包括温度在内固定1秒轮询所有传感器，都会增加工作量。
来源：[dispatch_source_set_timer](https://developer.apple.com/documentation/dispatch/dispatch_source_set_timer)、[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)。

## 尚须实验验证的风险

| 风险 | 验证动作 | 失败处理 |
| --- | --- | --- |
| NIO/TLS/Swift 内存基线超过预算 | G0 Release 基准 | 削减依赖、缓存与常驻控制端，必要时比较 Rust 原型 |
| 温度缺失或映射错误 | G1 多代 M 系列及系统版本验证 | 支持矩阵明确缺口；不得宣称完整温度支持 |
| 私有 GPU 数据变动 | G1 支持探测与升级回归 | unsupported，不影响基础指标 |
| 手机证书信任体验 | G2 iOS 与桌面实机配对 | 完善信任流程；不以明文回退作为已完成 |
| 500/2,000 进程扫描成本 | 独立进程数/负载实验 | 降频并展示覆盖；优化后再承诺预算 |

## Spec Kit 工作流来源

本项目已用本机 Specify CLI 1.0.3 初始化，使用安装的技能与模板生成宪章、需求、计划和任务。结构参考 [Spec Kit 官方项目](https://github.com/github/spec-kit)。本轮同步历史、认证与前端设计并生成tasks.md；当前不启动implement。

## R6 Docker 部署可行性

Web/API 可以容器化，但 macOS 原生采集器仍须在宿主运行。极低占用目标下推荐保留原生单服务。架构依据、权限边界、混合部署及开销计量见 [deployment-options.md](deployment-options.md)。此记录保留架构比较依据。

后续用户已确认第一版不采用 Docker，使用原生应用安装。

## R7 安装与SQLite（按最新需求修订）

**Decision**: 用户明确要求历史后，采用内嵌SQLite、内存聚合、分钟批量事务；系统30天、应用摘要7天。安装首选免费预编译包+开源一行安装器，用户不安装数据库。
**Rationale**: SQLite无独立服务，便于有界范围查询与事务恢复；不把每次实时采样都写盘。WAL+FULL同步、有限缓存和受限查询作为默认，实际CPU与写放大需真机验证。
**Alternatives considered**: JSON逐样本文件会使长范围查询/清理复杂；独立时序数据库增加进程与运维；WAL+NORMAL可减少同步但断电持久性边界更弱，不默认采用。
来源：[SQLite WAL](https://sqlite.org/wal.html)、[同步模式](https://sqlite.org/pragma.html#pragma_synchronous)、[SQLite无服务器架构](https://www.sqlite.org/serverless.html)。设计见 [history-storage.md](history-storage.md)。

## R8 React与多语言

**Decision**: React + TypeScript + Vite生产静态构建，页面按需加载、Canvas按数据更新、单SSE外部store订阅、简中/繁中/英文资源字典。
**Rationale**: 用户指定技术栈；生产无需常驻Node。React框架选择不能代替浏览器开销验证。
**2026-10-01 补充决定**: 用户要求文件便于扩展，采用 `locales/{tag}/{namespace}.json` 和语言元信息；构建自动发现语言并生成 Web 注册表、类型及原生资源。按需加载，缓存限当前语言与英语；新增语言不改业务代码。结构、插值/复数约束及贡献流程见 [localization.md](localization.md)。
来源：[React应用构建](https://react.dev/learn/build-a-react-app-from-scratch)、[Vite生产构建](https://vite.dev/guide/build)。

## R9 单账户密码保护

**Decision**: Argon2id，通过libsodium固定已验证参数；初始64MiB交互配置，全局单任务、有限排队和限流。每请求检查会话，不重复KDF。
**Rationale**: 密码验证需要刻意保留计算成本，区分登录瞬态和长期监测负载；不能为“低CPU”使用快速普通哈希。单账号SQLite事务保证首次创建与authEpoch一致。
来源：[libsodium密码哈希](https://doc.libsodium.org/password_hashing/default_phf)。

## R10 开源与发行费用

**Decision**: 用户确定免费预编译ad-hoc包+公开一行安装器为首选；Developer ID/公证DMG为后续可选渠道。许可证建议MIT，正式发布前由项目所有者确定。
**Rationale**: Apple Developer Program当前通常99美元/年，包含Developer ID与公证；个人开源不自动符合非营利机构减免条件。
来源：[Apple会员比较](https://developer.apple.com/support/compare-memberships/)、[官方减免资格](https://developer.apple.com/help/account/membership/fee-waivers)、[MIT原文](https://opensource.org/license/mit)。细节见 [signing-and-open-source.md](signing-and-open-source.md)。

## R11 持续采集、缓存与传输

系统1秒/应用4秒提高为待测默认，最近五分钟优先内存、系统仍每分钟持久聚合；多客户端共享采集但网络/渲染成本仍增加。首版保留SSE+HTTP，明确401前端导航、EventSource错误认证核验和独立过期判断；具体算法、频率成本推导和协议依据见 [realtime-data-flow.md](realtime-data-flow.md)。

## R12 LaunchDaemon启动与权限

用户明确选择不依赖桌面登录的系统级自启动。使用system域LaunchDaemon、指定普通服务所有者UID，按需特权安装/维护而非root Web服务；路径、身份绑定、无GUI采集、FileVault及权限验收见 [launchdaemon.md](launchdaemon.md)。这替代旧用户LaunchAgent和无需管理员授权安装假设，Apple付费会员仍非必需。


## 审查修订决策（2026-10-01，用户已确认）

| 编号 | 决策与定位 | 实现/验收 |
| --- | --- | --- |
| I1 | history-storage：查询时合并为2h等桶，跨所有段合计遵守maxPoints；无法保真合并时明确拒绝 | T025/T029/T031，SC-012 |
| U1 | launchdaemon：NSAppleScript系统授权调用固定维护工具；首装sudo，G4提前验证ad-hoc路径 | T004 → T041/T043/T046，SC-011 |
| U2 | HTTP契约：apps仅通知扫描版本，按页读取唯一共享表，有界重试/响应/查询 | T018/T023/T024/T038 |
| I2 | history-storage：267,264与60,480仅单连续segment名义估算，实际执行磁盘预算 | T028/T031 |
| U3 | launchdaemon：明确start/enable/disable/stop状态表、停机握手及局部失败日志 | T004/T040/T041/T046 |
| U4 | HTTP契约：按请求类型校验Origin，正常GET/SSE可缺失，写操作仍严格验证 | T008/T009，SC-008 |
| U5 | history-storage/data-model：HistoryControl、epoch和串行屏障；暂停与清空范围明确 | T028～T031，FR-022 |
| U6 | localization：普通参数全部string，复数计数受限整数，Web/原生生成一致 | T013～T015，SC-009 |

授权机制参考[Apple命令参考](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html)及[TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html)。该文档依据支持机制选择，不等于已验证目标系统的免费发行兼容性。launchctl enable/disable/bootout/kickstart语义已只读核对本机手册；G4仍须实测。GET缺Origin依据[Fetch规范](https://fetch.spec.whatwg.org/#origin-header)。

本次只修正文档；48项实现任务仍未执行，硬件支持、免费安装和持续1秒/4秒性能仍须真机验收。
