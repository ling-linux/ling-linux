# 灵 Linux 用户空间持久化设计文档

## 1. 背景与目标

灵 Linux 当前以单 EFI 文件发行，全内存运行（rootfs 在 initramfs 中），
无持久化存储。内核和系统软件保持不可变，用户家目录、配置和应用软件需持久化
到外部存储。

### 设计目标

- 内核与系统软件不可变，每次启动从 EFI 文件重建
- 用户家目录与配置存放在独立分区的加密镜像文件中
- 登录时解密并挂载用户空间，注销时卸载并移除用户
- 同一密码同时用于 LUKS 解密和 PAM 用户认证
- 用户级包管理器（Nix）支持软件安装，不影响系统不可变性
- root 和系统用户（如 greetd、nobody）无需外部镜像，直接登录

---

## 2. 整体架构

```
    ┌──────────────────────────────────────────────┐
    │  灵 Linux EFI 文件 (initramfs, 不可变)         │
    │                                                │
    │  greetd ──→ labwc ──→ ling-greeter (root)     │
    │                │                               │
    │    IPC  ┌──────┴──────┐                        │
    │    ◄───►│ ling-greetd-ipc │                     │
    │         │ (C 辅助程序)  │                     │
    │         └───────────────┘                      │
    │                                                │
    │  Zenity UI:                                    │
    │    1. 用户名 + 密码                            │
    │    2. 分区选择 (lsblk)                         │
    │    3. .img 文件选择                             │
    └──────────────────────────────────────────────┘
                       │
              LUKS 解密 │ ext4 挂载 + bind mount
                       ▼
    ┌──────────────────────────────────────────────┐
    │   外部分区                                     │
    │   └─ alice-ling.img (LUKS2 + ext4, 稀疏文件)   │
    │        ├─ .ling-user ("alice")                │
    │        └─ home/                                │
    │             ├─ .bashrc, .profile, ...          │
    │             ├─ .config/                        │
    │             └─ .nix-store/                     │
    └──────────────────────────────────────────────┘
```

### 启动与登录流程

```
UEFI → 内核(EFI Stub) → init(overlay/init)
  → OpenRC 启动服务 (含 greetd)
    → greetd 启动 labwc + ling-greeter (root)
      → 用户输入凭据
         ├─ 系统用户 (getent passwd 存在) → 直走 PAM 认证
         └─ 新用户 → 分区选择 → .img 选择
              → cryptsetup luksOpen → mount ext4
              → 比对 .ling-user → useradd → PAM
      → 认证成功 → start_session → labwc 用户会话
```

### 登录分支逻辑

```
getent passwd "$username"
  ├─ 存在 → IPC create_session → PAM → start_session
  └─ 不存在
       ├─ 选分区 (lsblk -f 列出 FSTYPE 非空分区)
       ├─ 挂载分区到 /tmp/ling-data
       ├─ 选 .img 文件 (zenity --file-selection)
       ├─ 卸载分区
       ├─ cryptsetup luksOpen "$img" ling-vault
       ├─ mount /dev/mapper/ling-vault /tmp/ling-user-$$
       ├─ 比对 /tmp/ling-user-$$/.ling-user
       ├─ useradd -m $username
       ├─ mount --bind /tmp/ling-user-$$/home /home/$username
       ├─ umount /tmp/ling-user-$$
       ├─ chown -R $username:$username /home/$username
       ├─ echo "$username:$password" | chpasswd
       └─ IPC create_session → PAM → start_session
```

密码由 LUKS 和 PAM 各自独立校验，greeter 不做密码强度或空密码策略限制。
root 密码已锁定（`!`），禁止直接登录，仅 wheel 用户可通过 `sudo su` 提升权限。

---

## 3. 加密与存储方案

### 3.1 方案选择历程

- **方案 A（裸目录 + gocryptfs）**：文件级加密，FUSE 用户态，非单文件形态
- **方案 B（LUKS2 + 稀疏 ext4 镜像）**：块级加密，内核态，单文件容器 ← **选定**

### 3.2 技术细节

