#!/bin/bash
# entrypoint.sh
#
# 启动 OpenConnect 并以 site-to-site 方式运行：
#   - 开启内核 IP 转发
#   - 通过 vpnc-script-nat 在隧道建立后自动配置 iptables NAT/FORWARD 规则
#   - 容器后面的局域网主机只需把默认网关/路由指向本容器，即可通过 VPN 隧道访问对端网络
#
# 必需环境变量：
#   VPN_GATEWAY    VPN 服务器地址 (host 或 host:port)
#   VPN_USERNAME   VPN 用户名
#
# 可选环境变量：
#   VPN_PASSWORD    VPN 密码（通过 stdin 传入，不落盘）
#   VPN_PASSWORD_FILE  存放密码的文件路径（优先级低于 VPN_PASSWORD）
#   VPN_PROTOCOL    协议，默认 anyconnect（可选 nc/gp/pulse/f5/fortinet/array 等，取决于 openconnect 支持）
#   VPN_SERVERCERT  服务器证书指纹，用于跳过证书校验告警
#   VPN_EXTRA_OPTS  追加给 openconnect 的其它参数，例如 "--authgroup=xxx --no-dtls"
#   TUN_IF          tun 设备名，默认 tun0
#   LAN_SUBNET      需要 NAT 出去的本地网段，逗号分隔，如 "192.168.1.0/24,10.0.0.0/24"
#   RECONNECT_DELAY 断线后重连等待秒数，默认 5

set -euo pipefail

: "${VPN_GATEWAY:?必须设置环境变量 VPN_GATEWAY（VPN 服务器地址）}"
: "${VPN_USERNAME:?必须设置环境变量 VPN_USERNAME（VPN 用户名）}"
: "${VPN_PROTOCOL:=anyconnect}"
: "${TUN_IF:=tun0}"
: "${RECONNECT_DELAY:=5}"
export LAN_SUBNET="${LAN_SUBNET:-}"

echo "[entrypoint] 开启内核 IP 转发 (net.ipv4.ip_forward)"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 \
    || echo 1 > /proc/sys/net/ipv4/ip_forward \
    || echo "[entrypoint] 警告：无法设置 ip_forward，请确认容器已加 --cap-add=NET_ADMIN 或 --privileged 运行"

if [ ! -c /dev/net/tun ]; then
    echo "[entrypoint] 错误：/dev/net/tun 不存在，请以 --device /dev/net/tun 启动容器" >&2
    exit 1
fi

# 解析密码
if [ -z "${VPN_PASSWORD:-}" ] && [ -n "${VPN_PASSWORD_FILE:-}" ] && [ -f "${VPN_PASSWORD_FILE}" ]; then
    VPN_PASSWORD="$(cat "${VPN_PASSWORD_FILE}")"
fi

build_cmd() {
    ARGS=(
        openconnect
        --protocol="${VPN_PROTOCOL}"
        --interface="${TUN_IF}"
        --script=/usr/local/bin/vpnc-script-nat
        --background=no
        -u "${VPN_USERNAME}"
    )
    if [ -n "${VPN_SERVERCERT:-}" ]; then
        ARGS+=(--servercert="${VPN_SERVERCERT}")
    fi
    if [ -n "${VPN_EXTRA_OPTS:-}" ]; then
        # shellcheck disable=SC2206
        EXTRA=(${VPN_EXTRA_OPTS})
        ARGS+=("${EXTRA[@]}")
    fi
    ARGS+=("${VPN_GATEWAY}")
    echo "${ARGS[@]}"
}

term_handler() {
    echo "[entrypoint] 收到停止信号，退出"
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    exit 0
}
trap term_handler SIGTERM SIGINT

echo "[entrypoint] OpenConnect 版本: $(cat /VERSION 2>/dev/null || echo unknown)"

while true; do
    CMD=$(build_cmd)
    echo "[entrypoint] 启动: ${CMD} --passwd-on-stdin"

    if [ -n "${VPN_PASSWORD:-}" ]; then
        echo "${VPN_PASSWORD}" | eval "${CMD} --passwd-on-stdin" &
    else
        eval "${CMD}" &
    fi
    child=$!
    wait "$child"

    echo "[entrypoint] OpenConnect 进程已退出，${RECONNECT_DELAY} 秒后尝试重连..."
    sleep "${RECONNECT_DELAY}"
done
