<p align="center">
  <h1 align="center">🛡️ Node Guardian</h1>
  <p align="center"><strong>云原生节点轻量级运维工具箱 / Lightweight Cloud-Native Node Operations Toolkit for Kubernetes</strong></p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/bash-4.2%2B-brightgreen" alt="Bash 4.2+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
  <img src="https://img.shields.io/badge/platform-linux%2Famd64-lightgrey" alt="Linux/amd64">
  <img src="https://github.com/noneedtostudy/node-guardian/actions/workflows/lint.yml/badge.svg" alt="CI">
</p>

---

## 目录 / Table of Contents

- [概述](#概述)
- [快速开始](#快速开始)
- [工具集](#工具集)
- [架构](#架构)
- [配置说明](#配置说明)
- [开发](#开发)
- [贡献](#贡献)
- [许可证](#许可证)
- [English](#english)

---

## 概述

**Node Guardian** 是一款为 Kubernetes 工作节点与控制平面节点 Day-2 运维场景量身打造的轻量级 Bash 工具集。它以高内聚、幂等、防御性编程的工具链取代传统运维脚本的"一把梭"模式。

### 为什么需要 Node Guardian？

云原生集群的故障模式高度可预测：conntrack 表耗尽、MTU 不匹配、kubelet 参数配置不当、高负载进程无法追溯到 Pod。大多数团队在凌晨三点被电话叫醒时才仓促应对。Node Guardian 将这些排障经验编码为开箱即用的工具链。

### 核心原则

| 原则 | 实现方式 |
|------|---------|
| **幂等性** | 一切变更操作先比对当前状态再执行；反复运行始终安全 |
| **防御性执行** | 全链路 `set -euo pipefail`、信号捕获 (EXIT/INT/TERM)、命令注入元字符拦截 |
| **干运行优先** | 所有工具支持 `--dry-run` — 先预览变更，确认后再正式执行 |
| **可组合性** | 共享 `lib/` 模块使入口脚本保持轻薄、可测试 |

---

## 快速开始

```bash
# 在任意 K8s 节点上克隆仓库
git clone https://github.com/noneedtostudy/node-guardian.git
cd node-guardian

# 查看工具版本
./bin/kn-preflight --version

# 预演模式 — 仅展示将要修改的内容，不做实质性变更
sudo ./bin/kn-preflight --dry-run

# 正式执行节点内核调优与加固
sudo ./bin/kn-preflight

# 节点异常时，5 分钟内完成排障信息收集
sudo ./bin/kn-diagnose --minutes 15 --top 5

# 基于 CIS 基线审计节点安全态势（JSON 输出便于接入监控系统）
sudo ./bin/kn-security --json

# 在变更窗口前创建节点配置快照
sudo ./bin/kn-backup --output /var/backups/node-guardian

# 以结构化 JSON 输出诊断结果
sudo ./bin/kn-diagnose --minutes 15 --top 5 --json
```

### 环境要求

- **Bash 4.2+**
- **Linux 内核 4.x+**（conntrack、sysctl、cgroups v1/v2）
- **Root 权限**（sysctl 写入、服务状态检查、日志读取必需）
- **可选依赖（推荐安装）：** `jq`、`crictl`、`conntrack`、`journalctl`

---

## 工具集

### kn-preflight — 节点准入预检

新节点加入集群前，验证并加固内核参数、容器运行时及网络配置。

```
用法: kn-preflight [--dry-run] [--json] [--version]
```

**执行阶段：**
1. **权限检查** — 验证 root 执行上下文
2. **内核调优** — 审计并幂等应用 8 项关键 sysctl 参数（somaxconn、tcp_tw_reuse、bridge-nf-call、inotify watches 等）
3. **容器运行时检测** — 自动识别 containerd / docker，探测 cgroup 驱动并与 kubelet 交叉校验
4. **MTU 一致性** — 对比物理网卡与 CNI 虚拟网卡 MTU，标记 overlay 封装风险

**输出示例：**
```
[2026-05-24 10:15:32] [OK] [kn-preflight] [PASS] net.core.somaxconn = 32768
[2026-05-24 10:15:32] [WARN] [kn-preflight] [DIFF] net.ipv4.tcp_tw_reuse (当前: 0, 预期: 1)
[2026-05-24 10:15:32] [OK] [kn-preflight] 容器运行时: containerd
[2026-05-24 10:15:32] [OK] [kn-preflight] Cgroup 驱动: systemd
```

### kn-diagnose —「黄金五分钟」排障

当节点 NotReady 时，这是你的第一个命令。一键收集系统负载、Pod 溯源、网络诊断与关键错误日志。

```
用法: kn-diagnose [--dry-run] [--json] [--minutes <N>] [--top <N>] [--version]
```

**执行阶段：**
1. **系统负载快照** — 主机名、运行时长、内核版本、负载均值 vs CPU 核数、内存使用率、关键挂载点磁盘占用
2. **Pod 逆向溯源** — 取内存占用 Top-N PID，通过 `/proc/<pid>/cgroup` → 容器 ID → `crictl inspect` 反查 K8s Pod 名与 Namespace
3. **网络诊断** — Conntrack 表使用率（85%/95% 分级告警）、TIME_WAIT 缓解检查、MTU 一致性审计
4. **关键日志提取** — 在指定时间窗口内，从 kubelet / containerd / docker 日志中按 `error|timeout|deadline|panic|oom|backoff` 模式过滤错误

### kn-security — 安全基线审计

基于 CIS 规范的三阶段只读扫描，提供可操作的修复建议。退出码 1 表示存在未通过项，适合接入 CI/CD 卡点。

```
用法: kn-security [--dry-run] [--json] [--config <path>] [--version]
```

**执行阶段：**
1. **kubelet 加固** — 审计 `anonymous-auth`、`read-only-port`、`authorization-mode` 三项关键参数
2. **高危端口扫描** — 检查 12 项不应在 K8s 节点上监听的端口（FTP、Telnet、SMTP、RPCBIND、SMB、NFS、未认证 Redis/MongoDB 等）
3. **安全服务检查** — 验证 `auditd` 等必需服务处于运行状态且已设开机自启

### kn-backup — 灾备快照

在变更窗口前创建带完整性校验的节点配置快照，支持闭环验证。

```
用法: kn-backup [--dry-run] [--json] [--config <path>] [--output <path>] [--version]
     kn-backup --verify <archive.tar.gz>
```

**功能特性：**
- 时间戳命名 gzip 归档，覆盖 kubelet 状态、容器运行时配置、CNI 配置、sysctl 持久化文件、静态 Pod 清单
- 每个归档伴随 SHA256 校验文件
- `--verify` 模式实现闭环灾备验证：重新计算摘要并检查归档可读性
- 所有备份目标通过 `config/backup_targets.conf` 可配置
- 支持目录级 **exclude 规则**（逗号分隔的通配模式），避免备份容器日志等大体积临时数据
- 支持 **大小上限**（max_size_mb），超出阈值的路径自动跳过，防止备份膨胀

---

## 架构

```
.
├── bin/                        # 可执行入口
│   ├── kn-preflight            # 节点准入预检
│   ├── kn-diagnose             # "黄金五分钟"排障
│   ├── kn-security             # CIS 安全审计
│   └── kn-backup               # 灾备快照
├── lib/                        # 共享库模块
│   ├── core.sh                 # 日志、trap 信号处理、安全命令执行器
│   ├── sysctl.sh               # 内核参数幂等审计
│   ├── network.sh              # MTU 一致性、Conntrack 分析
│   └── k8s-utils.sh            # 容器运行时检测、Pod 溯源、日志提取
├── config/                     # 基线配置文件
│   ├── sysctl_baseline.env     # 生产内核参数基线
│   ├── cis_rules.cfg           # CIS 规则（kubelet、端口、服务）
│   └── backup_targets.conf     # 灾备目标清单
├── tests/                      # BATS 单元测试套件
│   ├── test_helper.bash        # 测试 Harness（断言与 Mock 支持）
│   ├── test_core.bats          # 核心库测试（日志、干运行、trap、清理）
│   ├── test_sysctl.bats        # sysctl 幂等性、差异检测、干运行穿透
│   ├── test_network.bats       # 网络库测试（MTU 一致性、Conntrack 分级告警）
│   └── test_k8s_utils.bats     # K8s 工具库测试（运行时检测、Pod 溯源、日志提取）
├── .github/workflows/
│   └── lint.yml                # CI: ShellCheck + BATS 测试
├── init_workspace.sh           # 开发者工作区引导脚本
└── README.md
```

### 设计决策

**为什么用 Bash 而不是 Go/Python？**
K8s 节点自带 Bash — 无需运行时依赖、无需二进制分发、无版本漂移。当你只能通过 SSH 访问一台故障节点时，Bash 就是你仅有的武器。

**`crictl` / `conntrack` / `jq` 怎么办？**
均为可选依赖。工具会优雅降级：缺少 `crictl` 时 Pod 溯源终止于容器 ID；缺少 `conntrack` 时仍可通过 `/proc/sys` 计数器完成使用率分析。

**为什么每个工具都支持 `--dry-run`？**
Day-2 运维面向生产节点。一切变更操作必须在执行前可预览。`core.sh` 中的 `run_cmd` 门禁强制执行这一点 — 任何库函数都无法绕过。`run_cmd` 的注入防护采用分层策略：始终拒绝命令替换（`$()`、反引号），但允许 `&&`/`||` 条件串联以便合法操作链式执行。

**JSON 输出模式**
所有工具均支持 `--json` 标志，以结构化 JSON 格式输出报告。启用后终端日志将被静默，仅 stdout 输出 JSON。适用于接入 Prometheus textfile collector、日志平台（ELK/Loki）或 CI/CD 流水线结果解析。

```bash
# 安全审计 JSON 输出示例
sudo ./bin/kn-security --json | jq '.results[] | select(.status=="fail")'
```

**日志轮转**
每次工具启动时自动清理 `/var/log/kn-guardian_*.log` 中超过 30 天的旧日志文件，防止磁盘累积。保留天数可通过 `cleanup_old_logs` 函数参数调整。

---

## 配置说明

### 内核参数基线 (`config/sysctl_baseline.env`)

```ini
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
fs.inotify.max_user_watches=524288
```

在运行 `kn-preflight` 前按需调整。工具会逐项对比当前内核状态与基线值，仅在出现差异时写入。

### CIS 安全规则 (`config/cis_rules.cfg`)

```ini
# Kubelet 安全参数
KUBELET_CHECK_anonymous-auth=false
KUBELET_CHECK_read-only-port=0
KUBELET_CHECK_authorization-mode=Webhook

# 不应在节点上监听的高危端口
RISK_PORT=21:TCP:FTP
RISK_PORT=6379:TCP:Redis (无认证)
# ... 按需增删条目

# 必需安全服务
REQUIRED_SERVICE=auditd
```

### 备份目标 (`config/backup_targets.conf`)

管道分隔清单：`标签|路径|类型|exclude|max_size_mb`。exclude 和 max_size_mb 为可选列。根据节点实际情况注释或新增目标。

```ini
# 格式: <标签>|<路径>|<类型>|[exclude]|[max_size_mb]
kubelet-config|/var/lib/kubelet/config.yaml|file
# 排除日志与缓存，限制 500M 防止备份膨胀
kubelet-state|/var/lib/kubelet|dir|*.log,cache,tmp|500
containerd-config|/etc/containerd/config.toml|file
cni-config|/etc/cni/net.d|dir
```

### 环境变量

| 变量 | 默认值 | 使用者 |
|------|-------|--------|
| `DRY_RUN` | `false` | 所有工具（也可通过 `--dry-run` 标志设置） |
| `JSON_OUTPUT` | `false` | 所有工具（也可通过 `--json` 标志设置） |
| `SYSCTL_PERSIST_FILE` | `/etc/sysctl.d/99-node-guardian.conf` | `kn-preflight` |
| `BACKUP_ROOT` | `/var/backups/node-guardian` | `kn-backup` |
| `CNI_INTERFACE_GLOBS` | `cali*,flannel*,cilium*,weave*,cni*,vxlan*,lxc*,tunl*,kube-ipvs*,geneve*` | `check_mtu_consistency`（逗号分隔，适配新 CNI 插件） |
| `SYSFS_NET` | `/sys/class/net` | `check_mtu_consistency`（测试注入点） |
| `PROCFS_NET` | `/proc/sys/net` | `analyze_conntrack`（测试注入点） |
| `PROCFS` | `/proc` | `find_pod_by_pid`（测试注入点） |
| `CONTAINERD_CONFIG` | `/etc/containerd/config.toml` | `detect_container_runtime`（测试注入点） |

---

## 开发

```bash
# 引导新工作区
./init_workspace.sh

# 运行 ShellCheck 静态检查
shellcheck -x bin/* lib/*.sh tests/*.bats

# 运行 BATS 单元测试
bats tests/ --recursive
```

### 编写测试

测试使用 [BATS](https://github.com/bats-core/bats-core) 框架。Mock 通过 `PATH` 注入实现 — 在临时目录中创建 mock 二进制文件，并将其前置到 `$PATH`。

```bash
@test "示例：干运行模式阻止命令实际执行" {
    reload_core
    export DRY_RUN=true
    local marker="${TEST_TMP_DIR}/should_not_exist"
    run_cmd "touch ${marker}" "创建标记文件"
    [ ! -f "$marker" ]
}
```

断言辅助函数见 `tests/test_helper.bash`（`assert_eq`、`assert_contains`、`assert_file_exists`、`assert_files_equal`）。

---

## 贡献

1. Fork 本仓库
2. 创建功能分支：`git checkout -b feat/my-feature`
3. 确保 ShellCheck 和 BATS 测试在本地通过
4. 向 `main` 分支发起 Pull Request

所有 PR 将通过 GitHub Actions 自动执行静态检查与单元测试。

---

## 许可证

MIT © 2026 [Shaohan He](https://github.com/noneedtostudy)

---

## English

## Overview

**Node Guardian** is a lightweight, battle-tested Bash toolkit purpose-built for Day-2 operations of Kubernetes worker and control-plane nodes. It replaces ad-hoc shell scripts with a cohesive, idempotent, and defensive toolchain.

### Why Node Guardian?

Cloud-native clusters fail in predictable ways: conntrack table exhaustion, MTU mismatches, misconfigured kubelet parameters, runaway processes with no Pod traceability. Most teams discover these at 3 AM with no playbook. Node Guardian encodes the playbook.

### Core Principles

| Principle | Implementation |
|-----------|---------------|
| **Idempotency** | Every mutating operation checks current state before acting; re-running is always safe |
| **Defensive Execution** | `set -euo pipefail` throughout, signal traps (EXIT/INT/TERM), metacharacter injection guards |
| **Dry-Run First** | All tools support `--dry-run` — preview changes before applying them |
| **Composability** | Shared `lib/` modules keep entry points thin and testable |

## Quick Start

```bash
# Clone the repository on any K8s node
git clone https://github.com/noneedtostudy/node-guardian.git
cd node-guardian

# Preview what preflight would change (safe, read-only preview)
sudo ./bin/kn-preflight --dry-run

# Apply node hardening and kernel tuning
sudo ./bin/kn-preflight

# Diagnose a sick node in under 5 minutes
sudo ./bin/kn-diagnose --minutes 15 --top 5

# Audit security posture against CIS benchmarks
sudo ./bin/kn-security

# Snapshot critical node configuration before maintenance
sudo ./bin/kn-backup --output /var/backups/node-guardian
```

### Prerequisites

- **Bash 4.2+**
- **Linux kernel 4.x+** (conntrack, sysctl, cgroups v1/v2)
- **Root privileges** (required for sysctl writes, service inspection, and log access)
- **Optional but recommended:** `jq`, `crictl`, `conntrack`, `journalctl`

## Tools

### kn-preflight — Node Admission Preflight

Validate and harden a node before it joins the cluster.

```
Usage: kn-preflight [--dry-run] [--json] [--version]
```

**Phases:**
1. **Root check** — verifies execution context
2. **Kernel tuning** — audits and applies 8 critical sysctl parameters for high-concurrency workloads (somaxconn, tcp_tw_reuse, bridge-nf-call, inotify watches, etc.)
3. **Container runtime detection** — identifies containerd vs docker, detects cgroup driver, validates kubelet alignment
4. **MTU consistency** — compares physical NIC MTU against CNI virtual interfaces, flags overlay encapsulation risks

**Example output:**
```
[2026-05-24 10:15:32] [OK] [kn-preflight] [PASS] net.core.somaxconn = 32768
[2026-05-24 10:15:32] [WARN] [kn-preflight] [DIFF] net.ipv4.tcp_tw_reuse (current: 0, expected: 1)
[2026-05-24 10:15:32] [OK] [kn-preflight] Container runtime: containerd
[2026-05-24 10:15:32] [OK] [kn-preflight] Cgroup driver: systemd
```

### kn-diagnose — "Golden 5 Minutes" Diagnostic

When a node goes NotReady, this is your first command.

```
Usage: kn-diagnose [--dry-run] [--json] [--minutes <N>] [--top <N>] [--version]
```

**Phases:**
1. **System load snapshot** — hostname, uptime, kernel, load average vs CPU cores, memory %, disk usage on critical mount points
2. **Pod traceback** — takes the top-N memory-consuming PIDs and reverse-maps each to its K8s Pod namespace/name via `/proc/<pid>/cgroup` → container ID → `crictl inspect`
3. **Network diagnostics** — Conntrack table utilization with graded alerts (85%/95%), TIME_WAIT mitigation check, MTU consistency audit
4. **Critical log extraction** — scans kubelet/containerd/docker logs for `error|timeout|deadline|panic|oom|backoff` patterns within the time window

### kn-security — CIS Security Audit

Three-phase read-only scan with actionable remediation hints. Exits with code 1 if any check fails — suitable for CI/CD gating.

```
Usage: kn-security [--dry-run] [--json] [--config <path>] [--version]
```

**Phases:**
1. **Kubelet hardening** — audits `anonymous-auth`, `read-only-port`, `authorization-mode` against CIS benchmarks
2. **Risk port scan** — checks for 12 well-known insecure services listening on the node (FTP, Telnet, SMTP, RPCBIND, SMB, NFS, unauthenticated Redis/MongoDB, etc.)
3. **Security services** — validates `auditd` (and any additional services defined in config) is running and enabled at boot

### kn-backup — Disaster Recovery Snapshots

Capture node configuration before maintenance windows with integrity verification.

```
Usage: kn-backup [--dry-run] [--json] [--config <path>] [--output <path>] [--version]
       kn-backup --verify <archive.tar.gz>
```

**Features:**
- Timestamped gzipped snapshots of kubelet state, container runtime configs, CNI config, sysctl customizations, static pod manifests
- SHA256 integrity checksums written alongside each archive
- `--verify` mode for closed-loop DR validation: recomputes checksum and checks archive readability
- All backup targets are configurable via `config/backup_targets.conf`
- Directory **exclude rules** (comma-separated globs) to skip bulky temp files like container logs
- **Max size cap** (max_size_mb) — targets exceeding the threshold are automatically skipped

## Architecture

```
.
├── bin/                        # Executable entry points
│   ├── kn-preflight            # Node admission preflight
│   ├── kn-diagnose             # "Golden 5 minutes" diagnostics
│   ├── kn-security             # CIS security auditor
│   └── kn-backup               # Disaster recovery snapshots
├── lib/                        # Shared library modules
│   ├── core.sh                 # Logging, trap handlers, guarded command runner
│   ├── sysctl.sh               # Kernel parameter idempotent auditing
│   ├── network.sh              # MTU consistency, Conntrack analysis
│   └── k8s-utils.sh            # Container runtime detection, Pod traceback, log extraction
├── config/                     # Baseline configuration files
│   ├── sysctl_baseline.env     # Production kernel parameter baselines
│   ├── cis_rules.cfg           # CIS benchmark rules for kubelet, ports, services
│   └── backup_targets.conf     # DR snapshot target manifest
├── tests/                      # BATS unit test suite
│   ├── test_helper.bash        # Test harness with assertions and mock support
│   ├── test_core.bats          # Core library tests (logging, dry-run, traps, cleanup)
│   ├── test_sysctl.bats        # Sysctl idempotency, diff detection, dry-run penetration
│   ├── test_network.bats       # Network library tests (MTU consistency, Conntrack tiered alerts)
│   └── test_k8s_utils.bats     # K8s utils tests (runtime detection, Pod traceback, log extraction)
├── .github/workflows/
│   └── lint.yml                # CI: ShellCheck + BATS test execution
├── init_workspace.sh           # Developer workspace bootstrapper
└── README.md
```

### Design Decisions

**Why Bash and not Go/Python?**
K8s nodes ship with Bash — no runtime dependency, no binary distribution, no version skew. When SSH is your only access into a broken node, Bash is what you have.

**What about `crictl` / `conntrack` / `jq`?**
They're optional. The tools degrade gracefully: if `crictl` is missing, Pod traceback stops at container ID; if `conntrack` is missing, the usage-rate analysis still works from `/proc/sys` counters.

**Why `--dry-run` everywhere?**
Day-2 ops runs on production nodes. Every mutating operation must be previewable. The `run_cmd` gate in `core.sh` enforces this — no library function can bypass it. The injection guard uses a layered approach: command substitution (`$()`, backticks) is always blocked, while `&&`/`||` conditional chaining is allowed for legitimate multi-step operations.

**JSON output mode**
All tools support `--json` for structured machine-readable output. When enabled, stderr terminal logs are silenced and a complete JSON report is written to stdout — suitable for Prometheus textfile collectors, log platforms (ELK/Loki), or CI/CD pipeline result parsing.

**Log rotation**
On every invocation, tools automatically purge `kn-guardian_*.log` files older than 30 days from `/var/log`. The retention window is adjustable via the `cleanup_old_logs` function parameter.

## Configuration

### Kernel Baseline (`config/sysctl_baseline.env`)

```ini
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
fs.inotify.max_user_watches=524288
```

Customize values before running `kn-preflight`. The tool compares current kernel state against each entry and only writes on mismatch.

### CIS Rules (`config/cis_rules.cfg`)

```ini
# Kubelet security parameters
KUBELET_CHECK_anonymous-auth=false
KUBELET_CHECK_read-only-port=0
KUBELET_CHECK_authorization-mode=Webhook

# High-risk ports that should NOT be listening
RISK_PORT=21:TCP:FTP
RISK_PORT=6379:TCP:Redis (unauthenticated)
# ... add or remove entries as needed

# Required security services
REQUIRED_SERVICE=auditd
```

### Backup Targets (`config/backup_targets.conf`)

Pipe-delimited manifest: `label|path|type|exclude|max_size_mb`. Exclude and max_size_mb are optional. Comment out or add targets as your node landscape requires.

```ini
# Format: <label>|<path>|<type>|[exclude]|[max_size_mb]
kubelet-config|/var/lib/kubelet/config.yaml|file
# Skip logs and cache, cap at 500M to prevent backup bloat
kubelet-state|/var/lib/kubelet|dir|*.log,cache,tmp|500
containerd-config|/etc/containerd/config.toml|file
cni-config|/etc/cni/net.d|dir
```

### Environment Variables

| Variable | Default | Used By |
|----------|---------|---------|
| `DRY_RUN` | `false` | All tools (set via `--dry-run` flag) |
| `JSON_OUTPUT` | `false` | All tools (set via `--json` flag) |
| `SYSCTL_PERSIST_FILE` | `/etc/sysctl.d/99-node-guardian.conf` | `kn-preflight` |
| `BACKUP_ROOT` | `/var/backups/node-guardian` | `kn-backup` |
| `CNI_INTERFACE_GLOBS` | `cali*,flannel*,cilium*,weave*,cni*,vxlan*,lxc*,tunl*,kube-ipvs*,geneve*` | `check_mtu_consistency` (comma-separated, override for new CNI plugins) |
| `SYSFS_NET` | `/sys/class/net` | `check_mtu_consistency` (test injection point) |
| `PROCFS_NET` | `/proc/sys/net` | `analyze_conntrack` (test injection point) |
| `PROCFS` | `/proc` | `find_pod_by_pid` (test injection point) |
| `CONTAINERD_CONFIG` | `/etc/containerd/config.toml` | `detect_container_runtime` (test injection point) |

## Development

```bash
# Bootstrap a fresh workspace
./init_workspace.sh

# Run ShellCheck lint
shellcheck -x bin/* lib/*.sh tests/*.bats

# Run BATS tests
bats tests/ --recursive
```

### Writing Tests

Tests use the [BATS](https://github.com/bats-core/bats-core) framework. Mocking is done via `PATH` injection — create a mock binary in a temp directory and prepend it to `$PATH`.

```bash
@test "example: dry-run prevents command execution" {
    reload_core
    export DRY_RUN=true
    local marker="${TEST_TMP_DIR}/should_not_exist"
    run_cmd "touch ${marker}" "create marker"
    [ ! -f "$marker" ]
}
```

See `tests/test_helper.bash` for assertion helpers (`assert_eq`, `assert_contains`, `assert_file_exists`, `assert_files_equal`).

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Ensure ShellCheck and BATS tests pass locally
4. Open a pull request against `main`

PRs are automatically linted and tested via GitHub Actions.

## License

MIT © 2026 [Shaohan He](https://github.com/noneedtostudy)
