#!/usr/bin/env bash
# ====================================================================
# Node-Guardian - K8s Utils Library (lib/k8s-utils.sh)
# 容器运行时检测、Pod 溯源、关键日志提取
# ====================================================================
set -euo pipefail

# ------------------------------------------------------------------
# 容器运行时检测：自动识别 containerd/docker 及其 cgroup 驱动
# 返回: 打印 "${runtime}:${cgroup_driver}" 到 stdout，日志到 stderr
# ------------------------------------------------------------------
detect_container_runtime() {
    log_info "探测容器运行时环境..."

    local runtime=""
    local cgroup_driver=""

    # 优先级: containerd (K8s 默认) > docker
    if command -v containerd >/dev/null 2>&1 && pgrep -x containerd >/dev/null 2>&1; then
        runtime="containerd"
    elif command -v docker >/dev/null 2>&1 && pgrep -x dockerd >/dev/null 2>&1; then
        runtime="docker"
    fi

    if [ -z "$runtime" ]; then
        log_error "未检测到运行中的容器运行时 (containerd/docker)"
        return 1
    fi
    log_success "容器运行时: ${runtime}"

    local containerd_config="${CONTAINERD_CONFIG:-/etc/containerd/config.toml}"

    # 检测 cgroup 驱动
    case "$runtime" in
        containerd)
            if [ -f "$containerd_config" ]; then
                cgroup_driver=$(grep -Po 'SystemdCgroup\s*=\s*\K\w+' "$containerd_config" 2>/dev/null || echo "")
                case "$cgroup_driver" in
                    true)  cgroup_driver="systemd" ;;
                    false) cgroup_driver="cgroupfs" ;;
                    *)     cgroup_driver="" ;;
                esac
            fi
            if [ -z "$cgroup_driver" ]; then
                # shellcheck disable=SC2009
                cgroup_driver=$(ps aux 2>/dev/null | grep containerd | grep -oP '--cgroup-driver=\K\S+' | head -1 || echo "unknown")
            fi
            ;;
        docker)
            cgroup_driver=$(docker info 2>/dev/null | grep -i "Cgroup Driver" | awk '{print $NF}' || echo "unknown")
            ;;
    esac
    log_info "Cgroup 驱动: ${cgroup_driver}"

    # 校验与 kubelet 的 cgroup 驱动一致性
    local kubelet_cgroup=""
    if command -v kubelet >/dev/null 2>&1; then
        # shellcheck disable=SC2009
        kubelet_cgroup=$(ps aux 2>/dev/null | grep kubelet | grep -oP '--cgroup-driver=\K\S+' | head -1 || echo "")
        if [ -n "$kubelet_cgroup" ] && [ "$cgroup_driver" != "$kubelet_cgroup" ] && [ "$cgroup_driver" != "unknown" ]; then
            log_warn "Cgroup 驱动不一致: 运行时=${cgroup_driver}, kubelet=${kubelet_cgroup}"
        fi
    fi

    printf "%s:%s\n" "$runtime" "$cgroup_driver"
}

