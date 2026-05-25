# ====================================================================
# node-guardian: BATS Test Harness (tests/test_helper.bash)
# 提供测试环境初始化、mock 工具和公共 teardown
# ====================================================================

setup() {
    TEST_TMP_DIR="$(mktemp -d)"
    export TEST_TMP_DIR
}

teardown() {
    rm -rf "$TEST_TMP_DIR"
}

# 刷新干净的 core.sh 环境 (每次测试前调用)
reload_core() {
    # 重置 DRY_RUN 和 TMP_FILES
    export DRY_RUN=false
    export TMP_FILES
    TMP_FILES=()
    # 重新 source
    # shellcheck source=../lib/core.sh
    source "${BATS_TEST_DIRNAME}/../lib/core.sh"
}

# 创建一个临时文件并返回路径
make_tmp() {
    local name="${1:-tmpfile}"
    local path="${TEST_TMP_DIR}/${name}"
    touch "$path"
    echo "$path"
}

# 断言两字符串相等
assert_eq() {
    if [ "$1" != "$2" ]; then
        printf "  FAIL: 期望值不匹配\n    expected: %s\n    actual:   %s\n" "$1" "$2" >&2
        return 1
    fi
    return 0
}

# 断言字符串包含子串
assert_contains() {
    if [[ "$1" != *"$2"* ]]; then
        printf "  FAIL: 字符串不包含期望子串\n    haystack: %s\n    needle:   %s\n" "$1" "$2" >&2
        return 1
    fi
    return 0
}

# 断言文件存在
assert_file_exists() {
    if [ ! -f "$1" ]; then
        printf "  FAIL: 文件不存在: %s\n" "$1" >&2
        return 1
    fi
    return 0
}

# 断言两个文件内容一致
assert_files_equal() {
    if ! diff -q "$1" "$2" >/dev/null 2>&1; then
        printf "  FAIL: 文件内容不一致\n    file1: %s\n    file2: %s\n" "$1" "$2" >&2
        diff "$1" "$2" >&2
        return 1
    fi
    return 0
}
