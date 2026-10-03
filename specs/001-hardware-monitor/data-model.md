# Data Model

本文件是接口与实现共享的数据定义；JSON 字段使用 camelCase。

历史、唯一账户和多语言设计已同步。持久化使用内嵌SQLite的history.sqlite/state.sqlite；TLS秘密放系统专用secrets目录（服务所有者0700/0600），不依赖登录钥匙串，原始快照仅驻有界内存。详见 [history-storage.md](history-storage.md)。

## Metric<T>

字段：`value: T|null`、`unit`、`status`、`source`、`sampledAt`（UTC ISO-8601）、`intervalMs`、`reason`。

状态：`warmingUp → ok`；失败可进入 `unsupported / permissionDenied / error`；超过 `max(3×intervalMs, 15000ms)` 未更新进入 `stale`。恢复须重新建立差分基线。前端使用服务端ageMs及本地单调经过时间独立推进stale状态，断流立即显示连接异常，不等待服务端再推送；不直接比较两台设备的墙钟。`unsupported / permissionDenied / warmingUp / error` 的 value 为 null；stale 可保留最后值，但必须显示最后更新时间。`ok` 的 0 是有效零值，NaN/Infinity 禁止输出。

## DeviceCapabilities

`deviceId`（本地随机，不取硬件序列号）、`modelIdentifier`、`chipName`、`architecture`、`osVersion`、`logicalCpuCount`、`physicalMemoryBytes`、`capabilities[]`。

每项能力含 `name`、`supported`、`verified`、`source`、`reason`、`sensorIds[]`、`lastProbeAt`。verified 仅在兼容矩阵中有该芯片/系统验证记录时成立，探测成功与验证支持不能混同。未知机型默认启用基础采集，传感器须通过映射和合理性验证。

## SystemSnapshot

`serverTime`、各指标`ageMs`（服务端单调时钟计算）、`schemaVersion: 1`、`bootId`（本服务启动 ID）、`sequence`、`generatedAt`、`mode`、`effectiveIntervals`；CPU、内存、GPU[]、温度[]、磁盘[]、网络接口[] 各含 Metric。

`cpu.totalPercent` 分母为全部逻辑核容量。`memory.nonIdlePercent` 按 plan 指定公式；`memory.pressure` 是级别或 unknown。GPU 依设备/引擎单列，不任意平均。网络每接口有 `interfaceId / kind / isDefault / rxBytesPerSec / txBytesPerSec`。温度有 `sensorId / label / component / celsius`；组件最高值只取已验证成员，不能把电池温度当 CPU。

## ProcessIdentity / ProcessSample

唯一键 `processKey = bootId:pid:startTime`，禁止单用 PID。`startTime` 为内核启动标记的十进制字符串，防止 JavaScript 64 位精度丢失；累计纳秒/字节如需暴露也使用字符串。

`pid`、`uid`、`name`、`appId|null`、`cpuCorePercent`、`cpuMachinePercent`、`footprintBytes`、`rssBytes`、`diskReadBytesPerSec`、`diskWriteBytesPerSec`、`sampledAt`、`status`。完整可执行路径仅本机归属计算使用，默认不发送 LAN。

每个进程自身 CPU/磁盘计数差分；计数下降、身份改变或跨睡眠时不产生速率。采样退出视为离开集合；下一轮清理实时缓存，元数据最多保留 60 秒且受 4,096 身份上限约束。

## ApplicationGroup

`appId` 使用可信 bundle ID + bundle 路径的本地散列；没有可信应用身份时用 processKey 表示独立进程。内部字段 `displayName`、`members[]`、`attribution: verifiedBundle|verifiedHelper|unattributed`、`confidence`、`metrics`、`coverage`。

一个身份只能属于一个组；每个应用指标只加一次。coverage 分别计量 attempted/readable/denied/exited，字段级失败不能把其余指标清零。不能可靠归属的服务保留独立行。当前排行与历史应用摘要分开；历史每5分钟取最终Top并集，最多30组，不保存所有进程快照。

## AppScanNotification / ApplicationPage

AppScanNotification：`bootId / scanSequence / sampledAt / intervalMs / ageMs / coverage`，SSE apps事件≤2KiB，仅提示共享扫描已更新，不发送应用列表。

