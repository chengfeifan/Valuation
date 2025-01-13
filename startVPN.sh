#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <email_address> <vpn_address>"
    exit 1
fi

# Assign the input variables
EMAIL_ADDRESS=$1
VPN_ADDRESS=$2

# System: Debian
# get certbot install
sudo apt update
sudo apt -y install snapd
sudo snap install core
sudo snap install certbot --classic
sudo ln -s /snap/bin/certbot /usr/bin/certbot

# 安装apache2
sudo apt-get -y install apache2
systemctl start apache2
systemctl stop apache2


# 开放端口
# 使用iptables 开放：80,443,8443端口
sudo iptables -A INPUT -p udp -m udp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 8444 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 8444 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# 保存生效
iptables-save

# 颁发证书
echo "yes | sudo certbot certonly --standalone --email $EMAIL_ADDRESS -d $VPN_ADDRESS --agree-tos"

# 安装squid和nghttpx
sudo apt-get -y install squid
sudo apt-get -y install nghttp2

# 更改配置文件
## squid.conf
echo "# [HTTP2 Proxy Backend]

http_access allow localhost

http_port 127.0.0.1:8000

# No cache and log

cache deny all

access_log none

# Prefer IPv4 sites

dns_v4_first on

# No via header

via off

# No x-forwarded-for header

forwarded_for delete" >> /etc/squid/squid.conf

## nghttpx.conf
echo "frontend=*,8444

backend=127.0.0.1,8000

echo "private-key-file=/etc/letsencrypt/live/$VPN_ADDRESS/privkey.pem"

certificate-file=/etc/letsencrypt/live/$VPN_ADDRESS/fullchain.pem

http2-proxy=yes

tls-proto-list=TLSv1.3" > /etc/nghttpx/nghttpx.conf

# 重启服务
## 开放端口
sudo iptables -I INPUT -p tcp --dport 8444 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 8444 -j ACCEPT

# 启动squid和nghttpx
systemctl restart squid
systemctl stop nghttpx
nohup nghttpx >/dev/null 2>&1 &



