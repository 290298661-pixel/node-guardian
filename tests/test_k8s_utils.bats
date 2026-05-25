#!/usr/bin/env bats
# ====================================================================
# node-guardian: K8s 工具库单元测试 (tests/test_k8s_utils.bats)
# 测试 lib/k8s-utils.sh 的容器运行时检测、Pod 溯源与日志提取
# ====================================================================

load test_helper

setup_k8s_test() {
    reload_core
    export MOCK_DIR="${TEST_TMP_DIR}/bin"
    mkdir -p "$MOCK_DIR"
    export PATH="${MOCK_DIR}:${PATH}"
    export PROCFS="${TEST_TMP_DIR}/proc"

    # shellcheck source=../lib/k8s-utils.sh
    source "${BATS_TEST_DIRNAME}/../lib/k8s-utils.sh"
}

# ==================================================================
# detect_container_runtime 测试
# ==================================================================

@test "k8s-utils: containerd 运行 + systemd cgroup 驱动" {
    setup_k8s_test

    cat > "${MOCK_DIR}/containerd" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/containerd"

    cat > "${MOCK_DIR}/pgrep" <<'EOF'
#!/bin/bash
[ "$1" = "-x" ] && [ "$2" = "containerd" ] && exit 0
exit 1
EOF
    chmod +x "${MOCK_DIR}/pgrep"

    export CONTAINERD_CONFIG="${TEST_TMP_DIR}/config.toml"
    echo "SystemdCgroup = true" > "$CONTAINERD_CONFIG"

    run detect_container_runtime
    [ "$status" -eq 0 ]
    assert_contains "$output" "containerd:systemd"
}

@test "k8s-utils: 无容器运行时进程时报错退出" {
    setup_k8s_test

    cat > "${MOCK_DIR}/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "${MOCK_DIR}/pgrep"

    run detect_container_runtime
    [ "$status" -eq 1 ]
    assert_contains "$output" "未检测到运行中的容器运行时"
}

@test "k8s-utils: 运行时与 kubelet cgroup 驱动不一致时告警" {
    setup_k8s_test

    cat > "${MOCK_DIR}/containerd" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/containerd"

    cat > "${MOCK_DIR}/kubelet" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/kubelet"

    cat > "${MOCK_DIR}/pgrep" <<'EOF'
#!/bin/bash
[ "$1" = "-x" ] && [ "$2" = "containerd" ] && exit 0
exit 1
EOF
    chmod +x "${MOCK_DIR}/pgrep"

    cat > "${MOCK_DIR}/ps" <<'EOF'
#!/bin/bash
if [[ "$*" =~ "aux" ]]; then
    echo "root 456 kubelet --cgroup-driver=cgroupfs"
fi
EOF
    chmod +x "${MOCK_DIR}/ps"

    export CONTAINERD_CONFIG="${TEST_TMP_DIR}/config.toml"
    echo "SystemdCgroup = true" > "$CONTAINERD_CONFIG"

    run detect_container_runtime
    [ "$status" -eq 0 ]
    assert_contains "$output" "Cgroup 驱动不一致"
}

@test "k8s-utils: containerd 使用 cgroupfs 驱动" {
    setup_k8s_test

    cat > "${MOCK_DIR}/containerd" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${MOCK_DIR}/containerd"

    cat > "${MOCK_DIR}/pgrep" <<'EOF'
#!/bin/bash
[ "$1" = "-x" ] && [ "$2" = "containerd" ] && exit 0
exit 1
EOF
    chmod +x "${MOCK_DIR}/pgrep"

    export CONTAINERD_CONFIG="${TEST_TMP_DIR}/config.toml"
    echo "SystemdCgroup = false" > "$CONTAINERD_CONFIG"

    run detect_container_runtime
    [ "$status" -eq 0 ]
    assert_contains "$output" "containerd:cgroupfs"
}

# ==================================================================
# find_pod_by_pid 测试
# ==================================================================

@test "k8s-utils: PID 不存在时返回错误" {
    setup_k8s_test

    run find_pod_by_pid "99999"
    [ "$status" -eq 1 ]
    assert_contains "$output" "不存在或已退出"
}

@test "k8s-utils: cgroup 不含容器 ID 时返回警告" {
    setup_k8s_test

    mkdir -p "${PROCFS}/1234"
    echo "0::/system.slice/containerd.service" > "${PROCFS}/1234/cgroup"

    run find_pod_by_pid "1234"
    [ "$status" -eq 1 ]
    assert_contains "$output" "未运行在容器中"
}

@test "k8s-utils: 缺少 crictl 时优雅降级输出容器 ID" {
    setup_k8s_test

    mkdir -p "${PROCFS}/1234"
    echo "0::/system.slice/containerd.service/abc123def4567890abcdef1234567890abcdef1234567890abcdef1234567890" \
        > "${PROCFS}/1234/cgroup"

    run find_pod_by_pid "1234"
    [ "$status" -eq 0 ]
    assert_contains "$output" "pid=1234"
    assert_contains "$output" "container_id=abc123def4567890abcdef1234567890abcdef1234567890abcdef1234567890"
    assert_contains "$output" "未安装 crictl"
}

@test "k8s-utils: crictl 可用时完整溯源输出 namespace/pod_name" {
    setup_k8s_test

    mkdir -p "${PROCFS}/1234"
    echo "0::/system.slice/containerd.service/abc123def4567890abcdef1234567890abcdef1234567890abcdef1234567890" \
        > "${PROCFS}/1234/cgroup"

    cat > "${MOCK_DIR}/crictl" <<'EOF'
#!/bin/bash
case "$1" in
    inspect)
        echo '{"podSandboxId": "pod-xyz-abc-789"}'
        ;;
    inspectp)
        echo '{"name": "nginx-deployment-abc", "namespace": "production"}'
        ;;
esac
EOF
    chmod +x "${MOCK_DIR}/crictl"

    run find_pod_by_pid "1234"
    [ "$status" -eq 0 ]
    assert_contains "$output" "production/nginx-deployment-abc"
}

# ==================================================================
# extract_critical_logs 测试
# ==================================================================

@test "k8s-utils: journalctl 有匹配日志时提取成功" {
    setup_k8s_test

    cat > "${MOCK_DIR}/journalctl" <<'EOF'
#!/bin/bash
echo "May 24 10:15:30 node1 kubelet[123]: E0524 error: connection timeout"
EOF
    chmod +x "${MOCK_DIR}/journalctl"

    run extract_critical_logs 15
    [ "$status" -eq 0 ]
    assert_contains "$output" "connection timeout"
}

@test "k8s-utils: journalctl 无匹配日志时提示无记录" {
    setup_k8s_test

    cat > "${MOCK_DIR}/journalctl" <<'EOF'
#!/bin/bash
echo "May 24 10:15:30 node1 kubelet[123]: I0524 info: starting sync loop"
EOF
    chmod +x "${MOCK_DIR}/journalctl"

    run extract_critical_logs 15
    [ "$status" -eq 0 ]
    assert_contains "$output" "无匹配记录"
}

@test "k8s-utils: 日志提取完成标志输出" {
    setup_k8s_test

    cat > "${MOCK_DIR}/journalctl" <<'EOF'
#!/bin/bash
echo "May 24 10:15:30 node1 systemd[1]: Started kubelet."
EOF
    chmod +x "${MOCK_DIR}/journalctl"

    run extract_critical_logs 15
    [ "$status" -eq 0 ]
    assert_contains "$output" "关键日志提取完成"
}
