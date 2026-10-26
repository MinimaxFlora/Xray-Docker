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
CERT_DIR="$DATA_DIR/certs"
SUB_DIR="$DATA_DIR/sub"
ACME="$HOME/.acme.sh/acme.sh"
INFO_FILE="$DATA_DIR/connection-info.txt"

DEFAULT_IMAGE="dockorae/xray-core:v26.10.21"
DEFAULT_PORT="443"
DEFAULT_SNI="www.lovelive-anime.jp"
DEFAULT_NODE_NAME="Xray"

# 非交互模式：1 时所有询问取默认值（自动化用）
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# 提示：`curl | sudo bash` 时 sudo 的 stdin 是脚本管道，终端输入根本到不了子进程，
# 这时候读输入只会卡住。所以交互类操作前会检查 tty（见 require_tty）。
if [ ! -t 0 ] && [ "$NONINTERACTIVE" != "1" ]; then
    NO_TTY=1
else
    NO_TTY=0
fi

# =============================================================================
# 工具函数
# =============================================================================
print_line() {
    printf "%s\n" "$1"
}

require_tty() {
    if [ "$NO_TTY" = "1" ]; then
        echo -e "${RED_COLOR}当前不是交互终端，读不到你的输入。${RES}" >&2
        echo -e "${YELLOW_COLOR}原因：用 \`curl ... | sudo bash\` 时 sudo 的 stdin 是脚本管道。${RES}" >&2
        echo -e "${YELLOW_COLOR}请改用：${RES}" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/Xray-Docker/main/install.sh -o /tmp/xray-install.sh" >&2
        echo "  sudo bash /tmp/xray-install.sh" >&2
        echo -e "${YELLOW_COLOR}或者全默认：${RES}  curl -fsSL .../install.sh | sudo bash -s -- --auto" >&2
        return 1
    fi
    return 0
}

ASK_TIMEOUT="${ASK_TIMEOUT:-180}"

