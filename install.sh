#!/usr/bin/env bash
###############################################################################
#
#  Xray 一键安装 / 管理脚本
#
#  Version : 1.0.0
#  Target  : Linux VPS (systemd), Debian/Ubuntu/CentOS/Alma/Rocky/Alpine
#
#  功能:
#    * 安装 / 更新官方 Xray-core（自动识别架构）
#    * 部署 VLESS 节点: XHTTP + VLESS Encryption(ML-KEM-768) + Vision + REALITY
#    * 部署 Hysteria2 节点（Xray 原生 hy2 实现，自签证书 + 证书 pin）
#    * 自动生成 UUID / x25519 / shortId / vlessenc / hy2 密码 / 证书
#    * 生成客户端 config（server 用 server.json，客户端用 client-*.json）
#    * 输出 vless:// / hysteria2:// 节点链接 + 终端二维码 + PNG 二维码
#    * 服务管理、密钥轮换、BBR 优化、卸载
#
#  用法:
#    bash install.sh              # 交互菜单
#    bash install.sh install      # 安装/更新内核 + 应用当前配置
#    bash install.sh vless        # 部署/更新 VLESS 节点
#    bash install.sh hy2          # 部署/更新 Hysteria2 节点
#    bash install.sh links        # 查看链接 + 二维码
#    bash install.sh client       # 重新生成客户端配置
#    bash install.sh restart|start|stop|status|log
#    bash install.sh bbr          # 开启 BBR
#    bash install.sh uninstall    # 卸载
#
#  非交互（自动化）:
#    ASSUME_YES=1 SERVER_ADDR=1.2.3.4 SNI=www.example.com \
#    VLESS_PORT=443 HY2_PORT=443 bash install.sh vless
#
#  可覆盖的环境变量:
#    XRAY_BIN  CONF_DIR  ASSET_DIR  CLIENT_DIR  SNI  VLESS_PORT  HY2_PORT
#    SERVER_ADDR  NODE_NAME  ASSUME_YES  NO_QR  NO_SERVICE  FORCE_ROTATE
#
###############################################################################

set -uo pipefail

# ------------------------------- 颜色 --------------------------------------
RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[1;34m'
CYAN=$'\e[1;36m'
PURPLE=$'\e[1;35m'
BOLD=$'\e[1m'
RES=$'\e[0m'

info()  { printf "${CYAN}[信息]${RES} %s\n" "$*"; }
ok()    { printf "${GREEN}[成功]${RES} %s\n" "$*"; }
warn()  { printf "${YELLOW}[警告]${RES} %s\n" "$*"; }
err()   { printf "${RED}[错误]${RES} %s\n" "$*" >&2; }
title() { printf "\n${PURPLE}${BOLD}==== %s ====${RES}\n" "$*"; }

# ------------------------------- 全局路径 ----------------------------------
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CONF_DIR="${CONF_DIR:-/usr/local/etc/xray}"
ASSET_DIR="${ASSET_DIR:-/usr/local/share/xray}"
CLIENT_DIR="${CLIENT_DIR:-/root/xray-client}"
CONFIG_FILE="$CONF_DIR/config.json"
STATE_FILE="$CONF_DIR/nodes.conf"
CERT_DIR="$CONF_DIR/certs"
SERVICE_NAME="xray"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

SNI="${SNI:-www.lovelive-anime.jp}"
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
SERVER_ADDR="${SERVER_ADDR:-}"
NODE_NAME="${NODE_NAME:-Xray}"
ASSUME_YES="${ASSUME_YES:-0}"
NO_QR="${NO_QR:-0}"
NO_SERVICE="${NO_SERVICE:-0}"
FORCE_ROTATE="${FORCE_ROTATE:-0}"

DEFAULT_VLESS_PORT=443
DEFAULT_HY2_PORT=443
DEFAULT_SNI="www.lovelive-anime.jp"

# ------------------------------- 小工具 ------------------------------------
has() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u)" = "0" ] || { err "请用 root 运行：sudo bash $0"; exit 1; }
}

