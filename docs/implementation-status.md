# 实现状态：2026-10-03

系统监控功能的软件实现已完成。按用户“继续做，验证等你全部完成我会在真机上做”的要求，硬件/管理员 UI/手机/长期预算不作为软件开发前置阻碍，也未标记为验收通过。

## 软件交付

- Swift 原生普通 UID Agent，CPU/内存/swap/压力、磁盘/网络、libproc 应用与成员排行、只读温度/GPU 适配，共享单调调度与睡眠/电源/热状态处理。
- 唯一账户、Argon2id、会话代次撤销、Origin/CSRF、所有者 Unix 通道、显式损坏状态恢复；LAN 的本地 CA、IP SAN、配对后独立登录、设备撤销和共享流限额。
- SQLite FULL/WAL 分层历史、加权查询与缺口、最终 Top 并集、有界近期缓冲、暂停持久化及 clear 的 recordingEpoch 屏障。
- React 概览/排行/成员/历史/设置，单 SSE 生命周期、离线与过期提示；简中/繁中/英语统一资源、自动注册与原生生成。
- 原生控制窗口、按需固定 root 维护工具、LaunchDaemon、启停选择/实际状态、刷盘握手、升级与恢复、免费 ad-hoc arm64/x86_64 应用包及固定版本哈希安装器。运行时不需要 Node/Homebrew/外部 SQLite。

软件任务已在 `tasks.md` 勾选。含真机、完整故障矩阵或公开发行条件的任务保留未勾选，并写明软件部分与剩余验收。实现按模块合并部分原任务的建议文件路径，覆盖映射见 [acceptance.md](acceptance.md)。

## 开发机证据

执行环境为 Intel macOS，不能代表 M 系列兼容性或默认性能预算。

| 检查 | 结果/产物 |
|---|---|
| Swift 风险测试 | 22 项通过，`artifacts/install-fix-tests.log` |
| 多语言资源与第四语言注册 | 3 项通过，`artifacts/final-i18n-tests.log` |
| 网页类型/生产构建 | `artifacts/final-web-build.log`；入口 JS+CSS gzip 约 76KiB，另计按需语言字典 |
| 真实 HTTP/IPC 流程 | `artifacts/final-http-smoke.json` |
| 真实 LAN TLS/配对/撤销/3 流限制 | `artifacts/final-lan-smoke.json`；校验证书链与 IP SAN |
| 三语言网页主流程 | `artifacts/final-browser-tests.log` |
| 双架构 Release/ad-hoc 包 | `artifacts/final-package-arm64.log`、`artifacts/final-package-x86_64.log`；构建不等于目标机运行验收 |

自动流程全部使用临时数据目录，未安装生产系统任务、申请管理员操作或修改系统证书信任。

## 拿到真机后的顺序

1. Apple Silicon 使用 `artifacts/MacMonitor-0.1.1-arm64.tar.gz` 与对应 `.sha256`，按 README 的 `--local` 安装入口执行。正式公开版本下载仍需配置 ReleaseRepository；项目 LICENSE/版权主体尚待确定。
2. 按 [install-validation.md](install-validation.md) 验证首次批准、普通 UID/system 域、管理员取消、无桌面/注销、升级启停保留、失败恢复及卸载。
3. 按 [mobile-setup.md](mobile-setup.md) 导入 CA、配对/登录与撤销，核对 360px 界面、手机证书与网络切换。
4. 按 [compatibility.md](compatibility.md) 对照 CPU/内存/应用和原始 sensor ID，建立机型温度/GPU 表。当前不把未验证传感器猜作 CPU 温度。
5. 按 [performance.md](performance.md) 跑实际 Agent 的 0/1/3 查看者、500/2,000 进程、登录瞬态、睡眠/回拨、历史故障/容量和 24h 场景；记录参考机数据后核对发行清单。

这些验收项及公开许可/发行地址决定能否正式发布。代码和本地构建产物可直接用于上述验收。

## v0.1.1 installation-path correction

The v0.1.0 installer rejected the standard root:admin 775 `/Applications` directory before copying the app. v0.1.1 accepts this entry-point directory without chmod, stores the real bundle at `/Library/Application Support/CloudMacMonitor/Mac Monitor.app`, and creates a root-owned launcher symlink at `/Applications/Mac Monitor.app`. Both launchd and the fixed administrator tool execute from the protected bundle, not through the public link. The link is replaced using atomic rename and never follows or deletes an unrelated destination. Account/history/TLS data locations are unchanged.

Four installation regression tests cover the default directory policy, managed link replacement/removal, unrelated directory/link preservation, and interrupted staging-link recovery. Live administrator installation and launchd registration remain target-machine acceptance tests. A legacy v0.1.0 real bundle can migrate only while its complete original code path is protected; an unsafe or unmanaged legacy entry is refused without executing its helper.

## v0.1.2 usability update

Temperature now uses named °C rows and CPU/graphics/drive peak rings, with opaque SMC IDs retained in details rather than assigned an unverified hardware role. HID discovery allows up to 64 readings. Internal/external drive discovery includes read-only ATA/NVMe SMART temperature reads cached for 60 seconds; unavailable interfaces and permission failures remain explicit.

