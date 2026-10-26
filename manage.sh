#!/bin/bash
###############################################################################
#
# Xray Docker Manage Script
#
# Version: 1.0.0
# Last Updated: 2026-10-26
#
# Description:
#   Docker Compose 管理脚本，用于本仓库的 Xray 节点：
#       XHTTP  +  VLESS Encryption (ML-KEM-768)  +  XTLS Vision  +  REALITY
#
#   全部节点密钥（UUID / x25519 / shortId / XHTTP 路径 / 后量子密钥）
#   都由容器内的 entrypoint 自动生成，本脚本只负责：
#     - 拉镜像、起容器、更新、卸载
#     - 部署完直接弹出节点链接 + 二维码
#     - 导出客户端配置 client.json
#     - 轮换密钥、备份、看日志
#
#   VPS 上跑的是服务端 data/server.json（脚本自己管，不用你碰）
#   你拿走的东西：节点链接 / 二维码 / 客户端 client.json
#
# Requirements:
#   - Linux / macOS 上的 Docker Engine + Compose v2
#   - 可选：qrencode（显示二维码，没有会自动尝试安装）
#
# Author: MinimaxFlora
#
# License: MIT
#
###############################################################################

# 颜色定义
RED_COLOR='\e[1;31m'
GREEN_COLOR='\e[1;32m'
YELLOW_COLOR='\e[1;33m'
BLUE_COLOR='\e[1;34m'
CYAN_COLOR='\e[1;36m'
PURPLE_COLOR='\e[1;35m'
BOLD='\e[1m'
RES='\e[0m'

CURRENT_OS=$(uname -s)

# =============================================================================
# 配置部分
# =============================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
DATA_DIR="$SCRIPT_DIR/data"
LINK_FILE="$DATA_DIR/vless-link.txt"
CLIENT_FILE="$DATA_DIR/client.json"
INFO_FILE="$DATA_DIR/connection-info.txt"

DEFAULT_IMAGE="dockorae/xray-core:v26.10.21"
DEFAULT_PORT="443"
DEFAULT_SNI="www.lovelive-anime.jp"
DEFAULT_NODE_NAME="Xray"

# 非交互模式：1 时所有询问取默认值（自动化用）
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# =============================================================================
# 工具函数
# =============================================================================
print_line() {
    printf "%s\n" "$1"
}

ask_value() {
    local prompt="$1" default="$2" value
    if [ "$NONINTERACTIVE" = "1" ]; then
        echo "$default"
        return 0
    fi
    read -r -p "$prompt [$default]: " value
    [ -z "$value" ] && value="$default"
    echo "$value"
}

ask_yes() {
    local prompt="$1"
    [ "$NONINTERACTIVE" = "1" ] && return 0
    local answer
    read -r -p "$prompt [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@" >/dev/null 2>&1
    elif command -v brew >/dev/null 2>&1; then
        brew install "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

# docker compose 命令（v2 插件优先，兼容老的 docker-compose）
set_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD=""
    fi
}

