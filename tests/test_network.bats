#!/usr/bin/env bats
# ====================================================================
# node-guardian: 网络库单元测试 (tests/test_network.bats)
# 测试 lib/network.sh 的 MTU 一致性审计与 Conntrack 连接跟踪分析
# ====================================================================

load test_helper

setup_network_test() {
    reload_core
    export MOCK_DIR="${TEST_TMP_DIR}/bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:${PATH}"
    export SYSFS_NET="${TEST_TMP_DIR}/sys/class/net"
    export PROCFS_NET="${TEST_TMP_DIR}/proc/sys/net"

    # shellcheck source=../lib/network.sh
    source "${BATS_TEST_DIRNAME}/../lib/network.sh"
}

# ==================================================================
# check_mtu_consistency 测试
# ==================================================================

@test "network: MTU 一致时全部 PASS" {
    setup_network_test

    cat > "${MOCK_DIR}/ip" <<'EOF'
#!/bin/bash
[ "$1" = "route" ] && echo "default via 10.0.0.1 dev eth0" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    mkdir -p "${SYSFS_NET}/eth0"
    echo "1500" > "${SYSFS_NET}/eth0/mtu"
    mkdir -p "${SYSFS_NET}/cali001"
    echo "1500" > "${SYSFS_NET}/cali001/mtu"

    run check_mtu_consistency
    [ "$status" -eq 0 ]
    assert_contains "$output" "[MTU OK]"
    ! grep -q 'MTU MISMATCH' <<< "$output" || false
}

@test "network: MTU 不一致时输出 MISMATCH 并计数" {
    setup_network_test

    cat > "${MOCK_DIR}/ip" <<'EOF'
#!/bin/bash
[ "$1" = "route" ] && echo "default via 10.0.0.1 dev eth0" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    mkdir -p "${SYSFS_NET}/eth0"
    echo "1500" > "${SYSFS_NET}/eth0/mtu"
    mkdir -p "${SYSFS_NET}/cali001"
    echo "1450" > "${SYSFS_NET}/cali001/mtu"

    run check_mtu_consistency
    [ "$status" -eq 0 ]
    assert_contains "$output" "MTU MISMATCH"
    assert_contains "$output" "1 处不一致"
}

@test "network: 无物理网卡时跳过 MTU 审计" {
    setup_network_test

    cat > "${MOCK_DIR}/ip" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    run check_mtu_consistency
    [ "$status" -eq 0 ]
    assert_contains "$output" "跳过 MTU 审计"
}

@test "network: VXLAN overlay 封装开销超标时告警" {
    setup_network_test

    cat > "${MOCK_DIR}/ip" <<'EOF'
#!/bin/bash
[ "$1" = "route" ] && echo "default via 10.0.0.1 dev eth0" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/ip"

    mkdir -p "${SYSFS_NET}/eth0"
    echo "1500" > "${SYSFS_NET}/eth0/mtu"
    mkdir -p "${SYSFS_NET}/cali001"
    echo "1500" > "${SYSFS_NET}/cali001/mtu"
    mkdir -p "${SYSFS_NET}/vxlan0"
    echo "1480" > "${SYSFS_NET}/vxlan0/mtu"

    run check_mtu_consistency
    [ "$status" -eq 0 ]
    assert_contains "$output" "MTU 封装风险"
    assert_contains "$output" "vxlan0"
}

# ==================================================================
# analyze_conntrack 测试
# ==================================================================

@test "network: Conntrack 正常使用率输出 OK" {
    setup_network_test

    mkdir -p "${PROCFS_NET}/netfilter"
    echo "400" > "${PROCFS_NET}/netfilter/nf_conntrack_count"
    echo "1000" > "${PROCFS_NET}/netfilter/nf_conntrack_max"

    cat > "${MOCK_DIR}/sysctl" <<'EOF'
#!/bin/bash
[ "$1" = "-n" ] && echo "1" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/sysctl"

    run analyze_conntrack
    [ "$status" -eq 0 ]
    assert_contains "$output" "正常范围"
}

