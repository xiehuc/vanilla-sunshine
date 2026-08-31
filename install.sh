#!/usr/bin/env bash
# 安装 Sunshine-podman 系统级 systemd 服务（rootful podman）
#
# Vanilla OS 3 的 /etc 是 ABRoot 按 root 分区隔离的 overlay
# （upper 在 /var/lib/abroot/etc/vos-{a,b}），abroot 事务/重启会切换 root：
# 只写当前 root 的 /etc，切到另一个 root 后 unit 就"消失"。
# 本脚本把 unit + enable 符号链接**同时写入两个 root 的 /etc upper**，
# 保证无论从 A 还是 B 启动，服务都存在且启用。
#
# 用法:
#   ./install.sh            # 双 root 安装 + enable（不启动）
#   ./install.sh --restart  # 同上，并立即启动
#   ./install.sh --uninstall# 双 root 卸载
#   ./install.sh --status   # 查看状态
#
# 注意: 需要在桌面终端运行（pkexec 弹 polkit 授权窗）；SSH 无授权代理会失败。

set -euo pipefail

UNIT_NAME="sunshine-podman.service"
SRC="$HOME/vanilla-sunshine-podman/$UNIT_NAME"
ABROOT_ETC="/var/lib/abroot/etc"
SRC_ABS="$(readlink -f "$SRC")"

command -v systemctl >/dev/null || { echo "错误: 找不到 systemctl"; exit 1; }
command -v pkexec >/dev/null || { echo "错误: 找不到 pkexec"; exit 1; }
[ -f "$SRC" ] || { echo "错误: 找不到 $SRC"; exit 1; }
[ -d "$ABROOT_ETC/vos-a" ] && [ -d "$ABROOT_ETC/vos-b" ] || { echo "错误: 未找到 $ABROOT_ETC/vos-{a,b}，这不是 Vanilla OS 3 的 ABRoot /etc 布局？"; exit 1; }

ACTION="${1:-}"

# 双 root 写入/清理逻辑（在 pkexec 的 root shell 里执行，全部用绝对路径）
DUAL_SCRIPT='
set -euo pipefail
SRC="'"$SRC_ABS"'"
UNIT="'"$UNIT_NAME"'"
ETC="/var/lib/abroot/etc"
for d in "$ETC"/vos-a "$ETC"/vos-b; do
  [ -d "$d" ] || continue
  case "${1:-install}" in
    install)
      install -m 644 -o root -g root "$SRC" "$d/systemd/system/$UNIT"
      mkdir -p "$d/systemd/system/multi-user.target.wants"
      ln -sfn "../$UNIT" "$d/systemd/system/multi-user.target.wants/$UNIT"
      echo "    已写入 $d"
      ;;
    uninstall)
      rm -f "$d/systemd/system/$UNIT" "$d/systemd/system/multi-user.target.wants/$UNIT"
      echo "    已清理 $d"
      ;;
  esac
done
'

case "$ACTION" in
  --uninstall)
    echo "==> 双 root 卸载（会弹 polkit 授权）"
    pkexec /bin/bash -c "$DUAL_SCRIPT uninstall"
    pkexec systemctl daemon-reload
    echo "完成。"
    ;;
  --status)
    pkexec systemctl status "$UNIT_NAME" --no-pager 2>&1 | head -14 || true
    ;;
  *)
    echo "==> [1/2] 双 root 安装 unit + enable（会弹 polkit 授权）"
    pkexec /bin/bash -c "$DUAL_SCRIPT install"
    pkexec systemctl daemon-reload
    echo "==> [2/2] 服务状态"
    if [ "$ACTION" = "--restart" ]; then
      echo "==> 立即启动"
      pkexec systemctl restart "$UNIT_NAME"
    fi
    pkexec systemctl status "$UNIT_NAME" --no-pager 2>&1 | head -14 || true
    echo
    echo "完成。Web UI: https://localhost:47990"
    echo "日志: pkexec journalctl -u $UNIT_NAME -f   或   ~/vanilla-sunshine-podman/run.sh log"
    echo "注意: 若开机后短暂显示 inactive(排队)，是 network-online.target 等待期（本机约 2 分钟），属正常现象，稍后自动启动。"
    ;;
esac
