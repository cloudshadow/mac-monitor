# 部署选项：原生服务与 Docker

日期：2026-09-30。用户已确认第一版不使用 Docker，采用原生应用安装；下文保留部署方案比较作为决策依据。安装与存储方案见 [installation-and-storage.md](installation-and-storage.md)。

## 结论

完整采集程序不能仅靠 Mac 上的普通 Linux Docker 容器满足 macOS 硬件温度、宿主应用 CPU/内存等监测需求。Web 展示或数据汇总可以容器化，但 macOS 原生采集器仍需在宿主机运行。

## 原因及能力边界

Docker Desktop 在 Mac 上通过 Linux 虚拟机运行 Docker Engine 和 Linux 容器。容器读取的 Linux 进程、内存及 CPU 计数属于容器或虚拟机视角，不能替代 macOS 的宿主指标。macOS 的 Mach、libproc、IOKit 与 SMC/HID 采集代码必须在 macOS 侧执行。

`--privileged` 和 `--pid=host` 不能跨越 Linux VM 取得 macOS 内核及进程视图；宿主文件挂载也不会把 macOS 内核 API 带入容器。Docker Desktop 的 host networking 是 TCP/UDP 连通能力，不能赋予传感器访问能力。

依据：[Docker Desktop 网络架构](https://docs.docker.com/desktop/features/networking/)、[Mac 权限边界](https://docs.docker.com/desktop/setup/install/mac-permission-requirements/)、[host networking 限制](https://docs.docker.com/engine/network/drivers/host/)。原生 API 无法从 Linux 容器直接调用的结论是基于该架构与本项目采集接口作出的技术判断。

## 方案对比

| 部署方式 | 能否满足 macOS 监测需求 | 资源与运维取舍 |
| --- | --- | --- |
| 原生 Agent 内置网页/API | 可，温度/GPU 仍按机型验证 | 推荐基线；单服务，省去虚拟机依赖 |
| 原生 Agent + Mac 上 Docker Web/API | 可，由 Agent 提供宿主数据 | 多一层连接、认证及容器/VM 开销 |
| 只装 Docker 镜像 | 无法完整满足 | 主要得到容器/Linux VM 数据 |
| 原生 Agent + NAS/服务器上的容器界面 | 可 | 适合未来多 Mac 集中展示；Mac 只采集与传输 |

混合架构：`macOS 原生 Agent → 经认证的数据通道 → Docker Web/API → 浏览器`。
可以由 Agent 主动推送到容器映射端口，或容器经 Docker Desktop 的宿主地址访问 Agent；选择后必须验证绑定地址、防火墙、认证和重连，不能假定只监听回环的服务在所有 Docker 配置下都可访问。服务间凭据须独立于用户登录会话，浏览器通过同源接口访问，不能把 Agent 管理权限暴露给容器界面。

## 对极低占用要求的影响

专门为监测启动 Docker Desktop 时，CPU/内存预算必须计入 Linux VM、Docker 后台及容器，不能只报告镜像大小或容器内部内存。Docker 原本已常驻时，应同时报告增加监测容器后的增量与整套环境总开销，不预设固定数值。

Docker Desktop 的 Resource Saver 可在没有运行容器时停止 Linux VM；常驻监测容器可能使其无法进入这种空闲状态。依据：[Docker Desktop 设置说明](https://docs.docker.com/desktop/settings-and-maintenance/settings/)。

## 推荐

第一版保留原生 Agent 内置轻量 Web 服务，满足局域网访问，无需 Docker。容器版展示端作为未来可选部署目标，若后续采纳，再补齐独立接口、身份验证、跨服务性能预算和实现任务。
