# 开放端口
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables-save

# 启动squid 和 nghttpx
systemctl start squid
nohup nghttpx >/dev/null 2>&1 &

# 更新证书
sudo certbot certonly --standalone --email 1105470619@qq.com -d jtest.chengfeifan.com --agree-tos