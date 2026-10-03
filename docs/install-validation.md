# Installation and G4 validation

Implementation started: 2026-10-03. Prototype label `org.cloudmacmonitor.probe` is isolated from the future production `org.cloudmacmonitor.agent`. No production installer has been implemented.

## Available prototype

- `MaintenanceProbe` is a minimal SwiftUI control app using its own `NSAppleScript` and `do shell script … with administrator privileges`.
- Commands are compiled enum values only: status, enable, start, disable, stop, uninstall. No arbitrary shell, target user, URL, SQL or path is accepted by the helper.
- The fixed installed helper validates root ownership, non-writable paths and no symlinks; operations have a lock and root-protected journal. Failures report partial state rather than claiming success.
- `disable` leaves the current task loaded; `stop` disables and then bootouts. `start` rejects an explicitly disabled task. `enable` enables and bootstraps/kickstarts. No `kickstart -k` is used.
- Prototype uninstall removes the job/plist only. The prototype app/data remain for inspection. Full graphical cleanup and production migration/recovery belong to T041/T043.
- The prototype currently has no `prepareStop` protocol. Forced stop can lose the uncommitted minute. This limitation blocks G4 completion and is not a production stop implementation.

## Manual test procedure (changes system state)

First build and inspect the probe bundle. The following installer requires an explicitly authorized administrator operation:

```bash
bash scripts/build-maintenance-probe.sh
sudo bash scripts/install-maintenance-probe.sh "$PWD/artifacts/Cloud Mac Monitor Probe.app"
```

The local installer copies to root-protected staging and validates the copy, binds `SUDO_UID`/local GeneratedUID, installs root-owned app/plist and owner-only data. It refuses existing paths. It does not register/start the task; use the installed app's explicit `enable` command.

1. Open `/Applications/Cloud Mac Monitor Probe.app`. Click status, cancel authorization, and confirm neither the job nor operation journal changed.
2. Click enable, then status. Verify launchctl reports `system/org.cloudmacmonitor.probe`, ordinary process UID, actual loaded/running states and the benchmark's loopback listener.
3. Click disable and verify the current PID remains running. After stop, start must return serviceDisabled. Explicit enable should start again.
4. Test authorization cancellation before each mutation, then stop/uninstall. Inspect `/Library/Application Support/CloudMacMonitorProbe/operation.json` on failure. Do not infer running from plist existence.
5. On Apple Silicon, separately test after reboot at the actual macOS login window and after desktop logout. FileVault unlock is a separate boundary. Save capability output from the system context and record the owner UID.

## Evidence and gates

| Gate/scenario | Status | Evidence |
| --- | --- | --- |
| G4 compile/ad-hoc bundle | Passed on current Intel development host | Release build, `codesign --verify --strict --deep` and Info.plist lint passed; local bundle at `artifacts/Cloud Mac Monitor Probe.app` |
| sudo system installation | Not executed | Requires an authorized system mutation |
| GUI authorization + cancellation | Not executed | Requires desktop interaction on target Mac |
| ordinary UID / no desktop session | Not executed | Current process is interactive on Intel |
| enable/start/disable/stop/uninstall | Not executed | Only code and enum tests exist |
| production prepareStop / partial-failure recovery | Implemented; target acceptance pending | Software IPC smoke confirms flush acknowledgement; system authorization/recovery remains open |
| macOS 14 + current Apple Silicon | Not executed | Target hardware needed |

SC-010/011 and T004/T041/T046 are not passed by the existence of this prototype.

Read-only `launchctl print-disabled system` inspection on macOS 15.7.9 returned `enabled/disabled`. The parser supports those and older `true/false` forms, rejects unknown states, and has a passing regression test. No enable/disable/bootstrap/bootout command was executed during this development run.

## 完整实现后的真机步骤

使用 `scripts/package-app.sh` 生成对应架构包和哈希，或使用交付的 arm64 包。可通过 README 的 `install.sh VERSION --local ARCHIVE SHA256` 入口验收，无需预先发布到 GitHub。安装器尚未在此会话以管理员运行，没有注册真实后台任务。原生控制端、维护工具、plist 和 root 暂存安装/升级代码已落地；以下仍是待验收：

1. 检查 /Applications、/Library/Application Support 和 /Library/LaunchDaemons 的所有权与可写性；安装器拒绝普通用户可替换的父路径，不擅自 chmod 系统目录。
2. 校验包/哈希，首次 sudo 安装默认启用普通 UID system 任务；打开控制窗口创建唯一账户。检查 UID 和 GeneratedUID 绑定、root 文件及数据 0700/数据库 0600。
3. 图形 enable/start/disable/stop 的授权成功和取消；disable 保留本次运行，stop 先 prepareStop 后 bootout，不应被 KeepAlive 拉起。连续短期失败由启动熔断停止；明确 enable 可清除熔断。
4. 关闭自启动后升级必须保持关闭；已启用但未运行保持未运行。已启用且运行的升级恢复运行；关闭但仍在运行的升级停机后保持关闭。bootout/启动失败应保留事务信息与上一版包，不能报伪成功。
5. 验证登录前、用户注销后及钥匙串未解锁仍采集；FileVault 未解锁阶段另记录。睡眠/唤醒和网络地址变化后基线/证书/地址更新。
6. 端口冲突、重复实例、下载截断、哈希错误、危险归档、Gatekeeper 策略拒绝及系统权限拒绝。
7. 账户损坏仅显式所有者恢复，不开放公开注册；历史独立。卸载默认移除应用和 plist、保留数据目录；删除持久数据是独立选择，不与普通卸载混同。

运行路径为固定根下 `data/state.sqlite`、`data/history.sqlite`、`data/run/control.sock` 和 `data/secrets/`。run/secrets 嵌套于 data 的实现布局仍使用普通服务所有者、0700 与 root 保护的上级安装根，不依赖 HOME 或个人钥匙串。
