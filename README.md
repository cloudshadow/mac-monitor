# Cloud Mac Monitor

macOS 14+ 原生监测服务与 React 静态网页，依据 [最新 spec](specs/001-hardware-monitor/spec.md) 实现。应用包含账户、CPU/内存/磁盘/网络、应用排行、持久历史、LAN TLS 配对与本机管理。运行时不需要 Node、独立 SQLite 服务或 Homebrew。

软件实现及开发机自动检查已完成；M 系列系统域、手机、管理员图形授权和长期性能由用户随后真机验收。当前不声明通过发行门槛，也没有伪造公开下载地址或项目许可证。

开发需要 Swift 6.1+（Xcode/CLT）与 Node 22.12+：

```bash
npm --prefix web ci
npm --prefix web run build
bash scripts/swift.sh test -j 4
node --test scripts/i18n/validate.test.mjs
python3 scripts/smoke.py
python3 scripts/lan-smoke.py
```

HTTP/TLS smoke 使用临时数据，不安装系统任务或改变证书信任。浏览器端到端测试：

```bash
cd web
npx playwright test
```

默认使用本机 Google Chrome；可设置 CMM_CHROME 指定测试浏览器路径。开发运行服务和控制端：

```bash
mkdir -m 700 /private/tmp/cloudmacmonitor-dev
.build/debug/MonitorAgent --data-root /private/tmp/cloudmacmonitor-dev --web-root "$PWD/web/dist"
# 在另一个终端启动控制窗口；从窗口创建账户、打开页面。
.build/debug/MonitorControl --data-root /private/tmp/cloudmacmonitor-dev
```

代码不把当前登录用户当作生产服务所有者。生产服务由安装器绑定普通 UID，以 system LaunchDaemon 运行；未创建账户不能启用 LAN。setup/配对票据由所有者 Unix 通道签发，放在 URL fragment，五分钟一次使用。密码变化和设备撤销使旧会话失效。

免费 ad-hoc 包：

```bash
bash scripts/package-app.sh 0.1.0
CMM_ARCH=arm64 bash scripts/package-app.sh 0.1.0
```

分别生成 `artifacts/CloudMacMonitor-0.1.0-<arch>.tar.gz`、SHA-256 文件及 `artifacts/package/<arch>/Cloud Mac Monitor.app`。Apple Silicon 可以在 Intel 开发机交叉编译，但运行与兼容性仍需真机验证。

真机本地安装不需要先发布。将对应架构的归档、SHA-256 文件及仓库的安装脚本复制到目标 Mac，查看脚本后，以目标普通用户运行（会请求管理员授权）：

```bash
package="artifacts/CloudMacMonitor-0.1.0-$(uname -m).tar.gz"
expected="$(awk '{print $1}' "$package.sha256")"
bash scripts/install.sh 0.1.0 --local "$package" "$expected"
```

发布后的一条安装命令使用已审查的 `scripts/install.sh VERSION HTTPS_RELEASE_BASE SHA256`。安装器普通用户下载，管理员阶段在 root 暂存区重验、拒绝路径穿越/链接，安装固定应用和 LaunchDaemon；升级保留账户/历史和原先的启停选择。未配置正式 ReleaseRepository 前，原生更新入口不会假装找到官方发行。首次 Gatekeeper 批准、权限/策略拒绝与免费管理员授权仍待真机验收。安装器拒绝普通用户可替换的安装父路径，不自动修改系统目录权限。

默认持续系统 1 秒/应用 4 秒共享采样，无查看者仍记录。系统历史分级保留 30 天，应用最终 Top 并集摘要 7 天；暂停保留近期内存，清空使用代次屏障。温度原始 ID 可选择，未知机型对应关系不冒充已验证 CPU 温度。只读 SMC/HID/GPU 接口可能因机型/权限不可用。

实际 Agent 基准入口：

```bash
python3 scripts/runtime-benchmark.py --clients 0 --warmup 300 --duration 1800
python3 scripts/runtime-benchmark.py --clients 1 --warmup 300 --duration 1800
python3 scripts/runtime-benchmark.py --clients 3 --warmup 300 --duration 1800
```

预算、真机步骤与限制见 [性能](docs/performance.md)、[手机设置](docs/mobile-setup.md)、[安装验证](docs/install-validation.md)、[发行清单](docs/release-checklist.md) 和 [实现状态](docs/implementation-status.md)。项目许可需所有者确认版权主体后补齐；依赖声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
