# OpenConnect Site-to-Site 容器

基于源码编译最新版 [OpenConnect](https://gitlab.com/openconnect/openconnect) 的容器镜像，
通过 GitHub Actions 使用 `podman` 自动构建 `linux/amd64` 与 `linux/arm64` 双架构镜像并推送到 Docker Hub，
容器启动后以 site-to-site 方式运行，通过 `iptables NAT` 让本地网络中的其它主机可以经由本容器访问 VPN 对端网络。

## 目录结构

```
.
├── Dockerfile                      # 多阶段构建：编译 OpenConnect + 精简运行镜像
├── entrypoint.sh                   # 容器入口：开启 IP 转发、启动 openconnect、断线重连
├── vpnc-script-nat                 # 包装官方 vpnc-script，隧道 up/down 时自动配置 NAT
├── docker-compose.example.yml      # 运行示例
└── .github/workflows/build.yml     # CI：定时/手动构建并推送镜像
```

## 工作原理

1. **构建阶段**：Dockerfile 在 builder 阶段用 GitLab API 获取 OpenConnect 最新 tag（或使用
   workflow 传入的具体版本号），下载源码 tarball 编译安装。
2. **运行阶段**：精简的 Debian slim 镜像仅安装运行所需的动态库、`iproute2`、`iptables`、
   `vpnc-scripts`。
3. **site-to-site + NAT**：容器启动时通过 `entrypoint.sh` 开启内核 `ip_forward`，
   OpenConnect 使用自定义脚本 `vpnc-script-nat`：先调用官方 `vpnc-script` 完成 tun
   接口/路由配置，隧道建立（`reason=connect`）后自动追加
   `iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE`
   以及 `FORWARD` 链放行规则，使容器所在局域网中的其它主机只要把默认路由/网关指向
   本容器，即可经隧道访问对端内网，实现 site-to-site 互通；断线时自动清理规则。

## CI/CD（GitHub Actions）

- **触发方式**：`workflow_dispatch`（手动）+ `schedule`（每周日 03:00 UTC，约等于每 7 天一次）。
- **版本号**：跟随 OpenConnect 上游 GitLab 最新 tag，例如 `9.13`。若本次未检测到新版本，
  仍会用相同版本号重新构建并 **覆盖推送**（用于拉取最新基础镜像安全补丁），同时始终覆盖推送
  `latest` 标签。
- **多架构**：使用 `docker/setup-qemu-action` 提供 arm64 模拟环境，`podman build --platform`
  分别构建 amd64/arm64 镜像，再用 `podman manifest` 合并为一个多架构 manifest 推送到
  Docker Hub。

### 需要配置的 GitHub Secrets

| Secret 名称 | 说明 |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名（同时用作镜像仓库前缀 `<用户名>/openconnect`） |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token（建议使用 Token 而非账号密码） |

## 运行容器

必需的运行参数：

- `--cap-add=NET_ADMIN`：openconnect 需要配置路由和 tun 接口
- `--device=/dev/net/tun`：创建 tun 设备
- `--sysctl net.ipv4.ip_forward=1`（或在特权模式下由 entrypoint 自动设置）

```bash
docker run -d \
  --name openconnect-site2site \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  -e VPN_GATEWAY="vpn.example.com" \
  -e VPN_USERNAME="your-username" \
  -e VPN_PASSWORD="your-password" \
  -e VPN_PROTOCOL="anyconnect" \
  -e LAN_SUBNET="192.168.1.0/24" \
  your-dockerhub-user/openconnect:latest
```

若要让局域网内其它主机真正把流量转发进隧道，还需要以下二选一：

1. 让容器使用 `--network host`（或 `network_mode: host`），并在物理路由器/网关上把目标
   网段的静态路由指向宿主机 IP；
2. 或者将本容器所在宿主机作为局域网出口网关，在网络设备上把默认路由指到该宿主机，
   由宿主机再转发到容器（容器网络需与宿主机路由联动，视具体网络拓扑而定）。

## 环境变量一览

| 变量 | 必需 | 说明 |
|---|---|---|
| `VPN_GATEWAY` | 是 | VPN 服务器地址 |
| `VPN_USERNAME` | 是 | VPN 用户名 |
| `VPN_PASSWORD` | 否 | VPN 密码（经 stdin 传入，不落盘）|
| `VPN_PASSWORD_FILE` | 否 | 密码文件路径（优先级低于 `VPN_PASSWORD`）|
| `VPN_PROTOCOL` | 否 | 默认 `anyconnect`，可选 openconnect 支持的其它协议 |
| `VPN_SERVERCERT` | 否 | 服务器证书指纹（跳过证书告警）|
| `VPN_EXTRA_OPTS` | 否 | 追加给 openconnect 的其它参数 |
| `TUN_IF` | 否 | tun 设备名，默认 `tun0` |
| `LAN_SUBNET` | 否 | 需要 NAT 的本地网段，逗号分隔；不填则放行全部转发流量 |
| `RECONNECT_DELAY` | 否 | 断线重连等待秒数，默认 `5` |

## 安全提示

- 生产环境建议使用 `VPN_PASSWORD_FILE` 或 Docker/K8s secret 挂载密码，避免明文写入
  compose 文件或镜像历史。
- `--cap-add=NET_ADMIN` 权限较高，请仅在受信任的宿主机/网络环境中运行本容器。
