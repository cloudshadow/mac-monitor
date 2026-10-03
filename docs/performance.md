# Performance validation

The feasibility benchmark reports measured values only. Specification budgets remain targets. The initial implementation is an idle baseline, not the complete SC-001 history/client workload.

## Probe behavior

One NIO event-loop thread, loopback HTTP health listener and optional NIOSSL TLS listener are initialized in the measured process. Mach system samples run every second; libproc scans run every four seconds; SQLite WAL/FULL uses one serial queue and commits aggregate CPU buckets at minute boundaries. Samples and output arrays are bounded by the maximum 24-hour duration. No external command is invoked during sampling. libsodium is initialized; repeated password hashing is intentionally not part of steady-state measurements.

Each scan reports actual attempted/readable/denied/exited counts. It reads at most 4,096 identities. The benchmark never claims a 500/2,000-process workload from a smaller set and never starts artificial processes. The footprint and RSS measurements use `proc_pid_rusage`; CPU uses own user+system nanoseconds with one core = 100%.

TLS initialization alone is not a handshake or 1/3-client measurement. The server has no monitoring routes. The history baseline stores one system series, not 64 system series and application summaries; 30-day retention/capacity, disk write amplification, 24-hour stability and auth peaks are not yet implemented.

## Reproduction

```bash
bash scripts/benchmark.sh --warmup 300 --duration 1800 --database artifacts/benchmarks/idle.sqlite > artifacts/benchmarks/idle.json
```

Repeat three times on an M1 8GB reference Mac with ≤500 visible processes, in a system-domain ordinary-UID job. Save hardware/OS, build configuration, process count, thermal/power conditions and report. Separately measure 1/3 clients and the local browser once the authenticated monitoring server is available.

## Current evidence

Environment: MacBookPro11,5, Intel i7-4870HQ, x86_64, macOS 15.7.9, ordinary UID 501, Swift 6.1.2, macOS SDK 15.5. Debug/Release builds and 7 Swift Testing tests pass. The diagnostic capability probe read CPU/memory and 486 of 782 attempted processes (283 denied, 13 exited); these counts are one observation, not a supported-workload guarantee. The sandboxed SMC open and swap probe failed; null/error statuses are preserved.

G0 is **notValidated**, even if a short Intel smoke test succeeds. Full UI development remains gated by the plan's G0/G4 requirements.

### Release smoke (2026-10-03)

Release build passed. A 65.03s ordinary-UID interactive run, with no warmup and four loopback health/fail-closed requests (HTTP + verified TLS), produced:

| Observation | Measured value |
| --- | ---: |
| System samples / process scans | 65 / 17 |
| Minute transactions / persisted rows | 2 / 2 |
| Sampling gaps | 0 |
| Actual attempted processes, maximum | 795 |
| Actual readable processes, maximum | 498 |
| Process scan wall duration p95 | 7.68ms |
| Mean CPU, single-core denominator | 0.172% |
| Per-second CPU p95 | 0.686% |
| Physical footprint p95 | 2,887,680 bytes |
| RSS p95 | 12,406,784 bytes |
| Database + WAL + SHM | 53,376 bytes |

Certificate verification and HTTP response assertions passed; `/api/v1/snapshot` returned 404 without metrics on both listeners. These measurements cover only this short probe workload on Intel with one stored series. They do not prove the M1 steady-state budgets, full history workload, 1/3-client scenarios or temperature support. Reports are local ignored artifacts at `artifacts/benchmarks/release-smoke.json` and `capabilities-release.json`; temporary development keys are also ignored and must never be distributed.

## 完整 Agent 的测量入口（2026-10-03）

`python3 scripts/runtime-benchmark.py --clients 0|1|3 --warmup 300 --duration 1800` 运行真实 Release Agent、默认历史及对应 SSE 查看者，报告服务自身 libproc 差分 CPU、footprint、RSS、实际扫描版本数和历史存储量。需要先构建对应主机架构 Release。它还产生每秒一组用于测量的认证 HTTP 查询，必须计入观察流量；当前脚本不是严格零 HTTP 请求的空闲基准。curl 客户端用于传输测试，不代表浏览器开销。

24 小时可设置 `--duration 86400`。物理写放大、浏览器相关进程、M1 三次稳态预算、热/睡眠约束和 2,000 真实进程扫描仍由真机验收补齐。旧 Benchmark 是 feasibility 原型；不要将它的轻量分钟表测量当作完整历史的结果。

最终 Release Agent 的短运行记录见 `artifacts/final-runtime-smoke.json`：Intel 开发机、3 个 loopback 查看者、预热 2 秒/采样 12 秒，服务 CPU 均值约 6.20%/p95 21.84%（单核口径），footprint p95 约 12.6MiB、RSS p95 约 25.2MiB。该窗口覆盖冷启动应用元数据，不足一分钟、未覆盖分钟提交或稳态，不能判定满足预算；完整 Agent 的开销明显高于旧探针，必须按上述 5 分钟预热/30 分钟及目标 M1 场景实测后判断和优化。

## v0.1.3 short Intel diagnostic

A sequential Release-Agent diagnostic on the Intel development host used 15 seconds of warmup and 30 seconds of measurement with no viewers. The observer still issued one authenticated snapshot/apps request per second. v0.1.2 averaged 6.03% of one CPU core (p95 23.36%), compared with 3.17% (p95 5.05%) for v0.1.3. Observed process-scan increments fell from 7 to 3, consistent with the 4-second to 10-second process cadence change. Records: `artifacts/stop-sampling-benchmark-before.json`, `artifacts/stop-sampling-benchmark-after.json`, and `artifacts/stop-sampling-comparison.json`.

This is a short diagnostic, not Apple Silicon acceptance, a steady-state budget result, or a three-run/24-hour performance gate. The default normal cadence is now 10 seconds for system/apps/temperature/GPU; constrained cadence is 20 seconds and drive SMART caching remains 60 seconds.
