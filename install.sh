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
#   ./install.sh             # 安装 + enable + 立即启动（安装时交互选择要"强开"的 DRM 端口）
#   ./install.sh --uninstall # 卸载
#   ./install.sh --status    # 状态（只读，无需提权）
#
# 强开 DRM 端口：某些场景（如电视已断电但仍想串流）显示器没有有效信号，
# KMS 捕获会失败。做法：在 sunshine.conf 设 global_prep_cmd，让 Sunshine 在每次
# 串流开始前调用容器内的 force-connector.sh，把选中的 connector 强开：
#   - sunshine.container 里用占位符 @CONNECTOR@ 写的 bind 行，被 sed 替换成所选
#     connector，把该接口的 status 以 rw 挂进容器（固定路径 /connector-status）；
#   - force-connector.sh 被拷进配置目录并挂进容器，由 global_prep_cmd 调用；
#     它只在 status = disconnected 时才写 "on"（已 connected 则不动）。
# 非交互/CI 可用环境变量覆盖选择: SUNSHINE_FORCE_CONNECTOR=card0-HDMI-A-1|空串表示不开

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_SRC="$SCRIPT_DIR/sunshine.container"
QUADLET_DST="/etc/containers/systemd/sunshine.container"
SERVICE="sunshine.service"

# 容器内 bind 目标固定路径（force-connector.sh 读写它，勿随意改）
CONTAINER_STATUS_PATH="/connector-status"
# 强开脚本（宿主机在配置目录里，挂进容器即 /home/lizard/.config/sunshine/force-connector.sh）
FORCE_SCRIPT="$SCRIPT_DIR/force-connector.sh"
CONFIG_DIR="/var/lib/sunshine-podman"
SUNSHINE_CONF="$CONFIG_DIR/sunshine.conf"
GP_LINE='global_prep_cmd = [{"do":"/bin/sh /home/lizard/.config/sunshine/force-connector.sh","undo":""}]'

# systemd drop-in：服务启动时（容器起来前）先在宿主强开 connector，
# 解决"电视关着就启动服务 -> sunshine 初始化 KMS 时看不到显示"的场景1
DROPIN_DIR="/etc/systemd/system/$SERVICE.d"
DROPIN="$DROPIN_DIR/force-connector.conf"

ELEVATE="${SUNSHINE_ELEVATE:-run0}"
case "$ELEVATE" in
  run0)   ELEV="run0" ;;
  pkexec) ELEV="pkexec" ;;
  none)   ELEV="" ;;
  *) echo "错误: SUNSHINE_ELEVATE 只支持 run0|pkexec|none"; exit 1 ;;
esac

command -v systemctl >/dev/null || { echo "错误: 找不到 systemctl"; exit 1; }
[ -f "$QUADLET_SRC" ] || { echo "错误: 找不到 $QUADLET_SRC"; exit 1; }
[ -f "$FORCE_SCRIPT" ] || { echo "错误: 找不到 $FORCE_SCRIPT"; exit 1; }
if [ -n "$ELEV" ]; then
  command -v "$ELEV" >/dev/null || { echo "错误: 找不到提权命令 $ELEV"; exit 1; }
fi

