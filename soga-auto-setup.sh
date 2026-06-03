#!/bin/bash
# soga 自动化部署脚本
#
# 用法 1（交互式，弹问题）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/accfw87/test/main/soga-auto-setup.sh)
#
# 用法 2（环境变量预设，全自动）:
#   NODE_ID=5 CERT_DOMAIN=th.nodedjdom.shop \
#   OUT_SERVER=hkdns.nodedjdom.shop OUT_PORT=28026 OUT_PASSWORD=xxx \
#   bash <(curl -fsSL https://raw.githubusercontent.com/accfw87/test/main/soga-auto-setup.sh)
#
# 用法 3（先下载再运行）:
#   curl -fsSL -o setup.sh URL && bash setup.sh

set -e

# ============== 颜色输出 ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${BLUE}========== $1 ==========${NC}"; }

# ============== 处理 stdin 重定向（核心修复） ==============
# 当用 bash <(curl ...) 跑时，stdin 是脚本内容本身，read 会读到脚本剩余字节
# 解决：把 stdin 重定向到 /dev/tty（控制终端），让 read 正常读用户输入
if [ -t 0 ]; then
    : # stdin 是终端，正常情况
elif [ -e /dev/tty ]; then
    exec < /dev/tty
    info "Stdin 已重定向到 /dev/tty（兼容 bash <(curl ...) 模式）"
else
    # 没有 tty（如 cron / docker -d）, 必须用环境变量
    warn "未检测到 tty，将仅从环境变量读取参数"
    NON_INTERACTIVE=1
fi

# ============== Step 0: 架构检查 ==============
step "Step 0: 检查 CPU 架构"
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    error "本脚本仅支持 x86_64 架构，当前为: $ARCH"
    error "patch.py 不支持 ARM 架构，请更换 x86_64 VPS"
    exit 1
fi
info "架构检查通过: $ARCH ✓"

# ============== 必备工具检查 ==============
for cmd in curl python3 systemctl; do
    if ! command -v $cmd &> /dev/null; then
        error "缺少必备工具: $cmd，请先安装"
        exit 1
    fi
done

# ============== 收集用户输入（环境变量优先，缺失则问） ==============
step "收集配置信息（环境变量优先）"

ask() {
    local var_name=$1
    local prompt=$2
    local default=$3        # 第 3 个参数：默认值（可选）
    local current="${!var_name}"

    # 已经有环境变量值，直接用
    if [ -n "$current" ]; then
        info "$var_name = $current (来自环境变量)"
        return
    fi

    # 没有环境变量 → 看是否非交互模式
    if [ "$NON_INTERACTIVE" = "1" ]; then
        if [ -n "$default" ]; then
            eval "$var_name='$default'"
            info "$var_name = $default (使用默认值)"
        else
            error "缺少环境变量 $var_name 且无默认值，又没有 tty 可交互输入"
            exit 1
        fi
        return
    fi

    # 交互模式：提示用户输入，回车留空则用默认值
    local value
    if [ -n "$default" ]; then
        read -p "$prompt [回车=默认: $default]: " value
        value="${value:-$default}"   # 空则用默认
    else
        read -p "$prompt: " value
    fi
    eval "$var_name=\"\$value\""
}

ask NODE_ID       "请输入 node_id (面板里的节点ID)"
ask CERT_DOMAIN   "请输入 cert_domain (节点域名, 如 hk.nodedjdom.shop)"

# ============== 选择 DNS 解锁区域（菜单式） ==============
echo ""
echo "--- 配置 routes.toml 出站 (第 287-293 行) ---"
echo "请选择 DNS 解锁区域："
echo "  1) 香港   (hkdns.nodedjdom.shop:28026)"
echo "  2) 日本   (jpdns.nodedjdom.shop:48186)"
echo "  3) 美国   (usdns.nodedjdom.shop:29768)"
echo "  4) 英国   (ukdns.nodedjdom.shop:25184)"
echo "  5) 新加坡 (sgdns.nodedjdom.shop:39884)"
echo "  6) 台湾   (twdns.nodedjdom.shop:20944)"
echo "  7) 韩国   (krdns.nodedjdom.shop:39561)"