@test "network: Conntrack 使用率 >= 85% 输出 WARNING" {
    setup_network_test

    mkdir -p "${PROCFS_NET}/netfilter"
    echo "870" > "${PROCFS_NET}/netfilter/nf_conntrack_count"
    echo "1000" > "${PROCFS_NET}/netfilter/nf_conntrack_max"

    cat > "${MOCK_DIR}/sysctl" <<'EOF'
#!/bin/bash
[ "$1" = "-n" ] && echo "1" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/sysctl"

    run analyze_conntrack 85
    [ "$status" -eq 0 ]
    assert_contains "$output" "处于高位"
}

@test "network: Conntrack 使用率 >= 95% 输出 CRITICAL" {
    setup_network_test

    mkdir -p "${PROCFS_NET}/netfilter"
    echo "960" > "${PROCFS_NET}/netfilter/nf_conntrack_count"
    echo "1000" > "${PROCFS_NET}/netfilter/nf_conntrack_max"

    cat > "${MOCK_DIR}/sysctl" <<'EOF'
#!/bin/bash
[ "$1" = "-n" ] && echo "1" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/sysctl"

    run analyze_conntrack 85
    [ "$status" -eq 0 ]
    assert_contains "$output" "CRITICAL"
}

@test "network: nf_conntrack_max = 0 时返回错误" {
    setup_network_test

    mkdir -p "${PROCFS_NET}/netfilter"
    echo "0" > "${PROCFS_NET}/netfilter/nf_conntrack_count"
    echo "0" > "${PROCFS_NET}/netfilter/nf_conntrack_max"

    run analyze_conntrack
    [ "$status" -eq 1 ]
    assert_contains "$output" "内核配置异常"
}

@test "network: Conntrack 模块未加载时跳过分析" {
    setup_network_test

    run analyze_conntrack
    [ "$status" -eq 0 ]
    assert_contains "$output" "Conntrack 模块未加载"
}

@test "network: tcp_tw_reuse=0 时输出 TIME_WAIT 警告" {
    setup_network_test

    mkdir -p "${PROCFS_NET}/netfilter"
    echo "500" > "${PROCFS_NET}/netfilter/nf_conntrack_count"
    echo "1000" > "${PROCFS_NET}/netfilter/nf_conntrack_max"

    cat > "${MOCK_DIR}/sysctl" <<'EOF'
#!/bin/bash
[ "$1" = "-n" ] && [ "$2" = "net.ipv4.tcp_tw_reuse" ] && echo "0" && exit 0
[ "$1" = "-n" ] && echo "1" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/sysctl"

    run analyze_conntrack 85
    [ "$status" -eq 0 ]
    assert_contains "$output" "TIME_WAIT"
}

@test "network: conntrack 命令可用时统计 Top 来源 IP" {
    setup_network_test

    mkdir -p "${PROCFS_NET}/netfilter"
    echo "500" > "${PROCFS_NET}/netfilter/nf_conntrack_count"
    echo "1000" > "${PROCFS_NET}/netfilter/nf_conntrack_max"

    cat > "${MOCK_DIR}/sysctl" <<'EOF'
#!/bin/bash
[ "$1" = "-n" ] && echo "1" && exit 0
exit 0
EOF
    chmod +x "${MOCK_DIR}/sysctl"

    cat > "${MOCK_DIR}/conntrack" <<'EOF'
#!/bin/bash
echo "tcp src=10.0.0.1 dst=10.0.0.2"
echo "tcp src=10.0.0.1 dst=10.0.0.3"
echo "udp src=10.0.0.5 dst=10.0.0.6"
EOF
    chmod +x "${MOCK_DIR}/conntrack"

    run analyze_conntrack 85
    [ "$status" -eq 0 ]
    assert_contains "$output" "Top 5 连接来源 IP"
}
