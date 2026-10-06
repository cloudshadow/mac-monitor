# LaunchDaemon 系统级自启动

**Updated**: 2026-10-01。用户明确选定 LaunchDaemon；替代此前登录后启动的 LaunchAgent 方案。当前仅设计，未安装、提权或启动任何系统服务。

## 启动和运行边界

- 系统启动完成、数据卷可用后自动运行唯一采集/Web服务；无需登录Mac桌面或监控网页。用户登录、切换用户、锁屏及退出登录不停止服务。
- 系统保持唤醒时持续系统1秒、应用4秒采样；睡眠暂停、唤醒重新建立差分基线，关机停止。软件不默认阻止系统睡眠。
- FileVault在启动阶段等待解锁时不能承诺第三方服务已运行；系统数据卷可用后才进入服务启动验收。不能把FileVault解锁界面当作已完整启动的macOS登录窗口。
- 自动启动只启动服务，不打开浏览器；首次安装完成或用户主动打开控制端时才打开网页。账户会话在服务重启后失效，需要重新登录网页；采集与历史记录不依赖该会话。

## 系统启动域与运行身份

首版由安装器在 `/Library/LaunchDaemons/org.cloudmacmonitor.agent.plist` 安装固定任务，注册到launchd的 **system** 域。不再注册用户LaunchAgent，也不使用SMAppService登录项作为回退；未来如采用SMAppService.daemon，是另一种系统任务注册实现，不能并存两个任务或绕过系统拒绝。

**LaunchDaemon不等于业务进程必须以root运行。** 首版通过plist的 `UserName` 指定安装时确认的本机普通用户（服务所有者），launchd在用户未登录桌面时也可用该身份启动任务。保持原方案的普通用户采集权限，避免让HTTP/TLS/SQLite进程长期以root运行；不能据此承诺读取所有其他用户的受限进程。

安装器记录并校验所有者UID及本地账户GeneratedUID，拒绝root作为业务运行身份；用户从sudo发起安装时解析真实发起者，不将root误记为所有者。不将命令行任意用户名当作已授权目标；无人值守安装需显式指定并验证本地账户。账号改名/删除/身份不匹配时明确报错，禁止自动改为root或接管同名新用户；本机管理员可执行显式迁移。

本机控制权限仍属于指定服务所有者，而不是当前恰好登录的任何用户：Unix socket限制为所有者访问并验证内核提供的peer UID，不能相信请求里的uid。管理员恢复/所有者迁移走按需授权工具。其他本机用户若要查看数据，也必须走既有Web认证；唯一Web账户仍是整台Mac一份。

来源：[Apple launchd生命周期](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)。实现前还需核对目标系统 `man launchd.plist` 的UserName、RunAtLoad、KeepAlive与ThrottleInterval语义；本轮已只读核对本机手册，不能替代目标Apple Silicon测试。

## 安装位置与权限

| 内容 | 位置 | 权限/职责 |
| --- | --- | --- |
| 原生控制端、服务二进制、静态网页 | `/Library/Application Support/CloudMacMonitor/Mac Monitor.app` | 管理员安装，root拥有；所有父目录和包内可执行/库/资源均不可由普通用户替换 |
| 应用程序入口 | `/Applications/Mac Monitor.app` | 指向受保护程序的 root 所有入口链接；允许 /Applications 默认 root:admin 775，服务与管理员工具不经此链接执行 |
| 系统启动任务 | `/Library/LaunchDaemons/org.cloudmacmonitor.agent.plist` | root:wheel、0644，绝对程序路径和参数数组，不调用用户shell或读取用户PATH |
| 系统配置及目录根 | `/Library/Application Support/CloudMacMonitor/` | root拥有，普通用户不可替换目录；保存所有者绑定及安装元信息 |
| 数据库与受限日志 | 上述目录的 `data/` | 服务所有者拥有、0700；数据库及sidecar为0600；沿用history.sqlite/state.sqlite分离 |
| TLS私钥与本地CA秘密 | 上述目录的 `secrets/` | 服务所有者拥有、0700；文件0600；不依赖个人登录钥匙串解锁 |
| 本地控制socket | 上述目录的 `run/control.sock` | run目录服务所有者拥有、0700，socket0600；peer UID及服务身份校验 |

