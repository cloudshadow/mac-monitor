<!-- Sync Impact Report
Version: 1.1.0 → 1.2.0
Reason: 用户明确采用LaunchDaemon系统级启动；系统安装/维护需管理员授权，业务采集/Web仍以普通服务所有者身份运行。
Updated principle IV: 系统域任务及按需特权维护；登录前/注销后采集，独立数据与密钥存储。
Synced: spec, plan, data-model, contracts, history, installation, research, quickstart, tasks, checklist.
Performance targets remain unmeasured; 1s/4s configuration requires new verification.
-->
# Mac Hardware Monitor Constitution

## Core Principles

### I. 低占用必须可测量

CPU、内存、唤醒与写盘必须有明确预算和可复现测量。分别报告后台服务、Mac 本机网页、远程客户端开销；所有常驻组件计入后台总额。未经测量的数据只能称为目标。

### II. 数据必须真实且口径明确

缺失、不支持、权限不足、过期和真实零值必须区分。CPU 百分比必须标注分母，内存必须标注统计口径。温度必须注明传感器及来源，不得从热状态推算摄氏度；不得把相关性描述为应用导致的温升。

### III. 按需采样与有界资源

采集由唯一共享调度器持续执行，不随客户端数重复采集；频率按电源/热状态和明确故障调整。页面需求控制传输，无查看者时停止推送而继续默认采集。缓存、历史、连接和发送队列必须有上限。睡眠时停止，恢复时重建差分基线。常规采样不得周期启动外部命令。

### IV. 数据留在用户设备

默认不上传遥测。局域网访问必须显式开启，使用加密连接及配对认证，可撤销设备访问。监测/Web业务进程以指定普通服务所有者权限运行，LaunchDaemon在系统启动且数据卷可用后执行，与桌面登录无关。系统目录安装、任务管理、升级及卸载使用按需管理员授权工具；不引入常驻root网络服务。新增提权组件须有具体能力理由和独立预算，所有必要组件计入资源验收。

### V. 以最小可运行架构推进

第一版采用单个原生服务和静态网页；每个新增运行时、服务或持久化组件须说明必要性。先验证目标机型接口与资源预算，再扩展温度、GPU 等适配范围。

## Performance Standards

具体预算以 feature spec 为准，修改预算必须同步 spec、plan、验收方案及原因。不得以提高刷新间隔但仍显示旧“实时”标签、漏算 helper 或漏算本机浏览器的方式通过验收。适配器超时或异常必须降级，不得形成无限重试、无限日志或阻塞基本指标。

## Development Workflow

遵循 constitution → spec → research/plan/contracts → tasks → implementation。先完成能力与性能探针；正式发布须通过差分计算、PID 复用、权限降级、配对访问及性能验收。只对这些具体风险及必要端到端场景建立测试；文档质量检查不能表示实现已经完成。

## Governance

本文件是项目设计约束来源。新增原则使用 MINOR，破坏原则使用 MAJOR，文字澄清使用 PATCH。每次修改记录影响并检查关联文档；不复制规则到上游模板。用户新要求优先，变更须记录。

**Version**: 1.2.0 | **Ratified**: 2026-09-30 | **Last Amended**: 2026-10-01