compose() {
    [ -z "$COMPOSE_CMD" ] && return 1
    # shellcheck disable=SC2086
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

INSTALL_DOCKER() {
    echo -e "${BLUE_COLOR}使用 Docker 官方脚本安装（https://get.docker.com）...${RES}"
    if ! curl -fsSL https://get.docker.com | sh; then
        echo -e "${RED_COLOR}Docker 安装失败，请手动安装：https://docs.docker.com/engine/install/${RES}"
        exit 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker  >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        rc-service docker start >/dev/null 2>&1 || true
    fi
    local i
    for i in $(seq 1 15); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
    echo -e "${GREEN_COLOR}Docker 已就绪：$(docker --version)${RES}"
}

CHECK_ENV() {
    if ! command -v curl >/dev/null 2>&1; then
        install_pkg curl >/dev/null 2>&1 || true
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW_COLOR}未检测到 Docker${RES}"
        if [ "$(id -u)" != "0" ]; then
            echo -e "${RED_COLOR}自动安装需要 root，请用 sudo 运行${RES}"
            exit 1
        fi
        if [ "$NONINTERACTIVE" = "1" ] || ask_yes "是否用官方脚本自动安装 Docker？"; then
            INSTALL_DOCKER
        else
            echo -e "${YELLOW_COLOR}已取消。手动安装：curl -fsSL https://get.docker.com | sh${RES}"
            exit 1
        fi
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED_COLOR}错误：docker 守护进程没有运行${RES}"
        echo -e "${YELLOW_COLOR}尝试启动：${RES}systemctl start docker"
        exit 1
    fi

    set_compose_cmd
    if [ -z "$COMPOSE_CMD" ]; then
        echo -e "${YELLOW_COLOR}未找到 docker compose，尝试安装插件...${RES}"
        install_pkg docker-compose-v2 >/dev/null 2>&1 || install_pkg docker-compose-plugin >/dev/null 2>&1 || true
        set_compose_cmd
    fi
    if [ -z "$COMPOSE_CMD" ]; then
        echo -e "${RED_COLOR}错误：未找到 docker compose（v2 插件）或 docker-compose${RES}"
        echo -e "${YELLOW_COLOR}Debian/Ubuntu: ${RES}apt install docker-compose-v2"
        echo -e "${YELLOW_COLOR}官方插件: ${RES}https://docs.docker.com/compose/install/linux/"
        exit 1
    fi

    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${RED_COLOR}错误：找不到 $COMPOSE_FILE${RES}"
        echo -e "${YELLOW_COLOR}请在仓库目录里运行本脚本${RES}"
        exit 1
    fi
}

# 读取 .env 里的某个值（不存在则用默认值）
env_get() {
    local key="$1" default="$2" value
    if [ -f "$ENV_FILE" ]; then
        value=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)
    fi
    [ -z "$value" ] && value="$default"
    echo "$value"
}

