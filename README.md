# vanilla-sunshine-podman

用 **rootful podman + 官方镜像** 运行 [Sunshine](https://github.com/LizardByte/Sunshine)（Moonlight 宿主端），
替代 `~/vanilla-sunshine` 里「setuid-root bwrap + 注入 CAP_SYS_ADMIN」的 flatpak 方案，
目标就是**让 KMS/DRM master 屏幕捕获正常工作**。

## 为什么必须用 root？

KMS 捕获走 `drmSetMaster`，内核要求**初始用户命名空间**里的 `CAP_SYS_ADMIN`。
rootless podman 的 user namespace 里 `--cap-add=SYS_ADMIN` 只是 userns 内的能力，
对宿主 DRM 设备无效（实测表现：`Couldn't open /dev/dri/card0: Permission denied`，
即使挂载了设备，`drmSetMaster` 也会 EPERM）。所以脚本用 **rootful podman**：
容器 root = 宿主 root，能力完整，KMS 才能起来。

## 和旧 flatpak bwrap 方案对比

| 维度 | 旧方案 (flatpak + setuid bwrap) | 本方案 (rootful podman + 官方镜像) |
|------|----------------------------------|------------------------------------|
| 提权方式 | 把系统 `bwrap` 复制成 **root:root 4755 setuid**，再用 C 包装器往沙箱参数里注入 `--cap-add CAP_SYS_ADMIN` | `pkexec`/`run0` 提权跑 podman，`--user 0:0` + `--cap-add=SYS_ADMIN`，声明式 |
| 系统更新 | bwrap 被更新后旧副本失效，**必须重跑 install.sh** | 无此问题 |
| 沙箱参数 | C 包装器改写 bwrap 参数（脆弱难排错） | podman 命令行一目了然 |
| 依赖 | flatpak 运行时打包的 Sunshine 版本 | 官方镜像自带全套依赖，独立升级 |
| 捕获能力 | userns(flatpak)+ 注入 cap → 能 KMS | init ns 真 CAP_SYS_ADMIN → 能 KMS |

工程上 podman 的问题确实少：没有 setuid 副本、没有参数注入 hack、系统更新不会弄坏、
官方镜像与宿主机 Sunshine 版本解耦。

**已知代价**：rootful 容器以 root 运行（和 setuid bwrap 的权限模型相当，但更标准可控）；
配置目录会被写成 root 所有，`./run.sh stop` 会自动 chown 归还给当前用户。

## 目录内容

- `run.sh` — podman 启动脚本（rootful，pkexec/run0 提权）
- `install.sh` + `sunshine-podman.service` — 可选：安装为**系统级** systemd 服务（root）
- `README.md` — 本文件

## 快速开始

```bash
cd ~/vanilla-sunshine-podman

# 1) 启动（弹 polkit 授权窗口/密码提示；首次会自动拉镜像）
./run.sh

# 2) 看日志确认 KMS 捕获正常
./run.sh logs
#    期望: 无 "Failed to create session"，出现 DRM/KMS/encoder 相关 Info
#    反例: "Couldn't open: /dev/dri/card0: Permission denied" / "Unable to initialize capture method"

# 3) 打开 Web UI 完成初始化（随机用户名/密码在日志里）
#    https://localhost:47990
```

常用命令：

```bash
./run.sh pull      # 手动拉镜像（root 存储）
./run.sh stop      # 停止容器（并 chown 归还配置目录）
./run.sh restart   # 重启
./run.sh logs      # 看日志
./run.sh status    # 容器状态
./run.sh fg        # 前台运行，调试用
```

提权方式切换：`SUNSHINE_ELEVATE=run0 ./run.sh`（终端交互授权）或默认 `pkexec`；
已在 root / systemd 服务里调用时用 `SUNSHINE_ELEVATE=none ./run.sh`。

可选 systemd 集成（开机自启，root 服务）：

```bash
./install.sh            # 安装并启用（pkexec 授权；双 root 写入）
./install.sh --restart  # 安装并立即启动
./install.sh --uninstall# 卸载
```

> **Vanilla OS 3 的 /etc 是按 ABRoot root 分区隔离的**（upper 在 `/var/lib/abroot/etc/vos-{a,b}`），
> abroot 事务重启会切换 root——只写当前 /etc 的 unit 在切 root 后会"消失"（之前实测踩过）。
> `install.sh` 会把 unit + enable 符号链接**同时写入两个 root**，任何一侧启动都生效。
> 单元文件已去掉 `network-online.target` 依赖（本机它要开机 ~2 分钟才激活，会让服务显示
> inactive 排队假象）；Sunshine 用 host 网络无需等待，启动时资源未就绪由 `Restart=on-failure` 兜底。

## 配置

- **镜像**：默认 `lizardbyte/sunshine:latest-ubuntu-24.04`（Docker Hub，本机已配加速镜像）。
  可换 `SUNSHINE_IMAGE=ghcr.io/lizardbyte/sunshine:latest-ubuntu-24.04`。
- **配置目录**：默认 **`/var/lib/sunshine-podman`**（root 服务的数据放系统目录，不污染用户 home），
  挂载到容器内 `/home/lizard/.config/sunshine`（官方镜像入口就是 `/usr/bin/sunshine` 且镜像 ENV 固定
  `HOME=/home/lizard`，配置路径就是 `$HOME/.config/sunshine`；Docker README 里写的 `/config` 对当前镜像已失效，勿用）。
  - 目录由脚本用 pkexec/run0 提权创建，属主 root，跨用户、重启不丢；
  - 想放别处：`SUNSHINE_CONFIG=/path ./run.sh recreate`；仅当覆盖到 `$HOME` 下时，
    `stop` 才会 chown 归还给当前用户（默认系统目录无需此操作）；
  - **迁移旧数据**（沿用已设置好的 Web UI 账号/凭据）：
    ```bash
    # 从旧 home 目录（本脚本早期版本）迁移:
    pkexec bash -c 'mkdir -p /var/lib/sunshine-podman && cp -a /home/xiehuc/.config/sunshine-podman/. /var/lib/sunshine-podman/'
    # 或从 flatpak 版迁移:
    pkexec bash -c 'mkdir -p /var/lib/sunshine-podman && cp -a /home/xiehuc/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/. /var/lib/sunshine-podman/'
    ```
  （注意旧配置里 `capture = kms` 正适合本方案，见上方迁移命令）。
- **网络**：默认 `--network=host`（延迟最低、mDNS 发现正常）；要隔离可 `SUNSHINE_NETWORK=bridge`。
- **其他**：`SUNSHINE_NAME`、`SECCOMP=1`、`TZ` 见 `run.sh` 头部注释。

## 本机已自动处理的点

- **GPU**：检测到 NVIDIA Container Toolkit 的 CDI（`/run/cdi/nvidia.yaml`）时用
  `--device nvidia.com/gpu=all` 挂入 RTX 5070 Ti；无 CDI 回退 `/dev/dri/*`。
- **音频**：挂载用户 PipeWire socket（`/run/user/1000/pipewire-0`）。
- **输入**：root 容器直接挂 `/dev/uinput` + `/dev/input`（虚拟手柄可用，无 input 组权限问题）。
- **冲突检查**：启动前检测宿主机残留的 flatpak sunshine 并警告。

## 本机显示架构与捕获路径（GNOME Wayland + 虚拟 4K60 屏）

本机跑的是 GNOME Wayland（gnome-shell/Mutter），并配合 `sunshine-vos3-display-manager`
的 EDID 注入 + connector 开关提供无头 4K60 虚拟屏。捕获路径有两条，行为不同：

- **KMS 捕获**（`capture = kms`）：需要 DRM master。rootful 容器里能力已齐
  （CAP_SYS_ADMIN 在初始命名空间），**但**如果 Mutter 正持有 DRM master
  （在线桌面会话的正常状态），`drmSetMaster` 会得到 EBUSY/被拒。
  KMS 只在 compositor 未占用该设备时（如第二块 GPU、纯无头、或 compositor 释放）才通。
- **Portal 捕获**（portalgrab，flatpak 版实际在用的路径，配置里有 `portal_token`）：
  走 XDG Desktop Portal 屏幕分享（GNOME 弹授权窗），不需要 DRM master。
  容器里要走这条路，必须挂宿主 session bus + PipeWire + 设置 XDG_RUNTIME_DIR
  （`run.sh` 已自动处理：`/run/user/1000` 下的 `wayland-0`、`bus`、`pipewire-0`）。

如果你的目标是"容器里测试 KMS"，先看日志确认卡在哪一步（见下节第 2 条）；
若 Mutter 占着 master，容器里 KMS 起不来是预期行为——此时要么走 portal 捕获
（像 flatpak 一样），要么在 KMS 测试时让 compositor 释放设备。

## 已知限制与排错

1. **mDNS 自动发现**：当前官方 ubuntu-24.04 镜像缺 `libavahi-common`，
   日志会提示找不到 avahi 库 → Moonlight 无法自动发现主机，**手动填 IP 连接不受影响**。
   需要自动发现可换 `latest-debian-bookworm` 标签或改用 games-on-whales 的 sunshine 镜像。

2. **"Failed to create session" + "WAYLAND_DISPLAY has not been defined"**（你当前遇到的）：
   - 这两行总是成对出现：`WAYLAND_DISPLAY` 只是 wayland 后端的探针告警，不是根因；
   - 关键看它**之前**那几行——`/dev/dri/card0 -> nvidia-drm` 之后是什么：
     - `Couldn't get handle for DRM Framebuffer ... Probably not permitted` → 能力问题，
       rootful 下应消失（rootless 才会这样）；
     - `Device or resource busy` / `Couldn't set DRM master` → **Mutter 正持有 DRM master**，
       root 也拿不到，这是在线 GNOME 会话的预期行为（见上节）；
     - 若已挂好 session bus（本脚本默认挂），portalgrab 应能连上 dbus 并弹授权窗。
   - 快速定位：`./run.sh logs` 看 `nvidia-drm` 与 `Unable to initialize capture method` 之间的行。
3. **容器里 Qt 托盘导致 Web UI 掉线**：capture/编码器都正常，但日志出现
   `Could not find the Qt platform plugin "wayland"` / `could not connect to display` 后
   主循环退出、47990 没监听——容器内没有桌面，Qt 托盘初始化失败会连带退出主循环。
   已通过 `-e QT_QPA_PLATFORM=offscreen` 解决（容器无头跑，托盘本就不需要）。
   另外访问 Web UI 记得用 **https://localhost:47990**（自签证书，浏览器要点"继续访问"）。
3. **NVIDIA 编码器**：若 rootful 下 `nvenc` 仍报错，先试 `SECCOMP=1 ./run.sh`；
   仍不行则 `pkexec nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` 重新生成 CDI。

4. **端口冲突**：flatpak 版 Sunshine 还在跑时先停掉：
   `flatpak kill dev.lizardbyte.app.Sunshine`，否则 47984-48010 被占。

5. **pkexec 无授权代理**（如纯 SSH 会话）：改用 `SUNSHINE_ELEVATE=run0 ./run.sh`
   或先 `ssh -X` 保持图形会话；桌面终端里直接跑默认即可。

## 参考

- 官方镜像说明：<https://github.com/LizardByte/Sunshine/blob/master/DOCKER_README.md>
- Sunshine 文档：<https://docs.lizardbyte.dev/projects/sunshine/master/md_DOCKER__README.html>
