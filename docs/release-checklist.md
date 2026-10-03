# Release checklist

- [ ] M 系列/macOS 14+ 的 system 域普通 UID、无桌面会话采集通过；填兼容矩阵。
- [ ] 目标机传感器和 GPU 来源、有效值与降级有记录；没有温度可读的组合仅声明基础支持。
- [ ] 默认记录开启的 Release 0/1/3 客户端、三次 30 分钟、24 小时、登录瞬态和浏览器空白页对照满足预算。
- [ ] iOS Safari/Android 真机证书信任、配对/登录/撤销通过。
- [ ] 管理员授权/取消、首次系统安装、登录前采集、注销、端口冲突、关闭/停止、升级保留选择、卸载和失败恢复通过。
- [ ] 5 名首次用户安装验收完成，Gatekeeper 策略拒绝有记录。
- [ ] 配置正式 ReleaseRepository 与发布下载地址；对外公开安装器和校验清单。
- [ ] 项目所有者确认许可证及版权主体，生成 LICENSE；第三方许可证完整。
- [ ] 免费 ad-hoc 包及校验文件校验通过；源代码与包版本一致。
- [ ] FR/SC 覆盖审查完成，无未披露的软件缺口。

此清单是发行门槛，不能用开发机编译、浏览器自动测试或短时冒烟替代。

## v0.1.1 installation-path correction

The v0.1.0 installer rejected the standard root:admin 775 `/Applications` directory before copying the app. v0.1.1 accepts this entry-point directory without chmod, stores the real bundle at `/Library/Application Support/CloudMacMonitor/Cloud Mac Monitor.app`, and creates a root-owned launcher symlink at `/Applications/Cloud Mac Monitor.app`. Both launchd and the fixed administrator tool execute from the protected bundle, not through the public link. The link is replaced using atomic rename and never follows or deletes an unrelated destination. Account/history/TLS data locations are unchanged.

Four installation regression tests cover the default directory policy, managed link replacement/removal, unrelated directory/link preservation, and interrupted staging-link recovery. Live administrator installation and launchd registration remain target-machine acceptance tests. A legacy v0.1.0 real bundle can migrate only while its complete original code path is protected; an unsafe or unmanaged legacy entry is refused without executing its helper.

## v0.1.3 shutdown and sampling correction

The old signal handler inherited Swift 6 main-actor isolation but ran on a global signal queue, causing an executor assertion and abnormal-exit restart. The shutdown task also inherited the actor blocked by the top-level semaphore wait. Signal handlers are now explicitly Sendable and installed before startup; graceful shutdown runs in a detached task, with an explicit status-0 exit and a five-second fallback deadline. Owner IPC acknowledges the Agent PID and native Quit waits for actual process exit.

Default sampling is 10 seconds for all four channels, with 20-second constrained intervals and 60-second drive SMART caching. SMC queries use one connection per batch and cache readable keys. Names and core-family grouping follow the linked MacMonitor M2 reference; this does not pass the project's per-model hardware verification gate.

The 27-test Swift suite, localization/browser checks, HTTP/TLS tests with normal-exit assertions, temporary user-domain launchd lifecycle fixture, packaged Intel startup/shutdown smoke, dual-architecture builds, and signature/digest checks cover development validation. Native ⌘Q and production system-domain operation remain target-Mac acceptance; short Intel CPU diagnostics do not replace the M1 reference-machine or long-running performance gates.
