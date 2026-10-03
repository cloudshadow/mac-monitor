# Tasks: Cloud Mac Monitor

**Input**: spec、plan、research、data-model、contracts、history-storage、installation-and-storage、signing-and-open-source、localization、realtime-data-flow、free-command-install、launchdaemon。
**Status**: 2026-10-03 已完成软件实现及开发机自动检查；真机验收按用户要求延后。`[P]`表示依赖完成后可并行处理的独立文件；实测门槛未通过的任务仍保留未勾选。
**Tests**: 按spec验收和宪章执行有针对性的计算、认证、存储及生命周期验证，不为静态文案编写镜像测试。

**用户授权调整（2026-10-03）**：代码实现持续推进；涉及真机、管理员图形交互、手机、长期性能的验收由用户在全部实现后进行。下文 G0/G4 的“先通过”改为发行前验证，代码依赖保持原顺序。含实测的任务仅在软件部分完成时记录软件进度，未实测部分不得勾选为通过。

## Phase 1: Setup

- [X] T001 初始化Swift包及macOS应用目标，锁定NIO/NIOSSL、SQLite、libsodium依赖与许可证信息于 `Package.swift` 和 `Package.resolved`。
- [X] T002 [P] 建立React + TypeScript + Vite生产构建及依赖锁文件于 `web/package.json`、`web/vite.config.ts` 和 `web/package-lock.json`。
- [ ] T003 编写M系列system域普通UID、无桌面会话下的能力/接口成本探针于 `Tools/CapabilityProbe/main.swift`，输出温度、GPU、权限和采样成本报告。
- [ ] T004 编写默认历史开启的Release基线探针于 `Tools/Benchmark/main.swift`，先验证NIO/TLS/SQLite与500进程采集预算，再开始完整界面。 同步在 `Tools/MaintenanceProbe/` 完成G4最小ad-hoc控制端、NSAppleScript授权及固定维护工具原型，实测sudo安装、授权取消、普通UID、enable/start/disable/stop和卸载，记录于 `docs/install-validation.md`；G0/G4未通过不开始完整界面，T041复用结论。

## Phase 2: Foundational

- [X] T005 建立Metric/身份/segment/快照类型及最小C桥于 `Sources/MonitorCore/Models.swift` 和 `Sources/CMacBridge/bridge.c`。
- [X] T006 实现数据库初始化、版本迁移、单写者与唯一账户约束于 `Sources/HistoryStore/StateStore.swift`；状态库损坏不得回到开放注册。
- [X] T007 实现持续系统1秒/应用4秒共享调度、单调时钟、暂停恢复、速率基线及有界工作队列于 `Sources/MonitorCore/Scheduler.swift`。
- [X] T008 建立静态资源/HTTP路由、Host/Origin校验与默认拒绝的认证中间件于 `Sources/MonitorServer/Server.swift`。 按contracts的请求类型矩阵实现：允许无Origin的受保护GET/SSE，写操作要求正确Origin；不放行跨源/null Origin。

## Phase 3: US5 创建账户并登录 (P1)

**Goal**: 本机唯一账户、密码验证、账户会话与恢复。
**Independent Test**: 本机首次创建、并发重复创建、登录失败、改密/注销撤销；使用设备资格夹具独立验证LAN联合认证。

- [X] T009 [P] [US5] 编写创建事务、setup票据、密码变更与会话撤销验收于 `Tests/AuthTests.swift`。 覆盖缺Origin的同源GET/SSE成功、缺Origin写操作及错误Host/跨源/null Origin拒绝。
- [X] T010 [US5] 实现Argon2id单任务队列/限流、setup/login/logout、auth/status的loginRequired、auth/session刷新CSRF及authEpoch于 `Sources/MonitorServer/AuthService.swift`。
- [X] T011 [P] [US5] 实现React账户创建/登录页面、刷新认证恢复、统一401导航及受保护路由于 `web/src/pages/Authentication.tsx`；不把token存localStorage。
- [ ] T012 [US5] 实现绑定服务所有者UID及Unix peer身份验证的本机密码恢复与控制通道于 `Sources/MonitorControl/LocalControl.swift`，验证SC-008/015。

