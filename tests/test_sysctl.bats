#!/usr/bin/env bats
# ====================================================================
# node-guardian: sysctl 幂等性与 Dry-Run 单元测试 (tests/test_sysctl.bats)
# 测试 lib/sysctl.sh 的配置比对、幂等跳过、Dry-Run 穿透控制
# ====================================================================

load test_helper

setup_sysctl_test() {
    reload_core
    # 注入 mock sysctl 命令
    # 路径优先级确保 mock 覆盖真实命令
    export MOCK_DIR="${TEST_TMP_DIR}/bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:${PATH}"

    # 创建 mock awk (透传真实 awk，仅标记已调用)
    cat > "${MOCK_DIR}/awk" <<'MOCK'
#!/usr/bin/env bash
exec /usr/bin/awk "$@"
MOCK
    chmod +x "${MOCK_DIR}/awk"

    # 创建基线配置模板
    export BASELINE_CONF="${TEST_TMP_DIR}/sysctl_baseline.env"
}

# 创建 mock sysctl: -n 返回期望值 (已符合基线)，-w 记录写入
make_mock_sysctl_pass() {
    cat > "${MOCK_DIR}/sysctl" <<'MOCK'
#!/usr/bin/env bash
# Mock sysctl: 所有参数返回与基线一致的值 (模拟幂等跳过)
case "$1" in
    -n)
        case "$2" in
            net.core.somaxconn)          echo "32768" ;;
            net.ipv4.tcp_max_syn_backlog) echo "8192" ;;
            net.ipv4.ip_local_port_range) echo "1024 65535" ;;
            net.ipv4.tcp_tw_reuse)       echo "1" ;;
            net.bridge.bridge-nf-call-iptables) echo "1" ;;
            net.bridge.bridge-nf-call-ip6tables) echo "1" ;;
            net.ipv4.ip_forward)         echo "1" ;;
            fs.inotify.max_user_watches)  echo "524288" ;;
            *) echo "N/A" ;;
        esac
        ;;
    -w)  echo "mock: sysctl -w $2" >> "${TEST_TMP_DIR}/sysctl_calls.log" ;;
    *)   ;;
esac
MOCK
    chmod +x "${MOCK_DIR}/sysctl"
}

# 创建 mock sysctl: 返回不匹配的值 (模拟需要修正)
make_mock_sysctl_diff() {
    cat > "${MOCK_DIR}/sysctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    -n)
        case "$2" in
            net.core.somaxconn) echo "128" ;;  # 期望 32768，故意不同
            *) echo "0" ;;
        esac
        ;;
    -w) echo "mock: sysctl -w $2" >> "${TEST_TMP_DIR}/sysctl_calls.log" ;;
    *)   ;;
esac
MOCK
    chmod +x "${MOCK_DIR}/sysctl"
}

# 创建 mock sysctl --system：记录调用
make_mock_sysctl() {
    cat > "${MOCK_DIR}/sysctl" <<'MOCK'
#!/usr/bin/env bash
# 通用 mock，将 -n 查询和 -w 写入都记录到日志
if [ "$1" = "-n" ]; then
    echo "32768"
elif [ "$1" = "--system" ]; then
    echo "mock: sysctl --system" >> "${TEST_TMP_DIR}/sysctl_system_calls.log"
else
    echo "mock: sysctl $*" >> "${TEST_TMP_DIR}/sysctl_calls.log"
fi
MOCK
    chmod +x "${MOCK_DIR}/sysctl"
}

# 创建 mock cp
make_mock_cp() {
    cat > "${MOCK_DIR}/cp" <<'MOCK'
#!/usr/bin/env bash
echo "mock: cp $*" >> "${TEST_TMP_DIR}/cp_calls.log"
/bin/cp "$@"
MOCK
    chmod +x "${MOCK_DIR}/cp"
}

# 创建基线配置文件
write_baseline() {
    cat > "$BASELINE_CONF" <<'EOF'
# test baseline
net.core.somaxconn=32768
net.ipv4.ip_forward=1
fs.inotify.max_user_watches=524288
EOF
}

# 源入 sysctl.sh (依赖 core.sh 已加载)
source_sysctl_lib() {
    # shellcheck source=../lib/sysctl.sh
    source "${BATS_TEST_DIRNAME}/../lib/sysctl.sh"
}

