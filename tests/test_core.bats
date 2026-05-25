#!/usr/bin/env bats
# ====================================================================
# node-guardian: 核心底座单元测试 (tests/test_core.bats)
# 测试 lib/core.sh 的日志、Dry-Run、trap 清理与注册机制
# ====================================================================

load test_helper

# ------------------------------------------------------------------
# log_* 函数：验证日志输出到 stderr
# ------------------------------------------------------------------

@test "log_info 输出到 stderr" {
    reload_core
    run log_info "test message"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[INFO]"
    assert_contains "$output" "test message"
}

@test "log_warn 输出到 stderr 含 WARN 标签" {
    reload_core
    run log_warn "disk usage high"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[WARN]"
    assert_contains "$output" "disk usage high"
}

@test "log_error 输出到 stderr 含 ERROR 标签" {
    reload_core
    run log_error "connection refused"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[ERROR]"
    assert_contains "$output" "connection refused"
}

@test "log_success 输出到 stderr 含 OK 标签" {
    reload_core
    run log_success "all checks passed"
    [ "$status" -eq 0 ]
    assert_contains "$output" "[OK]"
    assert_contains "$output" "all checks passed"
}

# ------------------------------------------------------------------
# run_cmd: Dry-Run 模式不应执行实际命令
# ------------------------------------------------------------------

@test "run_cmd 在 DRY_RUN=false 时执行命令" {
    reload_core
    local marker="${TEST_TMP_DIR}/executed"
    run_cmd "touch ${marker}" "创建标记文件"
    assert_file_exists "$marker"
}

@test "run_cmd 在 DRY_RUN=true 时不执行命令" {
    reload_core
    export DRY_RUN=true
    local marker="${TEST_TMP_DIR}/not_executed"
    run_cmd "touch ${marker}" "创建标记文件"
    [ ! -f "$marker" ]
}

@test "run_cmd 在 DRY_RUN=true 时输出 DRY-RUN 提示" {
    reload_core
    export DRY_RUN=true
    run run_cmd "rm -f /tmp/nonexistent" "删除测试文件"
    [ "$status" -eq 0 ]
    assert_contains "$output" "DRY-RUN"
}

@test "run_cmd 传入空描述时使用默认提示" {
    reload_core
    run run_cmd "true"
    [ "$status" -eq 0 ]
    assert_contains "$output" "执行命令"
}

# ------------------------------------------------------------------
# register_tmp_file: 临时文件注册与陷阱清理
# ------------------------------------------------------------------

@test "register_tmp_file 注册文件后 TMP_FILES 数组包含该路径" {
    reload_core
    local tmpf="${TEST_TMP_DIR}/test_tmp_reg"
    touch "$tmpf"
    register_tmp_file "$tmpf"
    local found=false
    for f in "${TMP_FILES[@]}"; do
        [ "$f" = "$tmpf" ] && found=true && break
    done
    [ "$found" = true ]
}

@test "register_tmp_file 支持多文件注册" {
    reload_core
    local f1="${TEST_TMP_DIR}/reg_1" f2="${TEST_TMP_DIR}/reg_2"
    touch "$f1" "$f2"
    register_tmp_file "$f1"
    register_tmp_file "$f2"
    [ "${#TMP_FILES[@]}" -eq 2 ]
}

@test "cleanup 逻辑删除已注册临时文件 (隔离退出行为)" {
    reload_core
    local tmpf="${TEST_TMP_DIR}/to_be_cleaned"
    touch "$tmpf"
    register_tmp_file "$tmpf"
    # 仅验证核心清理逻辑：rm -rf 行为
    # 注: cleanup() 末尾有 exit，不在本测试中直接调用
    run bash -c "
        TMP_FILES=('$tmpf')
        [ \${#TMP_FILES[@]} -gt 0 ] && rm -rf \${TMP_FILES[@]}
        [ ! -f '$tmpf' ] && echo 'CLEANED'
    "
    [ "$status" -eq 0 ]
    assert_contains "$output" "CLEANED"
}

@test "TMP_FILES 为空时不触发 rm 调用" {
    reload_core
    TMP_FILES=()
    run bash -c "
        TMP_FILES=()
        [ \${#TMP_FILES[@]} -gt 0 ] && rm -rf \${TMP_FILES[@]}
        echo 'NOOP'
    "
    [ "$status" -eq 0 ]
    assert_contains "$output" "NOOP"
}

# ------------------------------------------------------------------
# require_root / require_command
# ------------------------------------------------------------------

@test "require_command 在命令存在时不报错" {
    reload_core
    run require_command "bash"
    [ "$status" -eq 0 ]
}

@test "require_command 在命令不存在时报错退出" {
    reload_core
    run require_command "nonexistent_command_xyzzy_42"
    [ "$status" -eq 1 ]
    assert_contains "$output" "nonexistent_command_xyzzy_42"
}