- **容器格式**：单个稀疏 `.img` 文件，动态增长
- **加密**：LUKS2 (Linux Unified Key Setup)，`cryptsetup luksFormat` + `luksOpen`
- **内部文件系统**：ext4（内核内置，日志可靠）
- **内核支持**：需启用 `DM_CRYPT`（已在 `scripts/03-kernel.sh:211` 中启用）
- **密码**：与用户 PAM 登录密码相同。greeter 不校验密码强度或空值，由 LUKS 和 PAM 各自决定

### 3.3 用户身份校验

镜像 ext4 根目录放置 `.ling-user` 文件，内容为所属用户名（纯文本，一行）。
Greeter 解密后先挂载到临时路径，读取比对身份文件，再通过 bind mount
将镜像的 `home/` 子目录暴露到 `/home/$username`。

```
镜像根/.ling-user  →  "alice"
镜像根/home/      →  (经由 bind mount 暴露为 /home/alice/)
```

运行时挂载点结构：

```
/tmp/ling-user-$$/        ← 镜像直接挂载点
  ├─ .ling-user           ← 身份验证文件
  └─ home/                ← 用户数据根
       └─ (经由 mount --bind → /home/alice/)
```

---

## 4. 登录 Greeter 脚本

### 4.1 技术选型

- **语言**：Shell (`/bin/sh`)
- **UI**：zenity（GTK3 对话框，Alpine 包已有）
- **分区扫描**：`lsblk -no NAME,SIZE,FSTYPE,LABEL`
- **IPC 通信**：`ling-greetd-ipc`（独立项目，C 辅助程序，封装整个 PAM 认证流程）

### 4.2 greetd 配置变更

文件：`overlay/etc/greetd/config.toml`

```toml
[terminal]
vt = 1

[default_session]
command = "labwc -C '/usr/local/lib/ling-labwc-login-config' -S '/usr/local/bin/ling-greeter'"
user = "root"
```

- 保留 labwc 作为最小混成器（zenity 依赖 Wayland compositor 渲染）
- greeter 以 root 身份运行（需要 `cryptsetup`、`mount`、`useradd` 权限）
- 不再使用 gtkgreet

### 4.3 Zenity UI 流程

```
第 1 步：zenity --forms
  ├─ --add-entry="用户名"
  └─ --add-password="密码"

  ↓ (取消 → exit 0 → greetd 重启 greeter)

第 2 步（仅当 getent passwd "$username" 失败时）：

  ├─ 2a. zenity --list
  │      列：设备 | 大小 | 文件系统 | 卷标
  │      数据源：lsblk -no NAME,SIZE,FSTYPE,LABEL | awk '$3!=""'
  │      显示优先级：LABEL > 空则用设备路径
  │
  │  2b. mount "/dev/$partition" /tmp/ling-data
  │      失败 → zenity --error → 返回 2a
  │
  │  2c. zenity --file-selection
  │      --filename=/tmp/ling-data/
  │      --file-filter="Ling 镜像 | *.img"
  │
  └─ 2d. umount /tmp/ling-data
```

### 4.4 Greetd IPC 协议交互

greetd 的 IPC 要求整个认证流程（`create_session` → PAM auth 循环 → `start_session`）
在**同一个 Unix socket 连接**内完成。因此 IPC 辅助程序封装为单个 `login` 命令：

```sh
# 接口定义（greeter 脚本中的单行调用，密码通过 stdin 传入）
echo "$password" | ling-greetd-ipc login "$GREETD_SOCK" "$username" \
    "/usr/local/bin/ling-session" "$username"
# 返回 0 = 成功（会话已由 greetd 启动，greeter 退出）
# 返回非 0 = 失败（stderr 输出错误描述，greeter 展示给用户后重试）
```

辅助程序内部完成：
1. 连接 Unix socket（`$GREETD_SOCK`）→ `create_session` + 密码
2. 处理 PAM `auth_message` 循环（自动回复密码）
3. 收到 `success` 后 → `start_session` 启动 ling-session
4. 断开连接，返回结果码

### 4.5 Greeter 挂载新架构（适用于新用户登录）

