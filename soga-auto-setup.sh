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
    local current="${!var_name}"
    if [ -z "$current" ]; then
        if [ "$NON_INTERACTIVE" = "1" ]; then
            error "缺少环境变量 $var_name，且无 tty 可交互输入"
            exit 1
        fi
        read -p "$prompt: " value
        eval "$var_name='$value'"
    else
        info "$var_name = $current (来自环境变量)"
    fi
}

ask NODE_ID       "请输入 node_id (面板里的节点ID)"
ask CERT_DOMAIN   "请输入 cert_domain (节点域名, 如 tw.example.com)"
echo ""
echo "--- 配置 routes.toml 出站 (第 287-293 行) ---"
ask OUT_SERVER    "出站 server (如 hkdns.nodedjdom.shop)"
ask OUT_PORT      "出站 port"
ask OUT_PASSWORD  "出站 password"

# 简单校验
if [ -z "$NODE_ID" ] || [ -z "$CERT_DOMAIN" ] || [ -z "$OUT_SERVER" ] || [ -z "$OUT_PORT" ] || [ -z "$OUT_PASSWORD" ]; then
    error "有字段为空，退出"
    exit 1
fi

# ============== Step 1: 安装 soga ==============
step "Step 1/4: 安装 soga v2.13.7"
bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/soga/master/install.sh) 2.13.7
info "soga 安装完成 ✓"

# 检查二进制是否是 x86_64（防止 install.sh 装了 ARM 版）
if ! file /usr/local/soga/soga | grep -q "x86-64"; then
    error "/usr/local/soga/soga 不是 x86_64 二进制，patch.py 无法使用"
    exit 1
fi

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
