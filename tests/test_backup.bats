#!/usr/bin/env bats
# ====================================================================
# node-guardian: kn-backup 单元测试 (tests/test_backup.bats)
# 测试灾备快照的创建、文件备份、大小上限、排除规则与完整性验证
# ====================================================================

load test_helper

setup_backup_test() {
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

    # mock date to return deterministic timestamp
    cat > "${MOCK_DIR}/date" <<'EOF'
#!/bin/bash
echo "20260101_120000"
EOF
    chmod +x "${MOCK_DIR}/date"

    # mock sha256sum
    cat > "${MOCK_DIR}/sha256sum" <<'EOF'
#!/bin/bash
echo "abc123def456"
EOF
    chmod +x "${MOCK_DIR}/sha256sum"

    # mock du
    cat > "${MOCK_DIR}/du" <<'EOF'
#!/bin/bash
echo "567  /some/path"
EOF
    chmod +x "${MOCK_DIR}/du"

    # mock tar
    cat > "${MOCK_DIR}/tar" <<'EOF'
#!/bin/bash
touch "${@: -1}"  # touch the output file
exit 0
EOF
    chmod +x "${MOCK_DIR}/tar"

    # mock mkdir
    cat > "${MOCK_DIR}/mkdir" <<'EOF'
#!/bin/bash
# passthrough
/bin/mkdir "$@"
EOF
    chmod +x "${MOCK_DIR}/mkdir"

    # mock cp
    cat > "${MOCK_DIR}/cp" <<'EOF'
#!/bin/bash
/bin/cp "$@"
EOF
    chmod +x "${MOCK_DIR}/cp"

    # mock rm
    cat > "${MOCK_DIR}/rm" <<'EOF'
#!/bin/bash
/bin/rm "$@"
EOF
    chmod +x "${MOCK_DIR}/rm"

    # backup targets config
    export BACKUP_TEST_CONF="${TEST_TMP_DIR}/backup_test.conf"
    export OUTPUT_DIR="${TEST_TMP_DIR}/output"

    export SCRIPT_DIR="${BATS_TEST_DIRNAME}/../bin"
    export CONFIG_DIR="${TEST_TMP_DIR}"
}

# ==================================================================
# backup_target 测试
# ==================================================================

@test "backup: 备份存在的文件成功" {
    setup_backup_test

    local test_file="${TEST_TMP_DIR}/test.txt"
    echo "hello" > "$test_file"

    local dest_dir="${TEST_TMP_DIR}/snapshot"
    /bin/mkdir -p "$dest_dir"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run backup_target "test-file" "$test_file" "file" "$dest_dir"
    [ "$status" -eq 0 ]
    assert_contains "$output" "OK"
    [ -f "${dest_dir}/test-file" ]
}

@test "backup: 备份不存在的路径跳过" {
    setup_backup_test

    local dest_dir="${TEST_TMP_DIR}/snapshot"
    /bin/mkdir -p "$dest_dir"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run backup_target "missing" "/nonexistent/path" "file" "$dest_dir"
    [ "$status" -eq 0 ]
    assert_contains "$output" "SKIP"
}

@test "backup: 备份目录成功" {
    setup_backup_test

    local test_dir="${TEST_TMP_DIR}/src-dir"
    /bin/mkdir -p "$test_dir"
    echo "content" > "${test_dir}/data.txt"

    local dest_dir="${TEST_TMP_DIR}/snapshot"
    /bin/mkdir -p "$dest_dir"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run backup_target "test-dir" "$test_dir" "dir" "$dest_dir"
    [ "$status" -eq 0 ]
    assert_contains "$output" "OK"
    [ -d "${dest_dir}/test-dir" ]
}

@test "backup: 超出大小上限的文件跳过" {
    setup_backup_test

    local test_file="${TEST_TMP_DIR}/big.bin"
    dd if=/dev/zero of="$test_file" bs=1K count=5 2>/dev/null

    local dest_dir="${TEST_TMP_DIR}/snapshot"
    /bin/mkdir -p "$dest_dir"

    # Mock du to report 6M (over 1M limit)
    cat > "${MOCK_DIR}/du" <<'EOF'
#!/bin/bash
echo "6144  /some/path"
EOF
    chmod +x "${MOCK_DIR}/du"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run backup_target "big-file" "$test_file" "file" "$dest_dir" "" "1"
    [ "$status" -eq 0 ]
    assert_contains "$output" "SKIP"
    assert_contains "$output" "超出上限"
}

@test "backup: 未知类型报错" {
    setup_backup_test

    local test_file="${TEST_TMP_DIR}/test.txt"
    echo "hello" > "$test_file"
    local dest_dir="${TEST_TMP_DIR}/snapshot"
    /bin/mkdir -p "$dest_dir"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run backup_target "bad-type" "$test_file" "unknown" "$dest_dir"
    [ "$status" -eq 1 ]
    assert_contains "$output" "未知类型"
}