当用户首次登录时（`getent passwd` 不存在），greeter 使用如下流程处理 LUKS 镜像：

```sh
# 1. 解密并挂载到临时路径（非用户家目录）
cryptsetup luksOpen "$IMG" "$MAPPER_NAME"
mkdir -p "$TMP_MNT"
mount "/dev/mapper/$MAPPER_NAME" "$TMP_MNT"

# 2. 验证身份
grep -qx "$USERNAME" "$TMP_MNT/.ling-user"

# 3. 创建系统用户
useradd -m "$USERNAME"

# 4. bind mount 将镜像 home 暴露为用户家目录
mount --bind "$TMP_MNT/home" "/home/$USERNAME"

# 5. 清理临时直接挂载点（bind mount 保持文件系统活跃）
umount "$TMP_MNT" && rmdir "$TMP_MNT"

# 6. 修复用户所有权（P0 修复：镜像 root 创建的文件需 chown）
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

# 7. PAM 改密与 IPC 认证
echo "$USERNAME:$PASSWORD" | chpasswd
echo "$PASSWORD" | ling-greetd-ipc login "$GREETD_SOCK" "$USERNAME" \
    /usr/local/bin/ling-session "$USERNAME"
```

### 4.6 创建辅助工具

通过 `ling-mkuserimg`（独立工具）创建新的 LUKS 镜像，而非由 greeter 创建。
详见 `docs/design-ling-mkuserimg.md`。

使用方式：

```sh
# 后端（可脚本化）
echo "$pass" | ling-mkuserimg --image /mnt/sda1/alice.img \
    --size 4G --username alice --password-stdin

# 前端向导（交互式用户界面）
ling-mkuserimg-wizard
```

### 4.7 Greeter 启动时的清理

第 0 步：由 `cleanup_mounts()` 在每轮主循环开始时以 root 身份执行，清理上一会话残留：

```sh
cleanup_mounts() {
    for dir in /home/*; do
        [ -d "$dir" ] || continue
        username=$(basename "$dir")
        mountpoint -q "$dir" 2>/dev/null && umount -l "$dir" 2>/dev/null || true
        # 删除上一会话残留的非系统用户（UID >= 1000）
        uid=$(getent passwd "$username" 2>/dev/null | cut -d: -f3)
        if [ -n "$uid" ] && [ "$uid" -ge 1000 ] 2>/dev/null; then
            userdel -r "$username" 2>/dev/null || true
        fi
    done
    umount /tmp/ling-data 2>/dev/null || true
    dmsetup remove ling-vault 2>/dev/null || true
}
```

### 4.8 错误处理

| 错误场景           | 处理                                              | 后续              |
| ------------------ | ------------------------------------------------- | ----------------- |
| 用户点取消         | `exit 0`                                           | greetd 重启 greeter |
| LUKS 解密失败      | `zenity --error --text="密码错误或文件损坏"`       | 返回第 1 步       |
| 分区挂载失败       | `zenity --error --text="无法挂载分区"`             | 返回第 2a 步      |
| .ling-user 不匹配    | `umount` + `luksClose` + `zenity --error`            | 返回第 1 步       |
| PAM 认证失败       | `zenity --error --text="认证失败"`                 | 返回第 1 步       |
| useradd 创建用户失败 | `umount` + `luksClose` + `zenity --error`            | 返回第 1 步       |

---

## 5. 会话管理

### 5.1 ling-session 变更

文件：`overlay/usr/local/bin/ling-session`，完全替换：

```sh
#!/bin/sh
# 由 ling-greeter 通过 greetd IPC 启动，参数 $1 为用户名。
# 清理由 ling-greeter step0 在下一轮登录前以 root 完成。
USERNAME="$1"
exec dbus-run-session -- labwc
```

- 接收用户名作为第一个参数（greeter 通过 `start_session.cmd` 数组传入）
- 会话以普通用户身份运行，无权限执行 `umount`/`cryptsetup`/`userdel`
- 实际清理由 `ling-greeter` 的 `cleanup_mounts()` 以 root 身份完成