env_set() {
    local key="$1" value="$2"
    if [ ! -f "$ENV_FILE" ]; then
        return 1
    fi
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

WRITE_DEFAULT_ENV() {
    if [ -f "$ENV_FILE" ]; then
        return 0
    fi
    echo -e "${BLUE_COLOR}生成默认配置文件 .env ...${RES}"
    cat > "$ENV_FILE" <<EOF
# ---------------------------------------------------------------------------
# docker compose 会自动读取这个文件
# 改完执行：docker compose up -d（脚本会重渲染配置，密钥不变）
# ---------------------------------------------------------------------------

# 镜像（tag 跟随内置 Xray 内核版本；升级时改这里）
IMAGE=${DEFAULT_IMAGE}

# 对外端口（容器内固定监听 443）
PORT=${DEFAULT_PORT}

# 伪装站点 == REALITY target == serverName
# 要求：TLS 1.3 + HTTP/2 + 证书包含该域名
SNI=${DEFAULT_SNI}

# 服务器公网地址，留空=自动探测；探测失败时链接里会是 YOUR_SERVER_IP
SERVER_ADDR=

# 客户端显示的节点名（仅 ASCII）
NODE_NAME=${DEFAULT_NODE_NAME}

# 1 = 本次启动轮换全部密钥（用完记得改回 0）
REGEN=0

TZ=Asia/Shanghai
EOF
    chmod 600 "$ENV_FILE"
    echo -e "${GREEN_COLOR}已生成 $ENV_FILE${RES}"
}

# 等待容器生成链接文件
WAIT_FOR_LINK() {
    local i
    echo -e "${BLUE_COLOR}等待容器生成节点信息...${RES}"
    for i in $(seq 1 30); do
        if [ -s "$LINK_FILE" ]; then
            return 0
        fi
        sleep 2
        printf "."
    done
    echo
    echo -e "${YELLOW_COLOR}30 秒内没等到 $LINK_FILE，请用“查看日志”排查${RES}"
    return 1
}

GET_LINK() {
    if [ -s "$LINK_FILE" ]; then
        grep -m1 '^vless://' "$LINK_FILE"
    fi
}

SHOW_QR() {
    local text="$1" name="$2"

    [ -z "$text" ] && return 0
    if [ "${NO_QR:-0}" = "1" ]; then
        echo -e "${YELLOW_COLOR}NO_QR=1，跳过二维码（链接已给出）${RES}"
        return 0
    fi

    if ! command -v qrencode >/dev/null 2>&1; then
        echo -e "${BLUE_COLOR}安装 qrencode 以显示二维码...${RES}"
        install_pkg qrencode >/dev/null 2>&1
    fi

    if command -v qrencode >/dev/null 2>&1; then
        # 链接很长（后量子密钥），只留 1 格白边；非终端（重定向/日志）不刷屏
        if [ -t 1 ]; then
            echo
            qrencode -t ANSIUTF8 -m 1 "$text" 2>/dev/null
            echo
        fi
        if qrencode -o "$DATA_DIR/qr-$name.png" -s 4 -m 1 "$text" 2>/dev/null; then
            echo -e "${GREEN_COLOR}二维码图片：$DATA_DIR/qr-$name.png${RES}"
        fi
    else
        echo -e "${YELLOW_COLOR}未安装 qrencode，跳过二维码（链接已给出）${RES}"
        echo -e "${YELLOW_COLOR}手动安装：apt install qrencode / brew install qrencode${RES}"
    fi
}

# =============================================================================
# 主流程
# =============================================================================
INSTALL() {
    CHECK_ENV
    WRITE_DEFAULT_ENV

    local port sni node_name image
    port=$(env_get PORT "$DEFAULT_PORT")
    sni=$(env_get SNI "$DEFAULT_SNI")
    node_name=$(env_get NODE_NAME "$DEFAULT_NODE_NAME")
    image=$(env_get IMAGE "$DEFAULT_IMAGE")

    echo -e "\n${PURPLE_COLOR}${BOLD}==== 部署 Xray 节点 ====${RES}"
    port=$(ask_value "对外端口" "$port")
    sni=$(ask_value "伪装站点（REALITY target / serverName）" "$sni")
    node_name=$(ask_value "节点名称" "$node_name")

    env_set IMAGE "$image"
    env_set PORT "$port"
    env_set SNI "$sni"
    env_set NODE_NAME "$node_name"

    echo -e "\n${GREEN_COLOR}拉取镜像：$image${RES}"
    if ! compose pull; then
        echo -e "${RED_COLOR}镜像拉取失败${RES}"
        echo -e "${YELLOW_COLOR}国内 VPS 可以改 .env 里的 IMAGE，例如：${RES}"
        echo -e "  IMAGE=ghcr.io/minimaxflora/xray-core:v26.10.21"
        echo -e "${YELLOW_COLOR}或者用国内加速：${RES}"
        echo -e "  IMAGE=ghcr.m.daocloud.io/xtls/xray-core:26.10.21"
        return 1
    fi

    echo -e "${GREEN_COLOR}启动容器 ...${RES}"
    if ! compose up -d; then
        echo -e "${RED_COLOR}容器启动失败，请查看日志${RES}"
        return 1
    fi

    if WAIT_FOR_LINK; then
        SUCCESS
    else
        echo -e "${YELLOW_COLOR}容器已启动，但还没拿到链接，试试“查看日志”${RES}"
    fi
}

UPDATE() {
    CHECK_ENV
    local image
    image=$(env_get IMAGE "$DEFAULT_IMAGE")
    echo -e "${BLUE_COLOR}当前镜像：$image${RES}"
    echo -e "${GREEN_COLOR}拉取最新镜像 ...${RES}"
    compose pull || { echo -e "${RED_COLOR}拉取失败${RES}"; return 1; }
    compose up -d || { echo -e "${RED_COLOR}重启失败${RES}"; return 1; }
    echo -e "${GREEN_COLOR}已更新并重启（密钥保存在 data/keys.env，客户端不会掉）${RES}"
}

UNINSTALL() {
    CHECK_ENV
    echo -e "${YELLOW_COLOR}即将停止并删除容器${RES}"
    if [ -d "$DATA_DIR" ]; then
        echo -e "${YELLOW_COLOR}同时会删除 $DATA_DIR（含节点密钥，删了客户端就再也连不上）${RES}"
    fi
    if ! ask_yes "确认卸载？"; then
        echo -e "${GREEN_COLOR}已取消${RES}"
        return 0
    fi

    compose down >/dev/null 2>&1
    if ask_yes "是否同时删除 data 目录（密钥/配置）？"; then
        rm -rf "$DATA_DIR"
        echo -e "${GREEN_COLOR}已删除容器和 data 目录${RES}"
    else
        echo -e "${GREEN_COLOR}容器已删除，data 目录保留${RES}"
    fi
}

STATUS() {
    CHECK_ENV
    echo -e "\n${PURPLE_COLOR}${BOLD}==== 系统状态 ====${RES}"
    echo -e "${GREEN_COLOR}系统${RES}   ：$CURRENT_OS $(uname -m)"
    echo -e "${GREEN_COLOR}Compose${RES}：$COMPOSE_CMD"
    echo -e "${GREEN_COLOR}镜像${RES}   ：$(env_get IMAGE "$DEFAULT_IMAGE")"
    echo -e "${GREEN_COLOR}端口${RES}   ：$(env_get PORT "$DEFAULT_PORT")"
    echo -e "${GREEN_COLOR}SNI${RES}    ：$(env_get SNI "$DEFAULT_SNI")"
    echo
    compose ps
}

SHOW_NODES() {
    local link info
    link=$(GET_LINK)
    if [ -z "$link" ]; then
        echo -e "${RED_COLOR}还没有生成节点，请先“安装 / 启动节点”${RES}"
        return 1
    fi

    echo -e "\n${PURPLE_COLOR}${BOLD}==== 节点信息 ====${RES}"
    if [ -s "$INFO_FILE" ]; then
        sed -n '1,15p' "$INFO_FILE" | while IFS= read -r line; do
            case "$line" in
                ""|"Xray node:"*|"generated:"*) continue ;;
                *) echo -e "${GREEN_COLOR}$line${RES}" ;;
            esac
        done
    fi

    echo -e "\n${GREEN_COLOR}分享链接：${RES}"
    echo -e "${CYAN_COLOR}$link${RES}"
    echo
    echo -e "${GREEN_COLOR}链接文件：${RES}$LINK_FILE"
    echo -e "${GREEN_COLOR}客户端配置：${RES}$CLIENT_FILE"

    SHOW_QR "$link" vless

    echo -e "\n${GREEN_COLOR}复制链接到 v2rayN：Ctrl+V 导入${RES}"
}