root拥有的父目录防止其他普通用户替换路径；服务仅可写自己的data/secrets/run，不可改启动任务或自身代码。TLS秘密保存在受权限保护的文件中，设备管理员仍可读取；不能把文件权限称为独立磁盘加密。系统数据卷和FileVault条件仍适用。所有根路径显式传入，不从HOME推导。

首次启动由服务身份生成数据及TLS秘密；不将私钥放入app包、下载归档或安装日志。秘密缺失/权限错误只使LAN无法启用，本机采样/历史应独立运行。之前若存在用户目录版本，必须停旧服务后显式迁移、核对所有者及数据库一致性，保留有界恢复备份；禁止自动合并多个用户的数据、重置账号或遗留旧LaunchAgent双重采集。当前尚无已发布旧版，但安装验收应覆盖该夹具。

## 管理员授权与免费一行安装

一行安装仍免费，维护者不需购买Apple会员。区别是写入系统目录、注册启动任务、升级和卸载需要Mac本机管理员授权；终端安装器可使用sudo，并清楚展示其用途，不能声称无密码或零确认。

下载/初步校验以普通用户执行；授权后在root控制的暂存目录复核产物，安全解包、检查归档路径/符号链接、所有权和签名，再安装固定文件。避免校验后继续从用户可改的目录读取待执行代码造成替换窗口；不执行root权限下的远程流式下载脚本，不开放任意路径、任意shell/SQL接口。保留已公开的安装器审查流程及同源哈希信任边界。

只在安装和系统管理动作运行按需特权工具，不新增常驻root网络服务或看门狗。系统任务操作通过固定枚举和路径执行；授权失败不改启动状态。图形控制端使用系统管理员授权流程调用同一有限工具，不提供setuid二进制、不写免密码sudo规则、不把管理员密码传给Web服务。图形控制端首版采用应用自身执行的NSAppleScript `do shell script … with administrator privileges`调用已安装、root拥有的固定MonitorMaintenance绝对路径；不tell其他应用执行、不传用户名/密码、不调用已废弃的AuthorizationExecuteWithPrivileges。命令只从编译期枚举生成，参数固定且正确shell引用，不插入网页输入、用户名、下载URL或任意路径；维护工具再次验证枚举和固定根路径。系统可能复用短期授权，不承诺每次都有密码弹窗。初次安装仍由公开终端安装器sudo完成受保护工具的引导安装。