## Phase 4: US6 多语言 (P1)

**Goal**: 未登录即可选择简中/繁中/英语；错误码可翻译；新增语言只添加资源文件，构建自动注册，遵循 `specs/001-hardware-monitor/localization.md`。
**Independent Test**: 三语言完成创建、登录和示例指标显示，切换不丢表单、不增加订阅；添加第四种测试语言目录可自动注册，无需改业务代码。

- [X] T013 [US6] 在 `locales/` 建立按语言/功能划分的 JSON、元信息、schema 和贡献指南；实现 `scripts/i18n/validate.mjs`、`scripts/i18n/generate.mjs` 的校验、自动注册与 TS 键/参数类型生成；在 `web/src/i18n/index.ts` 实现按需加载、有界字典缓存、浏览器匹配、英语回退、Intl 格式化及偏好存储。 普通插值生成string/Swift String语义，只有plural.argument为受限整数；npm脚本放web/package.json，根目录以npm --prefix web调用。
- [X] T014 [US6] 基于 T013 的统一资源契约，在 `scripts/i18n/generate.mjs` 增加 `native.json` 到 `Sources/MonitorControl/Resources/Localizable.xcstrings` 及原生键/参数包装的生成，覆盖插值转义、复数变体和语言选择，不手工维护重复翻译源。
- [ ] T015 [US6] 在 `web/tests/localization.spec.ts` 验收三语言完整流程、加载失败/缺失回退、连续切换、表单保留、SSE 数量及第四语言自动注册/按需请求；在 `scripts/i18n/validate.test.mjs` 覆盖重复键、参数及 published 完整性检查，在 `Tests/MonitorControlTests/LocalizationTests.swift` 验证原生生成结果；将校验接入构建和 CI，页面完成后运行流程验收。 覆盖普通参数误传数字、复数越界/小数、Web/原生参数顺序和转义一致性。

## Phase 5: US1 系统状态与温度 (P1)

**Goal**: 已验证系统指标、温度与真实降级。
**Independent Test**: 登录后加载概览，受控CPU负载变化可见，传感器缺失不画零。

- [X] T016 [P] [US1] 实现Mach CPU/内存与接口/磁盘计数器采集于 `Sources/MacCollectors/SystemCollector.swift`。
- [ ] T017 [P] [US1] 实现只读SMC/HID温度与GPU能力适配于 `Sources/MacCollectors/SensorCollector.swift`，发布机型验证记录于 `docs/compatibility.md`。
- [X] T018 [US1] 实现snapshot/capabilities/共享SSE、viewer总数6/活动流3的限额与慢连接限制于 `Sources/MonitorServer/MetricRoutes.swift`。 apps仅发送≤2KiB扫描通知，禁止完整应用表SSE；有界队列分别替换快照/通知。
- [X] T019 [US1] 实现React概览、选择器store与Canvas图表于 `web/src/pages/Overview.tsx`、`web/src/store/metrics.ts` 和 `web/src/components/TimeSeries.tsx`。
- [ ] T020 [US1] 验证差分、首次采样、缓冲释放、未知指标及温度对应关系于 `Tests/SystemCollectorTests.swift` 并记录真机对照。

## Phase 6: US2 应用排行 (P1)

**Goal**: 应用/进程CPU、footprint和磁盘I/O排行。
**Independent Test**: 已知多进程应用互斥归组、PID复用不污染、权限不足显示覆盖。

- [ ] T021 [US2] 编写PID复用、退出竞态、child计数不重复累加与归属夹具于 `Tests/ProcessCollectorTests.swift`。
- [X] T022 [US2] 实现libproc扫描、元数据缓存与500/2,000进程扫描调度于 `Sources/MacCollectors/ProcessCollector.swift`。
- [X] T023 [US2] 实现应用归属及分页路由于 `Sources/MonitorCore/AppAttribution.swift` 和 `Sources/MonitorServer/AppRoutes.swift`。 原子发布唯一当前表及四种共享排序索引；实现版本游标/409、页≤128KiB、显示名截断、成员独立分页和会话/全局查询限流。
- [X] T024 [US2] 实现排行搜索/排序/成员展开与覆盖提示于 `web/src/pages/Applications.tsx`。 实现通知触发共享缓存读取、单在途/最新合并、旧响应丢弃、有界409重试，翻页暂停自动替换并提示新版本。