# ------------------------------------------------------------------
# 通过高占用 PID 反查 K8s Pod 名称与 Namespace
# 用法: find_pod_by_pid <PID>
# ------------------------------------------------------------------
find_pod_by_pid() {
    local pid="$1"
    local procfs="${PROCFS:-/proc}"

    if [ -z "$pid" ]; then
        log_error "find_pod_by_pid: 缺少 PID 参数"
        return 1
    fi
    if [ ! -d "${procfs}/${pid}" ]; then
        log_error "PID ${pid} 不存在或已退出"
        return 1
    fi

    log_info "逆向追踪 PID ${pid} → K8s Pod..."

    # 1. 从 /proc/<pid>/cgroup 提取容器 ID
    local cgroup_file="${procfs}/${pid}/cgroup"
    if [ ! -r "$cgroup_file" ]; then
        log_error "无法读取 ${cgroup_file}"
        return 1
    fi

    local container_id=""
    # 按优先级尝试运行时特有模式提取容器 ID，提高匹配精度：
    #   1) containerd: .../containerd.service/<64-hex>
    #   2) cri-o: .../crio-<64-hex>.scope
    #   3) docker: .../docker/<64-hex>
    #   4) 兜底: 通用 64 位 hex（可能出现非容器 ID 的巧合匹配，作为最后手段）
    container_id=$(grep -oP 'containerd\.service/\K[a-f0-9]{64}' "$cgroup_file" 2>/dev/null | head -1)
    if [ -z "$container_id" ]; then
        container_id=$(grep -oP 'crio-\K[a-f0-9]{64}(?=\.scope)' "$cgroup_file" 2>/dev/null | head -1)
    fi
    if [ -z "$container_id" ]; then
        container_id=$(grep -oP 'docker/\K[a-f0-9]{64}' "$cgroup_file" 2>/dev/null | head -1)
    fi
    if [ -z "$container_id" ]; then
        # 兜底：通用 64 位十六进制匹配
        container_id=$(grep -oP '[a-f0-9]{64}' "$cgroup_file" 2>/dev/null | head -1)
    fi

    if [ -z "$container_id" ]; then
        log_warn "无法从 cgroup 提取容器 ID，进程可能未运行在容器中"
        return 1
    fi
    log_info "容器 ID: ${container_id:0:12}..."

    # 2. 通过 crictl 查询 Pod 元数据
    if ! command -v crictl >/dev/null 2>&1; then
        log_warn "未安装 crictl，仅输出容器 ID"
        printf "pid=%s container_id=%s\n" "$pid" "$container_id"
        return 0
    fi

    local pod_id=""
    pod_id=$(crictl inspect "$container_id" 2>/dev/null | grep -oP '"podSandboxId":\s*"\K[^"]+' || echo "")

    if [ -z "$pod_id" ]; then
        log_warn "无法查询容器 ${container_id:0:12} 的 Pod 信息"
        printf "pid=%s container_id=%s\n" "$pid" "$container_id"
        return 0
    fi

    local pod_json=""
    pod_json=$(crictl inspectp "$pod_id" 2>/dev/null || echo "")

    local pod_name="" pod_namespace=""
    pod_name=$(echo "$pod_json" | grep -oP '"name":\s*"\K[^"]+' | head -1)
    pod_namespace=$(echo "$pod_json" | grep -oP '"namespace":\s*"\K[^"]+' | head -1)

    log_success "Pod: ${pod_namespace:-unknown}/${pod_name:-unknown}"
    printf "pid=%s container_id=%s pod_id=%s namespace=%s pod_name=%s\n" \
        "$pid" "$container_id" "${pod_id:0:12}" "${pod_namespace:-unknown}" "${pod_name:-unknown}"
}

# ------------------------------------------------------------------
# 提取最近 15 分钟 kubelet / containerd / docker 关键错误日志
# ------------------------------------------------------------------
extract_critical_logs() {
    local minutes="${1:-15}"
    local keywords="error|timeout|deadline|exceeded|failed|refused|panic|oom|backoff"

    log_info "提取最近 ${minutes} 分钟内底层组件关键错误日志 (匹配: ${keywords})..."
    log_warn "============================================================"

    local has_jctl=false
    command -v journalctl >/dev/null 2>&1 && has_jctl=true

    # kubelet
    log_info "--- kubelet ---"
    if [ "$has_jctl" = true ]; then
        journalctl -u kubelet --since "${minutes} min ago" --no-pager -o short-iso 2>/dev/null \
            | grep -iE "$keywords" || log_info "  无匹配记录。"
    elif [ -f /var/log/kubelet.log ]; then
        grep -iE "$keywords" /var/log/kubelet.log 2>/dev/null || log_info "  无匹配记录。"
    elif [ -f /var/log/syslog ]; then
        grep -iE "kubelet" /var/log/syslog 2>/dev/null | grep -iE "$keywords" || log_info "  无匹配记录。"
    else
        log_warn "  日志源不可用。"
    fi

    # containerd
    log_error "--- containerd ---"
    if [ "$has_jctl" = true ]; then
        journalctl -u containerd --since "${minutes} min ago" --no-pager -o short-iso 2>/dev/null \
            | grep -iE "$keywords" || log_info "  无匹配记录。"
    elif [ -f /var/log/containerd.log ]; then
        grep -iE "$keywords" /var/log/containerd.log 2>/dev/null || log_info "  无匹配记录。"
    elif [ -f /var/log/syslog ]; then
        grep -iE "containerd" /var/log/syslog 2>/dev/null | grep -iE "$keywords" || log_info "  无匹配记录。"
    else
        log_warn "  日志源不可用。"
    fi

    # docker
    log_error "--- dockerd ---"
    if [ "$has_jctl" = true ]; then
        journalctl -u docker --since "${minutes} min ago" --no-pager -o short-iso 2>/dev/null \
            | grep -iE "$keywords" || log_info "  无匹配记录或未安装。"
    elif [ -f /var/log/docker.log ]; then
        grep -iE "$keywords" /var/log/docker.log 2>/dev/null || log_info "  无匹配记录。"
    else
        log_warn "  日志源不可用。"
    fi

    log_warn "============================================================"
    log_success "关键日志提取完成。"
}
