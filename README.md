# Xray 一键节点：XHTTP + VLESS Encryption (ML-KEM-768) + Vision + REALITY

在 VPS 上 `docker compose up -d --build` 一条命令起一个节点，
**UUID、REALITY x25519 密钥对、shortId、XHTTP 路径、后量子 VLESS Encryption 密钥全部自动生成**，
生成完直接给你 `vless://` 分享链接和 `client.json`，客户端粘一下就完事。

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

## 2. 部署（3 步）

前置：VPS 已装 Docker 24+ 和 compose v2，`443/tcp` 没被占用。

```bash
# 1) 把整个目录传到 VPS，例如 /root/xray
scp -r ./xray root@<你的VPS>:/root/

# 2) 进目录（.env 里默认值就能用，SERVER_ADDR 留空会自动探测公网 IP）
cd /root/xray

# 3) 起
docker compose up -d --build
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
├── docker-compose.yml
├── Dockerfile                  # 把官方二进制塞进带 shell 的 alpine（官方镜像是 distroless，没有 sh）
├── .dockerignore
├── .env                        # 端口 / 伪装站点 / 节点名，改完 `docker compose up -d` 即生效
├── docker/entrypoint.sh        # 生成密钥 + 渲染配置 + 校验 + 启动
├── .github/workflows/docker.yml# CI：构建并推送 ghcr.io + Docker Hub（见第 8 节）
└── data/                       # 挂载进容器的持久目录（首次启动后出现）
    ├── keys.env                # ★ 全部私密材料（0600）：UUID、私钥、shortId、vlessenc 对
    ├── server.json             # 服务端完整配置（自动 -test 过才启动）
    ├── client.json             # 客户端完整配置（socks 10808 + http 10809 + 国内直连）
    ├── vless-link.txt          # vless:// 分享链接
    └── connection-info.txt     # 人读的字段清单
```

幂等性：

* `keys.env` 存在 → 复用，**重启/重装容器不会换密钥**（客户端不会掉）。
* 每次启动都会用 `keys.env` + `.env` 重新渲染 `server.json` / `client.json` / 链接，
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

### 4.2 只要有完整配置的客户端

把 `data/client.json` 当普通 Xray 配置跑：

```bash
xray run -c client.json
```

它自带：

* `socks5 127.0.0.1:10808`（UDP 已开）
* `http 127.0.0.1:10809`
* 路由：私有地址 + `geoip:cn` + `geosite:cn` → 直连，其余走节点

### 4.3 系统代理

* 用 v2rayN 的话，它自己会设 Windows 系统代理，不用管。
* 用 `client.json` 的话，Windows「设置 → 网络和 Internet → 代理 → 手动设置」填
  `127.0.0.1:10809`（HTTP 代理）；或用 PAC/`socks5://127.0.0.1:10808`。macOS/Linux 同理。

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

**ghcr.io 拉不动（国内 VPS）**

改 `.env` 的 `XRAY_IMAGE`，例如：

```ini
XRAY_IMAGE=ghcr.m.daocloud.io/xtls/xray-core:26.10.21
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

**升级内核**：改 `.env` 的 `XRAY_IMAGE`（比如 `:latest` 或新版本号）→ `docker compose up -d --build`。

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
| `smoke` | push / PR / 手动 | 构建 amd64 镜像 → 跑一遍 `keygen` → 断言 `keys.env` 权限 600、server/client 里含 `mlkem768x25519plus`、链接带 `type=xhttp`/`security=reality`/`flow=xtls-rprx-vision` → 再用镜像内的 xray 对两份配置跑 `-test` |
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
git push -u origin main
git tag v1.0.0 && git push --tags     # 可选：打 tag 额外产生 1.0.0 / 1.0
```

也可以 Actions 页面 → `build` → Run workflow 手动跑。

以当前仓库（内核 `v26.10.21`）+ `main` 分支 + `v1.0.0` tag 为例，产出标签：

| 标签 | 含义 |
|---|---|
| **`v26.10.21`** | **跟随内置 Xray 内核版本**，由 `XRAY_IMAGE` 自动推出（`26.10.21` → `v26.10.21`）；升级内核只需改 `XRAY_IMAGE` |
| `latest` | 默认分支的最新构建 |
| `main` | 分支名 |
| `sha-xxxxxxx` | 提交 SHA |
| `1.0.0`、`1.0` | 你自己给本仓库打的 `v*` tag（可选） |

即：

* `ghcr.io/minimaxflora/xray-docker:v26.10.21`
* `docker.io/dockorae/xray-xhttp-reality-pq:v26.10.21`

### 8.3 用推好的镜像代替本地 build

VPS 上就不需要 `--build` 了，把 `docker-compose.yml` 的 `build:` 段删掉、改成 `image:`：

```yaml
services:
  xray:
    # 锁定内核版本，升级时把 tag 一起改（v26.10.21 -> v新版本）
    image: docker.io/dockorae/xray-xhttp-reality-pq:v26.10.21
    # 或 ghcr.io/minimaxflora/xray-docker:v26.10.21
```

然后 `docker compose pull && docker compose up -d`（`data/keys.env` 不变，客户端不掉线）。

私有仓库的 ghcr 包要先登录才能拉：`echo <PAT> | docker login ghcr.io -u <owner>`；
要公开拉取就去 Packages → 该包 → Package settings → Change visibility → Public。

---

## 9. 安全提醒

* `data/keys.env`、`data/vless-link.txt`、`data/client.json` 含全部密钥，等同于节点所有权，别提交到 git、别发群里。
* 默认单用户单节点；要多人用就每个用户一条 UUID，并给各自不同的 `shortId`/路径（改 `entrypoint.sh` 的 `clients` 数组）。
* 服务端路由只放行出站、封 `geoip:cn`，不做 DNS 转发、不开 API，攻击面很小；但仍建议定期 `docker compose pull` 更新镜像。