这是选定的实现候选，兼容性尚未实测：T004的G4必须先验证最低支持macOS及当前版本上的免费ad-hoc控制端授权、取消、安装/启停/卸载，T041/T043再做完整整合。GUI路径失败时提供同一有限工具的终端sudo操作用于诊断，但SC-011图形入口门槛仍未通过，不能据此发布完整首版。依据：[Apple AppleScript命令参考](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html)、[TN2065](https://developer.apple.com/library/archive/technotes/tn2065/_index.html)。

## 任务生命周期

- 新安装 `bootEnabled=true`，初始化服务所有者及持久数据后注册系统任务；重装/升级保留用户关闭状态和系统禁用状态，不自动重新启用。
- 设置RunAtLoad，并为异常退出设计KeepAlive条件和ThrottleInterval（初始30秒待验证）；不要配置无条件无限重启。服务早期记录短窗口启动失败，连续失败触发熔断并提供本机修复入口，日志轮转，不增加常驻监控进程。
- 系统命令遵循下表：start仅启动已启用任务，enable启用并启动，disable只关闭后续开机加载、保留本次运行，stop停止并关闭开机启动。修改system任务需管理员授权，普通网页登录不能执行。
- stop/卸载先持久禁用启动并核验，向存活Agent发送prepareStop：停止接纳新工作、最多5秒刷盘后报告ready但保持存活，随后bootout撤销加载并终止服务；不在bootout后再请求已退出的服务刷盘。服务无响应也在限时后bootout，报告可能未提交的窗口。升级使用同一停机握手，恢复规则见下表；禁止两份服务重叠运行。
- 由启动管理器报告期望配置、system任务实际启用/加载状态、进程运行/健康状态，不能把plist存在当作服务已运行。服务不运行时按需本机工具仍能读取系统状态并修复。
- 未创建Web账户时只提供受保护的本机初始化入口，不开放LAN。setup票据由服务验证所有者控制通道后签发；重启后无人登录Mac不意味着开放注册或免认证。

## 无桌面会话与权限能力探针

采集层不得依赖NSRunningApplication、NSWorkspace或登录用户GUI会话才能运行；基础采集使用Mach/libproc/IOKit，应用归属使用可验证的进程可执行路径及bundle元信息。GUI信息只能是可选补充，缺失时显示未归属/部分可见。系统域进程对同UID与其他UID的可读范围、温度接口、电源/睡眠通知及网络恢复均重新探测。权限不够不能自动改为root；如确有核心能力只能提权，应独立设计最小采集helper并重新计入性能预算。

## 验收

G0/G1增加系统域普通UID、无GUI会话探针。SC-011/T046必须覆盖：

1. 重启后停留真正的macOS登录窗口时已采集；若FileVault需先解锁，分别记录解锁前、系统启动后与桌面登录后的时间，不能以桌面登录后结果冒充登录前。
2. 已启用LAN时在网络就绪后，手机重新登录可查看；Mac用户注销/切换不终止记录，应用退出后的榜单正常更新。
3. 用户登录钥匙串未解锁时LAN仍能读取专用TLS文件；密钥错误时本机监测正常降级。
4. 服务有效UID非root，启动配置与代码不可由普通用户改写；其他UID不能获得setup票据、恢复密码或发本机管理命令。
5. 管理员授权取消、system任务禁用、崩溃节流、锁屏、睡眠/唤醒、更新中断、卸载、重复安装及旧用户任务迁移。
6. 持续1秒/4秒配置重测0/1/3客户端与24小时开销；单个业务服务及所有必要组件合计计入原预算，不能把特权维护动作的峰值藏入稳态结果。

FileVault边界依据：[Apple卷加密说明](https://support.apple.com/en-gb/guide/security/sec4c6dc1b6e/web)。以上为待实现/待测试设计。

## 管理命令状态表（U3）

`bootEnabled`表示持久用户选择；system实际禁用状态优先，出现不一致必须显示并经用户明确enable修复。以下为成功后的状态；所有命令幂等，已有running实例不重复启动。

| 命令/场景 | bootEnabled / system启用 | loaded / running | 下次开机 |
| --- | --- | --- | --- |
| 新安装 / service enable | true / enabled | bootstrap（若未加载）并启动；健康检查通过才报running | 自动启动 |
| service start，已启用 | 保持true / enabled | 按需bootstrap，再kickstart；不使用-k杀掉健康实例 | 自动启动 |
| service start，任一持久状态为关闭 | 保持原值 | 不改变；返回serviceDisabled，提示先明确enable | 保持关闭 |
| service disable | false / disabled | 不bootout；当前loaded/running保持，并显示“本次仍在运行” | 不加载 |
| service stop | false / disabled | 完成上述握手后bootout，false / false | 不加载 |
| 授权取消 | 全部保持 | 全部保持；取消必须发生在第一次变更前 | 保持原值 |
| 卸载服务 | false，移除plist | false / false；数据是否删除单独选择 | 不加载 |

关闭自启动后当前已加载任务仍按其KeepAlive规则管理直到stop/关机；这不是禁止本次崩溃恢复。disabled且已不运行时，图形“启动”入口明确引导“启用并启动”，不暗中修改选择。`disable`的在运保持行为须在G4目标系统实测。

升级前记录bootEnabled、system禁用和loaded/running。原本启用且运行的任务升级后恢复；原本关闭且停止的任务保持停止。原本关闭但仍运行的任务升级停机后保持关闭且停止，安装器提前显示该结果；用户需主动enable恢复，不临时打开启动开关冒险在更新中断后留下自启动。启用但未运行的任务升级后保持未运行，本次不bootstrap；下次开机按原选择启动。

系统配置修改使用root控制的事务日志记录operation/phase/原状态，操作串行。launchctl与文件系统不是原子事务：授权后中断或局部失败返回error和实际观测状态，不能套用“授权取消时不修改”；重试按日志完成或恢复安全的停止状态，不擅自enable。stop的禁用已成功而bootout失败时明确报告“自启动关闭、服务仍可能运行”，不返回伪成功。正常升级恢复规则不覆盖外部system禁用。

2026-10-03 真机安装反馈修正：/Applications 的默认 admin 组可写不能作为可信执行路径。保留该目录权限，实际 bundle 改存受 root 保护的 Application Support 根，图形入口为固定链接，launchd 和特权工具使用受保护绝对路径。
