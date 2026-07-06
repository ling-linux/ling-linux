# 灵 Linux 用户镜像创建工具 — 设计文档与实施方案

## 1. 背景

灵 Linux 的用户空间持久化依赖存储在外部分区上的 LUKS2 加密 ext4 稀疏镜像（`.img`）。
设计文档 §2 规定了 greeter 登录流程如何解密、挂载、使用这些镜像，但 `ling-mkuserimg`
所创建的原始镜像是从何而来的，至今没有工具负责。

本工具填补这一空白。

## 2. 工具拆分为二

——理念：将“收集参数”（交互式）与“执行创建”（可脚本化）分离。

|          | `ling-mkuserimg`（后端）          | `ling-mkuserimg-wizard`（前端）    |
| -------- | --------------------------------- | --------------------------------- |
| 角色     | Capability（资源创建）             | Capability（同资源，交互路径）       |
| 用户     | Agent-Primary                     | Pure Human                        |
| 交互形态 | Batch CLI                         | Zenity 向导 / CLI fallback         |
| 状态     | Stateless                         | Stateless                          |
| 风险     | High Side-Effect（分区写入、格式化） | 同后端                             |
| 放置     | `overlay/usr/local/bin/`           | `overlay/usr/local/bin/`           |

前端收集所有参数后调用后端执行，完成则报告结果。

## 3. 镜像内部结构

```
镜像根（ext4）/
├── .ling-user          # 身份验证文件，内容为用户名（一行）
└── home/               # 用户数据根目录（skel 骨架复制到此）
    ├── .bashrc
    ├── .profile
    ├── .config/        # labwc, foot, gtk-3.0, xfce4, netsurf 等应用配置
    └── .local/
```

设计要点：
- `.ling-user` 在镜像根——挂载后不经 bind 即可直接验证身份
- 用户实际数据在 `home/` 下——greeter 通过 `mount --bind <镜像>/home /home/$username` 暴露给用户
- skel 骨架复制自 `/etc/skel`（默认），可通过 `--skel` 自定义

## 4. 后端：`ling-mkuserimg`

### 4.1 完整接口

```sh
ling-mkuserimg \
    --image PATH          # 镜像文件绝对路径
    --size SIZE           # 人类可读的大小（如 4G、512M），传给 truncate -s
    --username NAME       # 用户名，写入 .ling-user
    --password-stdin      # 从 stdin 读取 LUKS 密码（不复用临时文件或 argv）
    [--skel PATH]         # 骨架源路径，默认为 /etc/skel
    [--force]             # 允许覆盖已存在的目标文件
    [--verbose]           # 输出每个步骤到 stderr
```

### 4.2 输入校验

| 检查                         | 失败行为                 |
| ---------------------------- | ------------------------ |
| root 权限                    | stderr → exit 1          |
| 参数完整性（至少 `--image`、`--size`、`--username`、`--password-stdin`） | stderr → exit 1 |
| `--username` 匹配 `^[a-z_][a-z0-9_-]{0,31}$` | stderr → exit 1 |
| 密码非空                     | stderr → exit 1          |
| `--force` 未指定但目标文件存在 | stderr → exit 1          |
| 镜像父目录不存在或不可写     | stderr → exit 1          |
| 镜像大小 (SIZE) ≥ 父分区可用空间 | stderr → exit 1       |
| 依赖工具（`cryptsetup`、`mkfs.ext4`、`truncate`）可用 | stderr → exit 1 |

### 4.3 输出模型

- stdout：成功时输出镜像绝对路径（一行），其余零输出
- stderr：全部错误与 `--verbose` 进度信息
- 退出码：0 = 成功，1 = 任意失败（v1 不细分）

### 4.4 LUKS2 参数（硬编码，不可配置）

```
--type luks2
--cipher aes-xts-plain64
--key-size 512
--pbkdf argon2id
--iter-time 2000
--luks-label ling-vault
--batch-mode
```

`--batch-mode` 防止 stdin 为管道时 `cryptsetup luksFormat` 尝试从 `/dev/tty` 读取
确认提示导致挂死。

### 4.5 执行流程