# ---------- 列出宿主机 DRM 端口 ----------
detect_connectors() {
  DETECTED_CONNS=()
  DETECTED_STATS=()
  local f
  for f in /sys/class/drm/*/status; do
    [ -f "$f" ] || continue
    DETECTED_CONNS+=("$(basename "$(dirname "$f")")")   # 如 card0-HDMI-A-1
    DETECTED_STATS+=("$(cat "$f" 2>/dev/null || echo '?')")
  done
}

# ---------- 交互选择要"强开"的 DRM 端口（输出 FORCE_CONNECTOR；空串=不开） ----------
choose_connector() {
  detect_connectors
  FORCE_CONNECTOR="${SUNSHINE_FORCE_CONNECTOR:-}"

  # 环境变量已显式指定 -> 不打扰
  if [ -n "${SUNSHINE_FORCE_CONNECTOR+x}" ]; then
    if [ -n "$FORCE_CONNECTOR" ]; then
      echo "==> 强开 DRM 端口: $FORCE_CONNECTOR（SUNSHINE_FORCE_CONNECTOR 指定）"
    else
      echo "==> 不开启强开（SUNSHINE_FORCE_CONNECTOR 为空）"
    fi
    return 0
  fi

  # 默认值：优先 HDMI-A-1，否则第一个 connector
  local i default_idx="" default_conn=""
  for i in "${!DETECTED_CONNS[@]}"; do
    if [ "${DETECTED_CONNS[$i]}" = "card0-HDMI-A-1" ]; then default_idx="$i"; break; fi
  done
  if [ -z "$default_idx" ] && [ "${#DETECTED_CONNS[@]}" -gt 0 ]; then default_idx=0; fi
  [ -n "$default_idx" ] && default_conn="${DETECTED_CONNS[$default_idx]}"

  if [ ! -t 0 ]; then   # 无 TTY（管道/CI）：用默认值，避免卡死
    echo "==> 无交互终端，采用默认: ${default_conn:-0(不开)}"
    FORCE_CONNECTOR="$default_conn"
    return 0
  fi

  while true; do
    echo
    echo "=================================================="
    echo "  Sunshine 串流前要\"强开\"哪个 DRM 端口？"
    echo "  （强开 = 串流前检查，disconnected 才写 on）"
    echo "=================================================="
    echo "  0) 不开启（跳过）"
    if [ "${#DETECTED_CONNS[@]}" -gt 0 ]; then
      for i in "${!DETECTED_CONNS[@]}"; do
        printf '  %d) %-22s 当前: %s\n' "$((i+1))" "${DETECTED_CONNS[$i]}" "${DETECTED_STATS[$i]}"
      done
    else
      echo "  (未在 /sys/class/drm 下检测到 connector，可手动输入，如 card0-HDMI-A-1)"
    fi
    printf '  默认: %s\n' "${default_conn:-0(不开)}"
    read -rp "  你的选择（回车=默认 / 数字 / 完整名如 card0-HDMI-A-1）: " ans
    case "$ans" in
      "") FORCE_CONNECTOR="$default_conn"; break ;;
      "0") FORCE_CONNECTOR=""; break ;;
      *[!0-9]*) FORCE_CONNECTOR="$ans" ;;
      *)
        local n=$((ans-1))
        if [ "$ans" -ge 1 ] && [ "$n" -lt "${#DETECTED_CONNS[@]}" ]; then
          FORCE_CONNECTOR="${DETECTED_CONNS[$n]}"
        else
          echo "  无效选项，请重试。"; continue
        fi
        ;;
    esac
    if [ -n "$FORCE_CONNECTOR" ] && [ -e "/sys/class/drm/$FORCE_CONNECTOR/status" ]; then
      break
    fi
    if [ -z "$FORCE_CONNECTOR" ]; then break; fi
    echo "  无法找到 /sys/class/drm/$FORCE_CONNECTOR/status，请重试。"
    FORCE_CONNECTOR=""
  done
  [ -n "$FORCE_CONNECTOR" ] && echo "==> 强开 DRM 端口: $FORCE_CONNECTOR" \
                          || echo "==> 不开启强开"
}

case "${1:-}" in
  --uninstall)
    echo "==> 卸载（提权: $ELEVATE）"
    ROOT="set -euo pipefail
systemctl disable --now $SERVICE 2>/dev/null || true
rm -f $QUADLET_DST $CONFIG_DIR/force-connector.sh $DROPIN
rmdir $DROPIN_DIR 2>/dev/null || true
# 从 sunshine.conf 移除 global_prep_cmd（保留其余配置）
sed -i '/^[[:space:]]*global_prep_cmd[[:space:]]*=/d' $SUNSHINE_CONF 2>/dev/null || true
systemctl daemon-reload
"
    $ELEV /bin/bash -c "$ROOT"
    echo "完成。"
    ;;
  --status)
    systemctl status "$SERVICE" --no-pager 2>&1 | head -14 || true
    ;;
  *)
    echo "==> 安装并启动（提权: $ELEVATE）"
    choose_connector

    # ---------- 生成部署内容（均为非 root 可读文件，逻辑集中在普通 shell） ----------
    TMP_CONTAINER="$(mktemp)"; TMP_CONF="$(mktemp)"; TMP_SCRIPT="$(mktemp)"; TMP_DROPIN="$(mktemp)"
    trap 'rm -f "$TMP_CONTAINER" "$TMP_CONF" "$TMP_SCRIPT" "$TMP_DROPIN"' EXIT
    chmod 644 "$TMP_CONTAINER" "$TMP_CONF" "$TMP_DROPIN"; chmod 755 "$TMP_SCRIPT"

    # 1) sunshine.container：sed 替换 @CONNECTOR@，或删掉该 bind 行
    if [ -n "$FORCE_CONNECTOR" ]; then
      sed "s/@CONNECTOR@/$FORCE_CONNECTOR/g" "$QUADLET_SRC" > "$TMP_CONTAINER"
      echo "    已把 @CONNECTOR@ 替换为 $FORCE_CONNECTOR"
    else
      sed '/^Volume=\/sys\/class\/drm\/@CONNECTOR@\/status:/d' "$QUADLET_SRC" > "$TMP_CONTAINER"
      echo "    未选择端口，已移除强开 bind 行"
    fi

    # 2) sunshine.conf：清掉旧的 global_prep_cmd，选中时再追加
    if [ -f "$SUNSHINE_CONF" ]; then
      cp "$SUNSHINE_CONF" "$TMP_CONF"
    else
      : > "$TMP_CONF"
    fi
    sed -i '/^[[:space:]]*global_prep_cmd[[:space:]]*=/d' "$TMP_CONF"
    if [ -n "$FORCE_CONNECTOR" ]; then
      printf '%s\n' "$GP_LINE" >> "$TMP_CONF"
      echo "    已设置 global_prep_cmd（串流前调用 force-connector.sh）"
    else
      echo "    未设置 global_prep_cmd"
    fi

    # 3) force-connector.sh 准备拷贝
    cp "$FORCE_SCRIPT" "$TMP_SCRIPT"

    # 4) systemd drop-in：服务启动时先调 force-connector.sh（传宿主真实 sysfs 路径）。
    #    容器未起、无 /connector-status，故用脚本的宿主路径参数模式。场景1：电视关着启动服务。
    if [ -n "$FORCE_CONNECTOR" ]; then
      printf '%s\n' \
        "[Service]" \
        "ExecStartPre=-/bin/sh $CONFIG_DIR/force-connector.sh /sys/class/drm/$FORCE_CONNECTOR/status" \
        > "$TMP_DROPIN"
      echo "    已生成启动时强开 drop-in（$FORCE_CONNECTOR）"
    fi

    # ---------- root 步骤（一次提权） ----------
    ROOT="set -euo pipefail
mkdir -p $CONFIG_DIR
install -m 644 -o root -g root '$TMP_CONTAINER' '$QUADLET_DST'
install -m 644 -o root -g root '$TMP_CONF' '$SUNSHINE_CONF'
if [ -n '$FORCE_CONNECTOR' ]; then
  mkdir -p '$DROPIN_DIR'
  install -m 644 -o root -g root '$TMP_SCRIPT' '$CONFIG_DIR/force-connector.sh'
  install -m 644 -o root -g root '$TMP_DROPIN' '$DROPIN'
else
  rm -f '$CONFIG_DIR/force-connector.sh' '$DROPIN'
  rmdir '$DROPIN_DIR' 2>/dev/null || true
fi
systemctl daemon-reload
# quadlet 生成器会自动 enable（is-enabled 显示 generated），这里容忍失败
systemctl enable $SERVICE 2>/dev/null || echo '    （generated 单元已由生成器 enable，跳过）'
systemctl restart $SERVICE
"
    $ELEV /bin/bash -c "$ROOT"
    echo "==> 服务状态"
    systemctl status "$SERVICE" --no-pager 2>&1 | head -14 || true
    echo
    echo "完成。Web UI: https://localhost:47990"
    echo "日志: ${ELEV:-} journalctl -u $SERVICE -f"
    echo "说明: 服务由 quadlet 生成（/etc/containers/systemd/sunshine.container -> $SERVICE）；"
    echo "      若 abroot 切 root 后服务消失，重跑本脚本即可。"
    if [ -n "$FORCE_CONNECTOR" ]; then
      echo "强开 $FORCE_CONNECTOR:"
      echo "  - 服务启动时宿主先 echo on（drop-in ExecStartPre）→ 解决电视关着启动服务"
      echo "  - 串流前 global_prep_cmd 调 force-connector.sh（disconnected 才 on + sleep）→ 解决运行中关电视"
    fi
    ;;
esac