gen_hex() { # $1=长度(偶数)
    "$XRAY_BIN" uuid | tr -d '-' | cut -c1-"$1"
}

rand_pass() {
    "$XRAY_BIN" uuid | tr -d '-' | cut -c1-24
}

url_host() { # IPv6 加方括号
    case "$1" in
        *:*) printf '[%s]' "$1" ;;
        *)   printf '%s' "$1" ;;
    esac
}

confirm() { # $1=提示
    [ "$ASSUME_YES" = "1" ] && return 0
    local a
    read -r -p "$1 [y/N]: " a
    case "$a" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

ask() { # $1=提示 $2=默认值 -> echo 结果
    local v
    if [ "$ASSUME_YES" = "1" ]; then printf '%s' "$2"; return 0; fi
    read -r -p "$1 [$2]: " v
    [ -z "$v" ] && v="$2"
    printf '%s' "$v"
}

have_systemd() {
    [ "$NO_SERVICE" = "1" ] && return 1
    has systemctl && [ -d /run/systemd/system ]
}

# ------------------------------- 依赖 --------------------------------------
install_pkg() {
    if has apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
    elif has dnf; then
        dnf install -y "$@" >/dev/null 2>&1
    elif has yum; then
        yum install -y "$@" >/dev/null 2>&1
    elif has apk; then
        apk add --no-cache "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

ensure_cmd() { # $1=命令 $2=包名
    has "$1" && return 0
    info "安装依赖 $2 ..."
    install_pkg "$2" || install_pkg "$2" >/dev/null 2>&1
    has "$1"
}

ensure_base_deps() {
    ensure_cmd curl curl || { err "curl 安装失败"; return 1; }
    ensure_cmd unzip unzip || warn "unzip 缺失，将尝试用 busybox unzip"
    return 0
}

ensure_qrencode() {
    [ "$NO_QR" = "1" ] && return 1
    has qrencode && return 0
    info "安装 qrencode（用于终端二维码）..."
    install_pkg qrencode >/dev/null 2>&1
    has qrencode
}

# ------------------------------- 架构 --------------------------------------
detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   ZIP_ARCH="64" ;;
        aarch64|arm64)  ZIP_ARCH="arm64-v8a" ;;
        armv7l|armv7)   ZIP_ARCH="arm32-v7a" ;;
        armv6l)         ZIP_ARCH="arm32-v6" ;;
        i386|i686)      ZIP_ARCH="32" ;;
        s390x)          ZIP_ARCH="s390x" ;;
        riscv64)        ZIP_ARCH="riscv64" ;;
        loongarch64)    ZIP_ARCH="loong64" ;;
        *) err "不支持的系统架构: $m"; return 1 ;;
    esac
    return 0
}

# ------------------------------- 部署前检查 --------------------------------
preflight() {
    need_root
    ensure_base_deps || return 1
    detect_arch || return 1
    mkdir -p "$CONF_DIR" "$CERT_DIR" "$CLIENT_DIR" "$ASSET_DIR"
    chmod 700 "$CONF_DIR" 2>/dev/null || true
    load_state
    return 0
}

# ------------------------------- 状态 --------------------------------------
load_state() {
    # 默认值
    : "${VLESS_ENABLED:=0}"
    : "${VLESS_PORT:=$DEFAULT_VLESS_PORT}"
    : "${VLESS_UUID:=}"
    : "${VLESS_PRIV:=}"
    : "${VLESS_PUB:=}"
    : "${VLESS_DEC:=}"
    : "${VLESS_ENC:=}"
    : "${VLESS_SID:=}"
    : "${VLESS_PATH:=}"
    : "${VLESS_FLOW:=xtls-rprx-vision}"
    : "${SNI:=$DEFAULT_SNI}"
    : "${HY2_ENABLED:=0}"
    : "${HY2_PORT:=$DEFAULT_HY2_PORT}"
    : "${HY2_AUTH:=}"
    : "${HY2_SNI:=}"
    : "${HY2_HASH:=}"
    : "${HY2_CERT:=$CERT_DIR/hy2.crt}"
    : "${HY2_KEY:=$CERT_DIR/hy2.key}"
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi
}