@test "backup: DRY_RUN 模式不实际复制" {
    setup_backup_test

    export DRY_RUN=true
    local test_file="${TEST_TMP_DIR}/test.txt"
    echo "hello" > "$test_file"
    local dest_dir="${TEST_TMP_DIR}/snapshot"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run backup_target "test-file" "$test_file" "file" "$dest_dir"
    [ "$status" -eq 0 ]
    assert_contains "$output" "DRY-RUN"
    [ ! -d "$dest_dir" ]
}

# ==================================================================
# create_snapshot 测试
# ==================================================================

@test "backup: create_snapshot 完整流程" {
    setup_backup_test

    local test_file="${TEST_TMP_DIR}/my-config.yaml"
    echo "key: value" > "$test_file"

    cat > "$BACKUP_TEST_CONF" <<EOF
my-config|${test_file}|file
EOF

    /bin/mkdir -p "$OUTPUT_DIR"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run create_snapshot "$BACKUP_TEST_CONF" "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    assert_contains "$output" "归档"
}

@test "backup: create_snapshot 缺失目标清单时失败" {
    setup_backup_test

    /bin/mkdir -p "$OUTPUT_DIR"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run create_snapshot "/nonexistent.conf" "$OUTPUT_DIR"
    [ "$status" -eq 1 ]
    assert_contains "$output" "丢失"
}

@test "backup: create_snapshot DRY_RUN 模式" {
    setup_backup_test

    export DRY_RUN=true
    local test_file="${TEST_TMP_DIR}/config.txt"
    echo "data" > "$test_file"

    cat > "$BACKUP_TEST_CONF" <<EOF
my-config|${test_file}|file
EOF

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run create_snapshot "$BACKUP_TEST_CONF" "$OUTPUT_DIR"
    [ "$status" -eq 0 ]
    assert_contains "$output" "DRY-RUN"
}

# ==================================================================
# verify_archive 测试
# ==================================================================

@test "backup: 归档不存在报错" {
    setup_backup_test

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run verify_archive "/nonexistent/backup.tar.gz"
    [ "$status" -eq 1 ]
    assert_contains "$output" "不存在"
}

@test "backup: SHA256 校验文件缺失时告警" {
    setup_backup_test

    local archive="${TEST_TMP_DIR}/backup.tar.gz"
    echo "data" > "$archive"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run verify_archive "$archive"
    [ "$status" -eq 1 ]
    assert_contains "$output" "未找到校验文件"
}

@test "backup: SHA256 匹配时验证通过" {
    setup_backup_test

    local archive="${TEST_TMP_DIR}/backup.tar.gz"
    echo "data" > "$archive"

    # mock sha256sum to always return the expected value
    cat > "${MOCK_DIR}/sha256sum" <<'EOF'
#!/bin/bash
echo "abc123"
EOF
    chmod +x "${MOCK_DIR}/sha256sum"

    local checksum_file="${archive}.sha256"
    echo "abc123" > "$checksum_file"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run verify_archive "$archive"
    [ "$status" -eq 0 ]
    assert_contains "$output" "通过"
}

@test "backup: SHA256 不匹配时验证失败" {
    setup_backup_test

    local archive="${TEST_TMP_DIR}/backup.tar.gz"
    echo "data" > "$archive"

    cat > "${MOCK_DIR}/sha256sum" <<'EOF'
#!/bin/bash
echo "actual456"
EOF
    chmod +x "${MOCK_DIR}/sha256sum"

    local checksum_file="${archive}.sha256"
    echo "expected123" > "$checksum_file"

    source "${BATS_TEST_DIRNAME}/../lib/core.sh" 2>/dev/null || true
    main() { :; }
    source "${BATS_TEST_DIRNAME}/../bin/kn-backup" 2>/dev/null || true
    unset -f main

    run verify_archive "$archive"
    [ "$status" -eq 1 ]
    assert_contains "$output" "失败"
}

# ==================================================================
# CLI 参数测试
# ==================================================================

@test "backup: --help 输出用法并退出 0" {
    run "${BATS_TEST_DIRNAME}/../bin/kn-backup" --help
    [ "$status" -eq 0 ]
    assert_contains "$output" "用法"
}

@test "backup: --version 输出版本并退出 0" {
    run "${BATS_TEST_DIRNAME}/../bin/kn-backup" --version
    [ "$status" -eq 0 ]
    assert_contains "$output" "kn-backup v"
}

@test "backup: 未知参数报错退出" {
    run "${BATS_TEST_DIRNAME}/../bin/kn-backup" --bogus-flag
    [ "$status" -eq 1 ]
    assert_contains "$output" "未知参数"
}
