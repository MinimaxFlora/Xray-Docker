#!/bin/bash
###############################################################################
#
# Xray Docker 一键安装（bootstrap）
#
# 用法（不需要 git）:
#   curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/Xray-Docker/main/install.sh -o /tmp/xray-install.sh
#   sudo bash /tmp/xray-install.sh
#
# 全自动（默认 443 + www.lovelive-anime.jp，不问问题）:
#   curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/Xray-Docker/main/install.sh | sudo bash -s -- --auto
#
# 它做三件事：
#   1. 没有 Docker 就用官方脚本安装（https://get.docker.com）
#   2. 用 curl 只下载 docker-compose.yml + manage.sh + .env 到 /root/Xray-Docker（不依赖 git）
#   3. 交给 manage.sh install：拉镜像 → 起容器 → 打印链接/二维码/client.json
#
# 可覆盖：
#   XRAY_HOME=/opt/xray     安装目录（默认 /root/Xray-Docker）
#   XRAY_BRANCH=main        分支
#
###############################################################################

set -uo pipefail

RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
BLUE='\e[1;34m'
CYAN='\e[1;36m'
RES='\e[0m'

info() { printf "${CYAN}[信息]${RES} %s\n" "$*"; }
ok()   { printf "${GREEN}[成功]${RES} %s\n" "$*"; }
warn() { printf "${YELLOW}[警告]${RES} %s\n" "$*"; }
die()  { printf "${RED}[错误]${RES} %s\n" "$*" >&2; exit 1; }

REPO="MinimaxFlora/Xray-Docker"
BRANCH="${XRAY_BRANCH:-main}"
TARGET="${XRAY_HOME:-/root/Xray-Docker}"
AUTO=0

for arg in "$@"; do
    case "$arg" in
        --auto|-y|--yes) AUTO=1 ;;
    esac
done

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# `curl ... | sudo bash` 会把脚本塞进 sudo 的 stdin，导致后面的交互读不到输入（会卡死）。
# 这种用法只允许配 --auto；否则直接提示正确的命令。
if [ ! -t 0 ] && [ "$AUTO" != "1" ]; then
    cat >&2 <<'EOM'

检测到通过管道执行（curl ... | bash）：这种模式下终端输入到不了脚本，交互会卡住。

请改用下面任意一种：

  1) 下载后执行（可以正常回答端口/域名/邮箱等问题）
     curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/Xray-Docker/main/install.sh -o /tmp/xray-install.sh
     sudo bash /tmp/xray-install.sh

  2) 全自动，不提问（默认 443 + www.lovelive-anime.jp）
     curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/Xray-Docker/main/install.sh | sudo bash -s -- --auto

EOM
    exit 1
fi

# ---------------------------------------------------------------- Docker
install_docker() {
    info "未检测到 Docker，使用官方脚本安装（https://get.docker.com）..."
    if ! command -v curl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl ca-certificates >/dev/null 2>&1
        fi
    fi
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法继续"

    curl -fsSL https://get.docker.com | sh || die "Docker 安装失败，请手动安装后重试"

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
    docker info >/dev/null 2>&1 || die "Docker 已安装但守护进程没起来（尝试 systemctl start docker）"
}

if ! command -v docker >/dev/null 2>&1; then
    if [ "$AUTO" = "1" ]; then
        install_docker
    else
        # 管道安装时 stdin 不是终端，问也问不出来；直接按“是”处理，避免卡住
        if [ ! -t 0 ]; then
            warn "非交互执行，直接使用官方脚本安装 Docker"
            install_docker
        else
            printf "${YELLOW}未检测到 Docker。${RES}是否用官方脚本自动安装？[Y/n]: "
            read -r answer || answer=""
            case "$answer" in
                [nN]|[nN][oO]) die "已取消。请先安装 Docker：https://docs.docker.com/engine/install/" ;;
                *) install_docker ;;
            esac
        fi
    fi
else
    info "已安装 Docker：$(docker --version)"
fi

# compose 插件
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    info "安装 compose 插件..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 >/dev/null 2>&1 \
            || DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker-compose-plugin >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker-compose-plugin >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache docker-cli-compose >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------- 只下需要的文件
# 不需要 git clone，也不要整包 tar：真正要用的只有 docker-compose.yml + manage.sh
# （.env 只是默认值，已存在就不覆盖，避免冲掉你的端口/域名配置）
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
info "下载配置到 $TARGET"
mkdir -p "$TARGET"

for f in docker-compose.yml manage.sh; do
    curl -fL --retry 3 --connect-timeout 15 "${BASE_URL}/${f}" -o "$TARGET/${f}" \
        || die "下载 ${f} 失败"
done

if [ -f "$TARGET/.env" ]; then
    info "保留已有的 .env：$TARGET/.env"
else
    curl -fL --retry 3 --connect-timeout 15 "${BASE_URL}/.env" -o "$TARGET/.env" \
        || die "下载 .env 失败"
    chmod 600 "$TARGET/.env"
fi

chmod +x "$TARGET/manage.sh" 2>/dev/null || true
ok "文件已就位：$TARGET（docker-compose.yml / manage.sh / .env）"

# ---------------------------------------------------------------- 交给 manage.sh
cd "$TARGET" || die "无法进入 $TARGET"

if [ "$AUTO" = "1" ]; then
    exec env NONINTERACTIVE=1 bash "$TARGET/manage.sh" install
else
    exec bash "$TARGET/manage.sh" install
fi