ask_value() {
    local prompt="$1" default="$2" value=""
    if [ "$NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then
        echo "$default"
        return 0
    fi
    printf '%s [%s]: ' "$prompt" "$default" >&2
    if ! IFS= read -r -t "$ASK_TIMEOUT" value; then
        printf '\n%s\n' "（${ASK_TIMEOUT}s 没输入，用默认值 $default）" >&2
        value="$default"
    fi
    [ -z "$value" ] && value="$default"
    printf '%s' "$value"
}

ask_yes() {
    local prompt="$1" answer=""
    if [ "$NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then
        return 0
    fi
    printf '%s [y/N]: ' "$prompt" >&2
    if ! IFS= read -r -t "$ASK_TIMEOUT" answer; then
        printf '\n%s\n' "（${ASK_TIMEOUT}s 没输入，按 N 处理）" >&2
        return 1
    fi
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
        # 链接很长（后量子密钥），只留 1 格白边
        echo
        qrencode -t ANSIUTF8 -m 1 "$text" 2>/dev/null
        echo
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
    require_tty || return 1
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

    # data 被删过但旧容器还在时，compose 不会重建 -> 密钥永远生成不出来
    if [ ! -f "$DATA_DIR/keys.env" ]; then
        echo -e "${YELLOW_COLOR}没有找到节点密钥，强制重建容器${RES}"
        if ! compose up -d --force-recreate; then
            echo -e "${RED_COLOR}容器启动失败，请查看日志${RES}"
            return 1
        fi
    elif ! compose up -d; then
        echo -e "${RED_COLOR}容器启动失败，请查看日志${RES}"
        return 1
    fi

    if WAIT_FOR_LINK; then
        SUCCESS
    else
        echo -e "${YELLOW_COLOR}容器已启动，但还没拿到链接，试试“查看日志”${RES}"
    fi
    # 可选：域名 → 证书 → HTTPS 订阅
    local domain email
    domain=$(ask_value "域名（可选：填了就申请证书并生成 HTTPS 订阅；直接回车跳过）" "$(env_get CERT_HOST "")")
    if [ -n "$domain" ]; then
        email=$(ask_value "Let's Encrypt 联系邮箱（可留空）" "$(env_get ACME_EMAIL "")")
        if ISSUE_CERT 1 "$domain" "$email"; then
            SUB
        else
            echo -e "${YELLOW_COLOR}证书没申请成功，订阅先跳过；修好后执行：sudo bash manage.sh sub${RES}"
        fi
    else
        echo -e "${YELLOW_COLOR}跳过证书/订阅。以后要加：sudo bash manage.sh cert && sudo bash manage.sh sub${RES}"
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
    require_tty || return 1
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
    require_tty || return 1
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

INSTALL_CLI() {
    local wrapper="${XRAY_CLI_PATH:-/usr/local/bin/xray}"
    local target="$SCRIPT_DIR/manage.sh"

    if [ ! -f "$target" ]; then
        echo -e "${RED_COLOR}找不到 $target${RES}"
        return 1
    fi

    # 已有真正的 xray 二进制就不覆盖
    if [ -e "$wrapper" ] && ! grep -q "manage.sh" "$wrapper" 2>/dev/null; then
        echo -e "${YELLOW_COLOR}$wrapper 已存在且不是本脚本的快捷方式，跳过${RES}"
        echo -e "${YELLOW_COLOR}可以手动加：alias xray='bash $target'${RES}"
        return 1
    fi

    cat > "$wrapper" <<EOF
#!/bin/bash
# Xray 节点管理菜单（由 manage.sh 生成）
exec bash "$target" "\$@"
EOF
    chmod +x "$wrapper"

    # 顺手给个首字母大写的别名
    if [ ! -e "${wrapper}Xray" ] && [ "$(dirname "$wrapper")" = "/usr/local/bin" ]; then
        ln -sf "$wrapper" /usr/local/bin/Xray 2>/dev/null || true
    fi

    echo -e "${GREEN_COLOR}快捷命令已安装：${RES}"
    echo -e "  输入 ${CYAN_COLOR}xray${RES} 或 ${CYAN_COLOR}Xray${RES} 打开管理菜单"
    echo -e "  也支持 ${CYAN_COLOR}xray links${RES} / ${CYAN_COLOR}xray client${RES} / ${CYAN_COLOR}xray cert${RES} ..."
    return 0
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
# 证书（acme.sh）与订阅
# =============================================================================
CERT_HOST=""       # 证书域名或 IP，存在 .env 里
SUB_TOKEN=""       # 订阅随机路径

cert_host() {
    local h
    h=$(env_get CERT_HOST "")
    [ -z "$h" ] && h=$(env_get SERVER_ADDR "")
    [ -z "$h" ] && h=$(get_public_ip)
    printf '%s' "$h"
}

ensure_acme() {
    if [ -x "$ACME" ]; then
        return 0
    fi
    echo -e "${BLUE_COLOR}安装 acme.sh ...${RES}"
    if ! curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1; then
        echo -e "${RED_COLOR}acme.sh 安装失败${RES}"
        return 1
    fi
    [ -x "$ACME" ] || { echo -e "${RED_COLOR}acme.sh 未就位：$ACME${RES}"; return 1; }
    echo -e "${GREEN_COLOR}acme.sh 已安装${RES}"
    return 0
}

get_public_ip() {
    local ip
    ip=$(env_get SERVER_ADDR "")
    if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
    ip=$(curl -s4 --connect-timeout 5 ip.sb 2>/dev/null | tr -d '[:space:]')
    [ -z "$ip" ] && ip=$(curl -s4 --connect-timeout 5 ifconfig.me 2>/dev/null | tr -d '[:space:]')
    [ -z "$ip" ] && ip=$(curl -s4 --connect-timeout 5 api.ipify.org 2>/dev/null | tr -d '[:space:]')
    [ -z "$ip" ] && ip="YOUR_SERVER_IP"
    printf '%s' "$ip"
}

ISSUE_CERT() {
    require_tty || return 1
    local mode="$1" host="$2" email="$3"

    if [ -z "$host" ] || [ "$host" = "YOUR_SERVER_IP" ]; then
        echo -e "${RED_COLOR}地址无效：$host${RES}"
        return 1
    fi

    ensure_acme || return 1

    # Let's Encrypt 要一个可用邮箱；example.com 会被拒（invalidContact）
    if [ -z "$email" ] && [ "$NONINTERACTIVE" != "1" ]; then
        echo -e "${YELLOW_COLOR}Let's Encrypt 需要联系邮箱（可留空；被拒过就换个真实的）${RES}"
        email=$(ask_value "邮箱" "$(env_get ACME_EMAIL "")")
    fi
    if [ -n "$email" ]; then
        case "$email" in
            *@example.com|*@example.org|*@test.com)
                echo -e "${RED_COLOR}$email 是保留域名，Let's Encrypt 会拒绝，请换真实邮箱${RES}"
                return 1 ;;
            *@*.*) : ;;
            *) echo -e "${RED_COLOR}邮箱格式不对：$email${RES}"; return 1 ;;
        esac
        env_set ACME_EMAIL "$email"
    fi

    # 之前用占位邮箱注册失败过：清掉/替换 account.conf 里的 ACCOUNT_EMAIL
    local acc_conf="$HOME/.acme.sh/account.conf"
    if [ -f "$acc_conf" ]; then
        if [ -n "$email" ]; then
            sed -i.bak "s|^ACCOUNT_EMAIL=.*|ACCOUNT_EMAIL='$email'|" "$acc_conf" 2>/dev/null || true
        else
            sed -i.bak "/^ACCOUNT_EMAIL=/d" "$acc_conf" 2>/dev/null || true
        fi
        rm -f "${acc_conf}.bak" 2>/dev/null || true
    fi

    if [ -n "$email" ]; then
        "$ACME" --register-account -m "$email" --server letsencrypt --force >/dev/null 2>&1 || true
        "$ACME" --update-account -m "$email" --server letsencrypt >/dev/null 2>&1 || true
    else
        "$ACME" --register-account --server letsencrypt --force >/dev/null 2>&1 || true
    fi

    echo -e "\n${YELLOW_COLOR}注意：HTTP-01 必须能通过 80 端口访问到本机，且 80 端口空闲。${RES}"
    mkdir -p "$CERT_DIR"

    "$ACME" --set-default-ca --server letsencrypt --force >/dev/null 2>&1

    local -a issue_args
    issue_args=(--issue -d "$host" --standalone --httpport 80 --force)
    if [ "$mode" = "2" ]; then
        issue_args+=(--certificate-profile shortlived)
    fi

    echo -e "${BLUE_COLOR}签发中：$host ...${RES}"
    if ! "$ACME" "${issue_args[@]}"; then
        echo -e "${RED_COLOR}签发失败${RES}"
        echo -e "${YELLOW_COLOR}排查：${RES}"
        echo -e "  - 80 端口是否放行 / 被占用（systemctl stop nginx apache2）"
        echo -e "  - 域名 $host 是否解析到本机公网 IP（dig +short $host）"
        echo -e "  - 邮箱被拒（example.com / test.com 不行，用 ACME_EMAIL=you@qq.com 重试）"
        echo -e "  - Let's Encrypt 对同一 IP / 域名的频率限制"
        echo -e "${YELLOW_COLOR}详细日志：$HOME/.acme.sh/acme.sh.log${RES}"
        return 1
    fi

    if ! "$ACME" --installcert -d "$host" \
        --key-file "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd "docker restart xray-sub >/dev/null 2>&1 || true" >/dev/null 2>&1; then
        if [ ! -s "$CERT_DIR/fullchain.pem" ]; then
            echo -e "${RED_COLOR}证书安装失败${RES}"
            return 1
        fi
    fi

    chmod 600 "$CERT_DIR/privkey.pem" 2>/dev/null || true
    chmod 644 "$CERT_DIR/fullchain.pem" 2>/dev/null || true
    "$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true

    env_set CERT_HOST "$host"
    echo -e "${GREEN_COLOR}证书已就绪${RES}"
    echo -e "  证书：$CERT_DIR/fullchain.pem"
    echo -e "  私钥：$CERT_DIR/privkey.pem"

    if [ -f "$SUB_DIR/nginx.conf" ]; then
        compose --profile sub up -d sub >/dev/null 2>&1 || true
        echo -e "${GREEN_COLOR}已重启订阅容器${RES}"
    fi
    return 0
}

CERT() {
    check_root
    local mode host email
    echo -e "\n${PURPLE_COLOR}==== 申请证书（Let's Encrypt / acme.sh）====${RES}"
    echo -e "${GREEN_COLOR}1) 域名证书（HTTP-01，需要 80 端口可达）${RES}"
    echo -e "${GREEN_COLOR}2) IP 证书（Let's Encrypt shortlived，约 6 天有效，自动续期）${RES}"
    mode=$(ask_value "请选择 1=域名 2=IP" "2")

    case "$mode" in
        1) host=$(ask_value "域名（已解析到本机）" "$(env_get CERT_HOST "")") ;;
        2) host=$(ask_value "IP（回车用本机公网 IP）" "$(get_public_ip)") ;;
        *) echo -e "${RED_COLOR}无效选项${RES}"; return 1 ;;
    esac

    email=$(env_get ACME_EMAIL "")
    ISSUE_CERT "$mode" "$host" "$email" || return 1

    echo -e "${YELLOW_COLOR}下一步：sudo bash manage.sh sub 生成订阅${RES}"
}

