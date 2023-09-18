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
sudo iptables -A INPUT -p udp -m udp --dport 8443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# 保存生效
iptables-save

# 颁发证书
yes | sudo certbot certonly --standalone --email 1105470619@qq.com -d chatone.chengff.com --agree-tos

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
echo "frontend=*,8443

backend=127.0.0.1,8000

private-key-file=/etc/letsencrypt/live/chatone.chengff.com/privkey.pem

certificate-file=/etc/letsencrypt/live/chatone.chengff.com/fullchain.pem

http2-proxy=yes

tls-proto-list=TLSv1.3" > /etc/nghttpx/nghttpx.conf

# 重启服务
## 开放端口
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 80 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 443 -j ACCEPT
sudo iptables -A INPUT -p udp -m udp --dport 8443 -j ACCEPT

# 启动squid和nghttpx
systemctl restart squid
systemctl stop nghttpx
nohup nghttpx >/dev/null 2>&1 &