## Phase 7: US8 持久历史 (P1)

**Goal**: 整机30天、应用摘要7天，持续共享采集并批量记录，最近五分钟优先读内存。
**Independent Test**: 固定样本与30天夹具验证分层、重启持久、Top并集、容量和故障降级。

- [ ] T025 [P] [US8] 编写加权桶、重试幂等、跨segment、最终Top并集及丢失窗口测试于 `Tests/HistoryAggregationTests.swift`。 覆盖查询时加权合并、maxPoints=1/600、30天720小时、多segment/缺口总点数与pointBudgetTooSmall。
- [X] T026 [US8] 实现SQLite历史库、FULL同步、单连接串行语句/检查点与有限缓存于 `Sources/HistoryStore/HistoryDatabase.swift`。
- [X] T027 [US8] 实现1m/5m/1h系统聚合及5分钟应用最终摘要于 `Sources/HistoryStore/Aggregator.swift`；在 `Sources/MonitorCore/RecentBuffer.swift` 实现360槽系统序列/90帧应用Top并集及4MiB近期共享缓冲，按 `specs/001-hardware-monitor/realtime-data-flow.md` 保留真实覆盖。
- [X] T028 [US8] 实现分钟提交、保留清理、容量高水位、写入失败状态和暂停/清空于 `Sources/HistoryStore/Retention.swift`。 在history.sqlite实现HistoryControl与recordingEpoch、pause持久边界、resume不回填、clear的epoch逻辑失效、串行屏障、旧批次拒绝和旧segment有界回收；近期内存暂停时继续，clear成功清空。
- [X] T029 [US8] 实现recent/history统一查询、内存/数据库边界去重与重启精度回退、最多8序列/600点、250ms数据库执行预算、应用分页与recordingStatus于 `Sources/MonitorServer/HistoryRoutes.swift`。 实现动态2h等查询合并、跨段总点数检查及实际源/输出精度、非对齐边缘桶语义、epoch查询/游标失效。
- [X] T030 [US8] 实现React时间范围、分辨率/覆盖/缺口与应用历史视图于 `web/src/pages/History.tsx`。 显示临时查询精度、暂停但近期可读、clear新epoch后取消旧请求并清空曲线；pointBudgetTooSmall引导缩小范围/增点。
- [ ] T031 [US8] 验证近期内存/数据库分界去重、缓存上限、重启精度回退、崩溃恢复、磁盘满、只读/损坏、30天数据量、查询中止和实际写放大于 `Tests/HistoryIntegrationTests.swift` 及 `Tools/Benchmark/HistoryScenario.swift`。 增加高频重启/唤醒/回拨导致多segment容量夹具，以及clear/排队提交/查询/崩溃交错，验证不复活旧历史。

## Phase 8: US3 局域网设备 (P1)

**Goal**: 本机显式开启LAN，手机配对并登录，访问可撤销。
**Independent Test**: iOS Safari与桌面浏览器信任证书、配对、登录；未配对/已撤销拒绝。

- [X] T032 [US3] 实现接口选择、TLS身份生命周期和动态端口于 `Sources/MonitorServer/LanListener.swift`。
- [X] T033 [US3] 实现票据兑换、设备资格及联合会话检查于 `Sources/MonitorServer/PairingService.swift`。
- [X] T034 [P] [US3] 实现原生地址/二维码/证书引导与React配对页面于 `Sources/MonitorControl/PairingGuide.swift` 和 `web/src/pages/Pairing.tsx`。
- [ ] T035 [US3] 验证配对不等于登录、跨会话viewer、设备撤销与3流上限于 `Tests/LanAccessTests.swift` 并记录手机实机步骤于 `docs/mobile-setup.md`。

## Phase 9: US4 长期开启且低占用 (P1)

**Goal**: 默认历史开启后仍满足稳态预算。
**Independent Test**: 无查看者/1/3客户端、本机React页、睡眠恢复与24h运行。

