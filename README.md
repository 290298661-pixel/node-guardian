<p align="center">
  <h1 align="center">🛡️ Node Guardian</h1>
  <p align="center"><strong>云原生节点轻量级运维工具箱 / Lightweight Node Operations Toolkit for Kubernetes</strong></p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/bash-4.2%2B-brightgreen" alt="Bash 4.2+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License">
  <img src="https://img.shields.io/badge/platform-linux%2Famd64-lightgrey" alt="Linux/amd64">
  <img src="https://github.com/290298661-pixel/node-guardian/actions/workflows/lint.yml/badge.svg" alt="CI">
</p>

## 目录 / Table of Contents

- [概述](#概述)
- [快速开始](#快速开始)
- [架构](#架构)
- [工具集](#工具集)
- [配置说明](#配置说明)
- [开发](#开发)
- [贡献](#贡献)
- [许可证](#许可证)
- [English](#english)

---

## 概述

**Node Guardian** 是 K8s 节点 Day-2 运维的 Bash 工具箱——把常见故障的排障经验编码为四个开箱即用的命令。(conntrack 表耗尽、MTU 不匹配、kubelet 配置漂移、高负载进程找不到对应) Node Guardian 把这些写成了 `kn-diagnose` 一个命令。

### 它在工具链中的位置

Node Guardian 是 [三部曲](https://github.com/290298661-pixel) 的**第一环**——"响应层"：

| 项目 | 语言 | 回答的问题 |
|------|------|-----------|
| **Node Guardian** ← 你在这里 | Bash | 出了故障怎么排查和修复？ |
| [Node Health Watcher](https://github.com/290298661-pixel/node-health-watcher) | Python | 什么时候该去排查？ |
| [Game Fleet Director](https://github.com/290298661-pixel/game-server-orchestrator) | Go | 谁来操作游戏服本身？ |

**选 Bash 是因为** K8s 节点自带 Bash，没有运行时依赖、没有版本漂移。当你只能 SSH 进一台故障节点时，Bash 就是你仅有的武器。`crictl`、`conntrack`、`jq` 都是可选的——缺失时工具会优雅降级。

### 核心原则

| 原则 | 实现 |
|------|------|
| **幂等** | 先比对再变更，反复运行始终安全 |
| **防御性** | `set -euo pipefail` 全链路 + 命令注入元字符拦截 + 信号捕获 |
| **干运行优先** | 四个工具全部支持 `--dry-run`，先预览再执行 |
| **可测试** | 共享 `lib/` 模块，BATS 测试通过 mock PATH 注入，无需 root |

---

## 快速开始

```bash
git clone https://github.com/290298661-pixel/node-guardian.git && cd node-guardian

# 预演内核调优，只看不改
sudo ./bin/kn-preflight --dry-run

# 正式执行
sudo ./bin/kn-preflight

# 节点挂了？五分钟收集所有关键信息
sudo ./bin/kn-diagnose --minutes 15 --top 5

# 安全基线审计（退出码 1 = 有未通过项，适合 CI/CD 卡点）
sudo ./bin/kn-security

# 变更窗口前创建带 SHA256 校验的配置快照
sudo ./bin/kn-backup --output /var/backups/node-guardian
```

**环境：** Bash 4.2+ · Linux 内核 4.x+ · Root 权限 · 可选：`jq` `crictl` `conntrack`

---

## 架构

```
.
├── bin/                        # 四个可执行入口
│   ├── kn-preflight            # 节点准入预检 + 内核加固
│   ├── kn-diagnose             # "黄金五分钟"排障（负载→Pod溯源→网络→日志）
│   ├── kn-security             # CIS 安全基线审计
│   └── kn-backup               # 灾备快照 + SHA256 闭环验证
├── lib/                        # 共享库（被四个工具复用）
│   ├── core.sh                 # 日志、trap、安全命令执行器 run_cmd
│   ├── sysctl.sh               # 内核参数幂等审计与持久化
│   ├── network.sh              # MTU 一致性、Conntrack 分级告警
│   └── k8s-utils.sh            # 运行时检测、PID→Pod 溯源、日志提取
├── config/                     # 基线配置（sysctl / CIS 规则 / 备份目标）
├── tests/                      # BATS 测试套件（6 个文件，50+ 用例）
└── .github/workflows/lint.yml  # CI：ShellCheck + BATS
```

### 设计决策

**为什么每个工具都支持 `--dry-run`？** Day-2 运维面向生产节点，任何变更必须先可预览。`core.sh` 的 `run_cmd` 是全局门禁——`$DRY_RUN=true` 时只记录不执行，命令替换（`$()`、反引号）始终被拦截。

**为什么支持 `--json`？** 四个工具全部支持结构化 JSON 输出，可直接接入 Prometheus textfile collector、ELK/Loki 或 CI/CD 流水线。JSON 模式会静默终端日志，仅 stdout 输出。

**日志轮转** —— 每次启动自动清理 `/var/log/kn-guardian_*.log` 中超过 30 天的旧文件。

---

## 工具集

### kn-preflight — 节点准入预检

新节点加入集群前，验证并加固内核参数、容器运行时及网络配置。

**执行阶段：**
1. **权限检查** — 验证 root 执行上下文
2. **内核调优** — 审计并幂等应用 8 项 sysctl 参数
3. **容器运行时检测** — 自动识别 containerd / docker，探测 cgroup 驱动并与 kubelet 交叉校验
4. **MTU 一致性** — 对比物理网卡与 CNI 虚拟网卡 MTU

```
用法: kn-preflight [--dry-run] [--json] [--version]
```

### kn-diagnose —「黄金五分钟」排障

节点 NotReady 时的第一个命令。一键完成负载快照 → Pod 溯源 → 网络诊断 → 关键日志提取。

**执行阶段：**
1. **系统负载快照** — 主机名、uptime、load vs CPU、内存、磁盘
2. **Pod 逆向溯源** — Top-N PID → `/proc/<pid>/cgroup` → 容器 ID → `crictl inspect` → Pod/Namespace
3. **网络诊断** — Conntrack 使用率（85%/95% 分级）、TIME_WAIT 堆积、MTU 审计
4. **关键日志** — 按 `error|timeout|deadline|panic|oom|backoff` 过滤 kubelet/containerd/docker

```
用法: kn-diagnose [--dry-run] [--json] [--minutes <N>] [--top <N>] [--version]
```

### kn-security — 安全基线审计

基于 CIS 规范的三阶段只读扫描，退出码 1 = 存在未通过项，直接接入 CI/CD 卡点。

1. **kubelet 加固** — 审计 `anonymous-auth`、`read-only-port`、`authorization-mode`
2. **高危端口扫描** — 检查 12 项不应在节点上监听的端口
3. **安全服务** — 验证 `auditd` 等必需服务运行且开机自启

```
用法: kn-security [--dry-run] [--json] [--config <path>] [--version]
```

### kn-backup — 灾备快照

变更窗口前创建时间戳 gzip 归档 + SHA256 校验。支持目录 exclude、大小上限、`--verify` 闭环验证。

```
用法: kn-backup [--dry-run] [--json] [--config <path>] [--output <path>] [--version]
     kn-backup --verify <archive.tar.gz>
```

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

MIT © 2026 [Shaohan He](https://github.com/290298661-pixel)

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
git clone https://github.com/290298661-pixel/node-guardian.git
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

MIT © 2026 [Shaohan He](https://github.com/290298661-pixel)