MIHOMO_YAML() {
    local addr="$1" port="$2" uuid="$3" sni="$4" pub="$5" sid="$6" path="$7" enc="$8" name="$9"
    cat <<EOF
# ==========================================================
# mihomo (Clash.Meta) 配置 - 由 manage.sh 生成
# 节点: ${name}  |  ${addr}:${port}
# 参考模板风格: https://github.com/HenryChiao/MIHOMO_YAMLS
# ==========================================================

mixed-port: 7890
allow-lan: false
bind-address: '*'
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true
find-process-mode: 'off'
external-controller: 127.0.0.1:9090

profile:
  store-selected: true
  store-fake-ip: true

# ---------------------- 域名嗅探 ----------------------
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: false
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]

# ---------------------- DNS ----------------------
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - '*.localdomain'
    - '+.msftconnecttest.com'
    - '+.msftncsi.com'
    - '+.srv.nintendo.net'
    - '+.stun.playstation.net'
    - 'xbox.*.microsoft.com'
    - 'localhost.ptlogin2.qq.com'
    - 'time.*.com'
    - 'ntp.*.com'
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  proxy-server-nameserver:
    - https://dns.alidns.com/dns-query
  nameserver-policy:
    '+.cn':
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query

# ---------------------- 节点 ----------------------
proxies:
  - name: "${name}"
    type: vless
    server: "${addr}"
    port: ${port}
    uuid: "${uuid}"
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "${sni}"
    client-fingerprint: chrome
    network: xhttp
    reality-opts:
      public-key: "${pub}"
      short-id: "${sid}"
      # Xray 26.9.8+ 要求 REALITY 握手带 ML-KEM key share，否则服务端判为非法握手
      # （3x-ui 的 Clash 订阅里同样是这一行）
      support-x25519mlkem768: true
    xhttp-opts:
      path: "${path}"
      mode: auto
    encryption: "${enc}"