save_state() {
    umask 077
    cat > "$STATE_FILE" <<EOF
# generated by install.sh - contains secrets, keep it private
VLESS_ENABLED=$VLESS_ENABLED
VLESS_PORT=$VLESS_PORT
VLESS_UUID=$VLESS_UUID
VLESS_PRIV=$VLESS_PRIV
VLESS_PUB=$VLESS_PUB
VLESS_DEC=$VLESS_DEC
VLESS_ENC=$VLESS_ENC
VLESS_SID=$VLESS_SID
VLESS_PATH=$VLESS_PATH
VLESS_FLOW=$VLESS_FLOW
SNI=$SNI
HY2_ENABLED=$HY2_ENABLED
HY2_PORT=$HY2_PORT
HY2_AUTH=$HY2_AUTH
HY2_SNI=$HY2_SNI
HY2_HASH=$HY2_HASH
HY2_CERT=$HY2_CERT
HY2_KEY=$HY2_KEY
EOF
    chmod 600 "$STATE_FILE"
}

# ------------------------------- 安装内核 ----------------------------------
latest_version() {
    local v
    v="$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
         | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$v" ] && printf '%s' "$v"
}

install_xray() {
    local ver tmp zip url
    if has "$XRAY_BIN"; then
        info "已安装: $("$XRAY_BIN" version | head -n1)"
        if ! confirm "是否重新安装 / 更新到最新版？"; then
            return 0
        fi
    fi

    detect_arch || return 1
    ver="$(latest_version)"
    if [ -z "$ver" ]; then
        warn "无法从 GitHub API 获取最新版本（可能被限流）"
        ver="$(ask "请输入要安装的版本号(不带 v)" "")"
        [ -z "$ver" ] && { err "版本号为空，中止"; return 1; }
    fi
    info "准备安装 Xray-core v$ver ($ZIP_ARCH)"

    tmp="$(mktemp -d)"
    zip="$tmp/xray.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/v${ver}/Xray-linux-${ZIP_ARCH}.zip"
    info "下载: $url"
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$zip" "$url"; then
        err "下载失败，请检查网络或换用代理"
        rm -rf "$tmp"
        return 1
    fi

    if has unzip; then
        unzip -oq "$zip" -d "$tmp/bin" || { err "解压失败"; rm -rf "$tmp"; return 1; }
    else
        mkdir -p "$tmp/bin" && (cd "$tmp/bin" && busybox unzip -o "$zip" >/dev/null 2>&1) \
            || { err "解压失败（缺少 unzip）"; rm -rf "$tmp"; return 1; }
    fi

    install -m 0755 "$tmp/bin/xray" "$XRAY_BIN" || { err "安装二进制失败"; rm -rf "$tmp"; return 1; }
    mkdir -p "$ASSET_DIR"
    [ -f "$tmp/bin/geoip.dat" ] && install -m 0644 "$tmp/bin/geoip.dat" "$ASSET_DIR/geoip.dat"
    [ -f "$tmp/bin/geosite.dat" ] && install -m 0644 "$tmp/bin/geosite.dat" "$ASSET_DIR/geosite.dat"
    rm -rf "$tmp"

    write_service
    ok "已安装: $("$XRAY_BIN" version | head -n1)"
    return 0
}