- [X] T036 [US4] 实现仅控制传输的可见租约、电源/热状态降频、无人查看仍1秒/4秒采集及恢复基线于 `Sources/MonitorCore/PowerPolicy.swift`。
- [X] T037 [P] [US4] 实现页面可见性、EventSource错误后HTTP核验认证、离线不误登出、客户端数据过期计时与单订阅生命周期于 `web/src/store/connection.ts`。
- [ ] T038 [US4] 完成持续1秒/4秒配置下0/1/3客户端采集次数不变、24h、登录瞬态与2,000进程基准入口于 `scripts/benchmark.sh`，写入 `docs/performance.md`。
- [ ] T039 [US4] 检查缓存、SQLite页/WAL、日志、文件句柄和React生产包体，并在 `docs/performance.md` 记录达标证据或调整项。

## Phase 10: US7 安装与开源发行 (P1)

**Goal**: 免费预编译.app的一行安装、安装器更新、图形化停止清理及源码自构建；公证为后续可选。
**Independent Test**: 干净Mac无额外运行环境完成安装；升级保留账号与历史；开发构建及首选发布包/安装器无Apple付费证书也成功。

- [X] T040 [US7] 实现安装位置检查、setup启动、单实例与图形化开关、新安装默认启用LaunchDaemon、bootEnabled/所有者绑定、期望/system任务加载/运行状态分离、自动启动不弹浏览器于 `Sources/MonitorControl/Onboarding.swift` 和 `Sources/MonitorControl/ServiceManager.swift`。
- [ ] T041 [US7] 按 `specs/001-hardware-monitor/launchdaemon.md` 在 `Resources/LaunchDaemons/org.cloudmacmonitor.agent.plist` 定义system域/UserName/启动与节流策略，在 `Sources/MonitorMaintenance/main.swift` 实现按需管理员授权的有限系统任务管理，在 `Sources/MonitorControl/Cleanup.swift` 实现禁用、停止及清理；验证免费ad-hoc授权流程、系统数据/TLS权限、无常驻root网络服务及旧用户任务迁移。 依赖T004的G4通过；落实launchdaemon状态表、prepareStop后bootout、root事务日志和局部失败反馈，图形入口调用固定维护工具。
- [X] T042 [US7] 实现按需检查更新、复制指定版本安装命令、运行中Agent协调与迁移失败恢复于 `Sources/MonitorControl/UpdateCoordinator.swift`；首版不依赖Sparkle或付费公证。
- [X] T043 [US7] 编写嵌入前端/SQLite/服务的免费ad-hoc归档打包于 `scripts/package-app.sh`，实现固定版本下载/校验、安全解包、管理员授权、系统目录安装及所有权校验、LaunchDaemon注册、首次批准引导、升级与失败恢复于 `scripts/install.sh`；公证DMG作为后续可选渠道，不作首版门槛。
- [ ] T044 [US7] 编写无付费证书的源码构建指南、贡献说明及依赖声明于 `README.md`、`CONTRIBUTING.md` 和 `THIRD_PARTY_NOTICES.md`；正式发布前确认MIT建议与版权主体再生成 `LICENSE`。
- [X] T045 [US7] 编写与fork隔离的普通构建/正式发行流程于 `.github/workflows/build.yml` 和 `.github/workflows/release.yml`，首选免费发布不依赖Apple凭据；若使用独立发布签名或可选Apple渠道，秘密仅用于受保护发行。
- [ ] T046 [US7] 在 `docs/install-validation.md` 记录SC-010/011的首次用户一行安装、Gatekeeper批准/策略拒绝、ad-hoc升级身份、包篡改/下载中断、端口冲突、重复启动、系统启动后尚未登录桌面即自动采集、退出Mac登录继续、网页未登录仍记录、管理员授权取消/system任务禁用后升级不重启用、FileVault边界和TLS不依赖登录钥匙串、崩溃节流、主动stop、更新失败与卸载实测。

## Phase 11: Polish & release gates

