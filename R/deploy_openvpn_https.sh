#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# OpenVPN + TLS-encrypted HTTPS CONNECT proxy one-click installer
# Target OS: Debian 11/12/13 (systemd)
#
# Usage:
#   sudo bash deploy_openvpn_https.sh <email_address> <vpn_domain>
#
# Optional environment variables:
#   CLIENT_NAME=windows-client
#   PROXY_USER=vpnproxy
#   PROXY_PASSWORD=<strong-password>   # auto-generated when omitted
#   OPENVPN_PORT=443
#   HTTPS_PROXY_PORT=8444
#   LOCAL_PROXY_PORT=18080
#   SQUID_PORT=8000
#   VPN_SUBNET=10.8.0.0
#   VPN_NETMASK=255.255.255.0
#   DNS1=1.1.1.1
#   DNS2=1.0.0.1
#   SKIP_DNS_CHECK=0

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\033[1;31m[x]\033[0m Installation failed at line %s (exit code %s).\n' "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  printf '    Check: journalctl -u openvpn-server@server -u squid -u nghttpx --no-pager -n 100\n' >&2
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<USAGE
Usage: sudo bash $0 <email_address> <vpn_domain>

Example:
  sudo bash $0 admin@example.com vpn.example.com

The domain must already have an A record pointing to this server.
USAGE
}

[[ $# -eq 2 ]] || { usage; exit 1; }
[[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash $0 ..."

EMAIL_ADDRESS="$1"
VPN_ADDRESS="${2#http://}"
VPN_ADDRESS="${VPN_ADDRESS#https://}"
VPN_ADDRESS="${VPN_ADDRESS%%/*}"
VPN_ADDRESS="${VPN_ADDRESS%%:*}"

CLIENT_NAME="${CLIENT_NAME:-windows-client}"
PROXY_USER="${PROXY_USER:-vpnproxy}"
OPENVPN_PORT="${OPENVPN_PORT:-443}"
HTTPS_PROXY_PORT="${HTTPS_PROXY_PORT:-8444}"
LOCAL_PROXY_PORT="${LOCAL_PROXY_PORT:-18080}"
SQUID_PORT="${SQUID_PORT:-8000}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_NETMASK="${VPN_NETMASK:-255.255.255.0}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-1.0.0.1}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"

[[ "$EMAIL_ADDRESS" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Invalid email address."
[[ "$VPN_ADDRESS" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || die "Use a valid domain name, without https:// or a port."
[[ "$CLIENT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "CLIENT_NAME may contain only letters, digits, dot, underscore and hyphen."
[[ "$PROXY_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "PROXY_USER may contain only letters, digits, dot, underscore and hyphen."
for port in "$OPENVPN_PORT" "$HTTPS_PROXY_PORT" "$LOCAL_PROXY_PORT" "$SQUID_PORT"; do
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "Invalid port: $port"
done
[[ "$OPENVPN_PORT" != "$HTTPS_PROXY_PORT" ]] || die "OPENVPN_PORT and HTTPS_PROXY_PORT must be different."

if [[ -z "${PROXY_PASSWORD:-}" ]]; then
  PROXY_PASSWORD="$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"
fi
[[ ${#PROXY_PASSWORD} -ge 16 ]] || die "PROXY_PASSWORD must be at least 16 characters."
[[ "$PROXY_PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]] || die "PROXY_PASSWORD may contain only letters, digits, dot, underscore and hyphen."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || warn "This script is tested on Debian; detected ${PRETTY_NAME:-unknown}."
else
  die "Cannot identify the operating system."
fi
command -v systemctl >/dev/null 2>&1 || die "systemd is required."

export DEBIAN_FRONTEND=noninteractive

log "Installing packages"
apt-get update
printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' | debconf-set-selections
printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' | debconf-set-selections
apt-get install -y \
  openvpn easy-rsa squid nghttp2-proxy apache2-utils \
  iptables iptables-persistent iproute2 curl ca-certificates dnsutils openssl snapd

install_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    return
  fi

  log "Installing Certbot"
  systemctl enable --now snapd.socket >/dev/null 2>&1 || true
  systemctl start snapd.service >/dev/null 2>&1 || true

  local ready=0
  for _ in $(seq 1 30); do
    if snap version >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done

  if [[ "$ready" -eq 1 ]]; then
    snap list core >/dev/null 2>&1 || snap install core
    snap refresh core >/dev/null 2>&1 || true
    snap list certbot >/dev/null 2>&1 || snap install certbot --classic
    ln -sf /snap/bin/certbot /usr/local/bin/certbot
  else
    warn "snapd did not become ready; falling back to Debian's Certbot package."
    apt-get install -y certbot
  fi

  command -v certbot >/dev/null 2>&1 || die "Certbot installation failed."
}
install_certbot

# Open the required host firewall ports before ACME validation. Cloud-provider
# firewalls/security groups must still be configured separately.
iptables -C INPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
iptables -C INPUT -p tcp --dport "$OPENVPN_PORT" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport "$OPENVPN_PORT" -m conntrack --ctstate NEW -j ACCEPT
iptables -C INPUT -p tcp --dport "$HTTPS_PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport "$HTTPS_PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT
netfilter-persistent save >/dev/null
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow "$OPENVPN_PORT/tcp"
  ufw allow "$HTTPS_PROXY_PORT/tcp"
fi

DOMAIN_IP="$(getent ahostsv4 "$VPN_ADDRESS" | awk 'NR==1 {print $1}')"
PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

[[ -n "$DOMAIN_IP" ]] || die "The domain $VPN_ADDRESS has no IPv4 A record."
if [[ "$SKIP_DNS_CHECK" != "1" && -n "$PUBLIC_IP" && "$DOMAIN_IP" != "$PUBLIC_IP" ]]; then
  die "DNS mismatch: $VPN_ADDRESS resolves to $DOMAIN_IP, but this server appears to be $PUBLIC_IP. Set the A record first, or use SKIP_DNS_CHECK=1 if this server is behind NAT."
fi

listener_on_port() {
  local port="$1"
  ss -H -ltnp "sport = :$port" 2>/dev/null || true
}

OPENVPN_LISTENER="$(listener_on_port "$OPENVPN_PORT")"
if [[ -n "$OPENVPN_LISTENER" && "$OPENVPN_LISTENER" != *openvpn* ]]; then
  die "TCP port $OPENVPN_PORT is already occupied: $OPENVPN_LISTENER"
fi
HTTPS_LISTENER="$(listener_on_port "$HTTPS_PROXY_PORT")"
if [[ -n "$HTTPS_LISTENER" && "$HTTPS_LISTENER" != *nghttpx* ]]; then
  die "TCP port $HTTPS_PROXY_PORT is already occupied: $HTTPS_LISTENER"
fi

CERT_DIR="/etc/letsencrypt/live/$VPN_ADDRESS"
if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; then
  PORT80_LISTENER="$(listener_on_port 80)"
  [[ -z "$PORT80_LISTENER" ]] || die "TCP port 80 is occupied and Certbot standalone validation cannot run: $PORT80_LISTENER"

  log "Requesting a Let's Encrypt certificate for $VPN_ADDRESS"
  certbot certonly --standalone \
    --non-interactive --agree-tos \
    --email "$EMAIL_ADDRESS" \
    --preferred-challenges http \
    -d "$VPN_ADDRESS"
else
  log "Existing Let's Encrypt certificate found; reusing it"
fi

log "Creating OpenVPN PKI"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
mkdir -p "$EASYRSA_DIR"
if [[ ! -x "$EASYRSA_DIR/easyrsa" ]]; then
  cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
fi
cd "$EASYRSA_DIR"

cat > vars <<'VARS'
set_var EASYRSA_ALGO rsa
set_var EASYRSA_KEY_SIZE 3072
set_var EASYRSA_DIGEST sha256
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 825
VARS

if [[ ! -s pki/ca.crt ]]; then
  EASYRSA_BATCH=1 ./easyrsa init-pki
  EASYRSA_BATCH=1 EASYRSA_REQ_CN="$VPN_ADDRESS OpenVPN CA" ./easyrsa build-ca nopass
fi
if [[ ! -s pki/issued/server.crt || ! -s pki/private/server.key ]]; then
  EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
fi
if [[ ! -s "pki/issued/$CLIENT_NAME.crt" || ! -s "pki/private/$CLIENT_NAME.key" ]]; then
  EASYRSA_BATCH=1 ./easyrsa build-client-full "$CLIENT_NAME" nopass
fi
EASYRSA_BATCH=1 ./easyrsa gen-crl

OPENVPN_SERVER_DIR="/etc/openvpn/server"
mkdir -p "$OPENVPN_SERVER_DIR" /var/log/openvpn
install -m 0644 pki/ca.crt "$OPENVPN_SERVER_DIR/ca.crt"
install -m 0644 pki/issued/server.crt "$OPENVPN_SERVER_DIR/server.crt"
install -m 0600 pki/private/server.key "$OPENVPN_SERVER_DIR/server.key"
install -m 0644 pki/crl.pem "$OPENVPN_SERVER_DIR/crl.pem"
chown nobody:nogroup "$OPENVPN_SERVER_DIR/crl.pem" || true

if [[ ! -s "$OPENVPN_SERVER_DIR/tls-crypt.key" ]]; then
  if ! openvpn --genkey secret "$OPENVPN_SERVER_DIR/tls-crypt.key"; then
    openvpn --genkey --secret "$OPENVPN_SERVER_DIR/tls-crypt.key"
  fi
  chmod 0600 "$OPENVPN_SERVER_DIR/tls-crypt.key"
fi

cat > "$OPENVPN_SERVER_DIR/server.conf" <<EOF_SERVER
port $OPENVPN_PORT
proto tcp-server
dev tun
topology subnet
server $VPN_SUBNET $VPN_NETMASK
ifconfig-pool-persist /var/log/openvpn/ipp.txt

ca $OPENVPN_SERVER_DIR/ca.crt
cert $OPENVPN_SERVER_DIR/server.crt
key $OPENVPN_SERVER_DIR/server.key
crl-verify $OPENVPN_SERVER_DIR/crl.pem
dh none
tls-crypt $OPENVPN_SERVER_DIR/tls-crypt.key
tls-version-min 1.2
remote-cert-tls client
verify-client-cert require

# Modern AEAD ciphers supported by current OpenVPN clients.
data-ciphers AES-256-GCM:AES-128-GCM
data-ciphers-fallback AES-256-GCM
auth SHA256

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"

keepalive 10 120
tcp-nodelay
persist-key
persist-tun
user nobody
group nogroup
status /var/log/openvpn/status.log
verb 3
EOF_SERVER

log "Enabling IPv4 forwarding and NAT"
cat > /etc/sysctl.d/99-openvpn-forward.conf <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
sysctl --system >/dev/null

PUBLIC_IF="$(ip -4 route list default | awk 'NR==1 {print $5}')"
[[ -n "$PUBLIC_IF" ]] || die "Could not determine the default network interface."

iptables -C INPUT -p tcp --dport "$OPENVPN_PORT" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport "$OPENVPN_PORT" -m conntrack --ctstate NEW -j ACCEPT
iptables -C INPUT -p tcp --dport "$HTTPS_PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport "$HTTPS_PROXY_PORT" -m conntrack --ctstate NEW -j ACCEPT
iptables -C INPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
iptables -t nat -C POSTROUTING -s "$VPN_SUBNET/$VPN_NETMASK" -o "$PUBLIC_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$VPN_SUBNET/$VPN_NETMASK" -o "$PUBLIC_IF" -j MASQUERADE
iptables -C FORWARD -i tun0 -o "$PUBLIC_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i tun0 -o "$PUBLIC_IF" -j ACCEPT
iptables -C FORWARD -i "$PUBLIC_IF" -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$PUBLIC_IF" -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
netfilter-persistent save >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$OPENVPN_PORT/tcp"
  ufw allow "$HTTPS_PROXY_PORT/tcp"
  ufw allow 80/tcp
fi

log "Configuring authenticated Squid backend"
SQUID_AUTH_HELPER="$(command -v basic_ncsa_auth || true)"
if [[ -z "$SQUID_AUTH_HELPER" ]]; then
  SQUID_AUTH_HELPER="$(find /usr/lib/squid /usr/libexec/squid -type f -name basic_ncsa_auth 2>/dev/null | head -n 1 || true)"
fi
[[ -x "$SQUID_AUTH_HELPER" ]] || die "Could not locate Squid's basic_ncsa_auth helper."

install -d -m 0750 -o root -g proxy /etc/squid
htpasswd -bcB /etc/squid/htpasswd "$PROXY_USER" "$PROXY_PASSWORD" >/dev/null
chown proxy:proxy /etc/squid/htpasswd
chmod 0640 /etc/squid/htpasswd

[[ -f /etc/squid/squid.conf ]] && cp -a /etc/squid/squid.conf "/etc/squid/squid.conf.backup.$(date +%Y%m%d%H%M%S)"
cat > /etc/squid/squid.conf <<EOF_SQUID
# Local backend for nghttpx. Never expose this port publicly.
http_port 127.0.0.1:$SQUID_PORT

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

auth_param basic program $SQUID_AUTH_HELPER /etc/squid/htpasswd
auth_param basic realm Private HTTPS Proxy
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on
acl authenticated proxy_auth REQUIRED

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

cache deny all
via off
forwarded_for delete
access_log stdio:/var/log/squid/access.log
cache_log /var/log/squid/cache.log
EOF_SQUID

squid -k parse
systemctl enable squid >/dev/null
systemctl restart squid
systemctl is-active --quiet squid || die "Squid failed to start."

log "Configuring TLS frontend with nghttpx"
NGHTTPX_BIN="$(command -v nghttpx)"
[[ -x "$NGHTTPX_BIN" ]] || die "nghttpx binary not found."
id -u nghttpx >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin nghttpx
install -d -m 0755 /etc/nghttpx

cat > /etc/nghttpx/nghttpx.conf <<EOF_NGHTTPX
frontend=0.0.0.0,$HTTPS_PROXY_PORT
backend=127.0.0.1,$SQUID_PORT
http2-proxy=yes
private-key-file=$CERT_DIR/privkey.pem
certificate-file=$CERT_DIR/fullchain.pem
tls-min-proto-version=TLSv1.2
tls-max-proto-version=TLSv1.3
backend-address-family=IPv4
no-via=yes
user=nghttpx
workers=2
EOF_NGHTTPX

cat > /etc/systemd/system/nghttpx.service <<EOF_UNIT
[Unit]
Description=nghttpx TLS HTTPS forward proxy frontend
After=network-online.target squid.service
Wants=network-online.target
Requires=squid.service

[Service]
Type=simple
ExecStart=$NGHTTPX_BIN --conf=/etc/nghttpx/nghttpx.conf
Restart=on-failure
RestartSec=3s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_UNIT

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-nghttpx.sh <<'EOF_HOOK'
#!/bin/sh
systemctl restart nghttpx.service
EOF_HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/restart-nghttpx.sh

systemctl daemon-reload
systemctl enable nghttpx >/dev/null
systemctl restart nghttpx
systemctl is-active --quiet nghttpx || die "nghttpx failed to start."

log "Starting OpenVPN"
systemctl enable openvpn-server@server >/dev/null
systemctl restart openvpn-server@server
systemctl is-active --quiet openvpn-server@server || die "OpenVPN failed to start."

log "Generating Windows client bundle"
BUNDLE_DIR="/root/openvpn-https-$CLIENT_NAME"
rm -rf "$BUNDLE_DIR"
install -d -m 0700 "$BUNDLE_DIR"

CLIENT_CA="$EASYRSA_DIR/pki/ca.crt"
CLIENT_CERT="$EASYRSA_DIR/pki/issued/$CLIENT_NAME.crt"
CLIENT_KEY="$EASYRSA_DIR/pki/private/$CLIENT_NAME.key"
TLS_CRYPT_KEY="$OPENVPN_SERVER_DIR/tls-crypt.key"

write_ovpn_common() {
  local output="$1"
  local use_https_proxy="$2"
  cat > "$output" <<EOF_OVPN
client
dev tun
proto tcp-client
remote $VPN_ADDRESS $OPENVPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server name
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
data-ciphers-fallback AES-256-GCM
auth SHA256
auth-nocache
pull
block-outside-dns
verb 3
EOF_OVPN

  if [[ "$use_https_proxy" == "yes" ]]; then
    cat >> "$output" <<EOF_PROXY

# OpenVPN itself only supports a cleartext HTTP CONNECT proxy.
# sing-box converts this local connection to the TLS-encrypted HTTPS proxy.
http-proxy 127.0.0.1 $LOCAL_PROXY_PORT
http-proxy-option VERSION 1.1
route $DOMAIN_IP 255.255.255.255 net_gateway
EOF_PROXY
  fi

  {
    printf '\n<ca>\n'
    cat "$CLIENT_CA"
    printf '</ca>\n<cert>\n'
    sed -ne '/-----BEGIN CERTIFICATE-----/,$p' "$CLIENT_CERT"
    printf '</cert>\n<key>\n'
    cat "$CLIENT_KEY"
    printf '</key>\n<tls-crypt>\n'
    cat "$TLS_CRYPT_KEY"
    printf '</tls-crypt>\n'
  } >> "$output"
  chmod 0600 "$output"
}

write_ovpn_common "$BUNDLE_DIR/$CLIENT_NAME-direct.ovpn" no
write_ovpn_common "$BUNDLE_DIR/$CLIENT_NAME-via-https.ovpn" yes

cat > "$BUNDLE_DIR/sing-box.json" <<EOF_SINGBOX
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "http",
      "tag": "local-http",
      "listen": "127.0.0.1",
      "listen_port": $LOCAL_PROXY_PORT
    }
  ],
  "outbounds": [
    {
      "type": "http",
      "tag": "https-upstream",
      "server": "$VPN_ADDRESS",
      "server_port": $HTTPS_PROXY_PORT,
      "username": "$PROXY_USER",
      "password": "$PROXY_PASSWORD",
      "tls": {
        "enabled": true,
        "server_name": "$VPN_ADDRESS"
      }
    }
  ],
  "route": {
    "final": "https-upstream"
  }
}
EOF_SINGBOX
chmod 0600 "$BUNDLE_DIR/sing-box.json"

cat > "$BUNDLE_DIR/start-https-proxy.bat" <<'EOF_BAT'
@echo off
setlocal
cd /d "%~dp0"
where sing-box.exe >nul 2>&1
if errorlevel 1 (
  echo sing-box.exe was not found in PATH.
  echo Install sing-box with: winget install sing-box
  echo Then reopen this window and run the file again.
  pause
  exit /b 1
)
sing-box.exe check -c sing-box.json
if errorlevel 1 (
  echo Invalid sing-box configuration.
  pause
  exit /b 1
)
echo Local HTTP proxy is starting on 127.0.0.1. Keep this window open.
sing-box.exe run -c sing-box.json
pause
EOF_BAT

cat > "$BUNDLE_DIR/proxy-credentials.txt" <<EOF_CREDS
HTTPS proxy: https://$VPN_ADDRESS:$HTTPS_PROXY_PORT
Username: $PROXY_USER
Password: $PROXY_PASSWORD
Local bridge: http://127.0.0.1:$LOCAL_PROXY_PORT
EOF_CREDS
chmod 0600 "$BUNDLE_DIR/proxy-credentials.txt"

cat > "$BUNDLE_DIR/README-Windows.txt" <<EOF_README
OpenVPN + HTTPS client instructions
===================================

Direct OpenVPN:
1. Install OpenVPN Connect or OpenVPN GUI.
2. Import: $CLIENT_NAME-direct.ovpn
3. Connect. All IPv4 traffic is routed through the VPN.

OpenVPN through the TLS-encrypted HTTPS proxy:
1. Install sing-box:
   winget install sing-box
2. Run start-https-proxy.bat and keep its window open.
3. Import: $CLIENT_NAME-via-https.ovpn
4. Connect OpenVPN.

Architecture:
Windows OpenVPN -> local sing-box 127.0.0.1:$LOCAL_PROXY_PORT
-> TLS HTTPS CONNECT proxy $VPN_ADDRESS:$HTTPS_PROXY_PORT
-> OpenVPN server $VPN_ADDRESS:$OPENVPN_PORT
-> Internet

Important:
- The via-HTTPS mode uses TCP inside TCP. It is more compatible with restrictive
  networks, but usually slower than direct OpenVPN.
- The server A record currently resolved to: $DOMAIN_IP
- If the server IP changes, update the explicit route line inside the via-HTTPS
  .ovpn profile.
- Keep this bundle private. It contains a client private key and proxy password.
EOF_README

BUNDLE_ARCHIVE="/root/${VPN_ADDRESS}-${CLIENT_NAME}-openvpn-https.tar.gz"
tar -C /root -czf "$BUNDLE_ARCHIVE" "$(basename "$BUNDLE_DIR")"
chmod 0600 "$BUNDLE_ARCHIVE"

# Local tests. The HTTPS proxy test is allowed to fail when the provider blocks
# hairpin access to its own public IP; external clients can still work.
log "Running service checks"
ss -ltnp | grep -E ":($OPENVPN_PORT|$HTTPS_PROXY_PORT|$SQUID_PORT)\\b" || true
curl -fsS --max-time 15 \
  --proxy "https://$PROXY_USER:$PROXY_PASSWORD@$VPN_ADDRESS:$HTTPS_PROXY_PORT" \
  https://api.ipify.org >/tmp/openvpn-https-proxy-test.txt 2>/dev/null || \
  warn "The local HTTPS proxy hairpin test did not complete. Test it from Windows after downloading the bundle."

cat <<EOF_DONE

============================================================
Deployment completed
============================================================
OpenVPN server:       tcp://$VPN_ADDRESS:$OPENVPN_PORT
HTTPS CONNECT proxy:  https://$VPN_ADDRESS:$HTTPS_PROXY_PORT
Proxy username:       $PROXY_USER
Proxy password:       $PROXY_PASSWORD
VPN subnet:           $VPN_SUBNET/$VPN_NETMASK
Public interface:     $PUBLIC_IF

Windows client bundle:
  $BUNDLE_ARCHIVE

Download it from your PC, for example:
  scp root@$VPN_ADDRESS:$BUNDLE_ARCHIVE .

Service checks:
  systemctl status openvpn-server@server squid nghttpx --no-pager
  journalctl -u openvpn-server@server -u squid -u nghttpx -n 100 --no-pager

Cloud firewall/security group must allow TCP ports:
  80, $OPENVPN_PORT, $HTTPS_PROXY_PORT
============================================================
EOF_DONE