ApplicationPage：`bootId / scanSequence / sampledAt / rows / coverage / nextCursor`；row不嵌入members，使用memberCount及独立成员分页。默认20、最多100行，单行≤2KiB/全页≤128KiB，达到页字节上限提前分页且保留nextCursor；displayName展示截断至UTF-8≤256字节并标nameTruncated。游标绑定版本/排序/过滤；只保留当前共享扫描表，旧游标409 snapshotChanged。成员页使用同样版本规则。表及索引计入总footprint，不计入4MiB近期历史额度；不为客户端复制全表。

## LiveHistoryBucket / PersistentMetricBucket

近期系统内存每序列最多360个1秒槽，上限64序列，覆盖至少5分钟及至多1分钟衔接余量；应用近期最多90帧、每帧排行并集30组，两类近期缓冲合计字节硬上限4MiB。当前全进程表不复制进每帧。覆盖/跨库查询见 [realtime-data-flow.md](realtime-data-flow.md)。内存缓冲、排队批次和查询均绑定recordingEpoch；持久桶字段：`recordingSegmentId / seriesId / resolutionSeconds / bucketStartUtc / bucketEndUtc / weightedSum / coveredDurationMs / sampleCount / min / max / status`。

唯一键(segmentId,seriesId,resolution,bucketStart)。UTC定位、单调时间计量；上层汇总按weightedSum/coveredDuration计算，不能直接平均avg。每1分钟事务同时更新相应5分钟与1小时桶；重试幂等。时钟回拨/唤醒/服务重启新建segment，避免覆盖。

系统持久1m/24h、5m/7d、1h/30d；查询按层选取、桶边界不重复，查询时可再合并为2h等精度。返回段具有sourceResolutionSeconds/resolutionSeconds/continuityId/partial，跨segment/缺口不合并；全部段每序列合计≤600点，不可满足时pointBudgetTooSmall。详见history-storage的动态合并和边缘桶规则。状态包含ok/partial/gap；未观测时不制造零值。

## RecentApplicationFrame

`segmentId / scanSequence / sampledAt / intervalMs / selectedBy / rows / coverage`；每4秒同一轮共享扫描取CPU、内存和磁盘合计各Top10并集，最多30行/帧、90帧。引用共享应用元信息，不复制完整进程表；未入榜为notRetained，不影响当前完整有界排行。系统与应用近期帧合计≤4MiB，超限显示实际覆盖；详细查询分界见 [realtime-data-flow.md](realtime-data-flow.md)。

## ApplicationHistoryBucket

`segmentId / windowStartUtc / appId / selectedBy[] / cpuWeightedSum / cpuCoveredMs / memoryObservedMaxBytes / memoryWeightedSum / memoryCoveredMs / diskReadDeltaBytes / diskWriteDeltaBytes / sampleCount / coverage / status`。

每5分钟从CPU均值、内存观测峰值、磁盘读写合计增量各Top10取并集最多30行；保留7天。身份引用独立app维表，维表包含显示名和散列、不含完整路径；无历史/实时引用后清理。未入榜是notRetained，不是零值。首个样本、缺失权限及短命进程不算完整覆盖。

## Account / DeviceGrant / AccountSession

- Account（state.sqlite）：`id=1` CHECK约束与主键；`username / passwordHashPHC / authEpoch / createdAt / updatedAt`。Argon2id PHC串包含盐与算法成本；不存明文。创建/改密和authEpoch变化同一事务提交。
- DeviceGrant（state.sqlite）：`id / label / tokenHash / createdAt / expiresAt / revokedAt`；30天有效，仅说明设备已配对。
- AccountSession（内存）：`sessionId / tokenHash / accountId / authEpoch / deviceGrantId|null / createdAt / expiresAt / csrfTokenHash`；12小时有效，重启失效。LAN必须绑定当前有效DeviceGrant；本机loopback会话使用独立cookie。
- PairingTicket（内存）：128-bit随机秘密仅在创建时返回，服务端存散列、5分钟有效、一次使用。
- SetupTicket（内存，兼容原生控制端入口；本机首次网页开户不要求票据）：绑定的服务所有者UID本机控制通道签发，5分钟有效、一次使用，仅在Account不存在时可创建；与配对票据用途隔离。

状态流：uninitialized → setupInProgress → ready；创建事务失败回到uninitialized并允许本机重试，存在但损坏的状态库进入recoveryRequired，不能当成不存在。密码变化撤销全部AccountSession，设备撤销使绑定的会话/流失效；故障历史库不改变账户状态。

