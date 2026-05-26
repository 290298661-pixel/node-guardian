#!/usr/bin/env bats
# ====================================================================
# node-guardian: kn-security 单元测试 (tests/test_security.bats)
# 测试安全审计的三个阶段：kubelet 审计、端口扫描、安全服务检查
# ====================================================================

load test_helper

setup_security_test() {
    reload_core
    export MOCK_DIR="${TEST_TMP_DIR}/bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:${PATH}"

    # mock hostname
    cat > "${MOCK_DIR}/hostname" <<'EOF'
#!/bin/bash
echo "test-node"
EOF
    chmod +x "${MOCK_DIR}/hostname"

    # mock kubelet binary
    cat > "${MOCK_DIR}/kubelet" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/kubelet"

    # mock grep for kubelet config checks
    cat > "${MOCK_DIR}/grep" <<'EOF'
#!/bin/bash
echo "false"
EOF
    chmod +x "${MOCK_DIR}/grep"

    # Default: no risk ports listening
    cat > "${MOCK_DIR}/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/ss"

    # Default: auditd active and enabled
    cat > "${MOCK_DIR}/systemctl" <<'EOF'
#!/bin/bash
case "$2" in
    is-active) exit 0 ;;
    is-enabled) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${MOCK_DIR}/systemctl"

    # CIS config for tests
    export CIS_TEST_CONFIG="${TEST_TMP_DIR}/cis_test.cfg"

    # Source the security tool partially — parse_cis_rules is a function inside it.
    # We test functions by calling them directly after sourcing.
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    source "${SCRIPT_DIR}/../lib/sysctl.sh" 2>/dev/null || true
}

# ==================================================================
# parse_cis_rules 测试
# ==================================================================

@test "security: parse_cis_rules 正确解析 KUBELET_CHECK 规则" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
KUBELET_CHECK_anonymous-auth=false
KUBELET_CHECK_read-only-port=0
EOF

    # reload after setting config
    unset -f parse_cis_rules
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    source "${SCRIPT_DIR}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run parse_cis_rules "$CIS_TEST_CONFIG" "KUBELET_CHECK_"
    [ "$status" -eq 0 ]
    assert_contains "$output" "anonymous-auth=false"
    assert_contains "$output" "read-only-port=0"
}

@test "security: parse_cis_rules 解析 RISK_PORT 规则" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
RISK_PORT=21:TCP:FTP
RISK_PORT=23:TCP:Telnet
EOF

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run parse_cis_rules "$CIS_TEST_CONFIG" "RISK_PORT"
    [ "$status" -eq 0 ]
    assert_contains "$output" "21:TCP:FTP"
    assert_contains "$output" "23:TCP:Telnet"
}

@test "security: parse_cis_rules 解析 REQUIRED_SERVICE 规则" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
REQUIRED_SERVICE=auditd
REQUIRED_SERVICE=ufw
EOF

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run parse_cis_rules "$CIS_TEST_CONFIG" "REQUIRED_SERVICE"
    [ "$status" -eq 0 ]
    assert_contains "$output" "auditd"
    assert_contains "$output" "ufw"
}

@test "security: parse_cis_rules 配置文件不存在时报错" {
    setup_security_test

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run parse_cis_rules "/nonexistent/file.cfg" "KUBELET_CHECK_"
    [ "$status" -eq 1 ]
    assert_contains "$output" "不存在"
}

# ==================================================================
# Phase 2: 高危端口扫描测试
# ==================================================================

@test "security: 风险端口未监听时 PASS" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
RISK_PORT=21:TCP:FTP
RISK_PORT=3306:TCP:MySQL
EOF

    cat > "${MOCK_DIR}/ss" <<'EOF'
#!/bin/bash
# no ports listening
exit 0
EOF
    chmod +x "${MOCK_DIR}/ss"

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run scan_risk_ports
    [ "$status" -eq 0 ]
    assert_contains "$output" "PASS"
}

@test "security: 风险端口在监听时 FAIL" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
RISK_PORT=21:TCP:FTP
EOF

    cat > "${MOCK_DIR}/ss" <<'EOF'
#!/bin/bash
echo "LISTEN 0 5 0.0.0.0:21 0.0.0.0:* users:(("vsftpd",pid=1001,fd=3))"
EOF
    chmod +x "${MOCK_DIR}/ss"

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run scan_risk_ports
    [ "$status" -eq 0 ]
    assert_contains "$output" "FAIL"
}

@test "security: 空端口规则时跳过扫描" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
# no risk ports
EOF

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run scan_risk_ports
    [ "$status" -eq 0 ]
    assert_contains "$output" "跳过"
}

# ==================================================================
# Phase 3: 安全服务状态检查测试
# ==================================================================

@test "security: 安全服务运行中且开机自启 PASS" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
REQUIRED_SERVICE=auditd
EOF

    cat > "${MOCK_DIR}/systemctl" <<'EOF'
#!/bin/bash
case "$2" in
    is-active) exit 0 ;;
    is-enabled) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${MOCK_DIR}/systemctl"

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run check_security_services
    [ "$status" -eq 0 ]
    assert_contains "$output" "PASS"
}

@test "security: 安全服务未运行时 FAIL" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
REQUIRED_SERVICE=auditd
EOF

    cat > "${MOCK_DIR}/systemctl" <<'EOF'
#!/bin/bash
case "$2" in
    is-active) exit 1 ;;
    is-enabled) exit 1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${MOCK_DIR}/systemctl"

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run check_security_services
    [ "$status" -eq 0 ]
    assert_contains "$output" "FAIL"
}

@test "security: 安全服务运行但未设为开机自启 WARN" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
REQUIRED_SERVICE=auditd
EOF

    cat > "${MOCK_DIR}/systemctl" <<'EOF'
#!/bin/bash
case "$2" in
    is-active) exit 0 ;;
    is-enabled) exit 1 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${MOCK_DIR}/systemctl"

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run check_security_services
    [ "$status" -eq 0 ]
    assert_contains "$output" "WARN"
}

@test "security: 空服务规则时跳过检查" {
    setup_security_test

    cat > "$CIS_TEST_CONFIG" <<'EOF'
# no services
EOF

    reload_core
    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
    CIS_CONFIG="$CIS_TEST_CONFIG"
    export CIS_CONFIG
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-security" 2>/dev/null || true
    unset -f main

    run check_security_services
    [ "$status" -eq 0 ]
    assert_contains "$output" "跳过"
}

# ==================================================================
# CLI 参数测试
# ==================================================================

@test "security: --help 输出用法并退出 0" {
    run "${BATS_TEST_DIRNAME}/../bin/kn-security" --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "用法"
}

@test "security: --version 输出版本并退出 0" {
    run "${BATS_TEST_DIRNAME}/../bin/kn-security" --version
    [ "$status" -eq 0 ]
    assert_contains "$output" "kn-security v"
}

@test "security: 未知参数报错退出" {
    run "${BATS_TEST_DIRNAME}/../bin/kn-security" --bogus-flag
    [ "$status" -eq 1 ]
    assert_contains "$output" "未知参数"
}