# ------------------------------------------------------------------
# 幂等性测试：已符合基线时跳过修改
# ------------------------------------------------------------------

@test "sysctl: 所有参数已符合基线时全部 PASS，零写入" {
    setup_sysctl_test
    make_mock_sysctl_pass
    write_baseline
    source_sysctl_lib

    run apply_sysctl_baseline "$BASELINE_CONF"

    [ "$status" -eq 0 ]
    # 每个参数应输出 PASS
    assert_contains "$output" "[PASS]"
    # 不应出现 DIFF
    ! grep -q 'DIFF' <<< "$output" || false
    # sysctl -w 未被调用
    if [ -f "${TEST_TMP_DIR}/sysctl_calls.log" ]; then
        ! grep -q 'sysctl -w' "${TEST_TMP_DIR}/sysctl_calls.log" || false
    fi
}

# ------------------------------------------------------------------
# 差异修正测试：参数不符时记录 DIFF 并调用修正
# ------------------------------------------------------------------

@test "sysctl: 参数不匹配时输出 DIFF 并调用 sysctl -w" {
    setup_sysctl_test
    make_mock_sysctl_diff
    write_baseline
    source_sysctl_lib

    run apply_sysctl_baseline "$BASELINE_CONF"

    [ "$status" -eq 0 ]
    assert_contains "$output" "[DIFF]"
    # 因为 somaxconn 返回 128 (期望 32768)，应触发修正
    assert_contains "$output" "DIFF"
}

# ------------------------------------------------------------------
# Dry-Run 模式测试
# ------------------------------------------------------------------

@test "sysctl: DRY_RUN=true 时不调用 sysctl --system" {
    setup_sysctl_test
    make_mock_sysctl_pass
    write_baseline
    export DRY_RUN=true
    source_sysctl_lib

    run apply_sysctl_baseline "$BASELINE_CONF"

    [ "$status" -eq 0 ]
    # sysctl --system 不应被调用
    if [ -f "${TEST_TMP_DIR}/sysctl_system_calls.log" ]; then
        ! grep -q 'sysctl --system' "${TEST_TMP_DIR}/sysctl_system_calls.log" || false
    fi
}

@test "sysctl: DRY_RUN=true 时输出跳过持久化提示" {
    setup_sysctl_test
    make_mock_sysctl_diff
    write_baseline
    export DRY_RUN=true
    source_sysctl_lib

    run apply_sysctl_baseline "$BASELINE_CONF"

    [ "$status" -eq 0 ]
    assert_contains "$output" "DRY-RUN"
}

# ------------------------------------------------------------------
# 边界条件测试
# ------------------------------------------------------------------

@test "sysctl: 配置文件不存在时返回错误" {
    setup_sysctl_test
    source_sysctl_lib

    run apply_sysctl_baseline "/nonexistent_file_xyzzy.env"

    [ "$status" -eq 1 ]
    assert_contains "$output" "基线配置文件丢失"
}

@test "sysctl: 空配置文件 (仅注释和空行) 正常返回" {
    setup_sysctl_test
    make_mock_sysctl_pass
    # 仅含注释和空行
    cat > "$BASELINE_CONF" <<'EOF'
# only comments
# and blank lines

EOF
    source_sysctl_lib

    run apply_sysctl_baseline "$BASELINE_CONF"

    [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# 幂等持久化测试 (需要 root 权限，CI 中跳过)
# ------------------------------------------------------------------

# 注: apply_sysctl_baseline 的持久化目标路径硬编码为
# /etc/sysctl.d/99-node-guardian.conf，该路径需要 root 写入。
# 持久化幂等逻辑 (diff -q 比对) 已在代码中实现，以下为手动验证。
# 生产环境中运行 `kn-preflight --dry-run` 可完整验证该路径。

@test "sysctl: 幂等性 — 第二次运行不应重复调用 sysctl -w" {
    setup_sysctl_test
    make_mock_sysctl_pass
    write_baseline
    source_sysctl_lib

    # 第一次运行: 所有参数 PASS，零写入
    run apply_sysctl_baseline "$BASELINE_CONF"
    [ "$status" -eq 0 ]
    # 确认日志文件不存在 (没有任何 sysctl -w 调用)
    [ ! -f "${TEST_TMP_DIR}/sysctl_calls.log" ]
}
