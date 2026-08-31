# vanilla-sunshine（rootful podman 版）

sunshine 提供了多种安装方式，但是在 vanillaOS/Fedora Silverblue 等不可变发行版里面，有很多坑。

1. deb 安装方式：vanilla 的 abroot 不支持本地deb包，故排除。
2. flatpak 方式：商店里面天然有，好安装。但不支持KMS捕获。新版本增加了XDG-Portal的捕获方式，天然支持wayland。但这个方式也很坑，首先是新屏幕需要授权，其次是显示器关机了，edid虚拟屏，DP诱骗器都没有信号。以前还有复制bwrap出来设置cap admin的方式绕过去。现在也封得差不多了。
3. docker方式：官方文档说不推荐（但实际上这个才是正解）
4. ps. 如果是接的电视：可以在设置（Gnome3）--电源--节电 里面关闭自动熄屏。这样就算电视关了。也可以串流，省去了弄一个虚拟显示器的方式。

该项目帮助安装一个root（为了KMS）的docker来启动sunshine。


=========

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
配置目录在 `/var/lib/sunshine-podman`（root 所有是预期，不污染用户 home）。

## 目录内容

- `sunshine.container` + `install.sh` — Quadlet 声明文件，装成系统级 systemd 服务（开机自启）
- `README.md` — 本文件

## 快速开始（推荐：systemd 服务方式）

```bash
cd ~/WORKROOT/vanilla-sunshine
./install.sh              # 安装 + enable + 立即启动（默认 run0，SSH 输密码；桌面可 SUNSHINE_ELEVATE=pkexec）

# 验证
systemctl status sunshine.service     # active (running)
ss -tlnp | grep 47990                 # 端口监听
# 日志: run0 journalctl -u sunshine.service -f
# 打开 https://localhost:47990 完成初始化（随机用户名/密码在日志里）
```

可选 systemd 集成（开机自启，root 服务）——**Quadlet 方式**：

```bash
./install.sh            # 安装并启用（pkexec 授权）
./install.sh --restart  # 安装并立即启动
./install.sh --uninstall# 卸载
```

SSH / 无 polkit 授权代理的环境用 run0（终端交互输密码）：

```bash
SUNSHINE_ELEVATE=run0 ./install.sh --restart
```

> Quadlet 是 podman 自带的 systemd generator：`sunshine.container` 放进
> `/etc/containers/systemd/` 后，`daemon-reload` 即自动生成系统服务 **`sunshine.service`**
> （`--replace --rm` 由生成器自带，重启/停止自动清理容器），不需要手写 unit。
> 注意：Vanilla OS 3 的 /etc 是 ABRoot 按 root 分区隔离的 overlay，若 abroot 事务切 root 后
> 服务消失，重跑一次 `./install.sh` 即可。
> 开机后服务若短暂显示 inactive(排队)，是 `network-online.target` 等待期（本机约 2 分钟），属正常；
> 未登录前会话 socket 不存在，容器会由 `Restart=on-failure` 重试，登录后自动成功。

## 配置

- **镜像**：默认 `lizardbyte/sunshine:latest-ubuntu-24.04`（Docker Hub，本机已配加速镜像）。
  可换 `SUNSHINE_IMAGE=ghcr.io/lizardbyte/sunshine:latest-ubuntu-24.04`。
- **配置目录**：默认 **`/var/lib/sunshine-podman`**（root 服务的数据放系统目录，不污染用户 home），
  挂载到容器内 `/home/lizard/.config/sunshine`（官方镜像入口就是 `/usr/bin/sunshine` 且镜像 ENV 固定
  `HOME=/home/lizard`，配置路径就是 `$HOME/.config/sunshine`；Docker README 里写的 `/config` 对当前镜像已失效，勿用）。
  - 属主 root，跨用户、重启不丢；想换路径就编辑 `sunshine.container` 里的 `Volume=` 行；
  - **迁移旧数据**（沿用已设置好的 Web UI 账号/凭据）：
    ```bash
    # 从旧 home 目录（本脚本早期版本）迁移:
    pkexec bash -c 'mkdir -p /var/lib/sunshine-podman && cp -a /home/xiehuc/.config/sunshine-podman/. /var/lib/sunshine-podman/'
    # 或从 flatpak 版迁移:
    pkexec bash -c 'mkdir -p /var/lib/sunshine-podman && cp -a /home/xiehuc/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/. /var/lib/sunshine-podman/'
    ```
  （注意旧配置里 `capture = kms` 正适合本方案，见上方迁移命令）。
- **网络**：默认 `--network=host`（延迟最低、mDNS 发现正常）；要隔离可 `SUNSHINE_NETWORK=bridge`。
- **其他**：镜像、环境变量、能力、设备、挂载都在 `sunshine.container` 里，直接编辑后重跑 `./install.sh` 生效。

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
  （`sunshine.container` 已配置：`/run/user/1000` 下的 `wayland-0`、`bus`、`pipewire-0`）。

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
   - 快速定位：`run0 journalctl -u sunshine.service` 看 `nvidia-drm` 与 `Unable to initialize capture method` 之间的行。
3. **容器里 Qt 托盘导致 Web UI 掉线**：capture/编码器都正常，但日志出现
   `Could not find the Qt platform plugin "wayland"` / `could not connect to display` 后
   主循环退出、47990 没监听——容器内没有桌面，Qt 托盘初始化失败会连带退出主循环。
   已通过 `-e QT_QPA_PLATFORM=offscreen` 解决（容器无头跑，托盘本就不需要）。
   另外访问 Web UI 记得用 **https://localhost:47990**（自签证书，浏览器要点"继续访问"）。
3. **NVIDIA 编码器**：若 rootful 下 `nvenc` 仍报错，试在 `sunshine.container` 的 `PodmanArgs=` 里去掉
   `--security-opt seccomp=unconfined`（或反之）后重跑 `./install.sh`；
   仍不行则 `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` 重新生成 CDI。

4. **端口冲突**：flatpak 版 Sunshine 还在跑时先停掉：
   `flatpak kill dev.lizardbyte.app.Sunshine`，否则 47984-48010 被占。

5. **提权**：默认 `run0`（SSH/终端交互输密码）；桌面要弹窗用 `SUNSHINE_ELEVATE=pkexec ./install.sh`；
   纯无 TTY 的环境两者都会失败，用 `ssh -t` 或桌面终端。

## 参考

- 官方镜像说明：<https://github.com/LizardByte/Sunshine/blob/master/DOCKER_README.md>
- Sunshine 文档：<https://docs.lizardbyte.dev/projects/sunshine/master/md_DOCKER__README.html>
