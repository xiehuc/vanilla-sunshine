#!/bin/sh
# 强开 DRM 端口(仅当 status = disconnected 时才写 "on")。
#
# 两种调用方式(同一份逻辑):
#   1) 容器内 global_prep_cmd(串流前):  /bin/sh force-connector.sh
#       默认读写容器内 bind 过来的 /connector-status(= 宿主所选 connector 的 status)。
#   2) 宿主 ExecStartPre(服务启动时):    /bin/sh force-connector.sh /sys/class/drm/<conn>/status
#       此时容器还没起、没有 /connector-status,所以直接传宿主的真实 sysfs 路径。
#
# 行为: 读取目标 status,只有在 disconnected 时才 echo on,然后 sleep 等内核重检测;
#       已 connected / 读不到 都安静退出(绝不把本来好的输出关掉、也不阻塞串流/启动)。
set -u

path="${1:-/connector-status}"
# 强开后留给内核/捕获线程重新检测该显示的时间（秒）
sleep_s=2

# 读不到就安静退出（比如没选强开、bind 未生效），不阻塞串流
status=$(cat "$path" 2>/dev/null || true)

case "$status" in
  disconnected)
    echo on > "$path"
    # 等内核完成热插拔/重检测，让 sunshine 能拿到新状态再开始捕获
    sleep "$sleep_s"
    ;;
esac
exit 0