The first local page shows account creation directly without a control-window ticket. Same-origin/Host checks, atomic single-account creation, damaged-state refusal, and the LAN setup prohibition remain in place. Control-window refresh and LAN explanations are localized in all three languages. Development checks include 24 Swift tests, three localization validator tests, HTTP/TLS smoke tests, and two browser tests including 360px temperature layout. External enclosure behavior and native administrator/UI checks require target hardware.

## v0.1.3 stop and sampling correction

Explicit native Quit (⌘Q) now sends owner-bound shutdown IPC, confirms actual Agent PID exit, and keeps the UI open if stopping fails. Window-close remains a background-monitoring action; system logout/restart does not issue the manual owner stop. The Agent exits with status 0 after a bounded shutdown, so KeepAlive/SuccessfulExit=false does not restart an intentional stop. Boot preference is preserved; administrator Stop service still disables and bootouts the job.

System/apps/temperature/GPU collection is now 10 seconds by default and 20 seconds under low-power/serious thermal constraints. Scheduler wakeup and gap detection, API capabilities, SSE publication, and web freshness match the lower frequency. SMC batch queries reuse one connection and cache readable keys. Reference temperature names follow the user-provided MacMonitor M2 SENSORS.md, separating die hotspots, SoC, proximity, memory, and VRM; raw IDs remain available and model attribution is not claimed as independently validated.

27 Swift tests, localization checks, HTTP/TLS/browser checks, and a temporary per-user launchd fixture cover the changes. The fixture confirms owner shutdown, SIGTERM exit, no successful-stop respawn, explicit restart, and abnormal-exit respawn. This is not installed system-domain or native ⌘Q hardware acceptance.

The shutdown regression reproduced a Swift 6 main-actor executor assertion in the old signal callback and a main-actor shutdown task blocked by the top-level semaphore wait. Explicit Sendable signal callbacks and detached shutdown work fix both. HTTP/TLS smoke cleanup now asserts exit status 0, so a crash during cleanup cannot count as a passing shutdown.

## v0.1.4 temperature-summary boundary

The frontend now honors explicit sensor categories before falling back to descriptive HID names. A CPU/charger proximity reading classified as system cannot enter the CPU die summary merely because its name contains CPU. Browser fixtures cover a hotter proximity reading and VRM reading excluded from the CPU summary. The v0.1.3 Agent termination and 10-second sampling fixes are unchanged.


## v0.1.5 control-window recovery

The v0.1.4 UI could refuse Quit after a failed owner shutdown, and Open monitor silently did nothing when no status address was available. The installed service intentionally remains stopped after a successful Quit; reopening the UI only queried status. Open monitor now refreshes IPC status, attempts administrator-authorized Start for the current owner when the installed service is unavailable, waits for readiness, and opens the current address. Failed status clears stale addresses and shows an error code. Start/Enable refresh status after the Agent becomes ready. Administrator AppleScript runs off the UI event loop. Failed shutdown shows a warning that the Agent may remain running and permits UI exit.

Native version/build and packaged web version are visible. Package version overrides are passed to the web build, so a release does not inherit the web package manifest's development version. Added four control-model tests for stale status, fresh Open queries, failed-shutdown exit, and absent-service exit. The original reported Agent startup failure cannot be identified from historical logs because that installation was removed. Apple Silicon installed-system and native authorization/quit interaction remain target-hardware checks.


## v0.1.6 reinstall after keeping data

Uninstall without data deletion leaves installation.json and disables the system job while removing the app. The old installer treated any retained record as an upgrade and tried to execute the missing old MonitorMaintenance binary. Reinstall now validates the same service owner and saved-data permissions, disables/bootouts a stale loaded job without executing missing code, and installs/starts the verified app while preserving data. Healthy upgrades still use the protected old helper; partial apps and dangling app links remain refused. Six temporary-path installer regression cases cover missing app, stale loaded job, healthy upgrade, partial app, dangling link, and unsafe data. The tests execute the real shell decision block and stub privilege checks/launchctl; installed system-domain operation remains a target-Mac check.


## v0.1.8 automatic LAN and independent service controls

The Agent automatically serves HTTPS on en0's active IPv4 address, before account setup; remote setup remains forbidden. It retries network availability and certificate renewal, ignores retired manual LAN settings, and never selects another interface. Pairing/device routes, IPC commands and native/web flows are removed. Clients use the existing account/password; local and LAN sessions remain isolated, and password changes revoke sessions and streams. Existing state schema tables are retained for upgrade compatibility; no account/history/CA data is deleted.

The control window now has two service buttons derived from read-only launchctl state without administrator prompts on refresh. Unknown state disables both actions. Boot enable/disable does not start/stop the current session; Start supports disabled boot startup using a temporary override, restores it even on start failure, and Stop flushes/bootouts without changing the boot choice. Upgrade restarts a previously running session even with boot disabled and restores that override after bootstrap. Validation includes 39 Swift tests, password-only en0 TLS and local HTTP smoke checks, temporary launchd lifecycle checks, seven installer cases, localization checks and browser checks. Installed system-domain and Apple Silicon runtime still require target-Mac validation.
