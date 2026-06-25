# Node Guardian

> Lightweight Bash toolkit for Kubernetes node diagnostics, preflight checks, security audits, and configuration snapshots.

[![Bash](https://img.shields.io/badge/bash-4.2%2B-brightgreen)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux%2Famd64-lightgrey)](https://www.kernel.org/)

## 概述

Node Guardian 是一组面向 Kubernetes 节点的 Bash 运维工具。它把常见节点维护动作拆成四个命令，分别处理节点预检、故障诊断、安全审计和配置备份。

设计目标：

- 在故障节点上尽量减少运行时依赖。
- 所有可能修改系统状态的操作支持 `--dry-run`。
- 输出既适合人工阅读，也支持 `--json` 供自动化系统消费。
- 通过 BATS 和 ShellCheck 保持基础质量。

## 工具

| 命令 | 用途 |
| --- | --- |
| `kn-preflight` | 节点加入集群前的内核、容器运行时和网络预检 |
| `kn-diagnose` | 节点异常时收集负载、Pod 溯源、网络和日志信息 |
| `kn-security` | 只读安全基线审计 |
| `kn-backup` | 变更前备份关键配置并生成校验信息 |

## 快速开始

```bash
git clone https://github.com/Shaohan-He/node-guardian.git
cd node-guardian

# 预览节点预检会执行的变更
sudo ./bin/kn-preflight --dry-run

# 执行节点预检和内核参数修正
sudo ./bin/kn-preflight

# 收集最近 15 分钟的节点诊断信息
sudo ./bin/kn-diagnose --minutes 15 --top 5

# 执行安全基线审计
sudo ./bin/kn-security

# 备份关键配置
sudo ./bin/kn-backup --output /var/backups/node-guardian
```

## 前提条件

- Bash 4.2+
- Linux kernel 4.x+
- 需要 root 权限执行涉及系统配置、日志读取或服务检查的命令
- 可选工具：`jq`、`crictl`、`conntrack`、`journalctl`

缺少可选工具时，相关检查会降级或跳过，其他检查继续执行。

## 目录结构

```text
node-guardian/
├── bin/
│   ├── kn-preflight
│   ├── kn-diagnose
│   ├── kn-security
│   └── kn-backup
├── lib/
│   ├── core.sh
│   ├── sysctl.sh
│   ├── network.sh
│   └── k8s-utils.sh
├── config/
│   ├── sysctl_baseline.env
│   ├── cis_rules.cfg
│   └── backup_targets.conf
├── deploy/
├── tests/
└── .github/workflows/
```

## 命令说明

### `kn-preflight`

用于新节点或维护后的节点检查。主要检查项包括：

- root 执行上下文。
- sysctl 参数与 `config/sysctl_baseline.env` 的差异。
- containerd/docker 运行时识别。
- kubelet 与容器运行时 cgroup driver 一致性。
- 物理网卡和 CNI 网卡 MTU 一致性。

```text
Usage: kn-preflight [--dry-run] [--json] [--version]
```

### `kn-diagnose`

用于节点 NotReady、负载异常、网络异常等场景的信息收集。主要输出：

- 主机负载、内存、磁盘和 uptime。
- Top-N 进程与 Pod 的对应关系。
- Conntrack 使用率、TIME_WAIT、MTU 检查。
- kubelet/containerd/docker 关键日志片段。

```text
Usage: kn-diagnose [--dry-run] [--json] [--minutes <N>] [--top <N>] [--version]
```

### `kn-security`

执行只读安全检查。发现未通过项时返回非零退出码，适合接入 CI 或定期巡检。

```text
Usage: kn-security [--dry-run] [--json] [--config <path>] [--version]
```

### `kn-backup`

根据 `config/backup_targets.conf` 备份关键文件或目录，生成 gzip 归档和 SHA256 校验信息。

```text
Usage: kn-backup [--dry-run] [--json] [--config <path>] [--output <path>] [--version]
       kn-backup --verify <archive.tar.gz>
```

## 配置

### 内核参数

`config/sysctl_baseline.env` 定义 `kn-preflight` 使用的基线值。

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

### 安全规则

`config/cis_rules.cfg` 定义 kubelet 参数、风险端口和必需服务。

### 备份目标

`config/backup_targets.conf` 使用管道分隔格式：

```text
label|path|type|exclude|max_size_mb
```

## 开发

```bash
./init_workspace.sh
shellcheck -x bin/* lib/*.sh tests/*.bats
bats tests/ --recursive
```

测试通过 mock `PATH` 注入外部命令，避免依赖真实 root 环境。

## 相关项目

| 仓库 | 关系 |
| --- | --- |
| [node-health-watcher](https://github.com/Shaohan-He/node-health-watcher) | 可在发现节点异常后触发人工或自动诊断流程 |
| [fleet-observability](https://github.com/Shaohan-He/fleet-observability) | 可采集 Node Guardian 输出的日志或 textfile 指标 |
| [fleet-gitops](https://github.com/Shaohan-He/fleet-gitops) | 可管理 DaemonSet 或 Job 形式的部署配置 |

## License

MIT © 2026 [Shaohan He](https://github.com/Shaohan-He)
