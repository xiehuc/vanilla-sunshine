#!/usr/bin/env bash
# =============================================================================
# Sunshine 官方镜像 —— podman 启动脚本（rootful，KMS 捕获验证用）
#
# 为什么必须 root：
#   KMS/DRM master 屏幕捕获要求"初始用户命名空间"里的 CAP_SYS_ADMIN，
#   rootless podman 的 user namespace 给不了这个能力（drmsetmaster -> EPERM），
#   所以本脚本用 rootful podman 运行容器，容器 root = 宿主 root，能力完整。
#
# 提权方式（不使用 sudo）:
#   pkexec（默认，走 polkit 图形/密码授权） 或 run0（systemd-run 交互式终端授权）
#   环境变量 SUNSHINE_ELEVATE=pkexec|run0|none 切换（none 用于已以 root 运行，
#   例如 systemd 系统服务里调用本脚本）。
#
# 用法:
#   ./run.sh [start|stop|restart|logs|status|fg|pull]
#
# 环境变量（均有默认值）:
#   SUNSHINE_IMAGE    镜像标签，默认 docker.io/lizardbyte/sunshine:latest-ubuntu-24.04
#   SUNSHINE_NAME     容器名，默认 sunshine
#   SUNSHINE_CONFIG   配置目录（挂到容器内 /home/lizard/.config/sunshine），
#                     默认 /var/lib/sunshine-podman（root 服务的数据放系统目录，不占用户 home；
#                     只有显式覆盖到 $HOME 下时，stop 才会 chown 归还给当前用户）
#   SUNSHINE_NETWORK  host | bridge，默认 host（低延迟 + mDNS 发现正常）
#   SUNSHINE_ELEVATE  pkexec | run0 | none，默认 pkexec
#   SECCOMP=0         关闭 seccomp=unconfined（默认开启：podman 默认 seccomp 会拦部分 DRM ioctl，
#                     KMS/编码器探测可能失败；root 容器测试场景直接放开）
# =============================================================================

set -euo pipefail

# ------------------------- 配置（可按需修改） -------------------------
IMAGE="${SUNSHINE_IMAGE:-docker.io/lizardbyte/sunshine:latest-ubuntu-24.04}"
NAME="${SUNSHINE_NAME:-sunshine}"
CONFIG_DIR="${SUNSHINE_CONFIG:-/var/lib/sunshine-podman}"
NETWORK="${SUNSHINE_NETWORK:-host}"
ELEVATE="${SUNSHINE_ELEVATE:-pkexec}"
SECCOMP="${SECCOMP:-1}"
TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}"

# 提权命令组装（不用 sudo）
case "$ELEVATE" in
  pkexec) ELEV_CMD="pkexec" ;;
  run0)   ELEV_CMD="run0" ;;
  none)   ELEV_CMD="" ;;
  *) echo "错误: SUNSHINE_ELEVATE 只支持 pkexec|run0|none"; exit 1 ;;
esac
POD="$ELEV_CMD podman"          # 例如 "pkexec podman" / "podman"

# ------------------------- 预检查 -------------------------
command -v podman >/dev/null || { echo "错误: 未找到 podman"; exit 1; }
if [ -n "$ELEV_CMD" ]; then
  command -v "$ELEV_CMD" >/dev/null || { echo "错误: 未找到提权命令 $ELEV_CMD"; exit 1; }
fi

# 若旧 flatpak 版 Sunshine 还在跑，会抢端口/DRM，先警告
if pgrep -x sunshine >/dev/null 2>&1; then
  echo "!! 警告: 检测到宿主机已有 sunshine 进程（可能是 flatpak 版）。"
  echo "!!       建议先停止它再启动容器，否则端口(47984-48010)与 KMS 捕获会冲突。"
fi

# ------------------------- 组装参数 -------------------------
ARGS=()

ARGS+=(run -d --name "$NAME" --restart=unless-stopped)
ARGS+=(--ipc=host --user 0:0)
ARGS+=(--cap-add=SYS_ADMIN --cap-add=SYS_NICE)
# 默认放开 seccomp：DRM/编码器 ioctl 在默认 profile 下可能被拒
[ "$SECCOMP" != "0" ] && ARGS+=(--security-opt seccomp=unconfined)
ARGS+=(-e TZ="$TZ")
# 容器内无桌面，Qt 托盘走 offscreen，避免 "no Qt platform plugin" 导致主循环退出、Web UI 掉线
ARGS+=(-e QT_QPA_PLATFORM=offscreen)

# 网络：host 直通（延迟最低，Moonlight 自动发现(mDNS)正常）
if [ "$NETWORK" = "bridge" ]; then
  ARGS+=(-p 47984-47990:47984-47990/tcp -p 48010:48010 -p 47998-48000:47998-48000/udp)
else
  ARGS+=(--network=host)
fi

# 配置目录：官方镜像入口是 /usr/bin/sunshine，且镜像 ENV 固定 HOME=/home/lizard，
# 所以配置实际落在容器内 /home/lizard/.config/sunshine（README 里的 /config 约定已失效）。
if [ ! -d "$CONFIG_DIR" ]; then
  echo "==> 创建配置目录 $CONFIG_DIR（需要提权）"
  $ELEV_CMD mkdir -p "$CONFIG_DIR"
fi
ARGS+=(-v "$CONFIG_DIR":/home/lizard/.config/sunshine)

