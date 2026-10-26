<div align="center">

# Xray 一键节点

**XHTTP · VLESS Encryption (ML-KEM-768) · XTLS Vision · REALITY**

一条命令在 VPS 上起节点：自动生成密钥，直接给 **节点链接 + 二维码 + 客户端配置**

[![build](https://github.com/MinimaxFlora/Xray-Docker/actions/workflows/docker.yml/badge.svg)](https://github.com/MinimaxFlora/Xray-Docker/actions/workflows/docker.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/dockorae/xray-core?logo=docker)](https://hub.docker.com/r/dockorae/xray-core)
[![ghcr.io](https://img.shields.io/badge/ghcr.io-minimaxflora%2Fxray--core-2496ED?logo=github)](https://github.com/MinimaxFlora/Xray-Docker/pkgs/container/xray-core)
[![Xray](https://img.shields.io/badge/Xray--core-26.10.21-6E4AFF)](https://github.com/XTLS/Xray-core)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

---

## ✨ 一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/Xray-Docker/main/install.sh | sudo bash
```

**全程自动，不需要回答任何问题**：没 Docker 装 Docker → 拉镜像 → 起容器 → 生成密钥 → 打印链接/二维码 →
**自动进入管理菜单**（按回车，之后就能在菜单里看链接、二维码、导出配置、申请证书、生成订阅）。

> root 用户可以直接 `curl ... | bash`（菜单输入会更顺）；
> 用 `sudo` 的话菜单提示只等 10 秒，超时会打印 `cd /root/Xray-Docker && sudo bash manage.sh` 让你自己进。

装完之后任何时候想再看：

```bash
cd /root/Xray-Docker && sudo bash manage.sh
```

菜单里能看/能做：

```
基础功能：   1、安装 / 启动节点    2、更新镜像    3、卸载
服务管理：   4、状态  5、启动  6、停止  7、重启  8、日志
节点管理：   9、链接 + 二维码      10、导出 client.json      11、轮换密钥
配置管理：   12、编辑 .env         13、备份 data
订阅（HTTPS）： 14、申请证书（域名 / IP，acme.sh）   15、生成订阅（base64 + mihomo）
0、退出
```

> **前置要求**：Linux VPS，`443/tcp` 空闲；Docker 没有会自动装。
> 云安全组和系统防火墙记得放行 443（要订阅再放行 8443，要申请证书还要 80）。

---

## 📦 这套配置是什么

| 层 | 技术 | 作用 |
|---|---|---|
| 传输 | **XHTTP**（`mode: auto`） | 把代理流量伪装成 HTTP/2 请求流 |
| 伪装 | **REALITY**（`target` / `sni` = `www.lovelive-anime.jp`） | 借用真实站点的 TLS 握手特征，不需要自己的域名和证书 |
| 加密 | **VLESS Encryption**（`mlkem768x25519plus`，ML-KEM-768 认证） | 后量子加密，防“先存后破” |
| 流控 | **XTLS Vision**（`flow: xtls-rprx-vision`） | 内层握手随机填充 + 减少拷贝 |

三个关键结论（都有官方依据，不是拍脑袋）：

* REALITY 只支持 `RAW` / `XHTTP` / `gRPC` → **XHTTP + REALITY 合法**；
* 官方文档写明 Vision 在 VLESS Encryption 下**不受底层传输限制** → 四者可以叠在一起；
* `xray vlessenc` 会输出两套密钥，本项目取 **ML-KEM-768（后量子）** 那套。

伪装站点实测：`TLS 1.3`、`ALPN h2`、`X25519MLKEM768`、证书 `*.lovelive-anime.jp`，
且不在官方「易被墙」名单（`apple` / `icloud` / `microsoft` / `.cn` / `.ru` / `.ir`）里。

---

## 🚀 两种部署姿势

### 方式一：`manage.sh` 菜单（推荐）

```bash
sudo bash manage.sh
```

第一次运行如果没装 Docker，会先问你要不要用官方脚本装（`NONINTERACTIVE=1` 时自动装）。

```
基础功能：   1、安装 / 启动节点    2、更新镜像    3、卸载
服务管理：   4、状态  5、启动  6、停止  7、重启  8、日志
节点管理：   9、链接 + 二维码      10、导出 client.json      11、轮换密钥
配置管理：   12、编辑 .env         13、备份 data
订阅（HTTPS）： 14、申请证书（域名 / IP，acme.sh）   15、生成订阅（base64 + mihomo）
0、退出
```

也可以不进菜单：

```bash
sudo bash manage.sh install    # 部署 + 打印链接/二维码
sudo bash manage.sh links      # 再看链接 + 二维码
sudo bash manage.sh client     # 导出 client.json 到当前目录
sudo bash manage.sh update     # 拉新镜像并重启（密钥不变）
sudo bash manage.sh rotate     # 轮换全部密钥（旧客户端失效）
sudo bash manage.sh cert       # 申请证书（域名 / IP 证书，acme.sh）
sudo bash manage.sh sub        # 生成 HTTPS 订阅（base64 + mihomo）
sudo bash manage.sh log        # docker compose logs --tail 100
```

### 方式二：纯 docker compose

```bash
docker compose up -d
docker compose logs xray | grep '^vless://'   # 链接就在日志里
```

底层就是这两步，`manage.sh` 只是替你记住“跑哪条、去哪拿链接/二维码”。

---

## 📲 客户端怎么用

### 1. 链接（最省事）

复制 `data/vless-link.txt` 里的整行 → v2rayN 按 `Ctrl+V` 导入 → 设为活动节点。
手机客户端同理，或者直接扫终端二维码 / `data/qr-vless.png`。

链接参数与 v2rayN 的 VLESS 解析器逐项对应：
`encryption` / `flow` / `security` / `sni` / `fp` / `pbk` / `sid` / `spx` / `type=xhttp` / `path` / `mode`。

**版本要求**：客户端内核必须支持 VLESS Encryption，即 **Xray-core ≥ 25.10**
（近期 v2rayN 在 `设置 → 内核` 里更新到最新）。旧内核会报 `unsupported encryption`。

### 2. 客户端配置 `client.json`

部署时会生成 `data/client.json`，适合要自己改路由 / 脚本化启动的场景：

```bash
sudo bash manage.sh client                     # 导出到仓库目录
scp root@<VPS>:/root/Xray-Docker/client.json . # 或者直接拉
xray run -c client.json
```

自带 `socks5 127.0.0.1:10808`（UDP 已开）、`http 127.0.0.1:10809`，
路由为「私有地址 + `geoip:cn` + `geosite:cn` 直连，其余走节点」。

### 3. 系统代理

* v2rayN：自己会设 Windows 系统代理，不用管；
* 手机客户端：全局 / TUN 模式即可；
* 手动设：`127.0.0.1:10809`（HTTP）或 `127.0.0.1:10808`（SOCKS5）。

---

## 📁 目录结构

```
.
├── docker-compose.yml          # 默认直接拉预构建镜像
├── docker-compose.build.yml    # 可选 overlay：本地构建
├── Dockerfile                  # 官方 distroless 镜像 + alpine shell 层
├── docker/entrypoint.sh        # 生成密钥 → 渲染配置 → 校验 → 启动
├── install.sh                  # 一键 bootstrap：装 Docker + 只下 compose/manage.sh + 跑 install
├── manage.sh                   # compose 菜单脚本（安装/链接/二维码/导出）
├── .env                        # 镜像 tag / 端口 / 伪装站点 / 节点名
└── data/                       # 首次启动后出现（挂载进容器）
    ├── keys.env                # ★ 全部密钥（0600），备份它就等于备份节点
    ├── server.json             # 服务端配置（容器自己管理，不用你碰）
    ├── client.json             # 客户端配置（socks/http + 国内直连）
    ├── vless-link.txt          # vless:// 链接
    ├── certs/                  # acme.sh 证书（fullchain.pem / privkey.pem）
    ├── sub/                    # HTTPS 订阅：nginx.conf + www/<token>/{base64.txt,mihomo.yaml}
    ├── connection-info.txt     # 字段明文（地址/端口/uuid/sni/shortId/path）
    └── qr-vless.png            # 二维码图片（装了 qrencode 才有）
```

幂等性：`keys.env` 存在就复用，**重启/重装容器不换密钥**；
每次启动都会用 `keys.env` + `.env` 重新渲染 `server.json` / `client.json` / 链接，
所以改端口、改 IP、改节点名只要重启容器，不用手改 JSON。

---

## ⚙️ 配置项（`.env`）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `IMAGE` | `dockorae/xray-core:v26.10.21` | 镜像，tag 跟随内置内核版本 |
| `PORT` | `443` | 对外端口（容器内固定 443） |
| `SNI` | `www.lovelive-anime.jp` | 伪装站点 = REALITY target = serverName |
| `SERVER_ADDR` | 空 | 公网 IP / 域名，留空自动探测 |
| `NODE_NAME` | `Xray` | 客户端里显示的节点名（仅 ASCII） |
| `REGEN` | `0` | `1` = 本次启动轮换全部密钥（用完改回 0） |
| `TZ` | `Asia/Shanghai` | 时区 |

改完执行 `sudo bash manage.sh restart`（或 `docker compose up -d`）生效。

---

## 🔧 常用命令

| 场景 | 命令 |
|---|---|
| 看链接 + 二维码 | `sudo bash manage.sh links` |
| 导出客户端配置 | `sudo bash manage.sh client` |
| 重启 / 停止 / 启动 | `sudo bash manage.sh restart` / `stop` / `start` |
| 看日志 | `sudo bash manage.sh log` |
| 升级镜像 | 改 `.env` 的 `IMAGE` → `sudo bash manage.sh update` |
| 轮换密钥 | `sudo bash manage.sh rotate` |
| 备份 | `sudo bash manage.sh backup`（生成 `xray-data-backup-*.tar.gz`） |
| 申请证书 | `sudo bash manage.sh cert`（域名 / IP，acme.sh） |
| 生成 HTTPS 订阅 | `sudo bash manage.sh sub`（base64 + mihomo） |
| 卸载 | `sudo bash manage.sh uninstall` |

---

## ❓ FAQ

<details>
<summary><b>镜像拉不动（国内 VPS）</b></summary>

改 `.env`：

```ini
IMAGE=ghcr.io/minimaxflora/xray-core:v26.10.21
# 或
IMAGE=ghcr.m.daocloud.io/xtls/xray-core:26.10.21
```

再 `sudo bash manage.sh update`。

</details>

<details>
<summary><b>链接里出现 YOUR_SERVER_IP</b></summary>

容器探测不到公网 IP。在 `.env` 里写死 `SERVER_ADDR=<IP或域名>`，然后
`sudo bash manage.sh restart`。

</details>

<details>
<summary><b>客户端连不上</b></summary>

按顺序排查：

1. 云安全组 / `ufw` 是否放行 `443/tcp`；
2. 客户端内核是否 ≥ 25.10（不支持 VLESS Encryption 会直接失败）；
3. `docker compose ps` 容器是否在跑、`sudo bash manage.sh log` 有没有报错；
4. 服务器能不能到伪装站点：`docker compose exec xray xray tls ping www.lovelive-anime.jp`；
5. 链接里的 `encryption` / `pbk` / `sid` / `path` 是否和 `data/connection-info.txt` 一致。

</details>

<details>
<summary><b>想换伪装站点</b></summary>

改 `.env` 的 `SNI`，然后 `sudo bash manage.sh restart`（密钥不变，客户端链接里的 `sni` 要同步改）。

新站点必须满足：国外网站、**TLS 1.3 + HTTP/2**、证书包含该域名、不会 301 跳转。
自检：`docker compose exec xray xray tls ping <域名>`，看 `TLS Version` / `Cert's allowed domains`。

</details>

<details>
<summary><b>端口不是 443</b></summary>

改 `.env` 的 `PORT`（容器内仍是 443），链接会自动跟着变。
注意非 443 会降低 REALITY 的伪装效果，内核也会警告。

</details>

<details>
<summary><b>百度 / 淘宝打不开了</b></summary>

故意的。服务端 `geoip:cn` + `geosite:cn` 走 `block`，防止服务器被当成回国代理（官方示例同样建议）。
客户端那侧是 `geoip:cn` / `geosite:cn` 直连，正常上网不受影响。

</details>

<details>
<summary><b>卡在「对外端口 [443]:」不动</b></summary>

`curl | bash` 时 stdin 是管道，旧版脚本读不到输入。现在会先把 stdin 接到 `/dev/tty`，
并带 180 秒超时兜底。如果面板/容器控制台没有真正的 tty，直接换成非管道方式：

```bash
cd /root/Xray-Docker
sudo bash manage.sh install
```

或全默认：`sudo NONINTERACTIVE=1 bash manage.sh install`。

</details>

<details>
<summary><b>二维码没出来</b></summary>

宿主机装一下 `qrencode`：`apt install qrencode`（`manage.sh` 也会自动尝试安装）。
链接本身不受影响；容器镜像里不带它（Alpine 仓库没有这个包）。

**二维码太大 / 不想刷屏**：链接里有 1KB 的后量子密钥，二维码天生密。现在的输出已经是最小边距（`-m 1`），
PNG 存在 `data/qr-vless.png`（4px/模块）。想完全关掉终端二维码：

```bash
sudo NO_QR=1 bash manage.sh links
```

</details>

<details>
<summary><b>不用 Docker，能直接装系统里吗</b></summary>

不建议，也不在本仓库范围内。本项目刻意只用容器：镜像固定、升级 / 回滚一条命令、不污染宿主机。
要本地构建用 `docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build`。

</details>

---

## 🔐 HTTPS 订阅（证书 + base64 / mihomo）

节点链接本身很长（后量子密钥），手抄/发群都麻烦，所以可以把它做成 **HTTPS 订阅**：
一份给 v2rayN（base64），一份给 mihomo/Clash（YAML），都用你自己的证书走 TLS。

### 1. 申请证书（acme.sh，参考 3x-ui 的做法）

```bash
sudo bash manage.sh cert
```

会先问证书类型（和 3x-ui 一样，回车默认 IP 证书）：

```
1) 域名证书（HTTP-01，需要 80 端口可达）
2) IP 证书（Let's Encrypt shortlived，约 6 天有效，自动续期）
请选择 [1/2]（回车默认 2 即 IP 证书）:
```

* **域名证书**：`acme.sh --issue -d <域名> --standalone --httpport 80`，Let's Encrypt 正式证书；
* **IP 证书**：`acme.sh --issue -d <IP> --certificate-profile shortlived`，Let's Encrypt 的 IP 证书，
  **只有 ~6 天有效**，靠 acme.sh 的 cron 自动续期（续期时 80 端口要能通）；
* 证书装到 `data/certs/fullchain.pem` + `data/certs/privkey.pem`（700 / 600），
  `--reloadcmd` 会自动重启订阅容器；
* 都走 **HTTP-01**，所以申请时 **80/tcp 必须可达且空闲**（有 nginx 先停掉）；
* **邮箱**：默认留空（不填联系方式）。别用 `example.com` / `test.com` 这类保留域名，
  Let's Encrypt 会直接以 `invalidContact` 拒绝；非交互可以
  `ACME_EMAIL=you@qq.com sudo bash manage.sh cert`；
* 之前失败过也没关系：脚本会清掉 `~/.acme.sh/account.conf` 里写坏的 `ACCOUNT_EMAIL` 再重试。

> 部署时如果第 4 步填了域名，证书和订阅会自动跑；也可以事后单独执行下面两步。

### 2. 生成订阅

```bash
sudo bash manage.sh sub
```

会起一个 `nginx:alpine` 容器（compose 里的 `sub` 服务，profile `sub`），输出：

```
v2rayN / base64 订阅：
  https://<域名或IP>:8443/<随机token>/base64.txt
mihomo / Clash 订阅：
  https://<域名或IP>:8443/<随机token>/mihomo.yaml
```

* `base64.txt` = `base64(vless://...)`，v2rayN 里「订阅 → 添加」直接粘这个 URL，或者把内容粘进剪贴板导入；
* `mihomo.yaml` = 参考 [HenryChiao/MIHOMO_YAMLS](https://github.com/HenryChiao/MIHOMO_YAMLS) 风格生成的完整配置：
  `dns`（fake-ip + DoH + `+.cn` 分流）、`sniffer`、3 个策略组（默认代理 / 自动选择 / 全球直连）、
  `rule-providers`（MetaCubeX 的 cn-domain / cn-ip / private，mrs 格式）+ 11 条规则；
  mihomo 订阅直接填这个 URL 即可（mihomo 支持 VLESS Encryption，字段是 `encryption`）；
* 文件也在本地：`data/sub/www/<token>/`；订阅路径是随机的，`data/sub/token` 可以改；
* 记得放行 **8443/tcp**（`SUB_PORT` 可改）。

> 续期：acme.sh 会自己加 cron，续期成功后 `--reloadcmd` 重启 `xray-sub` 容器，订阅 URL 不变。

## 🏗 镜像 & CI

| 来源 | 地址 |
|---|---|
| Docker Hub | [`dockorae/xray-core`](https://hub.docker.com/r/dockorae/xray-core) |
| GHCR | [`ghcr.io/minimaxflora/xray-core`](https://github.com/MinimaxFlora/Xray-Docker/pkgs/container/xray-core) |
| 架构 | `linux/amd64` + `linux/arm64` |
| 标签 | `v26.10.21`（跟随内核版本）、`latest` |

`.github/workflows/docker.yml` 两个 job：

| job | 触发 | 干什么 |
|---|---|---|
| `smoke` | push / PR / 手动 | 构建 amd64 镜像 → 跑 `keygen` → 断言 `keys.env` 600、server/client 含 ML-KEM 密钥、链接带 `type=xhttp`/`security=reality`/`flow=xtls-rprx-vision`、`client.json` 有 10808/10809 → 两份配置各跑一次 `xray -test` |
| `publish` | push 到 `main`、手动 | 多架构构建，推 Docker Hub（需要 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` 两个 secret）和 ghcr（用内置 `GITHUB_TOKEN`） |

升级内核：改 workflow 里的 `XRAY_IMAGE` → 下次构建自动产出 `v<新版本>` 标签。

---

## 🛡 安全

* `data/keys.env`、`data/client.json`、`data/vless-link.txt` 含全部密钥，等同于节点所有权，
  别提交到 git、别外传；`.gitignore` 已经排除 `data/`。
* 默认单用户单节点；多人用请改 `docker/entrypoint.sh` 里的 `clients` 数组，每人一条 UUID。
* 服务端只放行出站、封 `geoip:cn`，不开 API、不做 DNS 转发，攻击面很小。
* 建议定期 `sudo bash manage.sh update` 跟进内核安全更新。

---

## 📄 License

[MIT](LICENSE)