```
1. 参数校验（§4.2）
   └─ 失败 → stderr 错误 / exit 1

2. 设置 trap EXIT INT TERM 为防御清理
3. 创建临时挂载点 /tmp/ling-mkuserimg-$$-$RANDOM

4. truncate -s "$SIZE" "$IMAGE" && chmod 600 "$IMAGE"
   └─ 失败 → 清理 / exit 1

5. echo "$pass" | cryptsetup luksFormat --batch-mode --type luks2 \
     --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id \
     --iter-time 2000 --luks-label ling-vault "$IMAGE"
   └─ 失败 → 清理 / exit 1

6. echo "$pass" | cryptsetup luksOpen "$IMAGE" "ling-mkimg-$$-$RANDOM"
   └─ 失败 → 清理 / exit 1

7. mkfs.ext4 -m 0 "/dev/mapper/$DM_NAME"
   └─ 失败 → 清理 / exit 1

8. mount "/dev/mapper/$DM_NAME" "$MNT"
   └─ 失败 → 清理 / exit 1

9. mkdir -p "$MNT/home"
10. cp -a "$SKEL_PATH"/. "$MNT/home"/
    └─ 失败 → 清理 / exit 1

11. echo "$USERNAME" > "$MNT/.ling-user"
    └─ 失败 → 清理 / exit 1

12. 主动清理：umount "$MNT" && cryptsetup luksClose "$DM" && rm -rf "$MNT"
    └─ 失败 → 也记录错误但继续

13. trap - EXIT INT TERM  # 释放 trap，避免未完成清理的不必要调用

14. echo "$IMAGE"  # stdout 输出镜像路径
15. exit 0
```

### 4.6 清理与错误恢复

```sh
cleanup() {
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
    sleep 0.5           # 允许内核自行清除引用
    cryptsetup luksClose "$DM" 2>/dev/null || dmsetup remove "$DM" 2>/dev/null || true
    rm -rf "$MNT" 2>/dev/null
}
trap cleanup EXIT INT TERM
```

关键约束：
- dm-crypt 映射名使用 `ling-mkimg-$$-$RANDOM` 防止 PID 重用冲突
- trap handler 只处理异常路径
- 正常完成时，主流程自行 umount + luksClose，随后 `trap - EXIT` 释放 trap
- `umount -l` + `dmsetup remove` 作为防止碎片遗留在内核的最后手段

## 5. 前端：`ling-mkuserimg-wizard`

### 5.1 技术选型

- **GUI**：zenity（与 ling-greeter 一致），仅在 Wayland compositor 下工作
- **Fallback**：CLI `read` 交互（检测不到 `$DISPLAY` 或 `$WAYLAND_DISPLAY` 时激活）

### 5.2 预检阶段（启动时）

1. root 权限检查：若不是 root，`zenity --error` 或 `echo` 报错 → exit 1
2. Zenity 可用性检测：`command -v zenity` → 决定 GUI / CLI 模式
3. 后端可用性检测：`command -v ling-mkuserimg` → 不可用则 exit 1

### 5.3 交互流程（GUI 模式）

步骤 1 — 选择存储目标
```
zenity --file-selection --save --title="选择镜像存储位置"
```
返回值 → `IMAGE_PATH`

步骤 2 — 选择镜像容量
```
# 计算可用空间（字节）
AVAIL=$(df -B1 --output=avail "$(dirname "$IMAGE_PATH")" | tail -n1)
DEFAULT_SIZE=$(awk "BEGIN { printf \"%.0f\", $AVAIL * 0.7 / 1073741824 }")G

zenity --list --radiolist --title="选择镜像容量" \
    --column="" --column="大小" \
    TRUE  "512M"  FALSE "1G"  FALSE "2G"  FALSE "4G" \
    FALSE "8G"  FALSE "16G" FALSE "32G" FALSE "64G" \
    FALSE "自定义"
```
选择预设值或“自定义”（触发 `zenity --entry` 手动输入）
返回值 → `SIZE`

步骤 3 — 设置用户名
```
zenity --forms --title="设置用户名" \
    --add-entry="用户名 (a-z, 0-9, -, _)" \
    --add-password="密码" \
    --add-password="确认密码"
```
校验：
- 用户名匹配 `^[a-z_][a-z0-9_-]{0,31}$`
- 两遍密码一致且非空
- 不一致 → `zenity --error` → 重新填写

