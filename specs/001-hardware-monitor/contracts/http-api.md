# HTTP / SSE Contract v1

历史、账户与设备配对契约已实现；首次开户流程按 2026-10-03 用户要求修订。默认本机`http://127.0.0.1:8765`、LAN `https://<Mac主机名或IP>:8766`；端口冲突自动选择可用端口，由受限本地控制通道取得实际地址并同步Host/Origin白名单。

## 认证矩阵

| 请求 | 认证要求 |
| --- | --- |
| 静态页面、health、auth/status | 无账户会话；不返回指标/用户名/版本秘密 |
| 首次创建账户 | 仅loopback + 同源Origin + 尚无账户且无损坏状态；setup票据可选 |
| 配对兑换 | 已信任LAN TLS + 单次配对票据 + 同源Origin |
| 本机登录 | 同源Origin + 用户名密码 |
| LAN登录 | 已信任TLS + 有效设备资格 + 用户名密码 |
| 实时、排行、历史、Viewer/SSE | 有效账户会话；LAN还需绑定的有效设备资格 |
| 系统任务启停、自启动开关、升级/卸载 | 本机按需管理员授权工具；Web不提供该权限 |
| 改密、恢复、签发配对、设备撤销、应用设置、历史清空 | 服务所有者UID受保护本地控制通道；不开放远程管理路由 |

loopback使用独立cookie。LAN的device和account cookie为HttpOnly、Secure、SameSite=Strict；所有cookie限制Path，服务器只保存token散列。账户会话12小时、设备资格30天；配对绝不自动登录账户。退出/撤销同时关闭相关SSE，最迟5秒生效。服务重启清空账户会话，账号与设备资格及历史保留。

Host与请求类型对应的Origin规则见下表，不开放CORS。已有会话的修改操作需CSRF token；首次本机setup不要求票据；兼容setup/pair票据各5分钟一次使用，不进日志或query字符串。票据从URL fragment取得后清理地址，POST兑换；原生进程验证控制通道peer UID匹配安装时绑定的服务所有者，socket位于受限run目录且0600；不把任意当前登录用户当作所有者。静态内容纯文本渲染进程名，CSP为本源并禁止被frame嵌入。

## 请求来源校验（U4）

所有请求先校验当前listener允许的Host（规范化主机及端口），Origin出现时必须精确等于该请求实际scheme/host/port；`Origin: null`、多个Origin或跨源Origin均403，不能因为两个地址都在Host白名单就视作同源。不信任客户端X-Forwarded-*。

| 请求类型 | Origin缺失时 | 补充条件 |
| --- | --- | --- |
| 顶层页面、静态资源、health/auth/status GET或HEAD | 允许 | 不泄露受保护数据；顶层导航可来自外部链接 |
| snapshot/apps/history/auth/session及SSE等受保护GET | 允许 | 仍验证账户、LAN设备、viewer；Sec-Fetch-Site若存在只允许same-origin或none，不存在可兼容 |
| setup/login/pairing兑换等无现有会话的POST | 拒绝403 originRequired | Origin正确外仍需相应密码或一次票据；JSON Content-Type |
| logout/viewer等已登录POST/PATCH/DELETE | 拒绝403 originRequired | Origin正确且有效会话/CSRF；有body须JSON |
| 跨源预检OPTIONS | 拒绝403 | 不返回Access-Control-Allow-* |