- [ ] T047 在 `docs/acceptance.md` 汇总FR-001～024、SC-001～015覆盖与所有缺口；完成quickstart端到端验收。
- [ ] T048 核对 `docs/compatibility.md`、`docs/performance.md` 和 `docs/release-checklist.md`，以实际测得的支持范围发布，不能将设计预算当成结果。

## Dependencies & Execution Order

Setup（G0/G4真机验收延至发行前） → Foundation → 账户认证 → 多语言基础 → 系统概览 → 应用排行 → 历史 → LAN联合认证 → 完整性能 → 安装/发行验收。

各故事可用稳定模型和受控夹具独立开发/测试；整体验收需上述集成顺序。US8应用摘要依赖US2，US3联合授权依赖US5，US4最终性能依赖US8默认记录配置，US7发布依赖所有P1完成。不能把只有US1的概览预览版称为完整首版。

## Parallel Opportunities

在对应阶段前提满足后：US5 T009/T011；US1 T016/T017；US2服务夹具与React排行可使用固定契约独立开发；US8 T025与T026；US3 T034与后端；US4 T036/T037；US7文档T044与安装实现可并行。US6 按 T013 → T014 → T015 完成统一翻译源及生成验证。这里描述任务关系，不自动请求额外开发者或执行agent。

## Implementation Strategy

按用户授权先完成 Foundation、账号、多语言、系统/应用监测、历史、LAN 和安装管理代码。G0～G4、目标机预算和发行检查保留到真机验收阶段。传感器在未完成机型验证时显示原始 ID/未验证映射，未知指标不补零。

## 实现进度（2026-10-03）

- 已勾选的软件任务覆盖工程/依赖、共享采样、账户/IPC、三语言、系统与应用页面、历史聚合/清空屏障、LAN TLS、低功耗处理、原生管理、安装更新、ad-hoc 双架构包和 CI。
- 测试源码集中在 `Tests/MonitorCoreTests/`；路由集中在 `Sources/MonitorServer/Server.swift`，系统管理 UI 集中在 `Sources/MonitorControl/MonitorControl.swift`。原任务中的建议拆分路径不是遗漏模块。
- T003/T004/T017/T020/T035：探针、适配器、软件认证/流限额检查和使用说明已实现；M 系列无桌面/机型温度、管理员 GUI 和手机检查未验收。
- T012/T015/T021/T025/T031：密码恢复、生成器/语言与计算测试、历史风险测试及软件流程已实现；完整 SC 场景、原生复数/归属/故障矩阵仍属后续验收，未用当前小型自动套件替代全部用例。
- T038/T039：实际 Release Agent 的 0/1/3 查看者基准入口、有界缓存/队列/SQLite/WAL 和包体记录已提供；24h、参考 M1 多轮性能、2,000 进程及实际物理写放大未验收。
- T041/T046：正式 LaunchDaemon、有限 root 维护工具、prepareStop 刷盘、事务日志/部分失败实际状态、安装器升级/恢复和图形入口已实现；未在开发机执行管理员安装/系统任务变更，系统场景由用户验收。
- T044：README/CONTRIBUTING/第三方许可证已完成；项目 LICENSE 与正式 ReleaseRepository 需所有者最终确定，未自行授予许可或发布。
- T047/T048：覆盖表、兼容边界、性能/安装步骤和发行清单已整理；quickstart 的目标机完整验收与发行门槛保持未勾选。

交付位置、自动证据与真机顺序见 `docs/implementation-status.md`。未勾选项明确表示尚未完成其全部验收范围，不代表阻止继续软件实现。

## 2026-10-03 usability revision

- [x] T049 Replace the temperature selector with named °C readings, CPU/graphics/drive peak rings, raw-ID details, and a layout checked at 360px.
- [x] T050 Discover internal/external storage and read available ATA/NVMe SMART temperatures without privileged writes; cache for 60 seconds and show unsupported/denied readings explicitly.
- [x] T051 Allow direct first-account creation from the same-origin loopback page; preserve atomic uniqueness, damaged-state refusal, and LAN rejection. Cover first access with browser and HTTP tests.
- [x] T052 Explain refresh status and LAN interface selection in all three control-window languages; remove the separate account-creation button.

External enclosure temperature availability and target-Mac GUI/hardware acceptance remain user validation tasks.