返回值 → `USERNAME`、`PASSWORD`

步骤 4 — 确认摘要
```
if [ -f "$IMAGE_PATH" ]; then
    WARNING="⚠ 文件已存在，将被覆盖\n"
fi

zenity --question --title="确认创建" \
    --text="${WARNING}镜像路径: $IMAGE_PATH\n容量: $SIZE\n用户名: $USERNAME\n\n确认创建？" \
    --ok-label="创建" --cancel-label="取消"
```
取消 → exit 0

步骤 5 — 执行
```
# 如果文件已存在，添加 --force
OVERWRITE=""
[ -f "$IMAGE_PATH" ] && OVERWRITE="--force"

echo "$PASSWORD" | ling-mkuserimg \
    --image "$IMAGE_PATH" \
    --size "$SIZE" \
    --username "$USERNAME" \
    --password-stdin \
    $OVERWRITE \
    --verbose 2>&1 \
    | zenity --progress --pulsate --auto-close \
        --title="正在创建镜像..." --text="请稍候..." \
        --no-cancel
```

若后端 exit ≠ 0，用 `zenity --error` 显示 stderr 输出。若后端 exit 0，用 `zenity --info` 显示成功信息。

### 5.4 CLI 回退模式

无 zenity 时使用 `read` 逐项询问。关键差异：
- 密码输入用到 `read -s`（隐藏输入），重复确认匹配
- 默认大小计算：需提示用户（如 `"推荐大小 4G (分区 70% 空闲)，按 Enter 同意或输入自定义:"`）
- 确认：简单的 `"确认创建? [y/N]"` 提示

## 6. Greeter 适配

镜像结构变更需要 greeter 相应地调整挂载逻辑，同时修复 root 所有权问题。

### 6.1 当前问题

- 镜像 root 创建的镜像文件为 `root:root` 所有，用户登录时不可写
- `useradd -m "$username"` 静默失败（`/home/$username` 已存在）
- 缺少 `chown`，用户无法写入 `.config/`、`.local/` 等目录

### 6.2 新流程（外部用户登录）

```
1. 选分区 → 挂载到 /tmp/ling-data
2. 选 .img
3. 卸载分区
4. cryptsetup luksOpen "$img" ling-vault
5. mount /dev/mapper/ling-vault /tmp/ling-user-$$  ← 新：挂到临时路径
6. grep -qx "$username" /tmp/ling-user-$$/.ling-user                ← 验证身份
7. useradd -m "$username"
8. mount --bind /tmp/ling-user-$$/home /home/$username              ← bind mount
9. umount /tmp/ling-user-$$ && rmdir /tmp/ling-user-$$              ← 清理临时挂载
10. chown -R "$username:$username" /home/$username                  ← P0 修复
11. echo "$username:$password" | chpasswd
12. IPC 认证 → start_session
```

关键变更：
- 镜像先挂载到临时路径（不是最终用户路径）用于身份验证
- `mount --bind` 把镜像的 `home/` 暴露给用户的 `/home/$username`
- 临时挂载点 umount 后 bind mount 仍然保持（引用计数 ≥1）
- 新增 `chown -R` 解决所有权问题（P0 修复）
- 无需修改 `ling-greeter` 中的 dm-crypt 映射名 `ling-vault`——创建工具已经避免冲突

## 7. 安全注意事项

### 7.1 密码管道

- 密码通过 stdin 管道传入后端——不在 `/proc/<pid>/cmdline` 中出现
- `cryptsetup luksFormat` 和 `luksOpen` 都从 stdin 读取密码
- 密码仍作为 shell 变量存在——root 工具在 initramfs 系统上运行，无 swap，风险可接受

### 7.2 文件权限

- 后端在完成 `truncate` 后立即执行 `chmod 600 "$IMAGE"`——防止同分区的其他用户读取加密镜像
- 临时挂载点 `/tmp/ling-mkuserimg-$$-$RANDOM` 包含 `$$` 和 `$RANDOM`，缓解 DOS 风险

### 7.3 加固