# ---------------------- 策略组 ----------------------
proxy-groups:
  - name: "默认代理"
    type: select
    proxies:
      - "自动选择"
      - "${name}"
      - DIRECT

  - name: "自动选择"
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    lazy: true
    proxies:
      - "${name}"

  - name: "全球直连"
    type: select
    proxies:
      - DIRECT
      - "默认代理"

# ---------------------- 规则集 ----------------------
rule-providers:
  cn-domain:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs"
    path: ./ruleset/cn-domain.mrs
    interval: 86400
    proxy: DIRECT

  cn-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs"
    path: ./ruleset/cn-ip.mrs
    interval: 86400
    proxy: DIRECT

  private:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs"
    path: ./ruleset/private.mrs
    interval: 86400
    proxy: DIRECT

# ---------------------- 规则 ----------------------
rules:
  - RULE-SET,private,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - RULE-SET,cn-domain,DIRECT
  - RULE-SET,cn-ip,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,默认代理
EOF
}

SUB() {
    local uuid sid xpath spx enc addr port sni token www link host sub_port name
    if [ ! -f "$DATA_DIR/keys.env" ]; then
        echo -e "${RED_COLOR}还没有节点，请先 sudo bash manage.sh install${RES}"
        return 1
    fi
    if [ ! -s "$CERT_DIR/fullchain.pem" ]; then
        echo -e "${RED_COLOR}还没有证书，先执行：sudo bash manage.sh cert${RES}"
        echo -e "${YELLOW_COLOR}（订阅走 HTTPS，没有证书 nginx 起不来）${RES}"
        return 1
    fi

    # shellcheck disable=SC1091
    . "$DATA_DIR/keys.env"

    addr=$(get_public_ip)
    port=$(env_get PORT "443")
    sni=$(env_get SNI "www.lovelive-anime.jp")
    sub_port=$(env_get SUB_PORT "8443")
    name=$(env_get NODE_NAME "Xray")
    host=$(cert_host)

    xpath="$XPATH"
    sid="$SID"
    spx="$SPX"
    enc="$ENC"
    uuid="$UUID"

    mkdir -p "$SUB_DIR/www"
    token_file="$SUB_DIR/token"
    if [ -s "$token_file" ]; then
        token=$(cat "$token_file")
    else
        token=$(printf '%s' "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)" | tr -d '-' | cut -c1-16)
        printf '%s' "$token" > "$token_file"
        chmod 600 "$token_file"
    fi

    www="$SUB_DIR/www/$token"
    mkdir -p "$www"

    link=$(printf 'vless://%s@%s:%s?encryption=%s&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%s&type=xhttp&mode=auto&path=%s#%s' \
        "$uuid" "$addr" "$port" "$enc" "$sni" "$PUB" "$sid" "$spx" \
        "$(printf '%s' "$xpath" | sed 's|/|%2F|g')" "$name")

    printf '%s' "$link" | base64 | tr -d '\n' > "$www/base64.txt"
    printf '\n' >> "$www/base64.txt"

    MIHOMO_YAML "$addr" "$port" "$uuid" "$sni" "$PUB" "$sid" "$xpath" "$enc" "$name" > "$www/mihomo.yaml"

    cat > "$SUB_DIR/nginx.conf" <<EOF
server {
    listen 8443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /usr/share/nginx/html;
    add_header Cache-Control "no-store" always;

    location / { return 404; }

    location /$token/ {
        autoindex off;
        try_files \$uri =404;
    }
}
EOF
    chmod 600 "$SUB_DIR/nginx.conf" 2>/dev/null || true

    CHECK_ENV
    echo -e "${BLUE_COLOR}启动订阅容器 ...${RES}"
    if ! compose --profile sub up -d sub; then
        echo -e "${RED_COLOR}订阅容器启动失败，看日志：docker compose --profile sub logs sub${RES}"
        return 1
    fi

    echo
    echo -e "${PURPLE_COLOR}==================================================${RES}"
    echo -e "${GREEN_COLOR}${BOLD}  订阅已就绪（HTTPS）${RES}"
    echo -e "${PURPLE_COLOR}==================================================${RES}"
    echo -e "  v2rayN / base64 订阅："
    echo -e "    ${CYAN_COLOR}https://${host}:${sub_port}/${token}/base64.txt${RES}"
    echo -e "  mihomo / Clash 订阅："
    echo -e "    ${CYAN_COLOR}https://${host}:${sub_port}/${token}/mihomo.yaml${RES}"
    echo -e "  证书：$CERT_DIR/fullchain.pem"
    echo -e "  本地文件：$www/"
    echo -e "${PURPLE_COLOR}==================================================${RES}"
    echo -e "${YELLOW_COLOR}记得放行 ${sub_port}/tcp；证书到期前 acme.sh 会自动续并重启容器${RES}"
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
        echo -e "${GREEN_COLOR}订阅（HTTPS）：${RES}"
        echo -e "${GREEN_COLOR}14、申请证书（域名 / IP，acme.sh）${RES}"
        echo -e "${GREEN_COLOR}15、生成订阅（base64 + mihomo）${RES}"
        echo -e "${GREEN_COLOR}-------------------${RES}"
        echo -e "${GREEN_COLOR}16、安装快捷命令（输入 xray 打开菜单）${RES}"
        echo -e "${GREEN_COLOR}-------------------${RES}"
        echo -e "${GREEN_COLOR}0、退出脚本${RES}"
        echo
        read -r -p "请输入选项 [0-16]: " choice

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
            14) CERT ;;
            15) SUB ;;
            16) INSTALL_CLI ;;
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
    cert)      CERT ;;
    sub)       SUB ;;
    cli)       INSTALL_CLI ;;
    status)    STATUS ;;
    start)     CHECK_ENV && compose up -d ;;
    stop)      CHECK_ENV && compose stop ;;
    restart)   CHECK_ENV && compose restart ;;
    log)       SHOW_LOG ;;
    backup)    BACKUP ;;
    ""|menu)   SHOW_MENU ;;
    *)
        echo -e "${RED_COLOR}用法：${RES}$0 [install|update|uninstall|links|client|rotate|cert|sub|cli|status|start|stop|restart|log|backup]"
        exit 1
        ;;
esac
