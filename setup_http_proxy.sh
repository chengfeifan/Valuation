#!/usr/bin/env bash
set -Eeuo pipefail

# 用法：
# sudo bash setup_http_proxy.sh <允许访问的客户端IP或网段>
# 示例：
# sudo bash setup_http_proxy.sh 1.2.3.4/32
# 或允许整个 OpenVPN 网段：
# sudo bash setup_http_proxy.sh 10.8.0.0/24

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <allowed_client_ip_or_cidr>"
    exit 1
fi

ALLOWED_CLIENT="$1"
PROXY_PORT=3128
SQUID_CONF="/etc/squid/squid.conf"

# 安装 Squid 和防火墙规则持久化工具
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y squid iptables-persistent

# 备份原配置
sudo cp "$SQUID_CONF" \
    "${SQUID_CONF}.bak.$(date +%Y%m%d%H%M%S)"

# 写入 HTTP 代理配置
sudo tee "$SQUID_CONF" > /dev/null <<EOF
# HTTP forward proxy
http_port ${PROXY_PORT}

# 仅允许指定客户端访问，避免成为开放代理
acl allowed_client src ${ALLOWED_CLIENT}

http_access allow allowed_client
http_access deny all

# 不缓存内容，仅作为代理使用
cache deny all
EOF

# 检查 Squid 配置
sudo squid -k parse

# 只开放代理端口给指定客户端
if ! sudo iptables -C INPUT -p tcp -s "$ALLOWED_CLIENT" \
    --dport "$PROXY_PORT" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -p tcp -s "$ALLOWED_CLIENT" \
        --dport "$PROXY_PORT" -j ACCEPT
fi

# 保存防火墙规则
sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null

# 启动并设置开机启动
sudo systemctl enable --now squid
sudo systemctl restart squid

echo "HTTP proxy started successfully."
echo "Proxy server: $(hostname -I | awk '{print $1}')"
echo "Proxy port: ${PROXY_PORT}"
echo "Allowed client: ${ALLOWED_CLIENT}"