已有Origin错误时不能以Cookie、CSRF或缺Fetch Metadata绕过；GET/HEAD不得有管理副作用。API不使用JSONP，响应nosniff；页面禁止frame。浏览器普通同源GET可能不发Origin，不能把“必须有Origin”应用到所有路由。依据：[Fetch Origin规范](https://fetch.spec.whatwg.org/#origin-header)。缺Origin不是认证授权，命令行请求仍需正常凭据。

## 路由

| 方法/路径 | 输入 | 结果 |
| --- | --- | --- |
| GET `/healthz` | 无 | `{status:"ok"}` |
| GET `/api/v1/auth/status` | 无 | `setupRequired / recoveryRequired / loginRequired / authenticated / pairingRequired`，LAN不能据此setup；未初始化LAN仅提示回Mac设置 |
| GET `/api/v1/auth/session` | 有效会话，LAN需设备资格，同源读取 | csrfToken,expiresAt；no-store，未登录401 |
| POST `/api/v1/auth/setup` | username, password；setupTicket可选 | 201，唯一账户、本机会话及csrfToken；已有账户409 |
| POST `/api/v1/pairing/exchange` | ticket, deviceLabel | 200+设备cookie，不发账户会话 |
| POST `/api/v1/auth/login` | username,password | 200+账户cookie+csrfToken；失败统一401 |
| POST `/api/v1/auth/logout` | CSRF | 204，撤销当前账户会话和流 |
| GET `/api/v1/capabilities` | 会话 | DeviceCapabilities |
| GET `/api/v1/snapshot` | 会话 | 缓存SystemSnapshot，不强制新采样 |
| GET `/api/v1/apps` | sort,limit,cursor,q,scanSequence? | rows,coverage,sampledAt,bootId,scanSequence,nextCursor |
| GET `/api/v1/apps/{id}/processes` | cursor | 当前成员分页，未知404 |
| GET `/api/v1/recent/system` | seriesIds,from,to,maxPoints | 最近≤5分钟请求；优先共享内存，缺口可回退SQLite并标注精度 |
| GET `/api/v1/recent/apps` | from,to,appId?,cursor | 最近≤5分钟排行帧，未入榜notRetained；每页≤100行 |
| GET `/api/v1/history/system` | seriesIds,from,to,maxPoints,resolution=auto | 系统分级桶，保留/覆盖信息 |
| GET `/api/v1/history/apps` | from,to,sort,limit,cursor | 5分钟应用桶及selectedBy，非完整审计 |
| GET `/api/v1/history/status` | 会话 | RecordingStatus及实际存储量 |
| POST `/api/v1/viewers` | channels,CSRF | viewerId,expiresAt；总数≤6，全部操作绑定会话/设备 |
| PATCH `/api/v1/viewers/{id}` | visible,channels,CSRF | 只允许当前会话的viewer |
| DELETE `/api/v1/viewers/{id}` | CSRF | 204 |
| GET `/api/v1/events?viewerId=…` | 会话+租约 | 最多3个活动SSE，第4个429 |

CSRF token通过进程随机密钥与会话标识进行HMAC派生，只在JS内存使用；auth/session可在刷新后返回该会话同一token，不轮换而使其他标签页失效，服务端保存散列并校验。进程密钥不持久化，重启账户会话本就失效。

创建/登录均限长校验，账号创建使用唯一主键事务，写入成功才发会话。用户名1～64字符；密码12～128字符、UTF-8最多512字节，不截断或规范化密码。错误凭据统一提示；KDF仅1并发、2排队，每IP5次/分钟且全局10次/分钟，超限429，现有监测会话不被认证工作阻塞。会话/设备撤销使用服务器内存索引和已提交认证版本，持久操作失败不返回伪成功。

## 历史查询

recent与history复用同一有界查询服务；history遇近期范围也优先内存，客户端不分别查询后盲目拼接。系统最多8序列/每序列600点，应用每页100行；返回各段source/resolution/coverage及捕获的服务时间和版本，具体分钟边界、重启回退和去重见 [realtime-data-flow.md](../realtime-data-flow.md)。任何查询或订阅均不触发新硬件采集，独立于客户端数的采样为系统1秒/应用4秒。

`from/to`为UTC，`from < to`。系统最长30天、最多8个seriesIds、maxPoints每序列1～600；应用最长7天、limit默认20最多100。自动分辨率先按覆盖选层，再按需在查询时合并为更粗时间桶；30天小时720点可合并为约360个2h桶。每序列全部segment/连续段合计≤maxPoints，禁止静默截点或跨segment/缺口合并；无法满足返回400 pointBudgetTooSmall及minimumRequiredPoints，超过600返回下界601及minimumIsLowerBound=true。精度、边缘桶和加权规则见 [history-storage.md](../history-storage.md)。数据库查询执行预算250ms，超时返回503 queryBudgetExceeded/retryAfterMs，客户端缩小范围或退避。

返回`recordingEpoch / segments / series|rows / effectiveRange / resolution / coverage / truncated / lastCommittedAt`；段内含sourceResolutionSeconds/resolutionSeconds/continuityId/partial及实际桶边界，非对齐范围标partialRange。降采样不是truncated；clear后旧查询/游标409 historyChanged。部分范围超出保留期返回200并明确effectiveRange/gap；全无数据返回空结果并说明notRecorded/expired。非法超长范围返回400。每桶包含sampleCount、有效覆盖和观测极值，null/gap不绘成0。

应用摘要按windowStart分页，可选某个appId查询；未入Top并集应标记notRetained。实时apps的sort仅cpu/memory/diskRead/diskWrite，limit≤100，q≤128字符；游标绑定bootId/scanSequence/排序/过滤和位置，失效409 snapshotChanged；排行读取与SSE规则见下节。历史游标绑定recordingEpoch/排序键/查询范围，清理造成数据变化时标记truncated并允许重查。

## SSE与生命周期

Content-Type=text/event-stream，Cache-Control=no-store，不缓冲流压缩。事件`system / apps / capabilities / recordingStatus / reset / degraded / authExpired`；ID=`bootId:sequence`。system/capabilities等快照频道使用各自sampledAt/intervalMs，不混同生成时间；apps只发送下述扫描通知。慢客户端每频道只保留最新快照或通知，总待发≤128KiB，超限断开。

Last-Event-ID只判断连续性，不建立无限回放日志；重连发reset+当前system/capabilities快照及apps最新扫描通知，近期历史独立有界查询。15秒无数据可发heartbeat。首版使用原生EventSource：onerror立即close旧连接，唯一连接管理器按1/2/4/8/最大30秒抖动退避，通过普通HTTP认证请求区分401、设备失效、429与离线；不能从EventSource错误事件直接读取401，也不能运行两套重连。普通HTTP确认401后清空受保护页面数据并导航登录，错误密码留在登录页；设备资格失效提示配对，离线不误登出。已打开SSE撤销时停止指标、best-effort发authExpired并关闭，不能中途返回401；API/SSE不302到HTML登录页。页面hidden断流/停续租，visible核验会话、重建租约并取快照；语言切换不重建连接。租约不改变采样频率。

各快照携带serverTime及服务端计算的ageMs，前端结合本地单调时间独立更新数据新鲜度；断流立即显示连接异常，超过阈值再标过期，不能因服务未发stale事件而一直显示正常。登录/刷新恢复CSRF、启动顺序和浏览器协议说明见 [realtime-data-flow.md](../realtime-data-flow.md)。

本地控制命令：status/open/lan enable|disable/pair/devices/revoke/service enable|disable|start|stop/password change|reset/history pause|resume|clear。改密/恢复成功提升authEpoch并关闭所有旧账户流；history clear二次确认但不删账号。`status`额外返回ServiceStartupStatus，service enable/disable/start/stop由按需管理员授权工具执行，返回system任务启用/加载/运行状态；Web与普通daemon无权直接修改系统任务。service disable关闭后续开机加载但保持本次运行，stop先禁用、prepareStop限时刷盘并保持存活，再bootout；start仅启动已启用任务，enable启用并启动，完整状态表见launchdaemon；重启自启动不免除网页认证。管理权限、服务所有者绑定、系统数据路径及启动边界见 [launchdaemon.md](../launchdaemon.md)。控制通道不接受任意shell/SQL。

## 容量及错误

请求body≤16KiB、headers≤8KiB、普通请求读超时5秒；TCP总连接≤16、并发TLS握手≤2。状态写操作、查询和认证都有有界队列，不能由客户端任意改变采样频率。

错误体`{error:{code,message,retryAfterMs?}}`；UI按稳定code翻译三种语言，message只作诊断。400参数错误、401登录失效、403未配对/来源错误、404不存在、409冲突、429限额、503暂不可用。可选指标读取失败不让整个snapshot返回500；历史数据库故障也不阻断实时接口。

## 应用扫描通知与排行读取（U2）

`apps`事件仅包含 `{bootId,scanSequence,sampledAt,intervalMs,ageMs,coverage}`，编码后≤2KiB，不含应用行或成员列表。scanSequence按完成扫描递增，与SSE事件sequence用途不同；每客户端按自己的sort/q读取GET apps，共用同一当前扫描表，GET不触发硬件调用。

- 每次扫描原子发布当前有界应用表（最多4096身份），只长期保留当前版本；GET在短时锁内复制至多100条选定行，不让HTTP发送持有整张旧表。四种排序索引每扫描共享构建一次，过滤在共享索引中执行，不缓存无限q组合。
- scanSequence可省略以取最新；指定旧版本或失效cursor返回409 snapshotChanged及currentScanSequence。前端首屏/恢复/排序变化取最新首页；可见首页每新通知最多刷新一次，同页最多一个请求在途、一个待处理最新版本。迟到的旧bootId/scanSequence或旧sort/q请求不得覆盖新视图。409最多立即用最新版本重查一次，再冲突等下一通知，禁止忙循环。
- 实时首页自动更新。用户翻页时保留当前显示、暂停自动替换行但继续显示“有新数据”；点击下一页若版本已失效，明确回到最新首页。首版不承诺长时间固定分页快照，也不为每客户端保留4096行副本。主动刷新/回首页恢复实时更新。
- 每会话apps及成员查询合计≤4次/秒、突发最多4次、1个执行中；全局最多3个执行中、3个排队，超限429，客户端遵循retryAfterMs。排序/搜索输入防抖250ms，隐藏页不拉取。
- 应用摘要行只含appId、displayName、归属、指标、memberCount和coverage，不含members数组；成员通过独立分页接口读取并同样绑定版本。displayName展示字段UTF-8≤256字节，按字符边界截断并给nameTruncated，身份散列不改变；JSON转义后仍须满足行大小预算，必要时进一步缩短展示名。每行编码≤2KiB，apps/成员普通HTTP页总编码≤128KiB；达到字节预算时在完整行边界提前结束页，nextCursor指向未返回首行，因此实际页数可以少于limit且不丢行。长名称、成员数和身份上限必须有夹具，不能截断整个JSON来凑大小。

0/1/3客户端使用不同排序/搜索，验收硬件采集次数相同、通知/响应字节上限、409重查有界和慢客户端不保留旧全表。

## 历史控制结果（U5）

本机history pause/resume/clear返回RecordingStatus及recordingEpoch；clear成功广播新epoch的recordingStatus，客户端取消旧历史请求并清空曲线。pause只停止持久保存，近期内存继续；resume不回填暂停数据；clear同时清理数据库、近期曲线、旧聚合/队列，保留当前实时值、账户及暂停选择。历史切换期间503 historyResetting，跨epoch结果409 historyChanged；严格顺序与失败处理见 [history-storage.md](../history-storage.md)。

## Native owner stop (2026-10-03)

Owner-only Unix IPC `shutdown` returns `{stopping: true, pid: <Agent PID>}` and schedules graceful termination after acknowledgement. It is not exposed as an HTTP route. The UI waits for actual PID exit before completing explicit Quit; success exits with code 0, while abnormal exits retain launchd crash recovery. Root IPC remains limited to `prepareStop`.
