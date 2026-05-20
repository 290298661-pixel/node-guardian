#!/usr/bin/env bash
# ====================================================================
# Node-Guardian - Core Library (lib/core.sh)
# ====================================================================

# -----------------------------------------------------------------
# 1. 安全
# -------------------------------------------------------------------
set -euo pipefail

# ------------------------------------------------------------------
# 2. 全局环境变量与配置
# -----------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
TIMESTAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
readonly TIMESTAMP
readonly LOG_FILE="/var/log/kn-guardian_${TIMESTAMP}.log"

# 版本号（唯一来源，所有工具通过 source core.sh 继承）
readonly VERSION="0.2.0"

export DRY_RUN=false
export JSON_OUTPUT=false
export TMP_FILES=()
export JSON_ENTRIES=()

# 颜色定义
readonly COLOR_RESET='\e[0m'
readonly COLOR_INFO='\e[36m'
readonly COLOR_SUCCESS='\e[32m'
readonly COLOR_WARN='\e[33m'
readonly COLOR_ERROR='\e[31m'

# ------------------------------------------------------------------
# 3. 标准化日志
# -----------------------------------------------------------------
_log() {
    local level_name="$1"
    local color="$2"
    local message="$3"
    local time_now
    time_now="$(date +'%Y-%m-%d %H:%M:%S')"

    # 构建日志内容格式
    local log_format="[${time_now}] [${level_name}] [${SCRIPT_NAME}] ${message}"

    # 1. 输出到终端（JSON 模式下静默所有 stderr 日志）
    if [ "$JSON_OUTPUT" = false ]; then
        printf "%b\n" "${color}${log_format}${COLOR_RESET}" >&2
    fi

    # 2. 追加到日志文件
    if [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "${log_format}" >> "$LOG_FILE"
    fi
}

log_info()    { _log "INFO"    "$COLOR_INFO"    "$1"; }
log_success() { _log "OK"      "$COLOR_SUCCESS" "$1"; }
log_warn()    { _log "WARN"    "$COLOR_WARN"    "$1"; }
log_error()   { _log "ERROR"   "$COLOR_ERROR"   "$1"; }

# ------------------------------------------------------------------
# 3b. JSON 结构化输出（用于机器可读集成）
# -----------------------------------------------------------------
# 转义 JSON 字符串中的特殊字符
_json_escape() {
    local val="$1"
    val="${val//\\/\\\\}"   # \ → \\
    val="${val//\"/\\\"}"   # " → \"
    val="${val//$'\n'/\\n}" # newline → \n
    val="${val//$'\r'/\\r}" # CR → \r
    val="${val//$'\t'/\\t}" # tab → \t
    printf '%s' "$val"
}

# 添加一条结构化记录到 JSON 输出缓冲区
# 用法: json_record "phase" "status" "detail" ["key=val" ...]
json_record() {
    local phase="$1"
    local status="$2"
    local detail="$3"
    shift 3 2>/dev/null || true

    local ts=""
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    # 构建额外字段
    local extras=""
    for kv in "$@"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        extras+=", \"${k}\": \"$(_json_escape "${v}")\""
    done

    local entry ts_esc phase_esc status_esc detail_esc
    ts_esc=$(_json_escape "$ts")
    phase_esc=$(_json_escape "$phase")
    status_esc=$(_json_escape "$status")
    detail_esc=$(_json_escape "$detail")
    entry="{\"timestamp\":\"${ts_esc}\",\"phase\":\"${phase_esc}\",\"status\":\"${status_esc}\",\"detail\":\"${detail_esc}\"${extras}}"
    JSON_ENTRIES+=("$entry")
}

# 输出完整的 JSON 报告并清空缓冲区
json_flush() {
    local host=""
    host="$(hostname 2>/dev/null || echo "unknown")"

    printf '{\n'
    printf '  "tool": "%s",\n' "$SCRIPT_NAME"
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "hostname": "%s",\n' "$host"
    printf '  "generated": "%s",\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '  "results": [\n'
    local first=true
    for entry in "${JSON_ENTRIES[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            printf ',\n'
        fi
        printf '    %s' "$entry"
    done
    printf '\n  ]\n}\n'
    JSON_ENTRIES=()
}

# --------------------------------------------------------------------
# 4. 异常捕获与环境清理
# -----------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [ ${#TMP_FILES[@]} -gt 0 ]; then
        log_info "执行环境清理，删除临时文件: ${TMP_FILES[*]}"
        rm -rf "${TMP_FILES[@]}"
    fi
    
    if [ $exit_code -ne 0 ]; then
        log_error "脚本执行异常中断，退出码: ${exit_code}"
    else
        log_info "脚本执行完毕。"
    fi
    exit "$exit_code"
}

# 捕获正常退出(EXIT)、Ctrl+C(SIGINT) 和 进程终止(SIGTERM) 信号
trap cleanup EXIT INT TERM

# 添加临时文件注册函数
register_tmp_file() {
    TMP_FILES+=("$1")
}

# -----------------------------------------------------------------
# 5. 通用执行器
# -----------------------------------------------------------------
# 用途：所有可能修改系统的命令，都必须通过 run_cmd 执行，以支持预览模式
# 安全模型：允许 && || 条件串联和 >& 重定向，拒绝命令分隔/替换/后台注入
run_cmd() {
    local cmd="$1"
    local desc="${2:-"执行命令"}"

    # 防御层 1：始终拒绝命令替换（纵深防御最高优先级）
    if [[ "$cmd" =~ \$\( || "$cmd" =~ \` ]]; then
        log_error "拒绝执行包含命令替换的危险载荷: ${cmd}"
        return 1
    fi

    # 防御层 2：拒绝独立的 ; & | 元字符，但显式放行 &&、||
    # 将合法的双字符操作符替换为占位空格，再检查残余危险字符
    local check="${cmd}"
    check="${check//&&/ }"
    check="${check//||/ }"
    if [[ "$check" =~ [\;\&\|] ]]; then
        log_error "拒绝执行包含危险元字符的命令: ${cmd}"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY-RUN] ${desc} -> 会被执行: $cmd"
    else
        log_info "${desc} -> 正在执行: $cmd"
        bash -c "$cmd"
    fi
}

# ------------------------------------------------------------------
# 6. 前置环境
# -----------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "当前操作需要 root 权限，请使用 sudo 或切换 root 执行。"
        exit 1
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "缺少关键依赖: ${cmd}。请先安装后再运行。"
        exit 1
    fi
}

# ------------------------------------------------------------------
# 7. 日志轮转清理
# -----------------------------------------------------------------
# 移除超过指定天数的旧日志文件，防止磁盘累积
# $1: 保留天数（默认 30）
cleanup_old_logs() {
    local retention_days="${1:-30}"
    local log_dir="/var/log"

    if [ ! -d "$log_dir" ] || [ ! -w "$log_dir" ]; then
        return 0
    fi

    local deleted=0
    while IFS= read -r -d '' old_log; do
        rm -f "$old_log"
        deleted=$((deleted + 1))
    done < <(find "$log_dir" -maxdepth 1 -name 'kn-guardian_*.log' -type f -mtime +"${retention_days}" -print0 2>/dev/null || true)

    if [ "$deleted" -gt 0 ]; then
        log_info "日志轮转: 清理了 ${deleted} 个超过 ${retention_days} 天的旧日志文件。"
    fi
}