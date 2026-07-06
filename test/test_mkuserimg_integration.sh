#!/bin/sh
# test_mkuserimg_integration.sh — ling-mkuserimg 集成测试
#
# 需要: root 权限 + cryptsetup + mkfs.ext4
# 运行: sudo sh test/test_mkuserimg_integration.sh [MKUSERIMG_PATH]
#
# 创建真实 LUKS2 小镜像 (32M)，验证创建流程和输出结果。

set -e

# ── 前置检查 ──
if [ "$(id -u)" -ne 0 ]; then
    echo "跳过: 集成测试需要 root 权限" >&2
    exit 0
fi

for cmd in cryptsetup mkfs.ext4 truncate; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "跳过: 缺少 $cmd" >&2
        exit 0
    fi
done

# ── 测试工具路径 ──
MKUSERIMG="${1:-overlay/usr/local/bin/ling-mkuserimg}"

if [ ! -x "$MKUSERIMG" ]; then
    echo "跳过: $MKUSERIMG 不存在或无执行权限" >&2
    exit 0
fi

PASSED=0
FAILED=0

# ── 测试辅助 ──
PASS() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
FAIL() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

# ── 清理 ──
TEST_DIR=$(mktemp -d /tmp/ling-test-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
IMAGE="$TEST_DIR/test.img"

echo "临时目录: $TEST_DIR"
echo ""

# ═══════════════════════════════════════════
# 测试 1: 基本创建流程
# ═══════════════════════════════════════════
echo "=== 测试 1: 基本创建流程 ==="

OUTPUT=$(echo "testpass123" | "$MKUSERIMG" \
    --image "$IMAGE" \
    --size 32M \
    --username testuser \
    --password-stdin 2>&1) || { FAIL "创建失败: $OUTPUT"; }
[ "$OUTPUT" = "$IMAGE" ] && PASS "stdout 输出镜像路径正确" || FAIL "stdout 输出不正确: $OUTPUT"
[ -f "$IMAGE" ] && PASS "镜像文件已创建" || FAIL "镜像文件未创建"

# ═══════════════════════════════════════════
# 测试 2: 验证 LUKS2 内容
# ═══════════════════════════════════════════
echo ""
echo "=== 测试 2: 验证 LUKS2 内容 ==="

DM_NAME="ling-test-$$-$RANDOM"
MNT="/tmp/ling-test-mnt-$$-$RANDOM"

cleanup_test2() {
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    sleep 0.5
    cryptsetup luksClose "$DM_NAME" 2>/dev/null || dmsetup remove "$DM_NAME" 2>/dev/null || true
    rm -rf "$MNT" 2>/dev/null
}
trap 'cleanup_test2; rm -rf "$TEST_DIR"' EXIT INT TERM

echo "testpass123" | cryptsetup luksOpen "$IMAGE" "$DM_NAME" 2>&1 \
    && PASS "LUKS2 打开成功" || { FAIL "LUKS2 打开失败"; exit 1; }

mkdir -p "$MNT"
mount "/dev/mapper/$DM_NAME" "$MNT" 2>&1 \
    && PASS "ext4 挂载成功" || { FAIL "ext4 挂载失败"; exit 1; }

# 验证 .ling-user
if [ -f "$MNT/.ling-user" ]; then
    CONTENT=$(cat "$MNT/.ling-user")
    [ "$CONTENT" = "testuser" ] && PASS ".ling-user 内容正确" \
        || FAIL ".ling-user 内容错误: '$CONTENT' (期望 'testuser')"
else
    FAIL ".ling-user 缺失"
fi

# 验证镜像结构: .ling-user 在根 + home/ 为数据目录
[ -f "$MNT/.ling-user" ] && [ -d "$MNT/home" ] \
    && PASS "镜像根结构正确 (.ling-user + home/)" \
    || FAIL "镜像根结构不完整"

# 验证 skel 内容: /etc/skel/.nanorc 应复制到镜像 home/ 下
if [ -f /etc/skel/.nanorc ]; then
    [ -f "$MNT/home/.nanorc" ] && PASS "skel 文件复制成功 (.nanorc)" \
        || FAIL "skel 文件缺失 (.nanorc)"
else
    echo "  跳过 skel 验证: /etc/skel/.nanorc 不存在" >&2
fi

# 验证文件权限: 镜像应为 600
PERMS=$(stat -c '%a' "$IMAGE")
[ "$PERMS" = "600" ] && PASS "镜像文件权限为 600" \
    || FAIL "镜像文件权限错误: $PERMS (期望 600)"

# 验证 LUKS 标签
LABEL=$(cryptsetup luksDump "$IMAGE" 2>/dev/null | grep -F "ling-vault" || true)
[ -n "$LABEL" ] && PASS "LUKS 标签为 ling-vault" \
    || FAIL "LUKS 标签未正确设置"

# 清理
umount "$MNT" && cryptsetup luksClose "$DM_NAME" && rm -rf "$MNT"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

# ═══════════════════════════════════════════
# 测试 3: 覆盖保护
# ═══════════════════════════════════════════
echo ""
echo "=== 测试 3: 覆盖保护 ==="

echo "testpass123" | "$MKUSERIMG" \
    --image "$IMAGE" \
    --size 32M \
    --username testuser \
    --password-stdin 2>/dev/null && FAIL "无 --force 时不应覆盖已有文件" \
    || PASS "无 --force 时正确拒绝覆盖"

echo "testpass123" | "$MKUSERIMG" \
    --image "$IMAGE" \
    --size 32M \
    --username testuser \
    --password-stdin \
    --force 2>/dev/null && PASS "--force 覆盖成功" \
    || FAIL "--force 覆盖失败"

# ═══════════════════════════════════════════
# 汇总
# ═══════════════════════════════════════════
echo ""
echo "======================================"
echo "  结果: $PASSED 通过, $FAILED 失败"
echo "======================================"

[ "$FAILED" -eq 0 ] || exit 1