# 支持环境变量 REGION 预设，否则交互问
if [ -z "$REGION" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        error "缺少环境变量 REGION (1-6)，且无 tty 可交互输入"
        exit 1
    fi
    read -p "请选择 [回车=默认: 1 香港]: " REGION
    REGION="${REGION:-1}"
fi

case "$REGION" in
    1|hk|HK|香港)
        OUT_SERVER="hkdns.nodedjdom.shop"
        OUT_PORT="28026"
        OUT_PASSWORD="9d7f1e1e470cf545"
        REGION_NAME="香港"
        ;;
    2|jp|JP|日本)
        OUT_SERVER="jpdns.nodedjdom.shop"
        OUT_PORT="48186"
        OUT_PASSWORD="df614c8bb4466ae1"
        REGION_NAME="日本"
        ;;
    3|us|US|美国)
        OUT_SERVER="usdns.nodedjdom.shop"
        OUT_PORT="29768"
        OUT_PASSWORD="64d53e68eaae4733"
        REGION_NAME="美国"
        ;;
    4|uk|UK|英国)
        OUT_SERVER="ukdns.nodedjdom.shop"
        OUT_PORT="25184"
        OUT_PASSWORD="2e8a1480303d4ee9"
        REGION_NAME="英国"
        ;;
    5|sg|SG|新加坡)
        OUT_SERVER="sgdns.nodedjdom.shop"
        OUT_PORT="39884"
        OUT_PASSWORD="9eeffd23fc516fa2"
        REGION_NAME="新加坡"
        ;;
    6|tw|TW|台湾)
        OUT_SERVER="twdns.nodedjdom.shop"
        OUT_PORT="20944"
        OUT_PASSWORD="bfb08a5596498d3c"
        REGION_NAME="台湾"
        ;;
    7|kr|KR|韩国)
        OUT_SERVER="krdns.nodedjdom.shop"
        OUT_PORT="39561"
        OUT_PASSWORD="e5bb7a086e3b2ec4"
        REGION_NAME="韩国"
        ;;
    *)
        error "无效选择: $REGION，必须是 1-7"
        exit 1
        ;;
esac

info "已选择: $REGION_NAME"
info "  出站 server   = $OUT_SERVER"
info "  出站 port     = $OUT_PORT"
info "  出站 password = $OUT_PASSWORD"

# 简单校验
if [ -z "$NODE_ID" ] || [ -z "$CERT_DOMAIN" ] || [ -z "$OUT_SERVER" ] || [ -z "$OUT_PORT" ] || [ -z "$OUT_PASSWORD" ]; then
    error "有字段为空，退出"
    exit 1
fi

# ============== Step 1: 安装 soga ==============
step "Step 1/4: 安装 soga v2.13.7"
bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/soga/master/install.sh) 2.13.7
info "soga 安装完成 ✓"

# uname -m 已经在 Step 0 确认是 x86_64，install.sh 会按架构下载，相信它

# ============== Step 2: 下载并应用 patch ==============
step "Step 2/4: 下载并应用 patch.py"

# 必须先停 soga 才能 patch
soga stop default 2>/dev/null || systemctl stop soga 2>/dev/null || true
sleep 2

curl -fsSL -o /usr/local/soga/patch.py \
    https://raw.githubusercontent.com/accfw87/test/main/patch.py
info "patch.py 下载完成 ✓"

# 先验证一下是否已经 patched
if python3 /usr/local/soga/patch.py /usr/local/soga/soga --verify 2>&1 | grep -q "WRAPPER OK"; then
    warn "二进制已经是 patched 状态，跳过 patch"
else
    info "正在 patch 二进制..."
    python3 /usr/local/soga/patch.py /usr/local/soga/soga
    info "patch 完成 ✓"
fi

# ============== Step 3: 下载并配置 soga.conf ==============
step "Step 3/4: 下载并配置 soga.conf"

curl -fsSL -o /etc/soga/soga.conf \
    https://raw.githubusercontent.com/accfw87/test/main/soga.conf
info "soga.conf 下载完成 ✓"

# 替换 node_id 和 cert_domain
sed -i "s|^node_id=.*|node_id=$NODE_ID|" /etc/soga/soga.conf
sed -i "s|^cert_domain=.*|cert_domain=$CERT_DOMAIN|" /etc/soga/soga.conf
info "已配置 node_id=$NODE_ID, cert_domain=$CERT_DOMAIN ✓"

# ============== Step 4: 下载并配置 routes.toml ==============
step "Step 4/4: 下载并配置 routes.toml"

curl -fsSL -o /etc/soga/routes.toml \
    https://raw.githubusercontent.com/accfw87/test/main/routes.toml
info "routes.toml 下载完成 ✓"

# 替换 287-293 行的 server / port / password
sed -i "287,293{
    s|^server=.*|server=\"$OUT_SERVER\"|
    s|^port=.*|port=$OUT_PORT|
    s|^password=.*|password=\"$OUT_PASSWORD\"|
}" /etc/soga/routes.toml
info "已配置出站 server=$OUT_SERVER, port=$OUT_PORT ✓"

# ============== 启动并显示日志 ==============
step "重启 soga 并查看日志"
systemctl restart soga
sleep 3

info "soga 已重启，下面是实时日志（Ctrl+C 退出查看，soga 仍在跑）"
echo "--------------------------------------------"
sleep 1

# 用 soga 管理脚本，失败则用 journalctl
if command -v soga &> /dev/null; then
    soga log default -f
else
    journalctl -u soga -f
fi
