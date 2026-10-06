# 免费的一行命令安装方案

日期：2026-10-01。用户已确定本方案为首版首选，替代首版强制公证DMG要求；不表示脚本或Release已发布。

## 可行结论

可以免费公开源码、构建带ad-hoc签名的arm64二进制，并提供安装脚本完成下载、校验、安装和启动。Apple silicon代码需要有效签名，ad-hoc签名可免费用于该技术要求；它不提供Developer ID发行者身份，也不等于Apple公证。[Apple嵌入命令行工具说明](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)。

“一行命令”可以减少手工安装操作，但不能保证所有macOS版本、企业策略和下载路径下都不触发首次运行确认。被Gatekeeper拦截时应给出Apple支持的针对该应用的批准入口，不自动关闭安全机制或静默抹去文件来源属性。[Apple首次打开说明](https://support.apple.com/en-sg/102445)。

## 推荐入口

未来公开发布后，提供固定版本的安装入口，形式如下（example.com为占位域名，目前不可用于安装本项目）：

```bash
curl -fsSL https://example.com/mac-monitor/v0.1.0/install.sh | /bin/bash
```

同时提供下载后阅读脚本再执行的方式。实际命令在仓库和Release地址确定、脚本实现并验证后生成；不能把未存在的GitHub路径当成可用安装链接。固定版本入口便于审查和重现，升级由用户明确执行。

### 安装脚本职责

1. 检查macOS版本、arm64架构、磁盘空间和已有安装。确认服务所有者本地UID/身份；普通权限下载，写系统目录和注册LaunchDaemon时请求管理员授权（sudo）。
2. 从固定HTTPS Release地址下载包含Agent、控制端、React静态资源、SQLite及全部必需库的预编译包，用户无需Node、Xcode、Homebrew或数据库服务。
3. 校验发布清单及包的SHA-256，条件具备时验证维护者的独立发布签名。自行生成的发布签名不需要Apple会员，但也不获得Apple信任；来自同一下载源的哈希仅能验证一致性，不能独立证明发行者身份。
4. 临时目录解包，检查归档路径/符号链接，验证应用内部文件及ad-hoc签名；先暂存新版本，失败保留旧版，避免把半下载文件覆盖到运行版本。
5. 经管理员授权默认安装至`/Applications/Mac Monitor.app`，保护代码所有权，注册system域LaunchDaemon，已有服务先通过本地控制协议协调停止与替换。保留系统Application Support/data中的账号与历史，不以重新安装为由重置数据库。
6. 启动应用控制端，服务就绪后打开本机创建账户/登录页。新安装经管理员授权默认注册“开机自动启动服务”（LaunchDaemon），展示系统批准状态，可关闭；重装/升级保留原选择，LAN仍由用户主动开启；操作系统确认和手机证书信任无法由命令承诺消除。
7. 输出实际安装位置、页面地址、版本、自动启动注册/系统批准状态、更新与卸载入口；明确报告失败和恢复动作，不静默假成功。

命令执行远程脚本意味着用户信任该脚本和发布源。仓库应公开完整安装器源码，固定release版本，不把安装器当成关闭系统防护的工具。

## 另两个免费选择

| 方式 | 前置条件 | 取舍 |
| --- | --- | --- |
| 自有Homebrew tap | 用户已安装Homebrew | 安装/升级入口熟悉；依赖Homebrew，不自动解决公证问题 |
| 从源码编译安装 | 匹配Swift/Xcode工具链及前端构建工具 | 无付费发行身份；首次耗时与磁盘占用明显更高 |

Homebrew可通过自己的tap分发，无需假定已被官方仓库收录；formula/cask及签名政策以实际实现时验证为准。[Homebrew Taps](https://docs.brew.sh/Taps)。

## 与既有架构的衔接与验证

采用LaunchDaemon，系统启动且数据卷可用后、尚未登录桌面时就采集，用户注销也继续；不弹浏览器，读取数据仍需Web认证。业务进程以指定普通服务所有者UID运行，系统安装/维护需管理员授权。系统目录、FileVault边界与完整生命周期见 [launchdaemon.md](launchdaemon.md)。

- 安装方式不改变Swift原生采集、React网页、SQLite历史、账户登录和多语言设计。
- ad-hoc分发验证动态库加载、system任务注册、普通UID无GUI运行、专用TLS文件读取、授权工具和升级身份；不能套用已公证包的结论。不以用户LaunchAgent替代已选定的LaunchDaemon，也不因采集权限不足自动将Web服务改为root。
- 无会员的第一版可使用显式重新运行安装器进行更新；保留稳定数据路径。付费Developer ID和公证DMG以后可作为另一发行渠道，数据库不迁移到新目录。
- 开发者可免费生成自己的更新签名，但这不使未公证应用自动获得Gatekeeper认可。免费安装测试应覆盖干净Mac、系统目录安装及管理员授权取消、下载失败、篡改/损坏包、企业策略拒绝和现有版本升级。
- 已同步spec的FR-017/024、SC-010/014及US7，允许一次终端操作和可能的应用特定首次确认；付费公证不再作为首版发布硬门槛。

## 已选定的首版方案

不付Apple年费时，优先“预编译包 + 开源的一行安装脚本”，后续提供可选Homebrew tap。把“一条命令完成下载与安装”作为目标，把首次系统授权、首次账户创建和可选手机配置保留为清楚可见的交互。

## 提前验证的安装路径

G4/T004先验证免费ad-hoc控制端和固定维护工具：首装终端sudo，已安装图形控制端以NSAppleScript管理员授权调用root保护的绝对工具路径；不让root运行远程流式脚本。T041/T043做完整整合，图形授权失败仍阻塞SC-011。命令状态及升级恢复按 [launchdaemon.md](launchdaemon.md)：disable保留当前运行，stop禁用并退出；已关闭但仍运行的服务升级后保持关闭且停止，安装器在停机前明确提示。

2026-10-03 安装路径修正：/Applications/Mac Monitor.app 为图形入口链接；实际代码位于 /Library/Application Support/CloudMacMonitor/Mac Monitor.app。默认 root:admin 775 的 /Applications 不修改权限，服务与固定管理员工具直接执行受保护路径。