- `mkfs.ext4 -m 0`——用户镜像无需保留块（已由 LUKS 保证备份），节省空间
- `--batch-mode` 传递给 `cryptsetup luksFormat`——防止管道下卡死
- 用户名白名单限制为 POSIX 允许字符，避免路径遍历或 shell 注入
- Greeter 验证 `.ling-user` 继续使用 `grep -qx`——用户名已限制为合法字符

## 8. 构建集成变更

### 8.1 包依赖

`config/packages.list` 新增：

```
e2fsprogs
```

理由：`mkfs.ext4` 来自 `e2fsprogs`（Alpine 基础包）。`DM_CRYPT` 已由 `scripts/03-kernel.sh:211` 启用，无需更改。

### 8.2 文件放置

无需额外构建步骤——`overlay/` 已通过 `cp -a` 复制到 rootfs（`scripts/02-rootfs.sh`）。

### 8.3 文件变更清单

| 文件                                    | 操作   | 说明                     |
| --------------------------------------- | ------ | ------------------------ |
| `overlay/usr/local/bin/ling-mkuserimg`    | **新建** | 后端                     |
| `overlay/usr/local/bin/ling-mkuserimg-wizard` | **新建** | 前端                     |
| `overlay/usr/local/bin/ling-greeter`      | **修改** | 新镜像架构 + chown       |
| `config/packages.list`                   | **修改** | + `e2fsprogs`             |
| `docs/design-ling-mkuserimg.md`           | **新建** | 本文档                   |
| `docs/design-user-space.md`              | **修改** | 更新镜像架构与文件清单   |

## 9. 测试方案

### 9.1 测试文件

```
test/
├── test_mkuserimg.sh              # 后端单元测试
└── test_mkuserimg_integration.sh  # 集成测试（需 root）
```

### 9.2 单元测试覆盖

- 参数解析：必选参数缺失 → exit 1
- 用户名校验：非法字符拒绝、合法字符通过、长度超限拒绝
- `--force` / 文件存在交互
- 密码为空：拒绝
- 非 root 运行：拒绝
- Skel 路径默认值与显式指定

### 9.3 集成测试覆盖（需 root）

- 创建小型镜像（32M），验证成功退出与正确的输出路径
- 验证 `.ling-user` 内容
- 验证 skel 复制内容一致性（抽样比对文件）
- 再次创建无 `--force`：验证被拒绝
- `--force` 创建：验证覆盖成功
- Greeter 兼容性：创建后的镜像能被 `ling-greeter` 的验证逻辑正确识别

所有测试在 `test/` 下用普通 shell 脚本编写，通过 `sh test/test_*.sh` 运行。

## 10. 实施顺序

| 优先级 | 步骤                                        | 说明                                   |
| ------ | ------------------------------------------- | -------------------------------------- |
| **1**      | 编写并审查本设计文档                         | [当前完成]                             |
| **2**      | 实现 `ling-mkuserimg`（后端）                 | 参数解析 + 核心创建逻辑 + trap          |
| **3**      | 实现 `test/test_mkuserimg.sh`（单元测试）     | 后端签名 + 校验                        |
| **4**      | 实现 `test/test_mkuserimg_integration.sh`（集成测试） | 完整创建 + greeter 兼容性              |
| **5**      | 实现 `ling-mkuserimg-wizard`（前端）          | Zenity 向导 + CLI 回退                 |
| **6**      | 修改 `ling-greeter`                          | 新架构成接 + chown 修复                 |
| **7**      | `config/packages.list` 新增                  | `e2fsprogs`                             |
| **8**      | 更新 `docs/design-user-space.md`             | 镜像架构变更 + 文件清单更新             |

### 10.1 v1 非目标

- 自定义 LUKS 参数暴露（`--cipher`、`--pbkdf` 等）
- 结构化输出（JSON）
- 端口映射 / `--label` 自定义
- Greeter 中直接集成向导
- 批量镜像创建
- 非交互式密码的 stdin 输入到前端

## 11. 未覆盖事项

| 事项                 | 说明                                       |
| -------------------- | ------------------------------------------ |
| 密码修改             | LUKS + PAM 同时更改暂不支持                |
| Homed 支持           | `systemd-homed` / LUKS home 目录直接挂载不可行（需要 systemd） |
| Nix 初始化           | Nix-store 预植留待后续                                     |
| SSH 用法             | 非桌面登录场景，不由 greeter 处理                             |
