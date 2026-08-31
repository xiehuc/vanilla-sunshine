#!/usr/bin/env bash
# 安装 Sunshine 官方镜像的自动启动服务 —— Quadlet 方式
#
# 原理：podman 自带 systemd generator（quadlet），把 sunshine.container 放进
# /etc/containers/systemd/ 后，daemon-reload 即自动生成系统服务 sunshine.service。
#
# 提权方式（不用 sudo）:
#   SUNSHINE_ELEVATE=run0（默认，终端交互输密码，SSH 可用）
#   SUNSHINE_ELEVATE=pkexec（桌面弹 polkit 授权窗）
#   SUNSHINE_ELEVATE=none（已以 root 运行时）
# 所有 root 步骤打包成一次提权执行，只弹一次授权。
#
# 用法:
#   ./install.sh             # 安装 + enable + 立即启动
#   ./install.sh --uninstall # 卸载
#   ./install.sh --status    # 状态（只读，无需提权）

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_SRC="$SCRIPT_DIR/sunshine.container"
QUADLET_DST="/etc/containers/systemd/sunshine.container"
SERVICE="sunshine.service"

ELEVATE="${SUNSHINE_ELEVATE:-run0}"
case "$ELEVATE" in
  run0)   ELEV="run0" ;;
  pkexec) ELEV="pkexec" ;;
  none)   ELEV="" ;;
  *) echo "错误: SUNSHINE_ELEVATE 只支持 run0|pkexec|none"; exit 1 ;;
esac

command -v systemctl >/dev/null || { echo "错误: 找不到 systemctl"; exit 1; }
[ -f "$QUADLET_SRC" ] || { echo "错误: 找不到 $QUADLET_SRC"; exit 1; }
if [ -n "$ELEV" ]; then
  command -v "$ELEV" >/dev/null || { echo "错误: 找不到提权命令 $ELEV"; exit 1; }
fi

case "${1:-}" in
  --uninstall)
    echo "==> 卸载（提权: $ELEVATE）"
    ROOT="set -euo pipefail
systemctl disable --now $SERVICE 2>/dev/null || true
rm -f $QUADLET_DST
systemctl daemon-reload
"
    $ELEV /bin/bash -c "$ROOT"
    echo "完成。"
    ;;
  --status)
    systemctl status "$SERVICE" --no-pager 2>&1 | head -14 || true
    ;;
  *)
    ROOT="set -euo pipefail
mkdir -p /var/lib/sunshine-podman
install -m 644 -o root -g root '$QUADLET_SRC' '$QUADLET_DST'
systemctl daemon-reload
# quadlet 生成器会自动 enable（is-enabled 显示 generated），这里容忍失败
systemctl enable $SERVICE 2>/dev/null || echo '    （generated 单元已由生成器 enable，跳过）'
systemctl restart $SERVICE
"
    echo "==> 安装并启动（提权: $ELEVATE）"
    $ELEV /bin/bash -c "$ROOT"
    echo "==> 服务状态"
    systemctl status "$SERVICE" --no-pager 2>&1 | head -14 || true
    echo
    echo "完成。Web UI: https://localhost:47990"
    echo "日志: ${ELEV:-} journalctl -u $SERVICE -f"
    echo "说明: 服务由 quadlet 生成（/etc/containers/systemd/sunshine.container -> $SERVICE）；"
    echo "      若 abroot 切 root 后服务消失，重跑本脚本即可。"
    ;;
esac
