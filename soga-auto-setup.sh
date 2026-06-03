#!/bin/bash
# soga 自动化部署脚本
# 用法: bash soga-auto-setup.sh

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

# ============== 收集用户输入（开头一次性问完）==============
step "收集配置信息"
read -p "请输入 node_id (面板里的节点ID): " NODE_ID
read -p "请输入 cert_domain (节点域名, 如 tw.example.com): " CERT_DOMAIN
echo ""
echo "--- 现在配置 routes.toml 里的出站 (第 287-293 行) ---"
read -p "请输入出站 server (如 hkdns.nodedjdom.shop): " OUT_SERVER
read -p "请输入出站 port: " OUT_PORT
read -p "请输入出站 password: " OUT_PASSWORD

# 简单校验
if [ -z "$NODE_ID" ] || [ -z "$CERT_DOMAIN" ] || [ -z "$OUT_SERVER" ] || [ -z "$OUT_PORT" ] || [ -z "$OUT_PASSWORD" ]; then
    error "有字段为空，请重新填写"
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

# 下载 patch.py（用 raw 链接，不是 blob）
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

info "soga 已重启，下面是实时日志（Ctrl+C 退出查看，但 soga 仍在跑）"
echo "--------------------------------------------"
sleep 1

# 尝试用 soga 管理脚本查看日志，失败则用 journalctl
if command -v soga &> /dev/null; then
    soga log default -f
else
    journalctl -u soga -f
fi