# --- GPU / 显示设备 ---
# NVIDIA: 优先用 Container Toolkit 的 CDI 设备（含 nvidia0/nvidia-uvm/dri，root 下无权限问题）
if [ -f /run/cdi/nvidia.yaml ] || [ -f /etc/cdi/nvidia.yaml ]; then
  ARGS+=(--device nvidia.com/gpu=all)
else
  [ -e /dev/dri/card0 ] && ARGS+=(--device /dev/dri/card0)
  [ -e /dev/dri/renderD128 ] && ARGS+=(--device /dev/dri/renderD128)
fi

# --- 输入设备（虚拟手柄）: root 容器无权限障碍 ---
[ -e /dev/uinput ] && ARGS+=(--device /dev/uinput)
[ -d /dev/input ] && ARGS+=(--device /dev/input)

# --- 桌面会话挂载（Wayland / D-Bus / 音频）---
# 宿主机是 GNOME Wayland 会话（Mutter 持有 DRM master）：
#   - 若走 KMS 捕获，只需要上面的 DRM 设备；
#   - 若 KMS 被 compositor 占用（EBUSY），Sunshine 会回退到 wayland / portal 捕获，
#     此时必须把宿主 Wayland socket、session bus、PipeWire 挂进容器，并设置对应环境变量。
# 注意: 容器以 root 运行，XDG_RUNTIME_DIR 指向宿主 /run/user/<uid>（root 可写，测试无碍）。
UID_NUM="$(id -u)"
RT="/run/user/$UID_NUM"
[ -S "$RT/wayland-0" ]  && ARGS+=(-v "$RT/wayland-0:$RT/wayland-0" -e WAYLAND_DISPLAY=wayland-0)
[ -S "$RT/bus" ]        && ARGS+=(-v "$RT/bus:$RT/bus" -e DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus")
[ -S "$RT/pipewire-0" ] && ARGS+=(-v "$RT/pipewire-0:$RT/pipewire-0")
ARGS+=(-e XDG_RUNTIME_DIR="$RT")
if [ -S "$RT/pipewire-0" ]; then
  # 兼容部分组件硬编码 /tmp/pipewire-0 的情况
  ARGS+=(-v "$RT/pipewire-0:/tmp/pipewire-0" -e PIPEWIRE_RUNTIME_DIR=/tmp)
elif [ -d "$RT/pulse" ]; then
  ARGS+=(-v "$RT/pulse:/tmp/pulse" -e PULSE_SERVER=unix:/tmp/pulse/native)
fi

# ------------------------- 动作 -------------------------
ACTION="${1:-start}"

case "$ACTION" in
  pull)
    $POD pull "$IMAGE"
    ;;
  start)
    if $POD ps --format '{{.Names}}' | grep -qx "$NAME"; then
      echo "==> $NAME 已在运行:"
      $POD ps --filter "name=$NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
      echo "    Web UI: https://localhost:47990   （用户名/密码首次启动时在日志里）"
      exit 0
    fi
    if $POD ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
      echo "==> 启动已有容器 $NAME"
      $POD start "$NAME"
    else
      echo "==> 创建并启动容器 $NAME（提权: $ELEVATE）"
      echo "    镜像: $IMAGE"
      echo "    配置: $CONFIG_DIR -> 容器内 /home/lizard/.config/sunshine"
      $POD "${ARGS[@]}" "$IMAGE"
    fi
    echo "==> 完成。查看日志: $0 logs   Web UI: https://localhost:47990"
    echo "    验证 KMS 捕获: $0 logs 里应出现 DRM/KMS 相关 Info，无 'Failed to create session'"
    ;;
  stop)
    if $POD ps --format '{{.Names}}' | grep -qx "$NAME"; then
      $POD stop "$NAME"
    else
      echo "==> $NAME 未在运行"
    fi
    # 仅当配置目录被显式覆盖到 $HOME 下时，停止后 chown 归还给当前用户；
    # 默认 /var/lib/... 本来就是 root 所有，无需处理。
    if [[ "$CONFIG_DIR" == "$HOME"/* ]] && [ -d "$CONFIG_DIR" ]; then
      $ELEV_CMD chown -R "$UID_NUM:$UID_NUM" "$CONFIG_DIR" 2>/dev/null || true
    fi
    ;;
  restart)
    $POD stop "$NAME" 2>/dev/null || true
    $POD start "$NAME" || { echo "容器不存在，重新创建"; exec "$0" start; }
    ;;
  logs)
    $POD logs -f "$NAME"
    ;;
  log)
    # 一次性输出当前日志（不跟随），方便排查粘贴
    $POD logs --tail 80 "$NAME"
    ;;
  status)
    $POD ps -a --filter "name=$NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  recreate)
    # 删掉旧参数容器并用当前脚本参数重建（脚本更新后容器不会自动带新挂载）
    $POD rm -f "$NAME" 2>/dev/null || true
    exec "$0" start
    ;;
  dry)
    echo "提权: $ELEVATE  镜像: $IMAGE  容器: $NAME"
    echo "最终命令:"
    echo "  $POD ${ARGS[@]} $IMAGE"
    ;;
  fg)
    # 前台调试: 跳过 run -d --name --restart（与 --rm 冲突），其余参数一致
    $POD ps -a --format '{{.Names}}' | grep -qx "$NAME" && $POD rm -f "$NAME" >/dev/null 2>&1 || true
    exec $POD run --rm --name "$NAME" "${ARGS[@]:5}" "$IMAGE"
    ;;
  *)
    echo "用法: $0 [start|stop|restart|recreate|logs|log|status|fg|pull|dry]"; exit 1
    ;;
esac