### 5.2 注销清理路径（四重保障）

| 防线 | 位置                                       | 触发时机                 | 权限     |
| ---- | ------------------------------------------ | ------------------------ | -------- |
| 1    | `ling-greeter` 步骤 0                       | greetd 重启 greeter 时    | root ✅ |
| 2    | `ling-poweroff`                             | 关机 / 重启时             | 不限   |

> 注：`ling-session` trap 和 `labwc shutdown` 因以普通用户身份运行，无法执行
> `umount`/`cryptsetup luksClose`/`userdel`。主清理由 `ling-greeter` step0 以
> root 身份在下一次登录前完成。`ling-poweroff` 调用 `poweroff -f` 强制关机，
> 不依赖干净的 LUKS 关闭。

---

## 6. 关机脚本

### 6.1 ling-poweroff

文件：`overlay/usr/local/bin/ling-poweroff`

```sh
#!/bin/sh
for dir in /home/*; do
    mountpoint -q "$dir" && umount -l "$dir"
done
cryptsetup luksClose ling-vault 2>/dev/null
exec /bin/busybox poweroff -f
```

### 6.2 菜单变更

`overlay/root/.config/labwc/menu.xml` 和 `overlay/etc/skel/.config/labwc/menu.xml`
中的关机命令：

```xml
<!-- 旧 -->
<action name="Execute" command="busybox poweroff -f" />

<!-- 新 -->
<action name="Execute" command="ling-poweroff" />
```

---

## 7. Nix 包管理器预装

### 7.1 技术方案

- **二进制来源**：Hydra CI 静态构建（musl 兼容）
  `https://hydra.nixos.org/job/nix/master/buildStatic.x86_64-linux/latest/download-by-type/file/binary-dist`
- **系统内路径**：`/usr/local/bin/nix`
- **store 物理路径**：`~/.nix-store`（通过 `NIX_STORE_DIR` 环境变量指定）
- **store 逻辑路径**：保持 `/nix/store`（缓存 `cache.nixos.org` 正常可用）
- **功能启用**：`nix-command` + `flakes` 实验性功能

### 7.2 环境变量配置

文件：`overlay/etc/profile.d/nix.sh`（新建）

```sh
export NIX_STORE_DIR="$HOME/.nix-store"
export NIX_STATE_DIR="$HOME/.nix-state"
export NIX_LOG_DIR="$HOME/.nix-log"
export NIX_CONFIG="experimental-features = nix-command flakes"
export PATH="$HOME/.nix-profile/bin:$PATH"
```

### 7.3 Nix 自我升级

用户在 `~/.nix-profile` 中安装新版 Nix 后，通过 PATH 优先级覆盖系统版。

---

## 8. 构建系统变更

### 8.1 包列表 (`config/packages.list`)

新增：

```
cryptsetup
e2fsprogs
zenity
```

### 8.2 内核配置 (`scripts/03-kernel.sh`)

`DM_CRYPT` 已在 `scripts/03-kernel.sh:211` 中启用，无需更改。

### 8.3 RootFS 构建 (`scripts/02-rootfs.sh`)

在字体下载之后添加：

```sh
# --- Install Nix static binary ---
echo "[02-rootfs] Downloading Nix static binary..."
wget -q "https://hydra.nixos.org/job/nix/master/buildStatic.x86_64-linux/latest/download-by-type/file/binary-dist" \
    -O "$ROOTFS_DIR/usr/local/bin/nix" && \
    chmod +x "$ROOTFS_DIR/usr/local/bin/nix" || \
    echo "[02-rootfs] WARNING: Failed to download Nix. Skipping."

# --- Install greetd IPC helper ---
echo "[02-rootfs] Downloading ling-greetd-ipc..."
wget -q "https://github.com/ling-linux/ling-greetd-ipc/releases/latest/download/ling-greetd-ipc" \
    -O "$ROOTFS_DIR/usr/local/bin/ling-greetd-ipc" && \
    chmod +x "$ROOTFS_DIR/usr/local/bin/ling-greetd-ipc" || \
    echo "[02-rootfs] WARNING: Failed to download IPC helper. Skipping."
```