EXPORT_CLIENT() {
    if [ ! -s "$CLIENT_FILE" ]; then
        echo -e "${RED_COLOR}还没有 $CLIENT_FILE，请先启动节点${RES}"
        return 1
    fi
    local target="$SCRIPT_DIR/client.json"
    cp -f "$CLIENT_FILE" "$target"
    chmod 600 "$target"
    echo -e "${GREEN_COLOR}客户端配置已导出：$target${RES}"
    echo -e "${YELLOW_COLOR}它包含节点密钥，别提交到 git、别外传${RES}"
    echo
    echo -e "${GREEN_COLOR}用法：${RES}"
    echo -e "  xray run -c client.json     # socks5 127.0.0.1:10808 / http 127.0.0.1:10809"
    echo -e "  系统代理填 127.0.0.1:10809"
    echo
    local addr
    addr=$(env_get SERVER_ADDR "")
    [ -z "$addr" ] && addr="<VPS_IP>"
    echo -e "${GREEN_COLOR}从 VPS 下载到本地：${RES}"
    echo -e "  scp root@$addr:$target ./client.json"
}

ROTATE_KEYS() {
    CHECK_ENV
    if [ ! -f "$DATA_DIR/keys.env" ]; then
        echo -e "${RED_COLOR}还没有节点，请先安装${RES}"
        return 1
    fi
    echo -e "${YELLOW_COLOR}轮换会生成新的 UUID / x25519 / shortId / 路径 / 后量子密钥${RES}"
    echo -e "${YELLOW_COLOR}旧客户端会立即失效${RES}"
    if ! ask_yes "确认轮换？"; then
        echo -e "${GREEN_COLOR}已取消${RES}"
        return 0
    fi

    if ! compose run --rm xray keygen --force; then
        echo -e "${RED_COLOR}生成新密钥失败${RES}"
        return 1
    fi
    compose up -d >/dev/null 2>&1
    WAIT_FOR_LINK
    echo -e "${GREEN_COLOR}已轮换并重启${RES}"
    SHOW_NODES
}

