#!/usr/bin/env bash
# ====================================================================
# Node-Guardian - Network Library (lib/network.sh)
# MTU 一致性审计、Conntrack 连接跟踪分析
# ====================================================================
set -euo pipefail

# ------------------------------------------------------------------
# MTU 一致性检查：比对物理网卡与 CNI 虚拟网卡 MTU，检测 overlay 封装风险
# ------------------------------------------------------------------
check_mtu_consistency() {
    local sysfs_net="${SYSFS_NET:-/sys/class/net}"

    log_info "开始 MTU 一致性审计..."
    log_warn "============================================================"

    local phys_iface="" phys_mtu=""
    local mismatches=0

    # 1. 定位基准物理网卡: 默认路由 > 第一个非虚拟 UP 网卡
    phys_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [ -z "$phys_iface" ]; then
        phys_iface=$(ip -o link show up 2>/dev/null \
            | grep -vE 'lo|veth|docker|br-|cali|flannel|cilium|tunl|weave|cni|kube|lxc|geneve' \
            | awk -F': ' '{print $2}' | head -1)
    fi

    if [ -z "$phys_iface" ] || [ ! -f "${sysfs_net}/${phys_iface}/mtu" ]; then
        log_warn "未找到物理网卡，跳过 MTU 审计。"
        return 0
    fi

    phys_mtu=$(cat "${sysfs_net}/${phys_iface}/mtu")
    printf "%-24s MTU=%s\n" "基准网卡: ${phys_iface}" "$phys_mtu"
    log_info "基准网卡: ${phys_iface} (MTU=${phys_mtu})"

    # 2. 遍历 CNI 虚拟网卡并比对（支持通过环境变量覆盖以适配新 CNI）
    local default_cni_globs="cali*,flannel*,cilium*,weave*,cni*,vxlan*,lxc*,tunl*,kube-ipvs*,geneve*"
    local cni_globs_str="${CNI_INTERFACE_GLOBS:-${default_cni_globs}}"
    local cni_globs=()
    IFS=',' read -ra cni_globs <<< "$cni_globs_str"
    local found_any=false

    for glob in "${cni_globs[@]}"; do
        for iface in ${sysfs_net}/${glob}/mtu; do
            [ ! -f "$iface" ] && continue
            found_any=true
            local ifname="" cni_mtu=""
            ifname=$(basename "$(dirname "$iface")")
            cni_mtu=$(cat "$iface")

            if [ "$cni_mtu" -ne "$phys_mtu" ]; then
                log_warn "[MTU MISMATCH] ${ifname}: ${cni_mtu} (基准 ${phys_iface}: ${phys_mtu})"
                mismatches=$((mismatches + 1))
            else
                log_success "[MTU OK] ${ifname}: ${cni_mtu}"
            fi
        done
    done

    if [ "$found_any" = false ]; then
        log_info "未检测到 CNI 虚拟网卡，可能为单机环境或未部署 CNI。"
    fi

    # 3. Overlay 封装开销检查
    for iface in "${sysfs_net}"/vxlan*/mtu "${sysfs_net}"/tunl*/mtu "${sysfs_net}"/geneve*/mtu; do
        [ ! -f "$iface" ] && continue
        local ifname="" cni_mtu="" overhead=0
        ifname=$(basename "$(dirname "$iface")")
        cni_mtu=$(cat "$iface")

        case "$ifname" in
            vxlan*|geneve*) overhead=50 ;;
            tunl*)           overhead=20 ;;
        esac

        local safe_max=$((phys_mtu - overhead))
        if [ "$cni_mtu" -gt "$safe_max" ]; then
            log_warn "[MTU 封装风险] ${ifname}: ${cni_mtu} > 安全上限 ${safe_max} (${phys_mtu} - ${overhead} 封装开销)，可能导致分片丢包"
        fi
    done

    log_warn "============================================================"
    if [ "$mismatches" -eq 0 ]; then
        log_success "MTU 一致性审计通过，无异常。"
    else
        log_warn "MTU 审计完成: 发现 ${mismatches} 处不一致。建议统一 MTU 以避免丢包。"
    fi
}

# ------------------------------------------------------------------
# Conntrack 连接跟踪分析：检查 conntrack 表使用率，超出阈值告警
# $1: 告警阈值百分比 (默认 85)
# ------------------------------------------------------------------
analyze_conntrack() {
    local threshold="${1:-85}"
    local procfs_net="${PROCFS_NET:-/proc/sys/net}"

    log_info "开始 Conntrack 连接跟踪分析..."
    log_warn "============================================================"

    # 兼容新旧内核路径
    local ct_count_file="" ct_max_file=""
    if [ -f "${procfs_net}/netfilter/nf_conntrack_count" ]; then
        ct_count_file="${procfs_net}/netfilter/nf_conntrack_count"
        ct_max_file="${procfs_net}/netfilter/nf_conntrack_max"
    elif [ -f "${procfs_net}/ipv4/netfilter/ip_conntrack_count" ]; then
        ct_count_file="${procfs_net}/ipv4/netfilter/ip_conntrack_count"
        ct_max_file="${procfs_net}/ipv4/netfilter/ip_conntrack_max"
    fi

    if [ -z "$ct_count_file" ] || [ -z "$ct_max_file" ]; then
        log_warn "Conntrack 模块未加载或内核不支持，跳过分析。"
        return 0
    fi

    local ct_count="" ct_max=""
    ct_count=$(cat "$ct_count_file")
    ct_max=$(cat "$ct_max_file")

    if [ "$ct_max" -eq 0 ]; then
        log_error "nf_conntrack_max = 0，内核配置异常。"
        return 1
    fi

    local usage_pct=$((ct_count * 100 / ct_max))
    printf "%-24s %s/%s (%s%%)\n" "Conntrack 使用率" "$ct_count" "$ct_max" "$usage_pct"
    log_info "Conntrack: ${ct_count}/${ct_max} (${usage_pct}%)"

    # 分级告警
    if [ "$usage_pct" -ge 95 ]; then
        log_error "[CRITICAL] Conntrack 表使用率 ${usage_pct}% >= 95%，即将耗尽！大量新建连接将被丢弃。"
    elif [ "$usage_pct" -ge "$threshold" ]; then
        log_warn "[WARNING] Conntrack 表使用率 ${usage_pct}% >= ${threshold}%，处于高位，建议扩容或排查连接泄露。"
    else
        log_success "[OK] Conntrack 表使用率 ${usage_pct}%，处于正常范围。"
    fi

    # Top 来源 IP 统计
    if command -v conntrack >/dev/null 2>&1; then
        log_info "--- Top 5 连接来源 IP ---"
        conntrack -L 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/) print $i}' \
            | cut -d= -f2 \
            | sort | uniq -c | sort -rn | head -5 \
            || log_warn "无法解析 conntrack 表。"
    fi

    # TIME_WAIT 缓解检查
    local tw_reuse=""
    tw_reuse=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo "unknown")
    if [ "$tw_reuse" = "0" ]; then
        log_warn "net.ipv4.tcp_tw_reuse = 0，高并发下 TIME_WAIT 堆积会加剧 conntrack 压力。"
    fi

    log_warn "============================================================"
    log_success "Conntrack 分析完成。"
}
