#!/usr/bin/env bash
# lib/sysctl.sh - 内核参数审计与幂等应用库

# 审计并应用内核参数配置
# $1: 配置文件路径
apply_sysctl_baseline() {
    require_command "sysctl"
    require_command "awk"
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_error "基线配置文件丢失: $config_file"
        return 1
    fi

    log_info "启动内核参数审计，基线文件: $config_file"

    local needs_reload=false

    # 按行读取配置并比对
    while IFS='=' read -r key expected_val || [ -n "$key" ]; do
        # 忽略空行与注释
        [[ -z "$key" || "$key" == \#* ]] && continue
        
        # 清除多余空格
        key=$(echo "$key" | xargs)
        expected_val=$(echo "$expected_val" | xargs)

        local current_val
        # 获取当前值，静默处理不存在的参数
        current_val=$(sysctl -n "$key" 2>/dev/null || echo "N/A")

        # 将多空格标准化为单空格用于精确比对 (例如端口范围)
        current_val=$(echo "$current_val" | xargs)

        if [ "$current_val" == "$expected_val" ]; then
            log_success "[PASS] $key = $current_val"
        else
            log_warn "[DIFF] $key (当前: $current_val, 预期: $expected_val)"
            run_cmd "sysctl -w ${key}=\"${expected_val}\"" "临时修正内核参数"
            needs_reload=true
        fi
    done < "$config_file"
    
    # 仅在非 Dry-Run 模式且有修改时，执行持久化
    local persist_file="${SYSCTL_PERSIST_FILE:-/etc/sysctl.d/99-node-guardian.conf}"
    if [ "$DRY_RUN" = false ] && [ "$needs_reload" = true ]; then
        # 幂等性：目标文件已与基线一致则跳过写入
        if [ ! -f "$persist_file" ] || ! diff -q "$config_file" "$persist_file" >/dev/null 2>&1; then
            log_info "正在持久化配置至 ${persist_file}"
            run_cmd "cp \"$config_file\" \"$persist_file\"" "持久化 sysctl 配置到 ${persist_file}"
            run_cmd "sysctl --system > /dev/null 2>&1" "重载 sysctl 系统配置"
            log_success "内核参数持久化并重载完成。"
        else
            log_info "持久化配置已与基线一致，跳过写入。"
        fi
    elif [ "$DRY_RUN" = true ] && [ "$needs_reload" = true ]; then
        log_warn "[DRY-RUN] 跳过持久化配置步骤（将写入 ${persist_file}）。"
    fi
}