BACKUP() {
    if [ ! -d "$DATA_DIR" ]; then
        echo -e "${RED_COLOR}没有可备份的 data 目录${RES}"
        return 1
    fi
    local file="$SCRIPT_DIR/xray-data-backup-$(date +%Y%m%d%H%M%S).tar.gz"
    tar czf "$file" -C "$SCRIPT_DIR" data >/dev/null 2>&1
    if [ -f "$file" ]; then
        chmod 600 "$file"
        echo -e "${GREEN_COLOR}已备份：$file${RES}"
        echo -e "${YELLOW_COLOR}备份含节点密钥，注意保管${RES}"
    else
        echo -e "${RED_COLOR}备份失败${RES}"
        return 1
    fi
}

EDIT_ENV() {
    if [ ! -f "$ENV_FILE" ]; then
        WRITE_DEFAULT_ENV
    fi
    local editor="${EDITOR:-nano}"
    if ! command -v "$editor" >/dev/null 2>&1; then
        editor="vi"
    fi
    "$editor" "$ENV_FILE"
    echo -e "${GREEN_COLOR}改完执行“重启”或 docker compose up -d 生效${RES}"
}

SHOW_LOG() {
    CHECK_ENV
    compose logs --tail 100
}

SUCCESS() {
    local link addr port
    link=$(GET_LINK)
    addr=$(env_get SERVER_ADDR "")
    port=$(env_get PORT "$DEFAULT_PORT")

    if [ -z "$addr" ] && [ -s "$INFO_FILE" ]; then
        addr=$(sed -n 's/^address[[:space:]]*:[[:space:]]*//p' "$INFO_FILE" | head -n1)
    fi
    [ -z "$addr" ] && addr=$(printf '%s' "$link" | sed -n 's|^vless://[^@]*@\[\([^]]*\)\].*|\1|p;s|^vless://[^@]*@\([^:]*\):.*|\1|p')

    echo
    echo -e "${PURPLE_COLOR}==================================================${RES}"
    echo -e "${GREEN_COLOR}${BOLD}  Xray 节点部署成功！${RES}"
    echo -e "${PURPLE_COLOR}==================================================${RES}"
    echo -e "  协议组合：VLESS + XHTTP + REALITY + Vision"
    echo -e "            + VLESS Encryption (ML-KEM-768)"
    echo -e "  服务器：  $addr:$port"
    echo -e "  伪装站点：$(env_get SNI "$DEFAULT_SNI")"
    echo -e "  客户端配置：data/client.json"
    echo -e "  节点链接：  data/vless-link.txt"
    echo -e "  服务端配置：data/server.json（不用你管）"
    echo -e "${PURPLE_COLOR}==================================================${RES}"

    echo -e "\n${GREEN_COLOR}节点链接（复制到 v2rayN：Ctrl+V 导入）${RES}"
    echo -e "${CYAN_COLOR}$link${RES}"
    SHOW_QR "$link" vless

    echo -e "\n${GREEN_COLOR}导出客户端配置：sudo bash manage.sh client${RES}"
    echo -e "${GREEN_COLOR}以后随时查看链接：sudo bash manage.sh links${RES}"
    echo -e "${YELLOW_COLOR}提示：连不上先看安全组/防火墙是否放行 $port/tcp${RES}"
    echo
}

