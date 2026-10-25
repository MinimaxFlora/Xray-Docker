# Xray 一键节点：XHTTP + VLESS Encryption (ML-KEM-768) + Vision + REALITY

[![build](https://github.com/MinimaxFlora/Xray-Docker/actions/workflows/docker.yml/badge.svg)](https://github.com/MinimaxFlora/Xray-Docker/actions/workflows/docker.yml)

预构建镜像（amd64 + arm64）：

```bash
docker pull dockorae/xray-core:v26.10.21    # Docker Hub
docker pull ghcr.io/minimaxflora/xray-core:v26.10.21  # GitHub Container Registry
```

在 VPS 上 `docker compose up -d --build` 一条命令起一个节点，
**UUID、REALITY x25519 密钥对、shortId、XHTTP 路径、后量子 VLESS Encryption 密钥全部自动生成**，
部署完直接弹出 `vless://` 链接（+ 二维码），客户端粘一下就完事；VPS 上只生成服务端配置。

> 不想记 docker compose 命令？用 [`manage.sh`](#10-管理脚本-managesh-docker-compose-的菜单包装)：
> 一个菜单搞定安装/更新/链接+二维码/导出客户端/轮换密钥/卸载，底层仍然是 docker compose。

伪装站点：`www.lovelive-anime.jp`（可改，见 [换伪装站点](#换伪装站点)）。
已实测该站点：TLS 1.3 / ALPN `h2` / **X25519MLKEM768 后量子密钥交换** / 证书 `*.lovelive-anime.jp`，
且不在官方「易被墙」名单（`apple` / `icloud` / `microsoft` / `.cn` / `.ru` / `.ir`）里。

---

## 1. 这条链路到底是什么

| 层 | 用的东西 | 作用 | 官方依据 |
|---|---|---|---|
| 传输 | **XHTTP**（`network: xhttp`, `mode: auto`） | 把代理流量伪装成 HTTP/2 请求流 | [XHTTP: Beyond REALITY](https://github.com/XTLS/Xray-core/discussions/4113) |
| 伪装 | **REALITY**（`target` / `serverNames` = `www.lovelive-anime.jp`） | 借用该站点的真实 TLS 握手特征，无需自己的域名和证书 | [REALITY 文档](https://xtls.github.io/config/transports/reality.html) |
| 加密 | **VLESS Encryption**（`mlkem768x25519plus`，ML-KEM-768 认证） | 后量子加密，防“先存后破” | [Xray PR #5067](https://github.com/XTLS/Xray-core/pull/5067) |
| 流控 | **XTLS Vision**（`flow: xtls-rprx-vision`） | 内层握手随机填充 + 尽量少拷贝 | [VLESS 文档](https://xtls.github.io/config/inbounds/vless.html) |

关于“这四样能不能一起用”的官方结论：

* REALITY 只支持 `RAW` / `XHTTP` / `gRPC` 三种传输 —— 所以 **XHTTP + REALITY 合法**（core 源码里 `REALITY only supports RAW, XHTTP and gRPC`）。
* 官方文档明确：`xtls-rprx-vision` 在 **VLESS Encryption 下不受底层传输限制**；在 XHTTP 上它不做底层对拷，只是“穿透 Encryption”，填充照旧生效 —— 所以 **Vision + XHTTP 合法**。
* `xray vlessenc` 会输出两套密钥，本仓库自动取 **`Authentication: ML-KEM-768`（后量子）** 那一套，不是默认的 X25519 那套。

本仓库已在 **Xray-core v26.10.21** 上实测：隧道通、错误公钥被拒、`geoip:cn` 拦截生效。

---

## 2. 部署（2 步）

前置：VPS 已装 Docker 24+ 和 compose v2，`443/tcp` 没被占用。

```bash
# 1) 拿仓库（或者把整个目录 scp 到 VPS）
git clone https://github.com/MinimaxFlora/Xray-Docker.git && cd Xray-Docker

# 2) 起（直接拉预构建镜像 dockorae/xray-core:v26.10.21，不需要 build）
docker compose up -d
```

首次启动会自动生成全部密钥，十几秒后看结果：

```bash
docker compose logs xray | grep '^vless://'   # 分享链接
cat data/vless-link.txt                        # 同样是链接（含密钥，别外传）
cat data/connection-info.txt                   # 各字段明文，方便手动填客户端
docker compose logs -f xray                    # 跟踪日志；如果链接里是 YOUR_SERVER_IP 见下文
```

> 云厂商安全组 + 系统防火墙都要放行 443/tcp：
> `ufw allow 443/tcp`（防火墙没开就不用管）。

---

## 3. 自动生成了什么

```
.
├── docker-compose.yml          # 默认：拉预构建镜像
├── docker-compose.build.yml    # 可选 overlay：本地 build 时用（见第 8 节）
├── Dockerfile                  # 把官方二进制塞进带 shell 的 alpine（官方镜像是 distroless，没有 sh）
├── .dockerignore
├── .env                        # 镜像 tag / 端口 / 伪装站点 / 节点名，改完 `docker compose up -d` 即生效
├── manage.sh                   # docker compose 菜单脚本：安装/链接+二维码/导出客户端（见第 10 节）
├── docker/entrypoint.sh        # 生成密钥 + 渲染配置 + 校验 + 启动
├── .github/workflows/docker.yml# CI：构建并推送 ghcr.io + Docker Hub（见第 8 节）
└── data/                       # 挂载进容器的持久目录（首次启动后出现）
    ├── keys.env                # ★ 全部私密材料（0600）：UUID、私钥、shortId、vlessenc 对
    ├── server.json             # 服务端完整配置（自动 -test 过才启动）
    ├── vless-link.txt          # vless:// 分享链接
    └── connection-info.txt     # 人读的字段清单
```

幂等性：

* `keys.env` 存在 → 复用，**重启/重装容器不会换密钥**（客户端不会掉）。
* 每次启动都会用 `keys.env` + `.env` 重新渲染 `server.json` 和链接，
  所以改端口、改 IP、改节点名只需 `docker compose up -d`，不用手动改 JSON。
* 渲染完会跑 `xray run -test`，配置不合法就拒绝启动并打印原因。

---

## 4. 客户端怎么用

### 4.1 v2rayN（推荐）

复制 `data/vless-link.txt` 的内容 → v2rayN 里 `Ctrl+V`（从剪贴板导入）→ 选中节点 → 设为活动节点。

链接长这样（参数与 v2rayN 的 VLESS 解析器逐项对应：`encryption` / `flow` / `security` / `sni` / `fp` / `pbk` / `sid` / `spx` / `type=xhttp` / `path` / `mode`）：

```
vless://<uuid>@<ip>:443?encryption=mlkem768x25519plus.native.0rtt.<...>&flow=xtls-rprx-vision
     &security=reality&sni=www.lovelive-anime.jp&fp=chrome&pbk=<公钥>&sid=<16位hex>&spx=%2F
     &type=xhttp&mode=auto&path=%2F<随机路径>#XHTTP-Reality-PQ
```

**版本要求**：客户端内核必须支持 VLESS Encryption，也就是 **Xray-core ≥ 25.10**（请用近期 v2rayN，
并在 `设置 → 内核` 里把 Xray 更新到最新）。旧内核会报 `unsupported encryption` 或直接连不上。

### 4.2 其他客户端

节点就是一条 `vless://` 链接，凡是支持 **VLESS + XHTTP + REALITY + VLESS Encryption**
的客户端（NekoBox / sing-box / Hiddify / mihomo 新版等）都能直接导入，不需要额外的客户端配置文件：

```bash
cat data/vless-link.txt        # 复制整行即可
sudo bash manage.sh links      # 顺便打印二维码，手机扫码导入
```

### 4.3 系统代理

* 用 v2rayN 的话，它自己会设 Windows 系统代理，不用管。
* 手机客户端一般就是全局 / TUN 模式，也不用单独设代理。
* 需要手动设代理时，填客户端本地的混入端口：`127.0.0.1:10809`（HTTP）或 `127.0.0.1:10808`（SOCKS5）。

---

## 5. 换伪装站点（SNI）

改 `.env`：

```ini
SNI=www.lovelive-anime.jp   # 换成别的域名
```

然后 `docker compose up -d`（只重渲染配置，不换密钥，客户端链接里的 `sni` 要同步改）。

新站点必须满足（官方要求）：

1. 国外网站，**支持 TLS 1.3 + HTTP/2**；
2. 证书包含你填的域名（别用会 301 跳转的主域名）；
3. 用自带内核自检：

```bash
docker compose exec xray xray tls ping www.lovelive-anime.jp
```

看 `TLS Version: TLS 1.3`、`TLS Post-Quantum key exchange`（能 true 更好）、`Certificate chain's total length`、`Cert's allowed domains`。

> ⚠️ 官方内核会对 `apple` / `icloud` / `microsoft` 以及 `.cn` / `.ru` / `.ir` 结尾的 target 打出警告
> “会增加服务器 IP 被墙的概率”（用的人太多，容易被按特征批量封）。
> 现在默认的 `www.lovelive-anime.jp` **不会**触发该警告；以后换站点按上面三条要求挑，改一行 `.env` 即可。

---

## 6. 常见问题

**链接里出现 `YOUR_SERVER_IP`**
自动探测被墙/无网时会发生。在 `.env` 里写死 `SERVER_ADDR=<公网IP或域名>`，再 `docker compose up -d`。

**客户端连不上**

```bash
docker compose ps                        # 容器在跑吗
docker compose logs --tail=100 xray      # 有 error 吗
docker compose exec xray xray tls ping www.lovelive-anime.jp   # 服务器能不能到 target
```

依次排查：云安全组/`ufw` 是否放行 443 → 客户端内核版本是否 ≥ 25.10 → 客户端里 `encryption`/`pbk`/`sid`/`path` 是否和 `connection-info.txt` 一致
（链接是自动拼的，一般不会错）→ 本地网络是否封了 443 出站。

**443 被占用**

`.env` 里 `PORT=8443`（只改对外端口，容器内仍是 443），链接会自动用 8443。
注意：非 443 端口会降低 REALITY 的伪装效果，内核也会警告。

**镜像拉不动（国内 VPS）**

默认拉的是 `dockorae/xray-core:v26.10.21`，Docker Hub 一般还行；拉不动就换成 ghcr：

```ini
IMAGE=ghcr.io/minimaxflora/xray-core:v26.10.21
```

两个都慢时，用本地构建（基础镜像换成国内镜像源）：

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml build \
  --build-arg XRAY_IMAGE=ghcr.m.daocloud.io/xtls/xray-core:26.10.21
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d
```

或者先在能上网的机器 `docker save` 再 `docker load`。

**百度/淘宝打不开了**

这是故意的：服务端 `geoip:cn` + `geosite:cn` 走 `block`，防止服务器被当成回国代理（官方示例同样建议）。
客户端那侧 `geoip:cn/geosite:cn` 是直连，正常上网不受影响。确实要访问国内站点就别让它们走代理。

**日志里看不到访问记录**

默认 `loglevel: warning`（只看错误）。要排错可在 `data/server.json` 里临时改 `debug`，
但 `entrypoint.sh` 每次启动会重渲染，正确做法是改 `docker/entrypoint.sh` 里的 `loglevel` 后重新 build，
或临时 `docker compose run --rm xray sh` 手动跑。

---

## 7. 运维

**轮换全部密钥**（旧客户端立即失效）：

```bash
docker compose run --rm xray keygen --force   # 生成新 keys.env，旧的备份成 keys.env.bak.<时间>
docker compose up -d                          # 用新配置重启
cat data/vless-link.txt                       # 新链接发给客户端
```

**备份 / 迁移**：只需保住 `data/keys.env`（0600）。把它拷到新机器的同位置，`docker compose up -d` 就是同一个节点。

**升级内核**：把 `.env` 里的 `IMAGE` tag 换成新版本（如 `:v26.11.x`）→ `docker compose pull && docker compose up -d`。
CI 每次 push 都会按内置内核版本产出 `v<版本>` tag（见第 8 节）。

**性能**：容器内已放宽 `nofile`。宿主建议开 BBR：

```bash
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.conf
sysctl -p && sysctl net.ipv4.tcp_congestion_control
```

**想再快一点**：把 `docker-compose.yml` 里 `ports:` 注释掉，改用 `network_mode: host`（跳过 docker NAT，仅 Linux）。

---

## 8. GitHub Actions：自动构建并推送镜像

仓库里有 `.github/workflows/docker.yml`，两个 job：

| job | 触发 | 干了什么 |
|---|---|---|
| `smoke` | push / PR / 手动 | 构建 amd64 镜像 → 跑一遍 `keygen` → 断言 `keys.env` 权限 600、`server.json` 里含 `mlkem768x25519plus`、链接带 `type=xhttp`/`security=reality`/`flow=xtls-rprx-vision`、且**不生成 client.json** → 再用镜像内的 xray 对服务端配置跑 `-test` |
| `publish` | push 到 `main`/`master`、打 `v*` tag、手动 | 多架构（linux/amd64 + linux/arm64）构建，推到 ghcr.io 和 Docker Hub |

### 8.1 配置 secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret：

| Name | 值 |
|---|---|
| `DOCKERHUB_USERNAME` | 你的 Docker Hub 用户名 |
| `DOCKERHUB_TOKEN` | Docker Hub 的 Access Token（权限 Read & Write） |

ghcr.io 不用任何 secret，用内置 `GITHUB_TOKEN`（workflow 里已声明 `packages: write`）；
没配 Docker Hub 那两个 secret 时，会自动跳过 Docker Hub、只推 ghcr。

有 `gh` CLI 的话两条命令搞定：

```bash
gh secret set DOCKERHUB_USERNAME --body "<你的 Docker Hub 用户名>"
gh secret set DOCKERHUB_TOKEN    --body "<新生成的 access token>"
```

> 🔴 你在对话里贴出来的 `dckr_pat_...` 已经算泄露（聊天记录、截图、日志都可能留存）。
> **请立刻到 Docker Hub → Account settings → Personal access tokens 把它 revoke**，重新生成一个，
> 只填进上面的 secret。**不要**把它写进 `.env`、workflow、`docker-compose.yml` 或任何 commit ——
> 本仓库代码里没有这个值，也不该有。

### 8.2 触发与产物

```bash
git init && git add . && git commit -m "xray xhttp + reality + pq node"
git remote add origin git@github.com:<you>/<repo>.git
git push -u origin main                # push 到 main 就等于发版：覆盖 v26.10.21 + latest
```

也可以 Actions 页面 → `build` → Run workflow 手动跑。

以当前仓库（内核 `v26.10.21`）为例，**只产出两个标签**：

| 标签 | 含义 |
|---|---|
| **`v26.10.21`** | **跟随内置 Xray 内核版本**，由 `XRAY_IMAGE` 自动推出（`26.10.21` → `v26.10.21`）；升级内核只需改 `XRAY_IMAGE` |
| `latest` | 默认分支的最新构建 |

不产出 `sha-xxxxxxx` / 分支名 / 语义化版本这类标签，registry 里永远只有这两个名字。

即：

* `ghcr.io/minimaxflora/xray-core:v26.10.21`
* `docker.io/dockorae/xray-core:v26.10.21`

> `XRAY_IMAGE` 必须写明版本号（如 `:26.10.21`），否则 workflow 直接报错退出，
> 避免出现 `vlatest` 这种没有意义的 tag。

### 8.3 compose 用的是哪个镜像

`docker-compose.yml` **默认直接拉预构建镜像**，不需要 `build`：

```yaml
services:
  xray:
    image: ${IMAGE:-dockorae/xray-core:v26.10.21}
```

`.env` 里改一行就能换来源/版本：

```ini
IMAGE=dockorae/xray-core:v26.10.21
# IMAGE=ghcr.io/minimaxflora/xray-core:v26.10.21
```

升级：`docker compose pull && docker compose up -d`（`data/keys.env` 不变，客户端不掉线）。

**想本地构建**（不依赖 registry）用 overlay，主 compose 不用改：

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

`docker-compose.build.yml` 里会用 `XRAY_IMAGE`（默认 `ghcr.io/xtls/xray-core:26.10.21`，
即官方 distroless 镜像）作为基础镜像，产物本地 tag 为 `xray-core:local`。

私有仓库的 ghcr 包要先登录才能拉：`echo <PAT> | docker login ghcr.io -u <owner>`；
要公开拉取就去 Packages → 该包 → Package settings → Change visibility → Public。

---

## 9. 安全提醒

* `data/keys.env`、`data/vless-link.txt` 含全部密钥，等同于节点所有权，别提交到 git、别发群里。
* 默认单用户单节点；要多人用就每个用户一条 UUID，并给各自不同的 `shortId`/路径（改 `entrypoint.sh` 的 `clients` 数组）。
* 服务端路由只放行出站、封 `geoip:cn`，不做 DNS 转发、不开 API，攻击面很小；但仍建议定期 `docker compose pull` 更新镜像。

---


## 10. 管理脚本 manage.sh（docker compose 的菜单包装）

`manage.sh` 只是把 `docker compose` 包了一层菜单，**不下载任何二进制、不装 systemd 服务**，
节点始终跑在容器里：

* 拉镜像 / 起容器 / 更新 / 卸载
* 部署完直接把 `vless://` 链接 + 二维码打印出来，之后随时可以再看
* 轮换密钥、备份 `data`、看日志

VPS 上只有**服务端**配置（`data/server.json`）；客户端不落地任何文件，用链接导入。

### 10.1 用起来

```bash
git clone https://github.com/MinimaxFlora/Xray-Docker.git && cd Xray-Docker
sudo bash manage.sh
```

菜单：

```
基础功能：
1、安装 / 启动节点        2、更新镜像        3、卸载
服务管理：
4、查看状态   5、启动   6、停止   7、重启   8、查看日志
节点管理：
9、查看节点链接 + 二维码   10、轮换节点密钥
配置管理：
11、编辑 .env   12、备份 data
0、退出
```

也可以直接跑：

```bash
sudo bash manage.sh install    # 首次：拉镜像 → 起容器 → 生成密钥 → 打印链接 + 二维码
sudo bash manage.sh links      # 以后再查看链接 + 二维码
sudo bash manage.sh update     # 拉新镜像并重启（密钥不变，客户端不掉线）
sudo bash manage.sh rotate     # 轮换 UUID / x25519 / shortId / 路径 / 后量子密钥
sudo bash manage.sh log        # docker compose logs --tail 100
```

等价的底层操作仍然是 `docker compose up -d`，脚本只是替你记住“跑哪条、去哪拿链接”。

### 10.2 目录约定

| 路径 | 说明 |
|---|---|
| `./.env` | 镜像 tag / 端口 / 伪装站点 / 节点名（首次运行会自动生成） |
| `./data/server.json` | **服务端配置**（容器生成，VPS 上就是它在跑） |
| `./data/vless-link.txt` | **节点链接**（`vless://...`，客户端就吃这个） |
| `./data/connection-info.txt` | 各字段明文（地址/端口/uuid/sni/shortId/path 等） |
| `./data/keys.env` | 全部密钥（0600），备份它就等于备份节点 |
| `./data/qr-vless.png` | 二维码图片（装了 qrencode 才有） |

### 10.3 节点信息在哪看

* 部署完：脚本会直接把链接和二维码打出来；
* 之后：`sudo bash manage.sh links`，或者 `cat data/vless-link.txt`；
* 容器日志里也有：`docker compose logs xray | grep '^vless://'`。

### 10.4 常见问题

**镜像拉不动**

改 `.env` 里的 `IMAGE`：

```ini
IMAGE=ghcr.io/minimaxflora/xray-core:v26.10.21
# 或
IMAGE=ghcr.m.daocloud.io/xtls/xray-core:26.10.21
```

**链接里是 YOUR_SERVER_IP**

容器探测不到公网 IP。在 `.env` 里写死 `SERVER_ADDR=<IP或域名>`，再 `sudo bash manage.sh restart`。

**端口不是 443**

改 `.env` 的 `PORT`（容器内固定 443），链接会自动跟着变；非 443 会降低 REALITY 伪装效果。

**二维码没出来**

装一下 `qrencode`：`apt install qrencode`（脚本也会自动尝试安装），链接本身不受影响。
