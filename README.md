# 灵 Linux

单 EFI 文件 Linux 发行版，EFI Stub 启动，内核内嵌 initramfs。

## 构建

依赖 Docker 或 Podman。

```sh
docker build -t ling-linux-builder -f Containerfile .
docker run --rm -v "$(pwd)/output:/build/output" ling-linux-builder
```

产物：`output/LingLinux.efi`

## 技术栈

- **内核**：Linux 7.1（自编译，EFI Stub，nullfs 支持）
- **基础系统**：Alpine Linux 3.24
- **显示服务**：Wayland（labwc + wlroots）
- **桌面面板**：xfce4-panel（Xfce 4.20 Wayland 原生支持）
- **终端**：foot
- **应用启动器**：wofi（`ling-appmenu` 切换开关）
- **文件管理器**：thunar
- **通知**：mako
- **音频**：PipeWire + WirePlumber
- **输入法**：fcitx5 + rime
- **网络/蓝牙**：iwd + iwgtk / bluez + blueman

## 目录结构

```
ling-linux/
├── Containerfile              # 构建容器定义
├── build.sh                   # 入口构建脚本
├── config/
│   └── packages.list          # Alpine 包列表
├── overlay/                   # initramfs 覆盖层
│   ├── init                   # PID 1 初始化脚本
│   ├── etc/
│   │   ├── greetd/            # 登录管理器配置
│   │   ├── labwc/             # 系统级 labwc 主题
│   │   └── skel/              # 新用户模板（labwc 配置、会话环境等）
│   ├── root/
│   │   └── .config/labwc/     # root 用户 labwc 配置
│   └── usr/local/bin/         # ling-* 辅助脚本
├── output/                    # 构建产物
├── scripts/
│   ├── env.sh                 # 构建环境变量（镜像源、版本号）
│   ├── 01-fetch.sh            # 拉取 Alpine rootfs + 内核源码
│   ├── 02-rootfs.sh           # APK 安装 + 构建根文件系统
│   ├── 03-kernel.sh           # defconfig → 定制 → 编译内核
│   └── 04-assemble.sh         # 打包 initramfs + 嵌入内核 → EFI
└── test/                      # QEMU 测试
```

## CI

GitHub Actions 构建，支持手动触发并指定内核版本（默认 7.1.3）。
