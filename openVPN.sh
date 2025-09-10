#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <email_address> <vpn_address>"
    exit 1
fi

# Assign the input variables
EMAIL_ADDRESS=$1
VPN_ADDRESS=$2

# 开放端口
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables-save

# 启动squid 和 nghttpx
systemctl start squid
nohup nghttpx >/dev/null 2>&1 &

# 更新证书
sudo certbot certonly --standalone --email $EMAIL_ADDRESS -d $VPN_ADDRESS --agree-tos