---

## 9. 文件清单

### 9.1 需要新建的文件

| 文件                                       | 说明                                     |
| ------------------------------------------ | ---------------------------------------- |
| `overlay/usr/local/bin/ling-greeter`         | Shell greeter 主脚本                     |
| `overlay/usr/local/bin/ling-poweroff`        | 关机前清理包装                           |
| `overlay/usr/local/bin/ling-mkuserimg`       | 后端：创建 LUKS2 用户镜像（含参数解析）     |
| `overlay/usr/local/bin/ling-mkuserimg-wizard`| 前端：zenity / CLI 交互式向导             |
| `overlay/etc/profile.d/nix.sh`               | Nix 环境变量                             |
| `docs/design-user-space.md`                  | 本文档                                   |
| `docs/design-ling-mkuserimg.md`              | 镜像创建工具设计文档                |
| `test/test_mkuserimg.sh`                     | 后端单元测试（参数与校验逻辑）            |
| `test/test_mkuserimg_integration.sh`         | 集成测试（真实镜像创建，需 root）            |

### 9.2 需要修改的现有文件

| 文件                                       | 变更说明                                              |
| ------------------------------------------ | ----------------------------------------------------- |
| `config/packages.list`                       | + `cryptsetup`                                      |
| `scripts/03-kernel.sh`                       | `BLK_DEV_DM` 和 `DM_CRYPT` 启用                   |
| `scripts/02-rootfs.sh`                       | + Nix 下载 + IPC 辅助程序下载                          |
| `overlay/etc/greetd/config.toml`             | `[default_session]` 改为 labwc + ling-greeter, root 运行 |
| `overlay/usr/local/bin/ling-session`         | 完全重写：接收用户名参数、trap 清理                    |
| `overlay/root/.config/labwc/menu.xml`        | 关机命令 → `ling-poweroff`                               |
| `overlay/etc/skel/.config/labwc/menu.xml`    | 关机命令 → `ling-poweroff`                               |
| `overlay/root/.config/labwc/shutdown`        | **[新建]** labwc 退出时清理 LUKS 挂载                     |
| `overlay/etc/skel/.config/labwc/shutdown`    | **[新建]** labwc 退出时清理 LUKS 挂载                     |

### 9.3 不再需要的文件

| 文件                                        | 原因                                   |
| ------------------------------------------- | -------------------------------------- |
| (gtkgreet 相关功能被取代，但文件可保留不删) | greeter 功能由 ling-greeter + zenity 替代 |

---

## 10. 独立子项目

| 项目              | 说明                                                                                                      | 接口                                                              |
| ----------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `ling-greetd-ipc`   | C 程序，封装 greetd IPC 认证与会话启动。密码通过 stdin 传入。              | `echo 密码 \| ling-greetd-ipc login <socket> <username> <cmd> [args...]` |
| `ling-mkuserimg`    | Shell 脚本，创建 LUKS2 ext4 稀疏用户镜像，写入 `.ling-user` 和 skel 骨架。详见 `docs/design-ling-mkuserimg.md` | 后端：`ling-mkuserimg --image PATH --size SIZE --username NAME --password-stdin`；前端：`ling-mkuserimg-wizard` |

---

## 11. 未覆盖事项

以下事项在设计讨论中有涉及，但留待后续处理，不在当前实施范围内：

| 事项             | 说明                                                 |
| ---------------- | ---------------------------------------------------- |
| root 登录          | root 密码已锁定（`!`），禁止直接登录。wheel 用户可通过 `sudo su` 或 `sudo -i` 获取 root 权限 |
| 密码修改         | LUKS 和 PAM 密码绑定后不支持独立修改                  |
| Nix 用户引导       | Nix 预装后用户如何使用（文档 / 教程）                |
| SSH 多用户场景   | 非桌面登录场景不做处理（SSH 无 greeter 介入）        |
| 初始化 ramdisk 大小 | 加入 Nix (~50MB) 和 cryptsetup 后需验证内存占用可接受 |