# =============================================================================
# 菜单
# =============================================================================
SHOW_MENU() {
    while true; do
        echo -e "\n欢迎使用 Xray Docker 管理脚本\n"
        echo -e "${GREEN_COLOR}基础功能：${RES}"
        echo -e "${GREEN_COLOR}1、安装 / 启动节点${RES}"
        echo -e "${GREEN_COLOR}2、更新镜像${RES}"
        echo -e "${GREEN_COLOR}3、卸载${RES}"
        echo -e "${GREEN_COLOR}-------------------${RES}"
        echo -e "${GREEN_COLOR}服务管理：${RES}"
        echo -e "${GREEN_COLOR}4、查看状态${RES}"
        echo -e "${GREEN_COLOR}5、启动${RES}"
        echo -e "${GREEN_COLOR}6、停止${RES}"
        echo -e "${GREEN_COLOR}7、重启${RES}"
        echo -e "${GREEN_COLOR}8、查看日志${RES}"
        echo -e "${GREEN_COLOR}-------------------${RES}"
        echo -e "${GREEN_COLOR}节点管理：${RES}"
        echo -e "${GREEN_COLOR}9、查看节点链接 + 二维码${RES}"
        echo -e "${GREEN_COLOR}10、导出客户端配置 client.json${RES}"
        echo -e "${GREEN_COLOR}11、轮换节点密钥${RES}"
        echo -e "${GREEN_COLOR}-------------------${RES}"
        echo -e "${GREEN_COLOR}配置管理：${RES}"
        echo -e "${GREEN_COLOR}12、编辑 .env${RES}"
        echo -e "${GREEN_COLOR}13、备份 data${RES}"
        echo -e "${GREEN_COLOR}-------------------${RES}"
        echo -e "${GREEN_COLOR}0、退出脚本${RES}"
        echo
        read -r -p "请输入选项 [0-13]: " choice

        case "$choice" in
            1) INSTALL ;;
            2) UPDATE ;;
            3) UNINSTALL ;;
            4) STATUS ;;
            5) CHECK_ENV && compose up -d && echo -e "${GREEN_COLOR}已启动${RES}" ;;
            6) CHECK_ENV && compose stop && echo -e "${GREEN_COLOR}已停止${RES}" ;;
            7) CHECK_ENV && compose restart && echo -e "${GREEN_COLOR}已重启${RES}" ;;
            8) SHOW_LOG ;;
            9) SHOW_NODES ;;
            10) EXPORT_CLIENT ;;
            11) ROTATE_KEYS ;;
            12) EDIT_ENV ;;
            13) BACKUP ;;
            0) exit 0 ;;
            *) echo -e "${RED_COLOR}无效选项${RES}" ;;
        esac

        echo
        read -r -p "按回车继续..." _
    done
}

# =============================================================================
# 入口
# =============================================================================
case "${1:-}" in
    install)   INSTALL ;;
    update)    UPDATE ;;
    uninstall) UNINSTALL ;;
    links)     SHOW_NODES ;;
    client)    EXPORT_CLIENT ;;
    rotate)    ROTATE_KEYS ;;
    status)    STATUS ;;
    start)     CHECK_ENV && compose up -d ;;
    stop)      CHECK_ENV && compose stop ;;
    restart)   CHECK_ENV && compose restart ;;
    log)       SHOW_LOG ;;
    backup)    BACKUP ;;
    ""|menu)   SHOW_MENU ;;
    *)
        echo -e "${RED_COLOR}用法：${RES}$0 [install|update|uninstall|links|client|rotate|status|start|stop|restart|log|backup]"
        exit 1
        ;;
esac