## ViewerLease / LocalePreference

ViewerLease：`viewerId / accountSessionId / channels / visible / lastSeenAt`；可见页每15秒续租，35秒过期，断流/隐藏停止。viewer总数最多6个、活动流最多3个，全部操作绑定会话/设备。观看者消失只停止传输；系统1秒/应用4秒继续，不改变硬件采集频率。

LocalePreference：浏览器 localStorage 仅保存构建时发布语言注册表中的语言标签（首版 `zh-Hans|zh-Hant|en`），不保存密码或认证 token；不在业务代码中写死可选语言枚举。无偏好按浏览器语言选择，未知或已移除语言重新匹配并回退 en；原生控制端有独立语言偏好。API 提供稳定错误码/单位，显示层本地化。

LocaleDefinition：由 `locales/{tag}/locale.json` 定义 tag、nativeName、englishName、direction、aliases、status；标签及别名唯一，published 才进入正式构建。MessageCatalog：按功能 JSON 保存稳定键及普通字符串/复数对象，参数契约以英语为基准；普通参数统一string/Swift String，只有plural.argument参数为0～Int32.max整数（TS number/Swift Int32），不推断变量名类型；属于构建资源，不进入 SQLite。Web 和原生资源由同一源生成，详见 [localization.md](localization.md)。

## HistoryPolicy / RecordingStatus

HistoryPolicy：`enabled=true / systemRetentionDays=30 / appRetentionDays=7 / systemResolutions / appBucketSeconds=300 / diskBudgetBytes=268435456`。首版从本机设置修改enabled/清空，保留期限使用固定默认，未来扩展须迁移。enabled来自history.sqlite的HistoryControl，不在state.sqlite重复存储。

HistoryControl（history.sqlite单行）：`id=1 / recordingEpoch / enabled / clearedAt`；epoch是递增整数，对外十进制字符串。清空的逻辑可见性与epoch递增同库原子提交，旧行随后有界回收并继续计入容量。HistorySegment（history.sqlite）：`recordingSegmentId / recordingEpoch`；持久桶通过segment引用所属epoch，所有读/写均验证当前epoch。pause只暂停持久聚合，近期内存继续；resume新segment且不回填；clear清理历史、近期缓冲及旧待写批次，保留实时当前值、enabled与账号。返回成功之前完成提交和内存代次切换，旧查询/游标409 historyChanged；失败/崩溃按已提交元数据恢复。

RecordingStatus：`recordingEpoch / enabled / clearedAt / state=recording|paused|degraded|error / lastCommittedAt / lastAppCommittedAt / effectiveRetention / dbBytes / walBytes / pendingBytes / lastErrorCode`。有界缓存故障超过上限丢弃未提交最旧批次并记录gap与错误，不伪称已保存。

## SamplingConfiguration / StorageSchema

`lanEnabled / selectedInterface / localPort / lanPort / enabledSensors / profile`；profile=continuous，不允许浏览器任意指定高采样率。系统安装元信息中的`bootEnabled / serviceOwnerUID / serviceOwnerGeneratedUID`由管理员授权工具管理，bootEnabled仅新安装默认true，既有关闭选择/系统禁用状态不得被重装升级覆盖；不等于任务已加载或进程已运行。原loginEnabled设计由bootEnabled替代，数据库不能自行修改system任务权限。

ServiceStartupStatus（本地控制通道）：`desiredEnabled / registrationStatus / running / lastStartReason / lastError`；registrationStatus为enabled、disabled、authorizationRequired、notRegistered、error；另含loaded标记，running通过服务所有者UID/根保护安装身份与健康检查确认；lastStartReason区分manual、boot和recovery。服务未运行时本机按需工具查询system任务状态；观测状态不替代持久用户选择。start仅用于已启用任务，关闭时返回serviceDisabled；enable启用并启动，disable保留本次运行，stop禁用并退出。管理员工具的root保护事务日志记录operation/phase/原状态，局部失败返回真实状态，详见launchdaemon状态表。

state.sqlite与history.sqlite独立schemaVersion，迁移事务按库执行；无需跨库提交。用户名密码/设备删除与历史删除不能互相误删。账号存储使用FULL同步；两库和备份仅服务所有者及有系统特权的管理员可读，放在 `/Library/Application Support/CloudMacMonitor/data/`。运行时DDL/索引及迁移在实现阶段从以上唯一键与查询契约生成。
