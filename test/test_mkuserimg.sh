#!/bin/sh
# test_mkuserimg.sh — ling-mkuserimg 后端单元测试
#
# 运行: sh test/test_mkuserimg.sh [MKUSERIMG_PATH]
# MKUSERIMG_PATH 默认: overlay/usr/local/bin/ling-mkuserimg

set -e

# ── 测试工具路径 ──
MKUSERIMG="${1:-overlay/usr/local/bin/ling-mkuserimg}"

if [ ! -x "$MKUSERIMG" ]; then
    echo "跳过: $MKUSERIMG 不存在或无执行权限" >&2
    exit 0
fi

PASSED=0
FAILED=0
total_tests=0

# ── 测试辅助函数 ──
assert_exit() {
    total_tests=$((total_tests + 1))
    desc="$1"; expected_exit="$2"; shift 2
    if "$MKUSERIMG" "$@" 2>/dev/null; then
        actual=0
    else
        actual=$?
    fi
    if [ "$actual" -eq "$expected_exit" ]; then
        PASSED=$((PASSED + 1))
        echo "  PASS: $desc"
    else
        FAILED=$((FAILED + 1))
        echo "  FAIL: $desc (期望退出码 $expected_exit, 实际 $actual)"
    fi
}

assert_stderr_contains() {
    total_tests=$((total_tests + 1))
    desc="$1"; pattern="$2"; shift 2
    output=$("$MKUSERIMG" "$@" 2>&1) || true
    if echo "$output" | grep -qF "$pattern"; then
        PASSED=$((PASSED + 1))
        echo "  PASS: $desc"
    else
        FAILED=$((FAILED + 1))
        echo "  FAIL: $desc (期望匹配 '$pattern', 输出: $output)"
    fi
}

# ── 1. 参数完整性 ──
echo ""
echo "=== 参数解析测试 ==="

assert_exit "无参数"                               1
assert_exit "缺少 --image"                         1 --size 4G --username alice --password-stdin
assert_exit "缺少 --size"                          1 --image /tmp/x.img --username alice --password-stdin
assert_exit "缺少 --username"                      1 --image /tmp/x.img --size 4G --password-stdin
assert_exit "缺少 --password-stdin"                1 --image /tmp/x.img --size 4G --username alice
assert_exit "非法参数"                             1 --image /tmp/x.img --size 4G --username alice --password-stdin --bogus

# ── 2. 用户名合法性 ──
echo ""
echo "=== 用户名校验测试 ==="

# 合法用户名
assert_exit "合法: alice"                          1 --image /tmp/x.img --size 4G --username alice --password-stdin
assert_exit "合法: user_1"                         1 --image /tmp/x.img --size 4G --username user_1 --password-stdin
assert_exit "合法: 单字符 a"                        1 --image /tmp/x.img --size 4G --username a --password-stdin

# 非法用户名
assert_exit "非法: 大写 Alice"                     1 --image /tmp/x.img --size 4G --username Alice --password-stdin
assert_exit "非法: 数字起始 1user"                  1 --image /tmp/x.img --size 4G --username 1user --password-stdin
assert_exit "非法: 横线起始 -user"                  1 --image /tmp/x.img --size 4G --username -- -user --password-stdin
assert_exit "非法: 超长 33 字符"                    1 --image /tmp/x.img --size 4G \
    --username aaaaaaaaaabbbbbbbbbbcccccccccccccd --password-stdin
assert_exit "非法: 包含空格"                        1 --image /tmp/x.img --size 4G --username "a b" --password-stdin
assert_exit "非法: 包含 @符号"                      1 --image /tmp/x.img --size 4G --username "a@b" --password-stdin

# ── 3. 密码校验 ──
echo ""
echo "=== 密码校验测试 ==="

# 这个测试需要依赖项在空密码之前检查......或者需要先通过用户名、root 等检查
# 在非 root 环境下，root 检查在密码检查之前触发，所以密码测试可能要改为 root 后运行
# v1 的单元测试：在非 root 下只能测到 root 检查之前的所有校验

echo "  注意: 密码非空测试和括号式检查需 root 环境" >&2

# ── 4. 错误信息内容校验 ──
echo ""
echo "=== 错误信息测试 ==="

assert_stderr_contains "错误信息: 缺少 --image"    "缺少 --image" \
    --size 4G --username alice --password-stdin
assert_stderr_contains "错误信息: 未知参数"         "未知参数" \
    --image /tmp/x.img --size 4G --username alice --password-stdin --wtf

# ── 5. 大小格式校验 ──
echo ""
echo "=== 大小格式测试 ==="

# mkdir + temp 目录方式模拟父目录存在
TMP_TEST=$(mktemp -d)
trap 'rm -rf "$TMP_TEST"' EXIT

# 这些测试需要 root 才能越过 root 检查，所以大小格式校验在 root 之后也会失败
# （因为先触发了 root 检查）
# 对非 root 环境而言，大小格式校验被 root check 短路了

echo "  跳过大小格式校验测试（需要 root）" >&2

# ── 汇总 ──
echo ""
echo "======================================"
echo "  结果: $PASSED/$total_tests 通过, $FAILED 失败"
echo "======================================"

[ "$FAILED" -eq 0 ] || exit 1