write_service() {
    have_systemd || { warn "未检测到 systemd，跳过 service 写入"; return 0; }
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=$ASSET_DIR
ExecStart=$XRAY_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

# ------------------------------- 服务 --------------------------------------
svc() { # $1=start|stop|restart|status
    if ! have_systemd; then
        warn "无 systemd，跳过 systemctl $1"
        return 0
    fi
    systemctl "$1" "$SERVICE_NAME" 2>/dev/null || true
}

svc_restart() {
    svc restart
    sleep 1
    if have_systemd && ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "服务启动失败，最近日志："
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null | tail -n 30
        return 1
    fi
    return 0
}

# ------------------------------- 端口放行 ----------------------------------
open_firewall() {
    local port="$1" proto="${2:-tcp}"
    if has ufw && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "$port/$proto" >/dev/null 2>&1 && info "ufw 已放行 $port/$proto"
    elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        info "firewalld 已放行 $port/$proto"
    fi
}

# ------------------------------- VLESS 生成 --------------------------------
gen_vless_secrets() {
    info "生成 VLESS 密钥（UUID / x25519 / shortId / vlessenc ML-KEM-768）..."
    VLESS_UUID="$("$XRAY_BIN" uuid)" || return 1
    VLESS_SID="$(gen_hex 16)"
    VLESS_PATH="/$(gen_hex 12)"

    local x priv pub
    x="$("$XRAY_BIN" x25519)" || return 1
    priv="$(printf '%s\n' "$x" | sed -n 's/^[Pp]rivate[[:space:]]*[Kk]ey:[[:space:]]*//p' | head -n1)"
    pub="$(printf '%s\n' "$x" | sed -n -e 's/^[Pp]assword[[:space:]]*([Pp]ublicKey):[[:space:]]*//p' \
                                    -e 's/^[Pp]assword[[:space:]]*([Pp]ublic[[:space:]]*[Kk]ey):[[:space:]]*//p' \
                                    -e 's/^[Pp]ublic[[:space:]]*[Kk]ey:[[:space:]]*//p' | head -n1)"
    [ -n "$priv" ] && [ -n "$pub" ] || { err "无法解析 xray x25519 输出"; return 1; }
    VLESS_PRIV="$priv"
    VLESS_PUB="$pub"

    local v
    v="$("$XRAY_BIN" vlessenc)" || return 1
    VLESS_DEC="$(printf '%s\n' "$v" | awk '
        /Authentication: ML-KEM-768/ { f = 1 }
        f && /"decryption"/ { sub(/^.*"decryption"[[:space:]]*:[[:space:]]*"/, ""); sub(/"$/, ""); print; exit }')"
    VLESS_ENC="$(printf '%s\n' "$v" | awk '
        /Authentication: ML-KEM-768/ { f = 1 }
        f && /"encryption"/ { sub(/^.*"encryption"[[:space:]]*:[[:space:]]*"/, ""); sub(/"$/, ""); print; exit }')"
    [ -n "$VLESS_DEC" ] && [ -n "$VLESS_ENC" ] || { err "vlessenc 未返回 ML-KEM-768 密钥（内核过旧？）"; return 1; }
    return 0
}

deploy_vless() {
    title "部署 VLESS 节点 (XHTTP + VLESS Encryption + Vision + REALITY)"
    preflight || return 1

    if [ "$VLESS_ENABLED" = "1" ] && [ "$FORCE_ROTATE" != "1" ]; then
        if ! confirm "VLESS 节点已存在，是否重新生成密钥（旧客户端会失效）？"; then
            info "保留现有 VLESS 配置"
            VLESS_PORT="$(ask "对外端口" "$VLESS_PORT")"
            save_state
            apply_config && render_clients && print_nodes
            return $?
        fi
    fi

    VLESS_PORT="$(ask "VLESS 监听端口" "${VLESS_PORT:-$DEFAULT_VLESS_PORT}")"
    SNI="$(ask "伪装站点 (REALITY target / serverName)" "${SNI:-$DEFAULT_SNI}")"

    gen_vless_secrets || return 1
    VLESS_ENABLED=1
    VLESS_FLOW="xtls-rprx-vision"
    save_state
    open_firewall "$VLESS_PORT" tcp
    apply_config || return 1
    render_clients
    print_nodes
}

# ------------------------------- HY2 生成 ----------------------------------
gen_hy2_secrets() {
    info "生成 Hysteria2 密码与自签证书..."
    HY2_AUTH="$(rand_pass)"
    HY2_SNI="${HY2_SNI:-$SNI}"

    local base="$CERT_DIR/hy2"
    rm -f "$base.crt" "$base.key"
    "$XRAY_BIN" tls cert -domain="$HY2_SNI" -json=false -expire=87600h -file="$base" >/dev/null 2>&1 \
        || { err "生成证书失败"; return 1; }
    [ -f "$base.crt" ] && [ -f "$base.key" ] || { err "证书文件未生成"; return 1; }
    HY2_CERT="$base.crt"
    HY2_KEY="$base.key"
    chmod 600 "$HY2_KEY" 2>/dev/null || true

    local h
    h="$("$XRAY_BIN" tls hash --cert="$HY2_CERT" 2>/dev/null | sed -n 's/.*Leaf SHA256:[[:space:]]*//p' | head -n1)"
    if [ -z "$h" ]; then
        # 老版本输出格式兜底：取最后一行的 64 位 hex
        h="$("$XRAY_BIN" tls hash --cert="$HY2_CERT" 2>/dev/null | grep -oE '[0-9a-fA-F]{64}' | head -n1)"
    fi
    [ -n "$h" ] || { err "计算证书 pin 失败"; return 1; }
    HY2_HASH="$h"
    return 0
}

deploy_hy2() {
    title "部署 Hysteria2 节点"
    preflight || return 1

    if [ "$HY2_ENABLED" = "1" ] && [ "$FORCE_ROTATE" != "1" ]; then
        if ! confirm "Hysteria2 节点已存在，是否重新生成密码/证书（旧客户端会失效）？"; then
            info "保留现有 Hysteria2 配置"
            HY2_PORT="$(ask "Hysteria2 端口 (UDP)" "$HY2_PORT")"
            save_state
            apply_config && render_clients && print_nodes
            return $?
        fi
    fi

    HY2_PORT="$(ask "Hysteria2 监听端口 (UDP)" "${HY2_PORT:-$DEFAULT_HY2_PORT}")"
    SNI="$(ask "证书域名 / SNI（可填服务器 IP）" "${SNI:-$DEFAULT_SNI}")"
    HY2_SNI="$SNI"

    gen_hy2_secrets || return 1
    HY2_ENABLED=1
    save_state
    open_firewall "$HY2_PORT" udp
    apply_config || return 1
    render_clients
    print_nodes
}

# ------------------------------- 服务端配置 --------------------------------
render_inbounds() {
    local first=1 masq
    load_state
    # 域名就用反代伪装，IP 就回一个 404 页面（proxy 模式不接受 IP）
    if printf '%s' "$SNI" | grep -qE '^[0-9.]+$'; then
        masq='"masquerade": { "type": "string", "content": "<html><head><title>404 Not Found</title></head><body><h1>404 Not Found</h1></body></html>", "statusCode": 404 }'
    else
        masq="\"masquerade\": { \"type\": \"proxy\", \"url\": \"https://$SNI/\", \"rewriteHost\": true }"
    fi
    if [ "$VLESS_ENABLED" = "1" ]; then
        cat <<EOF
    {
      "tag": "vless-xhttp-reality",
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_UUID",
            "email": "default",
            "flow": "$VLESS_FLOW"
          }
        ],
        "decryption": "$VLESS_DEC"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$VLESS_PATH",
          "mode": "auto"
        },
        "security": "reality",
        "realitySettings": {
          "target": "$SNI:443",
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$VLESS_PRIV",
          "shortIds": [
            "$VLESS_SID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
EOF
        first=0
    fi

    if [ "$HY2_ENABLED" = "1" ]; then
        [ "$first" = "0" ] && printf ',\n'
        cat <<EOF
    {
      "tag": "hysteria2",
      "listen": "0.0.0.0",
      "port": $HY2_PORT,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": [
          {
            "auth": "$HY2_AUTH",
            "email": "default"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "certificateFile": "$HY2_CERT",
              "keyFile": "$HY2_KEY"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          ${masq}
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
EOF
    fi
}

render_server_config() {
    # 临时文件必须以 .json 结尾，xray 靠后缀判断格式
    local tmp="$CONF_DIR/.config-check.json"
    {
        printf '{\n'
        printf '  "log": {\n    "loglevel": "warning"\n  },\n'
        printf '  "inbounds": [\n'
        render_inbounds
        printf '  ],\n'
        cat <<'EOF'
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "geosite:cn"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
    } > "$tmp" || return 1

    if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$tmp" >/tmp/xray-test.log 2>&1; then
        err "配置校验失败："
        sed 's/^/  /' /tmp/xray-test.log | tail -n 20 >&2
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    ok "服务端配置已写入: $CONFIG_FILE"
    return 0
}

apply_config() {
    if [ "$VLESS_ENABLED" != "1" ] && [ "$HY2_ENABLED" != "1" ]; then
        warn "还没有启用任何节点，先部署 VLESS 或 Hysteria2"
        return 1
    fi
    render_server_config || return 1
    write_service
    svc_restart || return 1
    ok "服务已重启"
    return 0
}

# ------------------------------- 客户端配置 --------------------------------
server_addr() {
    if [ -n "${_ADDR_CACHE:-}" ]; then
        printf '%s' "$_ADDR_CACHE"
        return 0
    fi
    if [ -n "$SERVER_ADDR" ]; then
        _ADDR_CACHE="$SERVER_ADDR"
        printf '%s' "$_ADDR_CACHE"
        return 0
    fi
    local ip
    ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
    [ -z "$ip" ] && ip="$(curl -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]')"
    [ -z "$ip" ] && ip="YOUR_SERVER_IP"
    _ADDR_CACHE="$ip"
    printf '%s' "$ip"
}

render_client_vless() {
    local addr="$1"
    cat > "$CLIENT_DIR/client-vless.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    },
    {
      "tag": "http-in",
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "address": "$addr",
        "port": $VLESS_PORT,
        "id": "$VLESS_UUID",
        "flow": "$VLESS_FLOW",
        "encryption": "$VLESS_ENC"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$VLESS_PATH",
          "mode": "auto"
        },
        "security": "reality",
        "realitySettings": {
          "serverName": "$SNI",
          "fingerprint": "chrome",
          "publicKey": "$VLESS_PUB",
          "shortId": "$VLESS_SID",
          "spiderX": "/"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "direct"
      },
      {
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "direct"
      },
      {
        "domain": [
          "geosite:cn"
        ],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
}

render_client_hy2() {
    local addr="$1"
    cat > "$CLIENT_DIR/client-hy2.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    },
    {
      "tag": "http-in",
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "address": "$addr",
        "port": $HY2_PORT
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$HY2_SNI",
          "pinnedPeerCertSha256": "$HY2_HASH"
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": "$HY2_AUTH"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "direct"
      },
      {
        "ip": [
          "geoip:cn"
        ],
        "outboundTag": "direct"
      },
      {
        "domain": [
          "geosite:cn"
        ],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF
}

render_clients() {
    local addr
    load_state
    addr="$(server_addr)"
    [ "$addr" = "YOUR_SERVER_IP" ] && warn "未获取到公网 IP，客户端配置里用占位符，请手动替换"

    if [ "$VLESS_ENABLED" = "1" ]; then
        render_client_vless "$addr"
        ok "客户端配置: $CLIENT_DIR/client-vless.json"
    fi
    if [ "$HY2_ENABLED" = "1" ]; then
        render_client_hy2 "$addr"
        ok "客户端配置: $CLIENT_DIR/client-hy2.json"
    fi
    render_links "$addr"
}

# ------------------------------- 链接 & 二维码 -----------------------------
vless_link() {
    local addr host path_enc
    addr="$(server_addr)"
    host="$(url_host "$addr")"
    path_enc="$(printf '%s' "$VLESS_PATH" | sed 's|/|%2F|g')"
    printf 'vless://%s@%s:%s?encryption=%s&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=xhttp&mode=auto&path=%s#%s-VLESS' \
        "$VLESS_UUID" "$host" "$VLESS_PORT" "$VLESS_ENC" "$VLESS_FLOW" "$SNI" "$VLESS_PUB" "$VLESS_SID" "$path_enc" "$NODE_NAME"
}

hy2_link() {
    local addr host
    addr="$(server_addr)"
    host="$(url_host "$addr")"
    printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1#%s-HY2' \
        "$HY2_AUTH" "$host" "$HY2_PORT" "$HY2_SNI" "$NODE_NAME"
}

qr_show() { # $1=文本 $2=名字
    [ "$NO_QR" = "1" ] && return 0
    if ! ensure_qrencode; then
        warn "没有 qrencode，跳过二维码（链接已给出）"
        return 0
    fi
    printf '\n'
    qrencode -t ANSIUTF8 "$1" 2>/dev/null || warn "二维码渲染失败"
    qrencode -o "$CLIENT_DIR/qr-$2.png" -s 6 -m 2 "$1" 2>/dev/null \
        && info "二维码图片: $CLIENT_DIR/qr-$2.png"
}

render_links() {
    local addr host vlink hlink extra
    addr="$(server_addr)"
    host="$(url_host "$addr")"
    mkdir -p "$CLIENT_DIR"
    : > "$CLIENT_DIR/links.txt"
    {
        printf '# Xray node links (%s)\n\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    } >> "$CLIENT_DIR/links.txt"

    if [ "$VLESS_ENABLED" = "1" ]; then
        vlink="$(vless_link)"
        printf 'VLESS (XHTTP+REALITY+Vision+PQ)\n%s\n\n' "$vlink" >> "$CLIENT_DIR/links.txt"
    fi
    if [ "$HY2_ENABLED" = "1" ]; then
        hlink="$(hy2_link)"
        printf 'Hysteria2\n%s\n\n' "$hlink" >> "$CLIENT_DIR/links.txt"
        printf 'Hysteria2 cert pin (for clients that support pinSHA256)\n%s\n\n' "$HY2_HASH" >> "$CLIENT_DIR/links.txt"
    fi
    chmod 600 "$CLIENT_DIR/links.txt"
}

print_nodes() {
    local addr vlink hlink
    load_state
    addr="$(server_addr)"

    title "节点信息"
    if [ "$VLESS_ENABLED" = "1" ]; then
        vlink="$(vless_link)"
        printf "${BOLD}VLESS (XHTTP + REALITY + Vision + ML-KEM-768)${RES}\n"
        printf '  地址: %s   端口: %s\n' "$addr" "$VLESS_PORT"
        printf '  链接: %s\n' "$vlink"
        printf "${GREEN}  → v2rayN: 复制上面的链接，Ctrl+V 导入${RES}\n"
        qr_show "$vlink" vless
    fi

    if [ "$HY2_ENABLED" = "1" ]; then
        hlink="$(hy2_link)"
        printf "${BOLD}Hysteria2${RES}\n"
        printf '  地址: %s  端口: %s (UDP)\n' "$addr" "$HY2_PORT"
        printf '  链接: %s\n' "$hlink"
        printf '  证书 pin: %s\n' "$HY2_HASH"
        qr_show "$hlink" hy2
    fi

    if [ "$VLESS_ENABLED" != "1" ] && [ "$HY2_ENABLED" != "1" ]; then
        warn "还没有节点，先执行部署"
        return 0
    fi

    printf '\n  链接文件: %s\n' "$CLIENT_DIR/links.txt"
    printf '  客户端配置: %s\n' "$CLIENT_DIR"
    printf '  下载到本地: %sscp -r root@%s:%s ./xray-client%s\n' "$CYAN" "$addr" "$CLIENT_DIR" "$RES"
}

# ------------------------------- 菜单 --------------------------------------
show_status() {
    title "当前状态"
    if has "$XRAY_BIN"; then
        printf '  内核: %s\n' "$("$XRAY_BIN" version | head -n1)"
    else
        printf '  内核: %s未安装%s\n' "$RED" "$RES"
    fi
    if have_systemd; then
        printf '  服务: %s\n' "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
    fi
    printf '  VLESS: %s (端口 %s)\n' "$([ "$VLESS_ENABLED" = "1" ] && echo 已启用 || echo 未启用)" "$VLESS_PORT"
    printf '  Hysteria2: %s (端口 %s/udp)\n' "$([ "$HY2_ENABLED" = "1" ] && echo 已启用 || echo 未启用)" "$HY2_PORT"
}

do_bbr() {
    title "开启 BBR"
    if [ ! -f /etc/sysctl.d/99-bbr.conf ]; then
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf
    fi
    sysctl --system >/dev/null 2>&1
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已开启"
    else
        warn "当前内核可能不支持 BBR（需要 4.9+）"
    fi
}

do_uninstall() {
    title "卸载"
    confirm "确认卸载 Xray 并删除配置/密钥？" || { info "已取消"; return 0; }
    svc stop
    if have_systemd; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$XRAY_BIN"
    rm -rf "$CONF_DIR" "$ASSET_DIR" "$CLIENT_DIR"
    ok "已卸载"
}

menu() {
    while true; do
        title "Xray 管理脚本"
        show_status
        printf '\n'
        printf '  %s1)%s 安装 / 更新 Xray 内核\n' "$GREEN" "$RES"
        printf '  %s2)%s 部署 / 更新 VLESS 节点 (XHTTP + REALITY + Vision + 后量子)\n' "$GREEN" "$RES"
        printf '  %s3)%s 部署 / 更新 Hysteria2 节点\n' "$GREEN" "$RES"
        printf '  %s4)%s 查看节点链接 + 二维码\n' "$GREEN" "$RES"
        printf '  %s5)%s 重新生成客户端配置\n' "$GREEN" "$RES"
        printf '  %s6)%s 重启服务\n' "$GREEN" "$RES"
        printf '  %s7)%s 查看日志\n' "$GREEN" "$RES"
        printf '  %s8)%s 开启 BBR\n' "$GREEN" "$RES"
        printf '  %s9)%s 卸载\n' "$GREEN" "$RES"
        printf '  %s0)%s 退出\n' "$GREEN" "$RES"
        printf '\n'
        local c
        read -r -p "请选择 [0-9]: " c
        case "$c" in
            1) install_xray ;;
            2) deploy_vless ;;
            3) deploy_hy2 ;;
            4) preflight && render_clients && print_nodes ;;
            5) preflight && render_clients ;;
            6) svc_restart && ok "已重启" ;;
            7) have_systemd && journalctl -u "$SERVICE_NAME" -n 50 --no-pager ;;
            8) do_bbr ;;
            9) do_uninstall ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        printf '\n'
        [ "$ASSUME_YES" = "1" ] && exit 0
        read -r -p "按回车继续..." _ || true
    done
}

# ------------------------------- 入口 --------------------------------------
usage() {
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    case "${1:-menu}" in
        menu)        menu ;;
        install)     preflight && install_xray && { [ "$VLESS_ENABLED" = "1" ] || [ "$HY2_ENABLED" = "1" ]; } && apply_config ;;
        vless)       deploy_vless ;;
        hy2)         deploy_hy2 ;;
        links)       preflight && print_nodes ;;
        client)      preflight && render_clients ;;
        start)       svc start ;;
        stop)        svc stop ;;
        restart)     svc_restart ;;
        status)      show_status ;;
        log)         have_systemd && journalctl -u "$SERVICE_NAME" -n 50 --no-pager ;;
        bbr)         do_bbr ;;
        uninstall)   do_uninstall ;;
        -h|--help|help) usage ;;
        *) err "未知命令: $1"; usage; exit 1 ;;
    esac
}

# 只有直接执行时才进入主流程（source 时可单独调用函数做测试/复用）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
